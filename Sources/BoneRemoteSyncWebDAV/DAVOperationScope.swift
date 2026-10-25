import Foundation
import BoneRemoteSyncCore

struct DAVOperationTimedOut: Error {}

/// Cooperative total deadline. Synchronous IO and user callbacks cannot be forcibly interrupted.
struct DAVOperationScope: Sendable {
    let pool: DAVHTTPSession
    let runtime: DAVRetryRuntime
    let deadline: UInt64?

    init(pool: DAVHTTPSession, policy: WebDAVRetryPolicy, runtime: DAVRetryRuntime = .live) {
        self.pool = pool; self.runtime = runtime
        if let timeout = policy.totalTimeout, timeout.isFinite, timeout > 0, timeout <= 86_400 {
            let (value, overflow) = runtime.now().addingReportingOverflow(UInt64(timeout * 1_000_000_000))
            deadline = overflow ? UInt64.max : value
        } else { deadline = nil }
    }
    var remaining: TimeInterval? {
        let now = runtime.now()
        return deadline.map { Double($0 > now ? $0 - now : 0) / 1_000_000_000 }
    }
    func check() throws {
        try Task.checkCancellation()
        if pool.isClosed { throw CancellationError() }
        if let deadline, runtime.now() >= deadline { throw DAVOperationTimedOut() }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try check()
        // Without a total deadline there can be no retry sleep (policy validation enforces that).
        // URLSession invalidation wakes network consumers; disk loops call check themselves.
        guard let deadline else { let value = try await work(); try check(); return value }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { let value = try await work(); try check(); return value }
            group.addTask {
                let now = runtime.now()
                if now < deadline { try await runtime.sleep(deadline - now) }
                throw DAVOperationTimedOut()
            }
            group.addTask { try await pool.waitUntilClosed(); throw CancellationError() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// One-shot result also handles cancellation before continuation registration.
final class DAVCloseWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<Void, Error>? in
                if let result = self.result { return result }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
    func finish(_ value: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard result == nil else { return nil }
            result = value
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: value)
    }
}
