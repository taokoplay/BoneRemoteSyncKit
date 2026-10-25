import Foundation

struct DAVRetryRuntime: Sendable {
    let now: @Sendable () -> UInt64
    let wallNow: @Sendable () -> Date
    let sleep: @Sendable (UInt64) async throws -> Void
    let randomUnit: @Sendable () -> Double
    static let live = DAVRetryRuntime(now: { DispatchTime.now().uptimeNanoseconds }, wallNow: { Date() },
        sleep: { try await Task.sleep(nanoseconds: $0) }, randomUnit: { Double.random(in: 0...1) })
}

enum DAVRequestFailure: Error {
    case http(status: Int, retryAfter: TimeInterval?, path: String)
    case nonRetryable(any Error)
}

enum DAVRetryDecision: Equatable, Sendable {
    case stop
    case wait(nanoseconds: UInt64)
}

enum DAVRetryExecutor {
    static func run<T: Sendable>(policy: WebDAVRetryPolicy, scope: DAVOperationScope,
        runtime: DAVRetryRuntime = .live, attempt: @escaping @Sendable (Int) async throws -> T) async throws -> T {
        for number in 1...policy.maxAttempts {
            try scope.check()
            do { return try await attempt(number) }
            catch {
                try scope.check()
                switch decision(error: error, failedAttempt: number, policy: policy,
                                remaining: scope.remaining, runtime: runtime) {
                case .stop: throw error
                case .wait(let nanoseconds): try await runtime.sleep(nanoseconds)
                }
            }
        }
        throw CancellationError()
    }

    static func decision(error: any Error, failedAttempt: Int, policy: WebDAVRetryPolicy,
                         remaining: TimeInterval?, runtime: DAVRetryRuntime) -> DAVRetryDecision {
        guard (try? policy.validate()) != nil, failedAttempt >= 1, failedAttempt < policy.maxAttempts else { return .stop }
        let serverDelay: TimeInterval?
        if let failure = error as? DAVRequestFailure {
            guard case .http(let status, let retryAfter, _) = failure,
                  [408, 429, 500, 502, 503, 504].contains(status) else { return .stop }
            serverDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 && $0 <= 31_536_000 ? $0 : nil }
        } else if let error = error as? URLError,
                  [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
            serverDelay = nil
        } else { return .stop }
        let exponent = pow(2.0, Double(failedAttempt - 1))
        let bound = min(policy.maxDelay, policy.initialDelay * exponent)
        let random = runtime.randomUnit()
        let unit = random.isFinite ? min(1, max(0, random)) : 1
        let delay = max(bound * (0.5 + 0.5 * unit), serverDelay ?? 0)
        if let remaining, !remaining.isFinite || remaining <= delay { return .stop }
        return .wait(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}
