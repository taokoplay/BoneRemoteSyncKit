import Foundation
import CryptoKit
import Darwin
import BoneRemoteSyncCore

private struct ODUploadSessionResponse: Decodable, Sendable {
    let uploadUrl: String?
    let expirationDateTime: String?
    let nextExpectedRanges: [String]?
}

private struct ODMissingRange: Sendable {
    let start: Int64
    let end: Int64
}

private struct ODSessionStatus: Sendable {
    let firstMissing: ODMissingRange?
    let expirationDate: Date?
}

private enum ODSessionHTTPError: Error, Sendable {
    case status(Int, retryAfter: TimeInterval?)
    case transport
}

private struct ODUploadFileIdentity: Equatable, Sendable {
    let device: Int64
    let inode: Int64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

/// A snapshot reader owns the descriptor for the whole upload attempt. The
/// path is only used to open the file once; subsequent reads cannot follow a
/// replacement or symlink at that path.
private final class ODSnapshotReader: @unchecked Sendable {
    private let handle: FileHandle
    private let size: Int64

    init(record: ODUploadSessionRecord) throws {
        let fd = Darwin.open(record.snapshotURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw RemoteSyncError.sourceSnapshotMissing }
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var value = Darwin.stat()
        guard fstat(fd, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1,
              Int64(value.st_dev) == record.snapshotDevice,
              UInt64(value.st_ino) == record.snapshotInode,
              Int64(value.st_size) == record.handle.sourceSize else {
            try? handle.close()
            throw RemoteSyncError.sourceSnapshotMissing
        }
        self.size = Int64(value.st_size)
        do {
            var digest = SHA256()
            try handle.seek(toOffset: 0)
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                digest.update(data: data)
            }
            let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard fingerprint == record.handle.sourceFingerprint else {
                try? handle.close()
                throw RemoteSyncError.sourceSnapshotMissing
            }
            try handle.seek(toOffset: 0)
        } catch let error as RemoteSyncError {
            throw error
        } catch {
            try? handle.close()
            throw RemoteSyncError.sourceSnapshotMissing
        }
    }

    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0,
              Int64(count) <= size - offset else {
            throw RemoteSyncError.sourceSnapshotMissing
        }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }
}

private final class ODUploadSessionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(_ descriptor: Int32) { self.descriptor = descriptor }

    func release() {
        lock.withLock {
            guard let descriptor else { return }
            Darwin.close(descriptor)
            self.descriptor = nil
        }
    }

    deinit { release() }
}

extension OneDriveSource: RemoteResumableUploadSource {
    public func prepareResumableUpload(
        from localURL: URL,
        to target: RemoteFileReference,
        options: RemoteResumableUploadOptions
    ) async throws -> RemoteUploadHandle {
        do {
            let context = try context()
            try validateResumableTarget(target, context: context)
            try validateResumableOptions(options)
            guard let store = resumableSessionStore else {
                throw RemoteSyncError.unsupported(operation: "OneDrive 未配置上传会话安全存储")
            }
            let directoryLease = try acquireUploadLock(directory: options.snapshotDirectory)
            defer { directoryLease.release() }
            let snapshot = try makeSnapshot(from: localURL, directory: options.snapshotDirectory)
            guard snapshot.size > 0 else {
                try? FileManager.default.removeItem(at: snapshot.url)
                throw RemoteSyncError.unsupported(operation: "OneDrive 可恢复上传暂不支持空文件")
            }
            let handle = try RemoteUploadHandle(
                source: target.source,
                target: target,
                sourceSize: snapshot.size,
                sourceFingerprint: snapshot.fingerprint
            )
            do {
                let record = ODUploadSessionRecord(handle: handle, snapshotURL: snapshot.url,
                    snapshotDevice: snapshot.device, snapshotInode: snapshot.inode, contentType: options.contentType ?? "application/octet-stream", overwrite: options.overwrite,
                    expectedETag: nil, chunkSize: options.chunkSize, binding: target.source,
                    driveID: context.drive, blockDigests: snapshot.blockDigests)
                try store.insert(record)
                return handle
            } catch {
                try? FileManager.default.removeItem(at: snapshot.url)
                throw RemoteSyncError.secureStorageUnavailable
            }
        } catch {
            throw ODHTTPClient.mapped(error)
        }
    }

