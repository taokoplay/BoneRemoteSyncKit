import Foundation
import CryptoKit
import Darwin
import BoneRemoteSyncCore

final class DAVPreparedRecovery: @unchecked Sendable {
    let entry: RemoteEntry
    let handle: FileHandle
    let record: DAVCheckpointRecord
    let store: DAVCheckpointStore
    let alreadyInstalled: Bool
    init(entry: RemoteEntry, handle: FileHandle, record: DAVCheckpointRecord,
         store: DAVCheckpointStore, alreadyInstalled: Bool) {
        self.entry = entry; self.handle = handle; self.record = record
        self.store = store; self.alreadyInstalled = alreadyInstalled
    }
    deinit { try? handle.close() }
}

/// One worker is confined to one operation task; retry attempts are sequential, never concurrent.
/// Mutable hash/file state is not shared with the source actor or with another worker.
final class DAVResumableDownloadWorker: @unchecked Sendable {
    let session: DAVHTTPSession
    let target: WebDAVDownloadTarget
    let store: DAVCheckpointStore
    let options: WebDAVResumableDownloadOptions
    let policy: WebDAVRetryPolicy
    let scope: DAVOperationScope
    let hooks: DAVRecoveryTestHooks
    let path: String
    private var record: DAVCheckpointRecord?
    private var handle: FileHandle?
    private var handedOff = false

    init(session: DAVHTTPSession, target: WebDAVDownloadTarget, binding: DAVCheckpointBinding,
         options: WebDAVResumableDownloadOptions, policy: WebDAVRetryPolicy, scope: DAVOperationScope,
         path: String, hooks: DAVRecoveryTestHooks = .none) {
        self.session = session; self.target = target; store = DAVCheckpointStore(target: target, binding: binding)
        self.options = options; self.policy = policy; self.scope = scope; self.path = path; self.hooks = hooks
    }
    deinit { if !handedOff { try? handle?.close() } }

    func run(statRequest: URLRequest, getRequest: URLRequest, location: WebDAVLocation) async throws -> DAVPreparedRecovery {
        try await scope.run { try await self.prepare(statRequest: statRequest, getRequest: getRequest, location: location) }
    }

