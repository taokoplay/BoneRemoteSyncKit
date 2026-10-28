import Foundation
import BoneRemoteSyncCore

/// One generic file materialization request submitted to a coordinator.
public struct RemoteTransferRequest: Sendable {
    public let reference: RemoteFileReference
    public var options: RemoteMaterializationOptions

    public init(
        reference: RemoteFileReference,
        options: RemoteMaterializationOptions = .init()
    ) {
        self.reference = reference
        self.options = options
    }
}

public typealias RemoteTransferID = UUID

/// Coordinates bounded generic file transfers without knowing the file format.
///
/// A submitted task owns its completed lease until `wait(for:)` takes the result,
/// or until the task is cancelled. Callers should always wait for or cancel a
/// submitted task so managed files are not retained indefinitely.
public actor RemoteTransferCoordinator {
    private struct Job {
        var snapshot: RemoteTransferSnapshot
        var result: Result<MaterializedFileLease, Error>?
        var resultWasTaken = false
    }

    private let materializers: [RemoteSourceBinding: RemoteFileMaterializer]
    private let globalLimit: Int
    private var active: [RemoteSourceBinding: Int] = [:]
    private var queue: [(RemoteTransferID, RemoteTransferRequest)] = []
    private var closed = false
    private var jobs: [RemoteTransferID: Job] = [:]
    private var tasks: [RemoteTransferID: Task<Void, Never>] = [:]
    private var observers: [RemoteTransferID: [UUID: CheckedContinuation<Void, any Error>]] = [:]

    public init(materializer: RemoteFileMaterializer, maxConcurrentTransfers: Int = 1) {
        self.materializers = [materializer.sourceBinding: materializer]
        self.globalLimit = max(1, maxConcurrentTransfers)
    }

    /// One scheduler owns global and per-binding limits for all supplied sources.
    /// A binding must occur exactly once; providers remain connected by the caller.
    public init(materializers: [RemoteFileMaterializer], maxConcurrentTransfers: Int = 4) throws {
        var bindings: [RemoteSourceBinding: RemoteFileMaterializer] = [:]
        for materializer in materializers {
            guard bindings[materializer.sourceBinding] == nil else {
                throw RemoteSyncError.unsupported(operation: "重复的传输来源绑定")
            }
            bindings[materializer.sourceBinding] = materializer
        }
        self.materializers = bindings
        self.globalLimit = max(1, maxConcurrentTransfers)
    }

    /// Enqueues one materialization task and returns immediately with its ID.
    public func submit(_ request: RemoteTransferRequest) -> RemoteTransferID {
        let id = RemoteTransferID()
        jobs[id] = Job(
            snapshot: RemoteTransferSnapshot(id: id, phase: .preparing),
            result: nil
        )
        if closed {
            update(id: id, phase: .cancelled, error: RemoteSyncError.cancelled)
            jobs[id]?.result = .failure(RemoteSyncError.cancelled)
        } else if materializers[request.reference.source] == nil {
            let error = RemoteSyncError.unsupported(operation: "未注册传输来源")
            update(id: id, phase: .failed, error: error)
            jobs[id]?.result = .failure(error)
        } else {
            queue.append((id, request))
            schedule()
        }
        return id
    }

    public func snapshot(_ id: RemoteTransferID) -> RemoteTransferSnapshot? {
        jobs[id]?.snapshot
    }

    /// Waits for and takes the completed materialized-file lease exactly once.
    public func wait(for id: RemoteTransferID) async throws -> MaterializedFileLease {
        guard jobs[id] != nil else { throw RemoteSyncError.notFound(path: id.uuidString) }
        // Waiters are individually cancellable without cancelling the submitted job.
        // Cancellation of the job itself is explicit through cancel(id).
        let observerID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: RemoteSyncError.cancelled) }
                else if jobs[id]?.snapshot.isTerminal != false { continuation.resume() }
                else { observers[id, default: [:]][observerID] = continuation }
            }
        }, onCancel: { Task { await self.cancelObserver(observerID, jobID: id) } })
        try Task.checkCancellation()
        guard var job = jobs[id] else {
            throw RemoteSyncError.notFound(path: id.uuidString)
        }
        guard !job.resultWasTaken else { throw RemoteSyncError.conflict(path: id.uuidString) }
        guard let result = job.result else {
            throw RemoteSyncError.underlying("传输任务没有可领取的结果")
        }
        switch result {
        case .success(let lease):
            guard !job.resultWasTaken else {
                throw RemoteSyncError.conflict(path: id.uuidString)
            }
            job.resultWasTaken = true
            job.result = nil
            jobs[id] = job
            return lease
        case .failure(let error):
            throw error
        }
    }

    private func cancelObserver(_ id: UUID, jobID: UUID) {
        observers[jobID]?.removeValue(forKey: id)?.resume(throwing: RemoteSyncError.cancelled)
        if observers[jobID]?.isEmpty == true { observers[jobID] = nil }
    }

    /// Requests cancellation. A completed but not-yet-taken lease is released.
    public func cancel(_ id: RemoteTransferID) async {
        if let index = queue.firstIndex(where: { $0.0 == id }) {
            queue.remove(at: index)
            update(id: id, phase: .cancelled, error: RemoteSyncError.cancelled)
            jobs[id]?.result = .failure(RemoteSyncError.cancelled)
        }
        tasks[id]?.cancel()
        guard var job = jobs[id] else { return }
        if case .success(let lease)? = job.result, !job.resultWasTaken {
            job.resultWasTaken = true
            job.result = nil
            jobs[id] = job
            await lease.release()
        }
    }

    /// Cancels all currently known tasks and releases completed results.
    public func cancelAll() async {
        for id in Array(jobs.keys) {
            await cancel(id)
        }
    }

    /// Cancels and drains every owned task. Does not disconnect sources or
    /// shut down shared materializers. Caller-owned leases remain valid.
    public func shutdown() async {
        closed = true
        await cancelAll()
        let pending = Array(tasks.values)
        for task in pending { await task.value }
    }

    /// Explicitly discards terminal history. An unclaimed successful lease is released.
    public func forget(_ id: RemoteTransferID) async throws {
        guard let job = jobs[id] else { return }
        guard job.snapshot.isTerminal else { throw RemoteSyncError.conflict(path: id.uuidString) }
        jobs[id] = nil
        if case .success(let lease)? = job.result { await lease.release() }
    }

    private func schedule() {
        while tasks.count < globalLimit,
              let index = queue.firstIndex(where: {
                  let binding = $0.1.reference.source
                  return active[binding, default: 0] < (materializers[binding]?.maxConcurrentTransfers ?? 1)
              }) {
            let (id, request) = queue.remove(at: index)
            let binding = request.reference.source
            active[binding, default: 0] += 1
            tasks[id] = Task { await self.execute(id: id, request: request) }
        }
    }

    private func execute(id: RemoteTransferID, request: RemoteTransferRequest) async {
        defer {
            tasks[id] = nil
            active[request.reference.source, default: 1] -= 1
            schedule()
        }
        do {
            try Task.checkCancellation()
            guard let materializer = materializers[request.reference.source] else {
                throw RemoteSyncError.unsupported(operation: "未注册传输来源")
            }
            // AsyncStream bounds pending progress instead of spawning a Task per byte callback.
            let (stream, continuation) = AsyncStream<RemoteTransferProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            var options = request.options
            let callerProgress = options.transferProgress
            options.transferProgress = { progress in
                callerProgress?(progress)
                continuation.yield(progress)
            }
            let observation = Task {
                for await progress in stream { self.recordProgress(id: id, progress: progress) }
            }
            let lease: MaterializedFileLease
            do {
                lease = try await materializer.materialize(request.reference, options: options)
            } catch {
                continuation.finish()
                await observation.value
                throw error
            }
            continuation.finish()
            await observation.value
            // A delivered lease proves commit. Cancellation racing after this point
            // cannot rewrite it as a failure or leak an unowned lease.
            update(id: id, phase: .completed, url: lease.url)
            jobs[id]?.result = .success(lease)
            if Task.isCancelled { await cancel(id) }
        } catch {
            let cancelled = Task.isCancelled || isCancellation(error)
            update(id: id, phase: cancelled ? .cancelled : .failed,
                   error: cancelled ? RemoteSyncError.cancelled : error)
            jobs[id]?.result = .failure(cancelled ? RemoteSyncError.cancelled : error)
        }
    }

    private func recordProgress(id: RemoteTransferID, progress: RemoteTransferProgress) {
        guard let job = jobs[id], !job.snapshot.isTerminal,
              progress.sequence > (job.snapshot.progress?.sequence ?? 0) else { return }
        jobs[id]?.snapshot = RemoteTransferSnapshot(id: id, phase: progress.phase, progress: progress)
    }

    private func update(
        id: RemoteTransferID,
        phase: RemoteTransferPhase,
        error: Error? = nil,
        url: URL? = nil
    ) {
        guard var job = jobs[id] else { return }
        guard !job.snapshot.isTerminal else { return }
        let prior = job.snapshot.progress
        let progress = RemoteTransferProgress(phase: phase, completedBytes: prior?.completedBytes ?? 0,
                                               totalBytes: prior?.totalBytes,
                                               sequence: (prior?.sequence ?? 0) + 1)
        job.snapshot = RemoteTransferSnapshot(
            id: id,
            phase: phase,
            progress: progress,
            errorDescription: error.map(safeErrorDescription),
            materializedFileURL: url
        )
        jobs[id] = job
        if job.snapshot.isTerminal {
            for observer in observers.removeValue(forKey: id)?.values ?? [:].values { observer.resume() }
        }
    }

    private func safeErrorDescription(_ error: Error) -> String {
        guard let error = error as? RemoteSyncError else { return "传输失败" }
        switch error {
        case .cancelled: return "任务已取消"
        case .authenticationFailed: return "认证失败"
        case .notConnected: return "来源尚未连接"
        case .notFound: return "文件不存在"
        case .permissionDenied: return "无权访问文件"
        case .unsupported: return "不支持所请求的操作"
        case .rateLimited: return "来源限流"
        case .network: return "网络错误"
        case .conflict: return "文件版本或状态冲突"
        case .integrityMismatch: return "文件校验不一致"
        case .uploadSessionExpired: return "上传会话已过期"
        case .sourceSnapshotMissing: return "上传源快照不可用"
        case .uploadCommitUnknown: return "上传结果需要核对"
        case .secureStorageUnavailable: return "安全存储不可用"
        case .underlying: return "传输失败"
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? RemoteSyncError, error == .cancelled { return true }
        return false
    }
}
