import Foundation
import BoneRemoteSyncCore

/// Worker retains the open file until the source actor checks its session generation and installs.
final class DAVPreparedDownload: @unchecked Sendable {
    let entry: RemoteEntry
    let handle: FileHandle
    init(entry: RemoteEntry, handle: FileHandle) { self.entry = entry; self.handle = handle }
    deinit { try? handle.close() }
}

/// Non-actor async work runs off the source actor; one worker exclusively owns its destination.
enum DAVDownloadWorker {
    static func run(session: DAVHTTPSession, request: URLRequest, entry: RemoteEntry, target: WebDAVDownloadTarget,
                    options: RemoteDownloadOptions, offset: Int64, path: String,
                    retryPolicy: WebDAVRetryPolicy = .none, scope: DAVOperationScope) async throws -> DAVPreparedDownload {
        try await scope.run {
            try await DAVRetryExecutor.run(policy: retryPolicy, scope: scope, runtime: scope.runtime) { _ in
                try await runOnce(session: session, request: request, entry: entry, target: target,
                                  options: options, offset: offset, path: path, runtime: scope.runtime)
            }
        }
    }

    private static func runOnce(session: DAVHTTPSession, request: URLRequest, entry: RemoteEntry, target: WebDAVDownloadTarget,
                               options: RemoteDownloadOptions, offset: Int64, path: String, runtime: DAVRetryRuntime) async throws -> DAVPreparedDownload {
        let stream = try await DAVHTTP.stream(session: session, request: request)
        defer { stream.cancel() }
        let response = stream.response
        try Task.checkCancellation()
        let validated = try DAVDownloadResponse(response: response, entry: entry, options: options, offset: offset, path: path, now: runtime.wallNow())
        let expectedSize = validated.expectedSize
        let rangeLength = validated.rangeLength
        let etag = validated.etag
        // 状态、ETag 和 Range 全部验证之后才触碰 part。
        try target.validate(overwrite: options.overwrite, offset: offset)
        do {
        let output = try target.open(offset: offset)
        var handedOff = false
        defer { if !handedOff { try? output.close() } }
        var written = offset
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        options.reportTransferred(written, total: expectedSize)
        while let chunk = try await stream.next() {
            try Task.checkCancellation()
            var position = 0
            while position < chunk.count {
                let count = min(64 * 1024 - buffer.count, chunk.count - position)
                buffer.append(chunk.subdata(in: position..<(position + count)))
                position += count
                if buffer.count == 64 * 1024 {
                    try Task.checkCancellation()
                    if let expectedSize, options.verifySize || offset > 0, written > expectedSize - Int64(buffer.count) {
                        throw RemoteSyncError.integrityMismatch(path: path)
                    }
                    try output.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    options.reportTransferred(written, total: expectedSize)
                }
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty {
            if let expectedSize, options.verifySize || offset > 0, written > expectedSize - Int64(buffer.count) {
                throw RemoteSyncError.integrityMismatch(path: path)
            }
            try output.write(contentsOf: buffer)
            written += Int64(buffer.count)
            options.reportTransferred(written, total: expectedSize)
        }
        try Task.checkCancellation()
        if let rangeLength, written - offset != rangeLength { throw RemoteSyncError.integrityMismatch(path: path) }
        if let expectedSize, options.verifySize || offset > 0, written != expectedSize { throw RemoteSyncError.integrityMismatch(path: path) }
        try output.synchronize()
        try Task.checkCancellation()
        let result = RemoteEntry(id: RemotePath.relative(path), path: path, name: RemotePath.name(of: path), type: .file,
            size: written, modifiedAt: response.value(forHTTPHeaderField: "Last-Modified").flatMap(DAVHTTPDate.parse) ?? entry.modifiedAt,
            etag: etag, contentType: response.mimeType ?? entry.contentType, createdAt: entry.createdAt)
        handedOff = true
        return DAVPreparedDownload(entry: result, handle: output)
        } catch { throw DAVRequestFailure.nonRetryable(error) }
    }

}
