import Foundation
import BoneRemoteSyncCore

/// Process-local materialization. The source session and private, non-synced
/// cache directory are caller-owned. Do not reconnect a source to another account
/// while this instance is in use; create a new binding and materializer instead.
public actor RemoteFileMaterializer: RemoteFileMaterializing {
    private struct CacheKey: Hashable, Sendable {
        let reference: RemoteFileReference
        let version: RemoteVersion?
        let verifySize: Bool
        let checksum: RemoteContentChecksum?
        let consistency: RemoteReadConsistency
        let strategy: RemoteDownloadStrategy
        let nonce: UUID?
    }
    private struct Record: Sendable {
        let id: UUID
        let key: CacheKey
        let entry: RemoteEntry
        let version: RemoteVersion?
        let file: ManagedMaterializedFile
        var leases = 0
        var persistent = false
    }
    private struct Waiter {
        let continuation: CheckedContinuation<MaterializedFileLease, any Error>
        let options: RemoteMaterializationOptions
    }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        let relay: MaterializationProgressRelay
        var waiters: [UUID: Waiter]
    }

    private let source: any RemoteSource
    public nonisolated let sourceBinding: RemoteSourceBinding
    public nonisolated let maxConcurrentTransfers: Int
    private let cacheDirectory: URL
    private let readGate: MaterializationReadGate
    private var records: [UUID: Record] = [:]
    private var reusable: [CacheKey: UUID] = [:]
    private var flights: [CacheKey: Flight] = [:]
    // Includes cancelled flights until their underlying operation actually exits.
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var preparations: [UUID: Task<RemoteEntry, any Error>] = [:]
    private var closed = false
    private var cancellingWaiters: [UUID: [Waiter]] = [:]

    public init(source: any RemoteSource, sourceBinding: RemoteSourceBinding, cacheDirectory: URL) {
        self.source = source
        self.sourceBinding = sourceBinding
        self.maxConcurrentTransfers = max(1, source.capabilities.maxConcurrentTransfers)
        self.cacheDirectory = cacheDirectory
        self.readGate = MaterializationReadGate(limit: source.capabilities.maxConcurrentTransfers)
    }

    public func materialize(_ reference: RemoteFileReference,
                            options: RemoteMaterializationOptions = .init()) async throws -> MaterializedFileLease {
        try preflight(reference, options: options)
        try Task.checkCancellation()
        let preparationID = UUID()
        let preparation = Task { try await self.resolve(reference) }
        preparations[preparationID] = preparation
        let entry: RemoteEntry
        do {
            entry = try await withTaskCancellationHandler(operation: {
                try await preparation.value
            }, onCancel: { preparation.cancel() })
        } catch {
            preparations[preparationID] = nil
            throw error
        }
        preparations[preparationID] = nil
        try Task.checkCancellation()
        guard !closed else { throw RemoteSyncError.cancelled }
        guard !entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "物化目录") }
        let version = observedVersion(entry, reference: reference, strategy: options.downloadStrategy)
        if case .requireVersion(let required) = options.consistency {
            guard version == required else { throw RemoteSyncError.conflict(path: reference.displayLocator) }
        }
        let key = CacheKey(reference: reference, version: version, verifySize: options.verifySize,
                           checksum: options.expectedChecksum,
                           consistency: options.consistency, strategy: options.downloadStrategy,
                           nonce: options.reuse == .refresh || version == nil ? UUID() : nil)
        if let id = reusable[key], var record = records[id] {
            if record.file.isUnchanged {
                record.leases += 1
                record.persistent = record.persistent || options.retention == .persistent
                records[id] = record
                return lease(record)
            }
            // Do not replace an existing lease's identity with a new generation.
            reusable[key] = nil
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || closed {
                    continuation.resume(throwing: RemoteSyncError.cancelled)
                    return
                }
                let waiter = Waiter(continuation: continuation, options: options)
                if var flight = flights[key] {
                    flight.waiters[waiterID] = waiter
                    flight.relay.add(waiterID, options: options)
                    flights[key] = flight
                    return
                }
                let flightID = UUID()
                let relay = MaterializationProgressRelay()
                relay.add(waiterID, options: options)
                let task = Task {
                    let result: Result<Record, any Error>
                    do {
                        let file = try await self.download(entry, reference: reference, options: options, relay: relay)
                        result = .success(Record(id: UUID(), key: key, entry: entry, version: version, file: file))
                    } catch { result = .failure(error) }
                    self.finish(key: key, flightID: flightID, result: result)
                }
                flights[key] = Flight(id: flightID, task: task, relay: relay, waiters: [waiterID: waiter])
                workers[flightID] = task
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID, key: key) }
        })
    }

    /// Stops admission, cancels outstanding metadata reads and downloads, and waits
    /// for these source operations and download cleanup to finish.
    /// Does not disconnect the caller's source or invalidate already issued leases.
    public func shutdown() async {
        closed = true
        let current = Array(flights.values)
        flights.removeAll()
        for flight in current {
            flight.relay.close()
            flight.task.cancel()
            cancellingWaiters[flight.id, default: []].append(contentsOf: flight.waiters.values)
        }
        let tasks = Array(workers.values)
        let preparing = Array(preparations.values)
        for task in preparing { task.cancel() }
        for task in tasks { task.cancel() }
        for task in preparing { _ = await task.result }
        for task in tasks { await task.value }
        await clearPersistentCache()
    }

    public func evictUnleased() async {
        for record in Array(records.values) where record.leases == 0 && !record.persistent { remove(record) }
    }
    public func clearPersistentCache() async {
        for record in Array(records.values) where record.leases == 0 { remove(record) }
    }

    private func cancelWaiter(_ id: UUID, key: CacheKey) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: id) else { return }
        flight.relay.remove(id)
        if flight.waiters.isEmpty {
            flights[key] = nil
            flight.relay.close()
            flight.task.cancel()
            cancellingWaiters[flight.id, default: []].append(waiter)
        } else {
            flights[key] = flight
            waiter.continuation.resume(throwing: RemoteSyncError.cancelled)
        }
    }

    private func finish(key: CacheKey, flightID: UUID, result: Result<Record, any Error>) {
        workers[flightID] = nil
        for waiter in cancellingWaiters.removeValue(forKey: flightID) ?? [] {
            waiter.continuation.resume(throwing: RemoteSyncError.cancelled)
        }
        guard let flight = flights[key], flight.id == flightID else {
            if case .success(let record) = result { record.file.remove() }
            return
        }
        flights[key] = nil
        flight.relay.close()
        switch result {
        case .success(var record):
            record.leases = flight.waiters.count
            record.persistent = flight.waiters.values.contains { $0.options.retention == .persistent }
            records[record.id] = record
            if key.nonce == nil { reusable[key] = record.id }
            for waiter in flight.waiters.values { waiter.continuation.resume(returning: lease(record)) }
        case .failure(let error):
            for waiter in flight.waiters.values { waiter.continuation.resume(throwing: error) }
        }
    }

    private func lease(_ record: Record) -> MaterializedFileLease {
        // Keep the owner alive until release; records themselves hold no lease tokens.
        let releaser = LeaseReleaser { await self.release(record.id) }
        return MaterializedFileLease(url: record.file.url, reference: record.key.reference,
                                     entry: record.entry, version: record.version, releaser: releaser)
    }
    private func release(_ id: UUID) {
        guard var record = records[id], record.leases > 0 else { return }
        record.leases -= 1
        records[id] = record
        if record.leases == 0 && (!record.persistent || closed) { remove(record) }
    }
    private func remove(_ record: Record) {
        guard record.file.remove() else { return } // retain metadata if cleanup failed
        records[record.id] = nil
        if reusable[record.key] == record.id { reusable[record.key] = nil }
    }

    private func preflight(_ reference: RemoteFileReference, options: RemoteMaterializationOptions) throws {
        guard !closed else { throw RemoteSyncError.cancelled }
        try options.downloadStrategy.configuration?.validate()
        if let checksum = options.expectedChecksum, checksum.algorithm != .sha256 {
            throw RemoteSyncError.unsupported(operation: "物化校验目前仅支持 SHA-256")
        }
        guard reference.source == sourceBinding, sourceBinding.kind == source.kind else {
            throw RemoteSyncError.conflict(path: reference.displayLocator)
        }
        guard source.capabilities.stat && source.capabilities.download else {
            throw RemoteSyncError.unsupported(operation: "文件物化")
        }
        if case .requireVersion(let required) = options.consistency {
            guard required.source == sourceBinding, required.locator == reference.locator else {
                throw RemoteSyncError.conflict(path: reference.displayLocator)
            }
            // A source kind is not evidence of conditional read semantics.
            guard required.strength == .strongConditional,
                  source is any RemoteConditionalDownloadSource ||
                    (options.downloadStrategy.configuration != nil && source is any RemoteByteRangeSource) else {
                throw RemoteSyncError.unsupported(operation: "所请求的版本无法保证条件读取")
            }
        }
    }
    private nonisolated func resolve(_ reference: RemoteFileReference) async throws -> RemoteEntry {
        switch reference.locator {
        case .path(let path): return try await source.stat(path: path)
        case .itemID(let id):
            guard let source = source as? any RemoteIDAddressableSource else {
                throw RemoteSyncError.unsupported(operation: "按 ID 查询远端文件")
            }
            return try await source.stat(id: id)
        }
    }
    private nonisolated func observedVersion(_ entry: RemoteEntry, reference: RemoteFileReference,
                                             strategy: RemoteDownloadStrategy) -> RemoteVersion? {
        if strategy.configuration != nil, let ranged = source as? any RemoteByteRangeSource,
           let value = ranged.byteRangeVersion(for: entry), !value.isEmpty {
            return .init(source: sourceBinding, locator: reference.locator, value: value, strength: .strongConditional)
        }
        if let conditional = source as? any RemoteConditionalDownloadSource,
           let value = conditional.conditionalDownloadVersion(for: entry) {
            return .init(source: sourceBinding, locator: reference.locator, value: value, strength: .strongConditional)
        }
        if let etag = entry.etag, !etag.isEmpty, !etag.hasPrefix("W/") {
            return .init(source: sourceBinding, locator: reference.locator, value: etag, strength: .metadataFingerprint)
        }
        if let size = entry.size, let modified = entry.modifiedAt {
            return .init(source: sourceBinding, locator: reference.locator,
                         value: "\(size):\(modified.timeIntervalSince1970)", strength: .metadataFingerprint)
        }
        return nil
    }

    private nonisolated func download(_ entry: RemoteEntry, reference: RemoteFileReference,
                          options: RemoteMaterializationOptions,
                          relay: MaterializationProgressRelay) async throws -> ManagedMaterializedFile {
        try Task.checkCancellation()
        let transaction = try MaterializationTransaction(cacheDirectory: cacheDirectory)
        defer { transaction.cleanupUncommitted() }
        relay.report(.preparing)
        let downloadOptions = RemoteDownloadOptions(overwrite: false, verifySize: options.verifySize,
            phaseProgress: { progress in
                relay.report(progress.phase == .preparing ? .preparing : .transferring, download: progress)
            })
        let segmented = try await SegmentedDownloadWorker.download(
            source: source, entry: entry, staging: transaction.staging,
            strategy: options.downloadStrategy, gate: readGate,
            progress: { bytes, total in
                relay.report(.transferring, download: .transferring(completedBytes: bytes, totalBytes: total))
            })
        if !segmented {
            let staging = transaction.staging
            try await readGate.run {
                if case .requireVersion(let version) = options.consistency {
                    guard let conditional = source as? any RemoteConditionalDownloadSource,
                          conditional.conditionalDownloadVersion(for: entry) == version.value else {
                        throw RemoteSyncError.unsupported(operation: "所请求的版本无法保证条件读取")
                    }
                    _ = try await conditional.download(entry, to: staging,
                                                       requiringVersion: version.value, options: downloadOptions)
                } else {
                    _ = try await source.download(entry, to: staging, options: downloadOptions)
                }
            }
        }
        try Task.checkCancellation()
        relay.report(.verifying)
        try transaction.verify(expectedSize: options.verifySize || segmented ? entry.size : nil,
                               checksum: options.expectedChecksum)
        // A metadata fingerprint is change detection, never an atomic version lock.
        let after = try await resolve(reference)
        guard after.id == entry.id,
              after.size == entry.size,
              observedVersion(after, reference: reference, strategy: options.downloadStrategy) ==
                observedVersion(entry, reference: reference, strategy: options.downloadStrategy) else {
            throw RemoteSyncError.conflict(path: reference.displayLocator)
        }
        try Task.checkCancellation()
        relay.report(.committing)
        try Task.checkCancellation()
        return try transaction.commit()
    }
}