    private func prepare(statRequest: URLRequest, getRequest: URLRequest, location: WebDAVLocation) async throws -> DAVPreparedRecovery {
        try scope.check()
        record = try store.load()
        let partExists = try WebDAVDownloadTarget.information(target.part) != nil
        var alreadyInstalled = false
        if let record {
            alreadyInstalled = record.phase == .readyToInstall && !partExists
            guard partExists || alreadyInstalled else { throw conflict() }
            handle = try target.openManagedPart(installed: alreadyInstalled)
            try target.verifyManagedIdentity(handle: handle!, record: record, installed: alreadyInstalled)
            _ = try DAVPartHasher.verifyPrefix(handle: handle!, record: record, check: scope.check)
        } else if partExists { throw conflict() }
        if !alreadyInstalled { try target.validate(overwrite: options.overwrite, offset: 0) }

        let responses = try await DAVPropertyWorker.fetch(session: session, request: statRequest, path: path, location: location,
                                                          retryPolicy: policy, scope: scope)
        try scope.check()
        let item = try DAVPropertyWorker.resource(in: responses, path: path, location: location, requestURL: statRequest.url!)
        guard !item.isDirectory, let size = item.size, size >= 0,
              let etag = item.etag, WebDAVSource.isStrongETag(etag), etag.utf8.count <= 4096,
              item.contentType.map({ $0.utf8.count <= 1024 }) ?? true else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 恢复下载需要强 ETag、已知大小和有界元数据")
        }
        let entry = RemoteEntry(id: RemotePath.relative(path), path: path, name: RemotePath.name(of: path),
                               type: .file, size: size, modifiedAt: item.modifiedAt, etag: etag, contentType: item.contentType, createdAt: item.createdAt)
        if var saved = record {
            guard saved.etag == etag, saved.expectedSize == size else { throw conflict() }
            if saved.phase == .readyToInstall { return try prepared(saved, alreadyInstalled: alreadyInstalled) }
            if saved.committedBytes == saved.expectedSize {
                // A full length without confirmed EOF is not proof of completion (nor is HTTP 416).
                // Persist offset zero before any truncation so a crash here remains recoverable.
                saved.committedBytes = 0
                saved.prefixSHA256 = DAVPartHasher.hex(SHA256().finalize())
                try scope.check()
                try store.save(saved, hooks: hooks)
                record = saved
            }
        }
        return try await DAVRetryExecutor.run(policy: policy, scope: scope, runtime: scope.runtime) { _ in
            try await self.transfer(entry: entry, request: getRequest)
        }
    }

    private func transfer(entry: RemoteEntry, request original: URLRequest) async throws -> DAVPreparedRecovery {
        try scope.check()
        if var saved = record, saved.phase == .downloading, saved.committedBytes == saved.expectedSize {
            guard let handle, try store.load() == saved else { throw conflict() }
            try target.verifyManagedIdentity(handle: handle, record: saved)
            _ = try DAVPartHasher.verifyPrefix(handle: handle, record: saved, check: scope.check)
            saved.committedBytes = 0
            saved.prefixSHA256 = DAVPartHasher.hex(SHA256().finalize())
            try scope.check()
            try store.save(saved, hooks: hooks)
            record = saved
        }
        let offset = record?.committedBytes ?? 0
        var request = original
        request.setValue(record?.etag ?? entry.etag, forHTTPHeaderField: "If-Match")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let stream = try await DAVHTTP.stream(session: session, request: request)
        defer { stream.cancel() }
        let checked = try DAVDownloadResponse(response: stream.response, entry: entry,
            options: .init(expectedETag: record?.etag ?? entry.etag), offset: offset, path: path, now: scope.runtime.wallNow())
        try scope.check()
        guard stream.response.mimeType.map({ $0.utf8.count <= 1024 }) ?? true else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 响应元数据过长")
        }
        try target.validate(overwrite: options.overwrite, offset: 0)
        var hasher: SHA256
        if let saved = record {
            guard try store.load() == saved, let handle else { throw conflict() }
            try target.verifyManagedIdentity(handle: handle, record: saved)
            hasher = try DAVPartHasher.verifyPrefix(handle: handle, record: saved, check: scope.check)
            try scope.check()
            try handle.truncate(atOffset: UInt64(offset))
            try handle.synchronize()
            try handle.seek(toOffset: UInt64(offset))
        } else {
            handle = try target.createManagedPart()
            hasher = SHA256()
            var info = stat()
            guard let handle, fstat(handle.fileDescriptor, &info) == 0 else { throw conflict() }
            let saved = DAVCheckpointRecord(binding: store.binding, etag: entry.etag!, expectedSize: entry.size!,
                committedBytes: 0, prefixSHA256: DAVPartHasher.hex(hasher.finalize()),
                partDevice: UInt64(info.st_dev), partInode: UInt64(info.st_ino),
                createdAt: entry.createdAt, modifiedAt: entry.modifiedAt, contentType: entry.contentType)
            try commit(saved)
        }
        let output = handle!
        var written = offset
        var buffer = Data(); buffer.reserveCapacity(64 * 1024)
        options.progress?(written)
        while let chunk = try await stream.next() {
            try scope.check()
            var position = 0
            while position < chunk.count {
                let count = min(64 * 1024 - buffer.count, chunk.count - position)
                buffer.append(chunk.subdata(in: position..<(position + count))); position += count
                if buffer.count == 64 * 1024 {
                    try write(buffer, output: output, hasher: &hasher, written: &written)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        try scope.check()
        if !buffer.isEmpty { try write(buffer, output: output, hasher: &hasher, written: &written) }
        try scope.check()
        guard written == entry.size, checked.rangeLength.map({ written - offset == $0 }) ?? true else {
            throw RemoteSyncError.integrityMismatch(path: path)
        }
        var ready = record!
        ready.phase = .readyToInstall; ready.committedBytes = written
        ready.prefixSHA256 = DAVPartHasher.hex(hasher.finalize())
        ready.modifiedAt = stream.response.value(forHTTPHeaderField: "Last-Modified").flatMap(DAVHTTPDate.parse) ?? entry.modifiedAt
        ready.createdAt = entry.createdAt ?? ready.createdAt
        ready.contentType = stream.response.mimeType ?? entry.contentType
        try commit(ready)
        try hooks.call(.readyCommitted)
        return try prepared(ready, alreadyInstalled: false)
    }

    private func write(_ data: Data, output: FileHandle, hasher: inout SHA256, written: inout Int64) throws {
        try scope.check()
        guard let saved = record, written <= saved.expectedSize - Int64(data.count) else {
            throw RemoteSyncError.integrityMismatch(path: path)
        }
        try output.write(contentsOf: data)
        written += Int64(data.count); hasher.update(data: data)
        if written - saved.committedBytes >= options.checkpointIntervalBytes {
            var next = saved
            next.committedBytes = written; next.prefixSHA256 = DAVPartHasher.hex(hasher.finalize())
            try commit(next)
        }
        options.progress?(written)
    }

    private func commit(_ saved: DAVCheckpointRecord) throws {
        try scope.check()
        try target.verifyManagedIdentity(handle: handle!, record: saved)
        try handle!.synchronize()
        try hooks.call(.partSynced)
        try scope.check()
        try store.save(saved, hooks: hooks)
        record = saved
    }
    private func prepared(_ saved: DAVCheckpointRecord, alreadyInstalled: Bool) throws -> DAVPreparedRecovery {
        try scope.check()
        try target.verifyManagedIdentity(handle: handle!, record: saved, installed: alreadyInstalled)
        guard try store.load() == saved else { throw conflict() }
        let entry = RemoteEntry(id: RemotePath.relative(path), path: path, name: RemotePath.name(of: path), type: .file,
                                size: saved.expectedSize, modifiedAt: saved.modifiedAt, etag: saved.etag, contentType: saved.contentType, createdAt: saved.createdAt)
        handedOff = true
        return DAVPreparedRecovery(entry: entry, handle: handle!, record: saved, store: store, alreadyInstalled: alreadyInstalled)
    }
    private func conflict() -> RemoteSyncError { .conflict(path: path) }
}
