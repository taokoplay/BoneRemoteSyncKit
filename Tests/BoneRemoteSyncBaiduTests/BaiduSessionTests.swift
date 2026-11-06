#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncBaidu

private final class BaiduClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func read() -> Date { lock.withLock { value } }
    func advance() { lock.withLock { value = value.addingTimeInterval(500) } }
}
private actor RefreshCalls {
    var count = 0
    func increment() { count += 1 }
}
@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python3")) struct BaiduSessionTests {
    @Test func concurrentRefreshIsSingleUseAndAccountChecked() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let clock = BaiduClock(), calls = RefreshCalls()
        let source = BaiduDriveSource(configuration: server.configuration, endpoints: server.endpoints, refreshToken: { old in
            await calls.increment()
            #expect(old.refreshToken == "refresh-1")
            try await Task.sleep(nanoseconds: 80_000_000)
            return try .init(accessToken: "rotated", refreshToken: "refresh-2", expiresAt: .distantFuture)
        }, now: clock.read)
        try await source.connect(.oauth(accessToken: "fixture-token", refreshToken: "refresh-1", expiresAt: clock.read().addingTimeInterval(300)))
        clock.advance()
        async let a = source.list(path: "/")
        async let b = source.stat(path: "/a.txt")
        let (page, entry) = try await (a, b)
        #expect(page.entries.count == 3 && entry.size == Int64(BaiduTestServer.payload.count))
        #expect(await calls.count == 1)
        let requests = try server.requests()
        #expect(requests.filter { $0["method"] as? String == "uinfo" }.count == 2)
        #expect((requests.last?["query"] as? [String: [String]])?["access_token"] == ["rotated"])
        await source.disconnect()
    }
    @Test(arguments: [false, true]) func refreshFailureOrWrongUserInvalidatesWithoutRetry(_ wrongUser: Bool) async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let clock = BaiduClock(), calls = RefreshCalls()
        let source = BaiduDriveSource(configuration: server.configuration, endpoints: server.endpoints, refreshToken: { _ in
            await calls.increment()
            if !wrongUser { throw URLError(.cannotConnectToHost) }
            return try .init(accessToken: "other-user", refreshToken: "next", expiresAt: .distantFuture)
        }, now: clock.read)
        try await source.connect(.oauth(accessToken: "fixture-token", refreshToken: "old", expiresAt: clock.read().addingTimeInterval(300)))
        clock.advance()
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/") }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.list(path: "/") }
        #expect(await calls.count == 1)
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "list" })
    }
    @Test func expectedAccountMismatchPreventsDirectoryRequests() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let source = server.source()
        await #expect(throws: BaiduDriveError.invalidReference) { try await source.connect(server.credential, expectedUserID: "222") }
        #expect(try server.requests().count == 1)
    }
    @Test func expiredTokenWithoutRefresherRequiresNewAuthorization() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let source = server.source()
        await #expect(throws: RemoteSyncError.self) {
            try await source.connect(.oauth(accessToken: "expired", refreshToken: nil, expiresAt: .distantPast))
        }
        #expect(try server.requests().isEmpty)
    }
}
#endif
