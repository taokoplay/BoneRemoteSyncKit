import Foundation

/// Each active response leases one serial-delegate URLSession. A stalled consumer can block only
/// its own callback queue. Idle leases are reused for connection pooling; at most four are retained.
/// Active requests remain caller-bounded (e.g. RemoteWalkOptions); this is not a transfer scheduler.
final class DAVHTTPSession: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private var closed = false
    private var closeWaiters: [UUID: DAVCloseWaiter] = [:]
    var isClosed: Bool { lock.withLock { closed } }

    func waitUntilClosed() async throws {
        let id = UUID()
        let waiter = DAVCloseWaiter()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let alreadyClosed = lock.withLock {
                if closed { return true }
                closeWaiters[id] = waiter
                return false
            }
            defer { _ = lock.withLock { closeWaiters.removeValue(forKey: id) } }
            if alreadyClosed { waiter.finish(.success(())) }
            try await waiter.wait()
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
            _ = self.lock.withLock { self.closeWaiters.removeValue(forKey: id) }
        }
    }
    private var idle: [URLSession] = []
    private var active: [ObjectIdentifier: URLSession] = [:]

    init(timeout: TimeInterval) { self.timeout = timeout }
    deinit { invalidateAndCancel() }

    func start(request: URLRequest, state: DAVBodyState, uploadFile: URL? = nil,
               progress: (@Sendable (Int64) -> Void)? = nil) throws {
        try lock.withLock {
            let session = try acquireLocked()
            let delegate = session.delegate as! DAVSessionDelegate
            let task: URLSessionDataTask = uploadFile.map { session.uploadTask(with: request, fromFile: $0) }
                ?? session.dataTask(with: request)
            delegate.register(state, for: task, progress: progress) { [weak self] reusable in
                guard let self else { DAVHTTP.invalidate(session); return }
                self.release(session, reusable: reusable)
            }
            state.start(task)
        }
    }

    // Also used by focused lease lifecycle tests. Production creates/registers/starts atomically above.
    func acquire() throws -> URLSession { try lock.withLock { try acquireLocked() } }

    private func acquireLocked() throws -> URLSession {
        guard !closed else { throw CancellationError() }
        let session = idle.popLast() ?? DAVHTTP.makeSession(timeout: timeout)
        active[ObjectIdentifier(session)] = session
        return session
    }

    func release(_ session: URLSession, reusable: Bool) {
        let retained = lock.withLock {
            active.removeValue(forKey: ObjectIdentifier(session))
            if !closed, reusable, idle.count < 4 { idle.append(session); return true }
            return false
        }
        if !retained { DAVHTTP.invalidate(session) }
    }

    func invalidateAndCancel() {
        let (sessions, waiters): ([URLSession], [DAVCloseWaiter]) = lock.withLock {
            closed = true
            let sessions = idle + Array(active.values)
            let waiters = Array(closeWaiters.values)
            idle.removeAll(); active.removeAll(); closeWaiters.removeAll()
            return (sessions, waiters)
        }
        waiters.forEach { $0.finish(.success(())) }
        sessions.forEach { DAVHTTP.invalidate($0) }
    }
}
