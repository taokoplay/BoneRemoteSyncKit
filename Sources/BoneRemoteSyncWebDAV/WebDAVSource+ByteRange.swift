import Foundation
import BoneRemoteSyncCore

extension WebDAVSource: RemoteByteRangeSource {
    public nonisolated func byteRangeVersion(for entry: RemoteEntry) -> String? {
        guard !entry.isDirectory, let size = entry.size, size > 0,
              let etag = entry.etag, Self.isStrongETag(etag) else { return nil }
        return etag
    }

    public func readBytes(_ entry: RemoteEntry, range: RemoteByteRange,
                          requiringVersion: String) async throws -> Data {
        let (session, generation) = try context()
        guard let version = byteRangeVersion(for: entry) else { throw RemoteByteRangeError.unavailable }
        let path = RemotePath.normalize(entry.path ?? "/" + entry.id)
        guard version == requiringVersion, let size = entry.size,
              range.endExclusive <= size else { throw RemoteSyncError.conflict(path: path) }
        var request = try request(path: path, method: "GET")
        request.setValue(requiringVersion, forHTTPHeaderField: "If-Match")
        request.setValue("bytes=\(range.offset)-\(range.endExclusive - 1)", forHTTPHeaderField: "Range")
        let policy = retryPolicy
        let scope = DAVOperationScope(pool: session, policy: policy)
        let rangeRequest = request
        do {
            let bytes = try await scope.run {
                try await DAVRetryExecutor.run(policy: policy, scope: scope, runtime: scope.runtime) { _ in
                    try await DAVByteRangeWorker.read(session: session, request: rangeRequest, range: range,
                        total: size, version: version, path: path, now: scope.runtime.wallNow())
                }
            }
            try checkGeneration(generation)
            return bytes
        } catch let error as RemoteByteRangeError {
            // Do not turn a concurrent disconnect/cancel into permission to fallback.
            try checkGeneration(generation)
            throw error
        } catch { throw DAVHTTP.mapped(error) }
    }
}

private enum DAVByteRangeWorker {
    static func read(session: DAVHTTPSession, request: URLRequest, range: RemoteByteRange,
                     total: Int64, version: String, path: String, now: Date) async throws -> Data {
        let stream = try await DAVHTTP.stream(session: session, request: request)
        defer { stream.cancel() }
        try Task.checkCancellation()
        let response = stream.response
        try DAVHTTP.validateForRetry(response, path: path, allowed: [200, 206], now: now)
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 压缩传输编码")
        }
        // Only a structurally valid full-representation header permits fallback.
        // Never consume a 200 body into the bounded segment buffer.
        if response.statusCode == 200 {
            guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw RemoteSyncError.conflict(path: path)
            }
            if let etag = response.value(forHTTPHeaderField: "ETag"), etag != version {
                throw RemoteSyncError.conflict(path: path)
            }
            if response.expectedContentLength >= 0, response.expectedContentLength != total {
                throw RemoteSyncError.integrityMismatch(path: path)
            }
            throw RemoteByteRangeError.unavailable
        }
        guard response.value(forHTTPHeaderField: "ETag") == version,
              let raw = response.value(forHTTPHeaderField: "Content-Range"),
              let received = DAVDownloadResponse.parseRange(raw),
              received.start == range.offset, received.end == range.endExclusive - 1,
              received.total == total else { throw RemoteSyncError.conflict(path: path) }
        if response.expectedContentLength >= 0, response.expectedContentLength != range.length {
            throw RemoteSyncError.integrityMismatch(path: path)
        }
        // Match ordinary GET's conservative retry boundary: once body processing
        // starts, propagate failures without restarting this range or changing version.
        do {
            var bytes = Data()
            bytes.reserveCapacity(Int(range.length))
            while let chunk = try await stream.next() {
                try Task.checkCancellation()
                guard Int64(chunk.count) <= range.length - Int64(bytes.count) else {
                    throw RemoteSyncError.integrityMismatch(path: path)
                }
                bytes.append(chunk)
            }
            try Task.checkCancellation()
            guard Int64(bytes.count) == range.length else { throw RemoteSyncError.integrityMismatch(path: path) }
            return bytes
        } catch { throw DAVRequestFailure.nonRetryable(error) }
    }
}
