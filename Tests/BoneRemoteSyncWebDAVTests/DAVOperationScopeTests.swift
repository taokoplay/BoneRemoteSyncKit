import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite struct DAVOperationScopeTests {
    @Test func closedPoolWaitReturnsAndCancelledWaitDoesNotHang() async throws {
        let pool = DAVHTTP.session(timeout: 10)
        let waiting = Task { try await pool.waitUntilClosed() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        pool.invalidateAndCancel()
        try await pool.waitUntilClosed()
    }

    @Test func deadlineCancelsInFlightWorkAndScopeRemembersExpiry() async throws {
        let pool = DAVHTTP.session(timeout: 10)
        defer { pool.invalidateAndCancel() }
        let scope = DAVOperationScope(pool: pool, policy: .init(totalTimeout: 0.03))
        await #expect(throws: DAVOperationTimedOut.self) {
            try await scope.run { try await Task.sleep(nanoseconds: 5_000_000_000); return 1 }
        }
        #expect(throws: DAVOperationTimedOut.self) { try scope.check() }
    }

    @Test func disconnectWakesBackoffWithoutWaitingForIt() async throws {
        let pool = DAVHTTP.session(timeout: 10)
        let policy = WebDAVRetryPolicy(initialDelay: 30, maxDelay: 30, totalTimeout: 60)
        let scope = DAVOperationScope(pool: pool, policy: policy)
        let (events, ready) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { ready.finish() }
        let cancelled = ScopeSleepProbe()
        let retryRuntime = DAVRetryRuntime(now: DAVRetryRuntime.live.now, wallNow: { Date() }, sleep: { nanos in
            ready.yield(1)
            do { try await Task.sleep(nanoseconds: nanos) }
            catch { cancelled.mark(); throw error }
        }, randomUnit: { 1 })
        let task = Task {
            try await scope.run {
                try await DAVRetryExecutor.run(policy: policy, scope: scope, runtime: retryRuntime) { _ -> Int in
                    throw URLError(.timedOut)
                }
            }
        }
        for await _ in events { break }
        pool.invalidateAndCancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // Verify cancellation of the actual backoff, not a scheduler-sensitive wall-clock threshold.
        #expect(cancelled.value)
    }

    @Test func cancellationAndCloseRegistrationRaceAlwaysConverges() async throws {
        for _ in 0..<100 {
            let pool = DAVHTTP.session(timeout: 10)
            let task = Task { try await pool.waitUntilClosed() }
            task.cancel()
            pool.invalidateAndCancel()
            _ = try? await task.value
        }
    }
}

private final class ScopeSleepProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func mark() { lock.withLock { cancelled = true } }
    var value: Bool { lock.withLock { cancelled } }
}