    public func uploadResuming(
        _ handle: RemoteUploadHandle,
        options: RemoteResumableUploadOptions? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> RemoteResumableUploadResult {
        // Keep observed commit risk in memory as well as durable storage. A
        // failed Keychain read during cancellation must not erase that knowledge.
        var commitMayBeUnknown = false
        do {
            let context = try context()
            guard let store = resumableSessionStore else {
                throw RemoteSyncError.unsupported(operation: "OneDrive 未配置上传会话安全存储")
            }
            guard var record = try store.read(handle.id), record.handle == handle else {
                throw RemoteSyncError.sourceSnapshotMissing
            }
            try validateRecord(record, context: context)
            let lock = try acquireUploadLock(directory: record.snapshotURL.deletingLastPathComponent())
            defer { lock.release() }
            guard let fresh = try store.read(handle.id), fresh.handle == handle,
                  fresh.snapshotURL == record.snapshotURL else { throw RemoteSyncError.sourceSnapshotMissing }
            record = fresh
            commitMayBeUnknown = record.phase == .reconciling
            try validateRecord(record, context: context)

            if record.phase == .committed, record.committedEntry != nil {
                return try finishCommitted(record, store: store)
            }
            if record.phase == .creationUnknown || record.phase == .abortUnknown {
                throw RemoteSyncError.uploadCommitUnknown
            }
            if record.phase == .conflict { throw RemoteSyncError.conflict(path: "upload-session") }
            if record.phase == .aborted {
                throw RemoteSyncError.conflict(path: "upload-session")
            }
            let snapshotReader = try ODSnapshotReader(record: record)
            if let options {
                try validateResumableOptions(options)
                guard options.snapshotDirectory.standardizedFileURL == record.snapshotURL.deletingLastPathComponent().standardizedFileURL,
                      options.overwrite == record.overwrite,
                      options.expectedETag == record.expectedETag,
                      options.chunkSize == record.chunkSize else {
                    throw RemoteSyncError.conflict(path: "upload-options")
                }
            }

            if record.phase == .preparing {
                record = try await createSession(record, context: context, store: store)
            }
            let reportProgress: (@Sendable (Int64) -> Void)? = progress ?? options?.progress
            var transientAttempts = 0
            var noProgressAttempts = 0
            var greatestConfirmed = record.confirmedBytes
            while true {
                if Task.isCancelled {
                    throw record.phase == .reconciling ? RemoteSyncError.uploadCommitUnknown : RemoteSyncError.cancelled
                }
                guard noProgressAttempts < 5 else {
                    throw record.phase == .reconciling ? RemoteSyncError.uploadCommitUnknown : RemoteSyncError.conflict(path: "upload-session-range")
                }
                let status: ODSessionStatus
                do {
                    status = try await sessionStatus(record, context: context)
                } catch let error as ODSessionHTTPError {
                    if case .status(let code, let retryAfter) = error, code == 429 || (500...599).contains(code), transientAttempts < 4 {
                        transientAttempts += 1
                        try await sleepBeforeRetry(attempt: transientAttempts, retryAfter: retryAfter)
                        continue
                    }
                    if record.phase == .reconciling { throw RemoteSyncError.uploadCommitUnknown }
                    throw mapSessionError(error, final: false)
                } catch let error as RemoteSyncError {
                    if record.phase == .reconciling { throw RemoteSyncError.uploadCommitUnknown }
                    throw error
                } catch is CancellationError {
                    throw RemoteSyncError.cancelled
                } catch {
                    if record.phase == .reconciling { throw RemoteSyncError.uploadCommitUnknown }
                    if transientAttempts < 4 {
                        transientAttempts += 1
                        try await sleepBeforeRetry(attempt: transientAttempts, retryAfter: nil)
                        continue
                    }
                    throw RemoteSyncError.network("OneDrive 上传会话状态查询失败")
                }

                guard let missing = status.firstMissing else {
                    record = try replace(record, confirmedBytes: record.confirmedBytes, phase: .reconciling,
                                         expirationDate: status.expirationDate ?? record.expirationDate)
                    try store.replace(record)
                    throw RemoteSyncError.uploadCommitUnknown
                }
                let start = missing.start
                if start > greatestConfirmed {
                    greatestConfirmed = start
                    noProgressAttempts = 0
                    transientAttempts = 0
                }
                noProgressAttempts += 1
                guard start >= 0, start < handle.sourceSize,
                      missing.end >= start, missing.end < handle.sourceSize else {
                    throw RemoteSyncError.conflict(path: "upload-session-range")
                }
                record = try replace(record, confirmedBytes: start, phase: .uploading,
                                     expirationDate: status.expirationDate ?? record.expirationDate)
                try store.replace(record)
                commitMayBeUnknown = false // GET proved a missing range in this session

                let count = Int(min(record.chunkSize, missing.end - start + 1,
                                    handle.sourceSize - start))
                let data = try snapshotReader.read(offset: start, count: count)
                try verifyBlocks(data, offset: start, record: record)
                guard data.count == count else { throw RemoteSyncError.sourceSnapshotMissing }
                let end = start + Int64(data.count) - 1
                let isFinal = end + 1 == handle.sourceSize
                if isFinal {
                    // Persist the commit hazard before the final request can leave
                    // this process. A crash or cancellation cannot erase it.
                    record = try replace(record, confirmedBytes: start, phase: .reconciling)
                    try store.replace(record)
                    commitMayBeUnknown = true
                }
                reportProgress?(start)

                do {
                    let response = try await putChunk(record, context: context, data: data, start: start, end: end,
                                                       total: handle.sourceSize)
                    switch response.response.statusCode {
                    case 202:
                        let next: ODUploadSessionResponse
                        do {
                            next = try decode(ODUploadSessionResponse.self, response.data)
                        } catch {
                            // The 202 body may be truncated after the service accepted the
                            // range. Re-query the same session before selecting another chunk.
                            if transientAttempts < 4 {
                                transientAttempts += 1
                                continue
                            }
                            throw RemoteSyncError.uploadCommitUnknown
                        }
                        guard let confirmed = try firstMissing(next.nextExpectedRanges, total: handle.sourceSize) else {
                            throw RemoteSyncError.uploadCommitUnknown
                        }
                        record = try replace(record, confirmedBytes: confirmed.start, phase: .uploading,
                                             expirationDate: parseDate(next.expirationDateTime) ?? record.expirationDate)
                        try store.replace(record)
                        transientAttempts = 0
                    case 200, 201:
                        guard isFinal else { throw RemoteSyncError.conflict(path: "upload-session") }
                        do {
                            let value = try decode(ODItem.self, response.data)
                            guard case .path(let path) = handle.target.locator else {
                                throw RemoteSyncError.conflict(path: "upload-target")
                            }
                            try value.validate(drive: context.drive, path: path)
                            guard value.file != nil, value.size == handle.sourceSize,
                                  value.name == (try splitUploadPath(path)).name,
                                  value.parentReference?.driveId == record.driveID,
                                  value.parentReference?.id == record.parentID,
                                  record.parentID != nil else {
                                throw RemoteSyncError.integrityMismatch(path: path)
                            }
                            record = try replace(record, confirmedBytes: handle.sourceSize, phase: .committed,
                                                 committedEntry: value.entry(drive: context.drive, path: path))
                            do { try store.replace(record) } catch {
                                // The validated success response remains authoritative even
                                // when local persistence fails. Retain snapshot and intent.
                                return try RemoteResumableUploadResult(entry: record.committedEntry,
                                    handle: handle, state: .committedCleanupPending,
                                    confirmedBytes: handle.sourceSize, totalBytes: handle.sourceSize)
                            }
                            transientAttempts = 0
                            reportProgress?(handle.sourceSize)
                            return try finishCommitted(record, store: store)
                        } catch {
                            // A successful status without a valid driveItem is still not a
                            // proof that this client can account for the final write. Preserve
                            // reconciliation evidence instead of reporting success or starting
                            // a replacement session.
                            throw await reconcileFinal(record, context: context, store: store)
                        }
                    case 409, 412:
                        // A complete conflict response rejects this final commit.
                        // Keep its session for explicit abort, without replaying PUT.
                        let rejected = try replace(record, confirmedBytes: record.confirmedBytes, phase: .conflict)
                        try store.replace(rejected)
                        record = rejected
                        commitMayBeUnknown = false
                        throw RemoteSyncError.conflict(path: "upload-session")
                    case 416:
                        // The server is authoritative after an out-of-range response. The next
                        // loop performs GET and never advances from the local callback.
                        continue
                    case 429, 500...599:
                        let retryAfter = ODHTTPClient.retryAfter(response.response.value(forHTTPHeaderField: "Retry-After"))
                        if transientAttempts < 4 {
                            transientAttempts += 1
                            try await sleepBeforeRetry(attempt: transientAttempts, retryAfter: retryAfter)
                        } else {
                            throw mapSessionError(.status(response.response.statusCode, retryAfter: retryAfter), final: isFinal)
                        }
                    default:
                        throw mapSessionError(.status(response.response.statusCode, retryAfter: nil), final: isFinal)
                    }
                } catch let error as ODSessionHTTPError {
                    if case .status(416, _) = error { continue }
                    if case .status(let code, let retryAfter) = error, (code == 429 || (500...599).contains(code)), transientAttempts < 4 {
                        transientAttempts += 1
                        try await sleepBeforeRetry(attempt: transientAttempts, retryAfter: retryAfter)
                        continue
                    }
                    if case .transport = error, !isFinal, transientAttempts < 4 {
                        transientAttempts += 1
                        try await sleepBeforeRetry(attempt: transientAttempts, retryAfter: nil)
                        continue
                    }
                    if isFinal { throw await reconcileFinal(record, context: context, store: store) }
                    throw mapSessionError(error, final: false)
                } catch is CancellationError {
                    if isFinal { throw await reconcileFinal(record, context: context, store: store) }
                    throw RemoteSyncError.cancelled
                } catch let error as RemoteSyncError {
                    if isFinal && record.phase == .reconciling {
                        throw await reconcileFinal(record, context: context, store: store)
                    }
                    throw error
                } catch {
                    if isFinal { throw await reconcileFinal(record, context: context, store: store) }
                    throw RemoteSyncError.network("OneDrive 上传分片失败")
                }
            }
        } catch {
            let mapped = ODHTTPClient.mapped(error)
            if mapped == .cancelled && commitMayBeUnknown {
                throw RemoteSyncError.uploadCommitUnknown
            }
            throw mapped
        }
    }

    public func uploadCheckpoint(_ handle: RemoteUploadHandle) async throws -> RemoteUploadCheckpoint? {
        let context = try context()
        guard let store = resumableSessionStore,
              var record = try store.read(handle.id), record.handle == handle else { return nil }
        let lock = try acquireUploadLock(directory: record.snapshotURL.deletingLastPathComponent())
        defer { lock.release() }
        guard let fresh = try store.read(handle.id), fresh.handle == handle,
              fresh.snapshotURL == record.snapshotURL else { throw RemoteSyncError.sourceSnapshotMissing }
        record = fresh
        try validateRecord(record, context: context)
        return try RemoteUploadCheckpoint(
            handle: handle,
            confirmedBytes: record.confirmedBytes,
            totalBytes: handle.sourceSize,
            phase: record.phase,
            expiresAt: record.expirationDate
        )
    }

    public func abortResumableUpload(_ handle: RemoteUploadHandle) async throws {
        do {
            let context = try context()
            guard let store = resumableSessionStore,
                  var record = try store.read(handle.id), record.handle == handle else {
                throw RemoteSyncError.sourceSnapshotMissing
            }
            try validateRecord(record, context: context)
            let lock = try acquireUploadLock(directory: record.snapshotURL.deletingLastPathComponent())
            defer { lock.release() }
            guard let fresh = try store.read(handle.id), fresh.handle == handle,
                  fresh.snapshotURL == record.snapshotURL else { throw RemoteSyncError.sourceSnapshotMissing }
            record = fresh
            try validateRecord(record, context: context)
            if record.phase == .committed { throw RemoteSyncError.conflict(path: "upload-session-committed") }
            if [RemoteUploadPhase.creationUnknown, .reconciling, .abortUnknown].contains(record.phase) {
                throw RemoteSyncError.uploadCommitUnknown
            }
            if record.phase != .preparing && record.phase != .aborted {
                record.phase = .abortUnknown
                try store.replace(record)
                do {
                    let response = try await sessionRequest(record, context: context, method: "DELETE", body: nil)
                    guard response.response.statusCode == 204 else { throw RemoteSyncError.uploadCommitUnknown }
                } catch { throw RemoteSyncError.uploadCommitUnknown }
            }
            record.phase = .aborted
            record.uploadURL = nil
            try store.replace(record)
            try removeSnapshot(record)
            // Retain the terminal receipt until the host explicitly forgets it.
        } catch {
            throw ODHTTPClient.mapped(error)
        }
    }

    /// Explicit local retention cleanup after the caller has durably saved the
    /// terminal receipt. Never discards evidence for an uncertain remote write.
    public func forgetResumableUpload(_ handle: RemoteUploadHandle) async throws {
        let context = try context()
        guard let store = resumableSessionStore,
              let initial = try store.read(handle.id), initial.handle == handle else { return }
        try validateRecord(initial, context: context)
        let lock = try acquireUploadLock(directory: initial.snapshotURL.deletingLastPathComponent())
        defer { lock.release() }
        guard let record = try store.read(handle.id), record.handle == handle,
              record.snapshotURL == initial.snapshotURL else { throw RemoteSyncError.sourceSnapshotMissing }
        try validateRecord(record, context: context)
        guard record.phase == .committed || record.phase == .aborted else {
            throw RemoteSyncError.conflict(path: "upload-receipt-not-terminal")
        }
        try removeSnapshot(record)
        try store.remove(handle.id)
    }

    private func removeSnapshot(_ record: ODUploadSessionRecord) throws {
        var value = Darwin.stat()
        if lstat(record.snapshotURL.path, &value) != 0 {
            if errno == ENOENT { return }
            throw RemoteSyncError.sourceSnapshotMissing
        }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
              Int64(value.st_dev) == record.snapshotDevice, UInt64(value.st_ino) == record.snapshotInode,
              Int64(value.st_size) == record.handle.sourceSize else { throw RemoteSyncError.sourceSnapshotMissing }
        try FileManager.default.removeItem(at: record.snapshotURL)
    }

    private func validateResumableTarget(_ target: RemoteFileReference, context: ODContext) throws {
        let binding = RemoteSourceBinding(kind: .cloudAPI, identity: "onedrive:" + context.drive)
        guard target.source == binding, case .path(let path) = target.locator, path != "/" else {
            throw RemoteSyncError.conflict(path: "upload-binding")
        }
    }

    private func validateResumableOptions(_ options: RemoteResumableUploadOptions) throws {
        guard options.snapshotDirectory.isFileURL,
              options.snapshotDirectory.host == nil || options.snapshotDirectory.host == "localhost",
              options.snapshotDirectory.path != "/",
              !options.snapshotDirectory.path.contains("\0"),
              options.chunkSize >= 320 * 1024,
              options.chunkSize < 60 * 1024 * 1024,
              options.chunkSize % (320 * 1024) == 0 else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 上传会话分片大小")
        }
        if let contentType = options.contentType {
            guard !contentType.isEmpty, contentType.utf8.count <= 1024,
                  !contentType.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw RemoteSyncError.unsupported(operation: "OneDrive Content-Type 无效")
            }
        }
        guard options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 可恢复上传不支持最终提交条件 ETag")
        }
    }

    private func validateRecord(_ record: ODUploadSessionRecord, context: ODContext) throws {
        let binding = RemoteSourceBinding(kind: .cloudAPI, identity: "onedrive:" + context.drive)
        guard record.binding == binding, record.driveID == context.drive else {
            throw RemoteSyncError.conflict(path: "upload-binding")
        }
        try validateResumableTarget(record.handle.target, context: context)
        if let url = record.uploadURL { try ODLocation.validateUploadSessionURL(url, endpoints: endpoints) }
        guard record.handle.source == record.binding, record.expectedETag == nil,
              record.handle.sourceSize > 0, record.handle.sourceSize <= 5 * 1024 * 1024 * 1024,
              record.blockDigests.count == Int((record.handle.sourceSize + 327679) / 327680) * 32,
              record.confirmedBytes >= 0, record.confirmedBytes <= record.handle.sourceSize,
              record.snapshotURL.isFileURL,
              record.snapshotURL.host == nil || record.snapshotURL.host == "localhost",
              record.chunkSize >= 320 * 1024,
              record.chunkSize < 60 * 1024 * 1024,
              record.chunkSize % (320 * 1024) == 0 else {
            throw RemoteSyncError.conflict(path: "upload-session")
        }
    }

    private func replace(
        _ record: ODUploadSessionRecord,
        confirmedBytes: Int64,
        phase: RemoteUploadPhase,
        expirationDate: Date? = nil,
        committedEntry: RemoteEntry? = nil
    ) throws -> ODUploadSessionRecord {
        _ = try RemoteUploadCheckpoint(
            handle: record.handle,
            confirmedBytes: confirmedBytes,
            totalBytes: record.handle.sourceSize,
            phase: phase,
            expiresAt: expirationDate ?? record.expirationDate
        )
        var updated = record
        updated.expirationDate = expirationDate ?? record.expirationDate
        updated.phase = phase
        updated.confirmedBytes = confirmedBytes
        updated.committedEntry = committedEntry ?? record.committedEntry
        return updated
    }

    private func finishCommitted(
        _ record: ODUploadSessionRecord,
        store: any ODUploadSessionStore
    ) throws -> RemoteResumableUploadResult {
        guard let entry = record.committedEntry else { throw RemoteSyncError.uploadCommitUnknown }
        var cleanupPending = false
        do { try removeSnapshot(record) } catch { cleanupPending = true }
        // Preserve the terminal receipt across process death and repeated resume.
        // Remove the operation secret as soon as the committed receipt is durable.
        var terminal = record
        terminal.uploadURL = nil
        do { try store.replace(terminal) } catch { cleanupPending = true }
        return try RemoteResumableUploadResult(
            entry: entry,
            handle: record.handle,
            state: cleanupPending ? .committedCleanupPending : .committed,
            confirmedBytes: record.handle.sourceSize,
            totalBytes: record.handle.sourceSize
        )
    }

    private func sessionStatus(_ record: ODUploadSessionRecord, context: ODContext) async throws -> ODSessionStatus {
        let response = try await sessionRequest(record, context: context, method: "GET", body: nil)
        guard response.response.statusCode == 200 else {
            throw ODSessionHTTPError.status(response.response.statusCode,
                retryAfter: ODHTTPClient.retryAfter(response.response.value(forHTTPHeaderField: "Retry-After")))
        }
        let value = try decode(ODUploadSessionResponse.self, response.data)
        return ODSessionStatus(
            firstMissing: try firstMissing(value.nextExpectedRanges, total: record.handle.sourceSize),
            expirationDate: parseDate(value.expirationDateTime)
        )
    }

    private func putChunk(
        _ record: ODUploadSessionRecord,
        context: ODContext,
        data: Data,
        start: Int64,
        end: Int64,
        total: Int64
    ) async throws -> ODHTTPResponse {
        try check(context.generation)
        var request = try sessionURLRequest(record, method: "PUT")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue("bytes \(start)-\(end)/\(total)", forHTTPHeaderField: "Content-Range")
        request.setValue(record.contentType, forHTTPHeaderField: "Content-Type")
        do {
            let response = try await context.client.send(request, body: .data(data))
            // The request used the frozen drive/session. Preserve a returned
            // success receipt even if cancellation or disconnect arrived later.
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as RemoteSyncError {
            throw error
        } catch {
            throw ODSessionHTTPError.transport
        }
    }

    private func sessionRequest(
        _ record: ODUploadSessionRecord,
        context: ODContext,
        method: String,
        body: Data?
    ) async throws -> ODHTTPResponse {
        try check(context.generation)
        let request = try sessionURLRequest(record, method: method, body: body)
        do {
            let response = try await context.client.send(request, body: body.map(ODUploadBody.data))
            try check(context.generation)
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as RemoteSyncError {
            throw error
        } catch {
            throw ODSessionHTTPError.transport
        }
    }

    private func sessionURLRequest(_ record: ODUploadSessionRecord, method: String, body: Data? = nil) throws -> URLRequest {
        guard let url = record.uploadURL else { throw RemoteSyncError.uploadCommitUnknown }
        try ODLocation.validateUploadSessionURL(url, endpoints: endpoints)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        // Deliberately no Authorization and no Cookie. The upload URL is the
        // provider-issued pre-authenticated secret and URLSession is ephemeral.
        return request
    }

    private func mapSessionError(_ error: ODSessionHTTPError, final: Bool) -> RemoteSyncError {
        switch error {
        case .transport:
            return final ? .uploadCommitUnknown : .network("OneDrive 上传会话请求失败")
        case .status(let code, let retryAfter):
            switch code {
            case 401, 404: return final ? .uploadCommitUnknown : .uploadSessionExpired
            case 403: return .permissionDenied(path: "upload-session")
            case 409, 412: return .conflict(path: "upload-session")
            case 416: return .conflict(path: "upload-session-range")
            case 429: return .rateLimited(retryAfter: retryAfter)
            case 500...599: return final ? .uploadCommitUnknown : .network("OneDrive 上传会话请求失败")
            default: return .unsupported(operation: "OneDrive 上传会话 HTTP \(code)")
            }
        }
    }

    private func reconcileFinal(
        _ record: ODUploadSessionRecord,
        context: ODContext,
        store: any ODUploadSessionStore
    ) async -> RemoteSyncError {
        var reconciling = record
        do {
            reconciling = try replace(record, confirmedBytes: record.confirmedBytes, phase: .reconciling)
            try store.replace(reconciling)
        } catch {
            return .secureStorageUnavailable
        }
        do {
            let status = try await sessionStatus(reconciling, context: context)
            let updated = try replace(reconciling, confirmedBytes: status.firstMissing?.start ?? record.confirmedBytes,
                                       phase: .reconciling,
                                       expirationDate: status.expirationDate ?? record.expirationDate)
            try store.replace(updated)
        } catch {
            // Keep reconciling. In particular a 404 after a lost final response
            // is not proof that the remote commit did not happen.
        }
        return .uploadCommitUnknown
    }

    private func firstMissing(_ ranges: [String]?, total: Int64) throws -> ODMissingRange? {
        guard let ranges, !ranges.isEmpty, total > 0 else { return nil }
        var intervals: [(start: Int64, end: Int64)] = []
        for raw in ranges {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let first = pieces.first,
                  let start = Int64(first),
                  start >= 0,
                  start < total else {
                throw RemoteSyncError.conflict(path: "upload-session-range")
            }
            let end: Int64
            if pieces[1].isEmpty {
                end = total - 1
            } else {
                guard let parsedEnd = Int64(pieces[1]), parsedEnd >= start, parsedEnd < total else {
                    throw RemoteSyncError.conflict(path: "upload-session-range")
                }
                end = parsedEnd
            }
            intervals.append((start, end))
        }
        let sorted = intervals.sorted { $0.start < $1.start }
        for pair in zip(sorted, sorted.dropFirst()) where pair.1.start <= pair.0.end {
            throw RemoteSyncError.conflict(path: "upload-session-range")
        }
        let first = sorted[0]
        guard first.start % 327680 == 0,
              first.end == total - 1 || (first.end + 1) % 327680 == 0 else {
            throw RemoteSyncError.conflict(path: "upload-session-range")
        }
        return ODMissingRange(start: first.start, end: first.end)
    }

    private func acquireUploadLock(directory: URL) throws -> ODUploadSessionLease {
        guard directory.isFileURL, directory.host == nil || directory.host == "localhost", directory.path != "/", !directory.path.contains("\0") else {
            throw RemoteSyncError.secureStorageUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw RemoteSyncError.secureStorageUnavailable
        }
        var directoryStat = Darwin.stat()
        guard lstat(directory.path, &directoryStat) == 0,
              directoryStat.st_mode & S_IFMT == S_IFDIR,
              directoryStat.st_uid == geteuid(),
              directoryStat.st_mode & 0o077 == 0 else {
            throw RemoteSyncError.secureStorageUnavailable
        }
        let lockURL = directory.appendingPathComponent(".bone-onedrive-upload.lock")
        let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw RemoteSyncError.secureStorageUnavailable }
        var fileStat = Darwin.stat()
        guard fstat(fd, &fileStat) == 0,
              fileStat.st_mode & S_IFMT == S_IFREG,
              fileStat.st_nlink == 1,
              fileStat.st_uid == geteuid(),
              fileStat.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw RemoteSyncError.conflict(path: "upload-session-lock")
        }
        return ODUploadSessionLease(fd)
    }

    private func makeSnapshot(from source: URL, directory: URL) throws -> (url: URL, size: Int64, fingerprint: String, blockDigests: Data, device: Int64, inode: UInt64) {
        guard source.isFileURL, directory.isFileURL,
              source.host == nil || source.host == "localhost",
              !source.path.contains("\0"), !directory.path.contains("\0") else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 上传源快照路径")
        }
        let sourceFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard sourceFD >= 0 else { throw RemoteSyncError.sourceSnapshotMissing }
        var sourceStat = Darwin.stat()
        guard fstat(sourceFD, &sourceStat) == 0,
              sourceStat.st_mode & S_IFMT == S_IFREG,
              sourceStat.st_nlink == 1,
              sourceStat.st_size > 0, sourceStat.st_size <= 5 * 1024 * 1024 * 1024 else {
            Darwin.close(sourceFD)
            throw RemoteSyncError.sourceSnapshotMissing
        }
        let snapshot = directory.appendingPathComponent(".bone-onedrive-upload-\(UUID()).snapshot")
        let fd = Darwin.open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else {
            Darwin.close(sourceFD)
            throw RemoteSyncError.secureStorageUnavailable
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        var digest = SHA256()
        var copied: Int64 = 0
        var blockDigests = Data()
        do {
            while let data = try input.read(upToCount: 327680), !data.isEmpty {
                try Task.checkCancellation()
                guard copied + Int64(data.count) <= sourceStat.st_size,
                      data.count == 327680 || copied + Int64(data.count) == sourceStat.st_size else {
                    throw RemoteSyncError.sourceSnapshotMissing
                }
                blockDigests.append(contentsOf: SHA256.hash(data: data))
                try output.write(contentsOf: data)
                digest.update(data: data)
                copied += Int64(data.count)
            }
            guard fsync(fd) == 0 else { throw RemoteSyncError.secureStorageUnavailable }
            var snapshotStat = Darwin.stat()
            guard fstat(fd, &snapshotStat) == 0, snapshotStat.st_nlink == 1 else {
                throw RemoteSyncError.sourceSnapshotMissing
            }
            try output.close()
            var after = Darwin.stat()
            guard fstat(sourceFD, &after) == 0,
                  sourceIdentity(sourceStat) == sourceIdentity(after),
                  after.st_size == copied else {
                throw RemoteSyncError.sourceSnapshotMissing
            }
            let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
            try input.seek(toOffset: 0)
            var sourceDigest = SHA256()
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                sourceDigest.update(data: data)
            }
            let sourceFingerprint = sourceDigest.finalize().map { String(format: "%02x", $0) }.joined()
            guard sourceFingerprint == fingerprint else {
                throw RemoteSyncError.sourceSnapshotMissing
            }
            var finalSourceStat = Darwin.stat()
            guard fstat(sourceFD, &finalSourceStat) == 0,
                  sourceIdentity(sourceStat) == sourceIdentity(finalSourceStat),
                  finalSourceStat.st_size == copied else {
                throw RemoteSyncError.sourceSnapshotMissing
            }
            return (snapshot, copied, fingerprint, blockDigests, Int64(snapshotStat.st_dev), UInt64(snapshotStat.st_ino))
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: snapshot)
            throw error is RemoteSyncError ? error : RemoteSyncError.sourceSnapshotMissing
        }
    }

    private func sourceIdentity(_ value: Darwin.stat) -> ODUploadFileIdentity {
        ODUploadFileIdentity(
            device: Int64(value.st_dev),
            inode: Int64(value.st_ino),
            size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }

    private func splitUploadPath(_ path: String) throws -> (parent: String, name: String) {
        let parts = path.dropFirst().split(separator: "/")
        guard let last = parts.last, !last.isEmpty else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 路径")
        }
        let parent = parts.count == 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
        return (parent, String(last))
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func sleepBeforeRetry(attempt: Int, retryAfter: TimeInterval?) async throws {
        let fallback = min(8.0, 0.25 * pow(2.0, Double(max(0, attempt - 1))))
        if let retryAfter, !retryAfter.isFinite || retryAfter > 30 {
            throw RemoteSyncError.rateLimited(retryAfter: retryAfter)
        }
        let seconds = max(0, retryAfter ?? fallback)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func verifyBlocks(_ data: Data, offset: Int64, record: ODUploadSessionRecord) throws {
        var cursor = 0
        while cursor < data.count {
            let end = min(cursor + 327680, data.count)
            let block = Int((offset + Int64(cursor)) / 327680)
            let expected = record.blockDigests.subdata(in: (block * 32)..<((block + 1) * 32))
            guard Data(SHA256.hash(data: data.subdata(in: cursor..<end))) == expected else {
                throw RemoteSyncError.sourceSnapshotMissing
            }
            cursor = end
        }
    }

    private func createSession(_ prepared: ODUploadSessionRecord, context: ODContext,
                               store: any ODUploadSessionStore) async throws -> ODUploadSessionRecord {
        guard case .path(let path) = prepared.handle.target.locator else { throw RemoteSyncError.conflict(path: "upload-target") }
        let (parentPath, name) = try splitUploadPath(path)
        let parent = try await item(path: parentPath, context: context)
        guard parent.folder != nil else { throw RemoteSyncError.conflict(path: parentPath) }
        // Resolve credentials, URL and body before recording dispatch intent.
        // Do not use graph() here: its automatic 401 replay and post-response
        // cancellation checks lose the distinction between rejection and unknown.
        let url = ODLocation.createUploadSession(parent: parent.id, name: name, drive: context.drive, base: endpoints.graph)
        try ODLocation.validateGraph(url, base: endpoints.graph)
        let json = try JSONSerialization.data(withJSONObject: ["item": ["name": name,
            "@microsoft.graph.conflictBehavior": prepared.overwrite ? "replace" : "fail"]])
        let bearer = try await access(generation: context.generation, client: context.client)
        try check(context.generation)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var record = prepared
        record.parentID = parent.id
        record.phase = .creationUnknown
        try store.replace(record) // before POST: never recreate an uncertain session
        let response: ODHTTPResponse
        do { response = try await context.client.send(request) }
        catch { throw RemoteSyncError.uploadCommitUnknown }
        if [400, 401, 403, 404, 409, 412, 429].contains(response.response.statusCode) {
            // Complete rejection: no session was created. A later explicit call
            // may retry, or abort the purely local preparation.
            record.phase = .preparing
            try store.replace(record)
            try ODHTTPClient.validate(response.response, path: path)
        }
        do {
            try ODHTTPClient.validate(response.response, path: path)
            let session = try decode(ODUploadSessionResponse.self, response.data)
            guard let raw = session.uploadUrl, let uploadURL = URL(string: raw) else { throw RemoteSyncError.uploadCommitUnknown }
            try ODLocation.validateUploadSessionURL(uploadURL, endpoints: endpoints)
            record.uploadURL = uploadURL
            record.expirationDate = parseDate(session.expirationDateTime)
            record.phase = .uploading
            try store.replace(record)
            return record
        } catch {
            // The durable creationUnknown record and snapshot remain available.
            // Never issue a replacement POST or discard the caller's handle.
            throw RemoteSyncError.uploadCommitUnknown
        }
    }
}
