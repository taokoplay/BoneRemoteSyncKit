import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

let fixedRetryRuntime = DAVRetryRuntime(now: { 0 }, wallNow: { Date(timeIntervalSince1970: 1792458000) }, sleep: { _ in }, randomUnit: { 1 })

@Suite struct DAVRetryPolicyTests {
    @Test func policyDefaultsAndValidation() throws {
        #expect(WebDAVRetryPolicy.none.maxAttempts == 1)
        #expect(WebDAVRetryPolicy.none.totalTimeout == nil)
        #expect(WebDAVRetryPolicy.standard.maxAttempts == 3)
        try WebDAVRetryPolicy.standard.validate()
        for policy in [WebDAVRetryPolicy(maxAttempts: 0), .init(maxAttempts: 9), .init(initialDelay: .nan),
                       .init(initialDelay: -.infinity), .init(maxDelay: 301), .init(initialDelay: 2, maxDelay: 1),
                       .init(totalTimeout: 0), .init(totalTimeout: .infinity), .init(maxAttempts: 2, totalTimeout: nil)] {
            #expect(throws: (any Error).self) { try policy.validate() }
        }
    }

    @Test func retryAfterIsNotClampedBelowServerMinimum() {
        let policy = WebDAVRetryPolicy(maxAttempts: 3, initialDelay: 1, maxDelay: 2, totalTimeout: 30)
        let failure = DAVRequestFailure.http(status: 503, retryAfter: 7, path: "/")
        #expect(DAVRetryExecutor.decision(error: failure, failedAttempt: 1, policy: policy, remaining: 20, runtime: fixedRetryRuntime) == .wait(nanoseconds: 7_000_000_000))
        #expect(DAVRetryExecutor.decision(error: failure, failedAttempt: 1, policy: policy, remaining: 6, runtime: fixedRetryRuntime) == .stop)
        #expect(DAVRetryExecutor.decision(error: failure, failedAttempt: 3, policy: policy, remaining: 20, runtime: fixedRetryRuntime) == .stop)
    }

    @Test func httpDateRetryAfterUsesInjectedClock() throws {
        let now = Date(timeIntervalSince1970: 784111770)
        let response = try #require(HTTPURLResponse(url: URL(string: "http://127.0.0.1/")!, statusCode: 503, httpVersion: nil,
            headerFields: ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"]))
        let runtime = DAVRetryRuntime(now: { 0 }, wallNow: { now }, sleep: { _ in }, randomUnit: { 1 })
        do {
            try DAVHTTP.validateForRetry(response, path: "/", allowed: [200], now: runtime.wallNow())
            Issue.record("expected HTTP failure")
        } catch {
            #expect(DAVRetryExecutor.decision(error: error, failedAttempt: 1, policy: .standard, remaining: 20, runtime: runtime)
                == .wait(nanoseconds: 7_000_000_000))
        }
    }

    @Test(arguments: [408, 429, 500, 502, 503, 504]) func allowedStatusRetries(status: Int) {
        #expect(DAVRetryExecutor.decision(error: DAVRequestFailure.http(status: status, retryAfter: nil, path: "/"), failedAttempt: 1,
            policy: .standard, remaining: 100, runtime: fixedRetryRuntime) == .wait(nanoseconds: 500_000_000))
    }

    @Test(arguments: [301, 401, 403, 404, 409, 412, 416, 423, 501, 505]) func otherStatusStops(status: Int) {
        #expect(DAVRetryExecutor.decision(error: DAVRequestFailure.http(status: status, retryAfter: nil, path: "/"), failedAttempt: 1,
            policy: .standard, remaining: 100, runtime: fixedRetryRuntime) == .stop)
    }

    @Test func transportWhitelistDoesNotUsePublicRetryableHint() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed] {
            #expect(DAVRetryExecutor.decision(error: URLError(code), failedAttempt: 1, policy: .standard, remaining: 100, runtime: fixedRetryRuntime) != .stop)
        }
        let denied: [any Error] = [CancellationError(), URLError(.cancelled), URLError(.serverCertificateUntrusted), URLError(.badURL),
            RemoteSyncError.network("not a raw network failure"), RemoteSyncError.integrityMismatch(path: "/"),
            DAVRequestFailure.nonRetryable(URLError(.timedOut))]
        for error in denied {
            #expect(DAVRetryExecutor.decision(error: error, failedAttempt: 1, policy: .standard, remaining: 100, runtime: fixedRetryRuntime) == .stop)
        }
    }

    @Test func exponentialBoundJitterAndZeroDelay() {
        let error = URLError(.timedOut)
        let policy = WebDAVRetryPolicy(maxAttempts: 8, initialDelay: 1, maxDelay: 3, totalTimeout: 30)
        #expect(DAVRetryExecutor.decision(error: error, failedAttempt: 2, policy: policy, remaining: 20, runtime: fixedRetryRuntime) == .wait(nanoseconds: 2_000_000_000))
        #expect(DAVRetryExecutor.decision(error: error, failedAttempt: 7, policy: policy, remaining: 20, runtime: fixedRetryRuntime) == .wait(nanoseconds: 3_000_000_000))
        let low = DAVRetryRuntime(now: { 0 }, wallNow: { Date() }, sleep: { _ in }, randomUnit: { 0 })
        #expect(DAVRetryExecutor.decision(error: error, failedAttempt: 1, policy: policy, remaining: 20, runtime: low) == .wait(nanoseconds: 500_000_000))
        #expect(DAVRetryExecutor.decision(error: error, failedAttempt: 1, policy: .init(initialDelay: 0, maxDelay: 0), remaining: 20, runtime: low) == .wait(nanoseconds: 0))
    }

    @Test func resumableOptionsAreExplicitAndBounded() throws {
        try WebDAVResumableDownloadOptions(sourceNamespace: "account-uuid").validate()
        for options in [WebDAVResumableDownloadOptions(sourceNamespace: ""), .init(sourceNamespace: "a\0b"),
                        .init(sourceNamespace: String(repeating: "x", count: 257)),
                        .init(sourceNamespace: "id", checkpointIntervalBytes: 0),
                        .init(sourceNamespace: "id", checkpointIntervalBytes: Int64.max)] {
            #expect(throws: (any Error).self) { try options.validate() }
        }
    }
}
