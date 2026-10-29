#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

extension OneDriveTestServer {
    func source(onTokenRefresh: (@Sendable (OneDriveToken) throws -> Void)? = nil) -> OneDriveSource {
        OneDriveSource(configuration: configuration, endpoints: endpoints, onTokenRefresh: onTokenRefresh)
    }
    var credential: RemoteCredential { .oauth(accessToken: "NEW", refreshToken: "REFRESH", expiresAt: Date().addingTimeInterval(3600)) }
}
final class TokenProbe: @unchecked Sendable {
    private let lock = NSLock(); private var tokens: [String] = []
    func record(_ token: OneDriveToken) { lock.withLock { tokens.append(token.accessToken) } }
    var count: Int { lock.withLock { tokens.count } }
}
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveBrowsingTests {
    @Test func paginatesWithStableIDsAndHiddenFiltering() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        #expect(source.kind == .cloudAPI)
        // Write-capable since v1.1, but still no ranged download, resumable upload or server-side copy.
        #expect(source.capabilities.upload); #expect(source.capabilities.remove)
        #expect(!source.capabilities.rangedDownload); #expect(!source.capabilities.resumableUpload); #expect(!source.capabilities.copy)
        let first = try await source.list(path: "/", request: RemoteListRequest(limit: 2))
        #expect(first.entries.count == 2); #expect(first.entries[0].isDirectory)
        #expect(first.entries[1].path == "/资料 #?%.bin"); #expect(first.entries[1].size == 1048576)
        #expect(first.entries[1].id != first.entries[1].path)
        let cursor = try #require(first.nextCursor)
        #expect(!cursor.contains("http"))
        let next = try await source.list(path: "/", request: RemoteListRequest(cursor: cursor, limit: 2))
        #expect(next.entries.map(\.name) == ["last.txt"]); #expect(next.isLastPage)
        let root = try await source.stat(path: "/"); #expect(root.isDirectory)
        let file = try await source.stat(path: "/资料 #?%.bin"); #expect(file.id == first.entries[1].id)
        #expect(try server.requests().contains { ($0["path"] as? String)?.contains("%23%3F%25") == true })
        await source.disconnect()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/") }
    }
    @Test(arguments: ["evil-next", "other-next", "remote"])
    func rejectsUnsafePaginationAndUnsupportedFacets(scenario: String) async throws {
        let server = try OneDriveTestServer(scenario); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/") }
        #expect(try !server.requests().contains { ($0["path"] as? String)?.contains("stolen") == true })
        await source.disconnect()
    }
    @Test func cursorCannotCrossConnectionPathOrOptions() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        let page = try await source.list(path: "/"); let cursor = try #require(page.nextCursor)
        for request in [RemoteListRequest(cursor: "https://evil.invalid"), RemoteListRequest(cursor: cursor, includeHidden: true), RemoteListRequest(cursor: cursor, limit: 10)] {
            await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/", request: request) }
        }
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/folder", request: RemoteListRequest(cursor: cursor)) }
        try await source.connect(server.credential)
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/", request: RemoteListRequest(cursor: cursor)) }
        await source.disconnect()
    }
    @Test func rejectsBusinessAndWrongCredentialAndMapsErrors() async throws {
        let server = try OneDriveTestServer("business"); defer { server.cleanUp() }; let source = server.source()
        await #expect(throws: RemoteSyncError.self) { try await source.connect(server.credential) }
        await #expect(throws: RemoteSyncError.self) { try await source.connect(.anonymous) }
        let other = try OneDriveTestServer(); defer { other.cleanUp() }; let connected = other.source()
        try await connected.connect(other.credential)
        await #expect(throws: RemoteSyncError.notFound(path: "/missing")) { try await connected.stat(path: "/missing") }
        await connected.disconnect()
        let throttled = try OneDriveTestServer("error"); defer { throttled.cleanUp() }
        await #expect(throws: RemoteSyncError.rateLimited(retryAfter: 7)) { try await throttled.source().connect(throttled.credential) }
    }
}

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveLifecycleTests {
    @Test func proactiveAndReactiveRefreshAreSingleFlight() async throws {
        for proactive in [true, false] {
            let server = try OneDriveTestServer("refresh-slow"); defer { server.cleanUp() }; let probe = TokenProbe(); let source = server.source { probe.record($0) }
            let credential = RemoteCredential.oauth(accessToken: proactive ? "NEW" : "OLD", refreshToken: "REFRESH", expiresAt: Date().addingTimeInterval(proactive ? -1 : 3600))
            try await source.connect(credential)
            async let a = source.stat(path: "/file"); async let b = source.stat(path: "/file")
            _ = try await (a,b)
            #expect(probe.count == 1); #expect(try server.requests().filter { $0["method"] as? String == "POST" }.count == 1)
            await source.disconnect()
        }
    }
    @Test func disconnectCancelsConnectingAndDoesNotPublishOldState() async throws {
        let server = try OneDriveTestServer("connect-slow"); defer { server.cleanUp() }; let source = server.source()
        let task = Task { try await source.connect(server.credential) }
        for _ in 0..<100 { if try !server.requests().isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        await source.disconnect()
        await #expect(throws: RemoteSyncError.self) { try await task.value }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/") }
    }
    @Test func tokenPersistenceFailureClosesAuthentication() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }
        let source = server.source { _ in throw RemoteSyncError.underlying("SECRET-PERSISTENCE") }
        await #expect(throws: RemoteSyncError.self) {
            try await source.connect(.oauth(accessToken: "OLD", refreshToken: "REFRESH", expiresAt: Date().addingTimeInterval(-1)))
        }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/") }
    }
}
#endif

#if os(macOS)
extension OneDriveSource {
    func expireForTest() { token = OneDriveToken(accessToken: "OLD", refreshToken: "REFRESH", expiresAt: .distantPast) }
}
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveRefreshCancellationTests {
    @Test func cancellingOneWaiterDoesNotDiscardRotatedToken() async throws {
        let server = try OneDriveTestServer("refresh-slow"); defer { server.cleanUp() }; let probe = TokenProbe(); let source = server.source { probe.record($0) }
        try await source.connect(server.credential); await source.expireForTest()
        let cancelled = Task { try await source.stat(path: "/file") }
        for _ in 0..<100 { if try server.requests().contains(where: { $0["method"] as? String == "POST" }) { break }; try await Task.sleep(for: .milliseconds(5)) }
        cancelled.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await cancelled.value }
        _ = try await source.stat(path: "/file")
        #expect(probe.count == 1)
        #expect(try server.requests().filter { $0["method"] as? String == "POST" }.count == 1)
        await source.disconnect()
    }
}
#endif

#if os(macOS)
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveConcurrentLifecycleTests {
    @Test func simultaneousExpiredRequestsShareOneRefresh() async throws {
        let server = try OneDriveTestServer("refresh-slow"); defer { server.cleanUp() }; let probe = TokenProbe(); let source = server.source { probe.record($0) }
        try await source.connect(server.credential); await source.expireForTest()
        try await withThrowingTaskGroup(of: RemoteEntry.self) { group in
            for _ in 0..<12 { group.addTask { try await source.stat(path: "/file") } }
            for try await entry in group { #expect(entry.size == 1048576) }
        }
        #expect(probe.count == 1); #expect(try server.requests().filter { $0["method"] as? String == "POST" }.count == 1)
        await source.disconnect()
    }
    @Test func disconnectedRefreshCannotPublishIntoNewConnection() async throws {
        let server = try OneDriveTestServer("refresh-slow"); defer { server.cleanUp() }; let probe = TokenProbe(); let source = server.source { probe.record($0) }
        try await source.connect(server.credential); await source.expireForTest()
        let old = Task { try await source.stat(path: "/file") }
        for _ in 0..<100 { if try server.requests().contains(where: { $0["method"] as? String == "POST" }) { break }; try await Task.sleep(for: .milliseconds(5)) }
        try await source.connect(server.credential)
        await #expect(throws: RemoteSyncError.cancelled) { try await old.value }
        #expect(probe.count == 0)
        #expect(try await source.stat(path: "/file").size == 1048576)
        await source.disconnect()
    }
    @Test func failedRefreshDoesNotReusePossiblyRotatedCredential() async throws {
        let server = try OneDriveTestServer("token-error"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); await source.expireForTest()
        await #expect(throws: RemoteSyncError.self) { try await source.stat(path: "/file") }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/file") }
        #expect(try server.requests().filter { $0["method"] as? String == "POST" }.count == 1)
        await source.disconnect()
    }
}
#endif

#if os(macOS)
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveProtocolBoundaryTests {
    @Test(arguments: ["graph-redirect","large-json", "unknown-large-json"])
    func graphFailuresDoNotRedirectOrExposeBody(scenario: String) async throws {
        let server = try OneDriveTestServer(scenario); defer { server.cleanUp() }; let source = server.source()
        await #expect(throws: RemoteSyncError.self) { try await source.connect(server.credential) }
        #expect(try server.requests().count == 1)
    }
    @Test(arguments: ["bad-name", "duplicate"])
    func invalidChildrenFailClosed(scenario: String) async throws {
        let server = try OneDriveTestServer(scenario); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/") }
        await source.disconnect()
    }
    @Test func unauthorizedRefreshHasOneReplayBudget() async throws {
        let server = try OneDriveTestServer("always401"); defer { server.cleanUp() }; let probe = TokenProbe(); let source = server.source { probe.record($0) }
        await #expect(throws: RemoteSyncError.self) { try await source.connect(server.credential) }
        #expect(probe.count == 1)
        let requests = try server.requests()
        #expect(requests.filter { $0["method"] as? String == "GET" }.count == 2)
        #expect(requests.filter { $0["method"] as? String == "POST" }.count == 1)
    }
    @Test func consumedCursorAndLimitsAreExplicit() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        for limit in [0,-1] {
            await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/", request: .init(limit: limit)) }
        }
        let first = try await source.list(path: "/", request: .init(includeHidden: true))
        #expect(first.entries.contains { $0.name == ".secret" })
        let cursor = try #require(first.nextCursor)
        _ = try await source.list(path: "/", request: .init(cursor: cursor, includeHidden: true))
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/", request: .init(cursor: cursor, includeHidden: true)) }
        await source.disconnect()
    }
}
#endif

#if os(macOS)
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveReviewRegressionTests {
    @Test func defaultVisitorWalkClampsPageSizeWithoutChangingEntryBudget() async throws {
        let server = try OneDriveTestServer("walk"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        let result = try await source.walk(path: "/", options: .init()) { _ in }
        #expect(result.entryCount == 3); #expect(result.directoryCount == 2)
        #expect(try server.requests().contains { ($0["path"] as? String)?.contains("$top=200") == true })
        await source.disconnect()
    }
    @Test func abandonedCursorsAreEvictedAndFullTableCanAdvance() async throws {
        let server = try OneDriveTestServer("three-pages"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        var oldest: String?; var newest: String?
        for index in 0..<256 {
            let page = try await source.list(path: "/")
            if index == 0 { oldest = page.nextCursor }; newest = page.nextCursor
        }
        let next = try await source.list(path: "/", request: .init(cursor: newest))
        #expect(next.entries.map(\.name) == ["middle.txt"])
        #expect(next.nextCursor != nil)
        let fresh = try await source.list(path: "/")
        #expect(fresh.nextCursor != nil)
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/", request: .init(cursor: oldest)) }
        #expect(await source.cursors.count <= 256)
        let last = try await source.list(path: "/", request: .init(cursor: next.nextCursor))
        #expect(last.entries.map(\.name) == ["last.txt"]); #expect(last.isLastPage)
        await source.disconnect()
    }
}
#endif

#if os(macOS)
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveCursorConcurrencyTests {
    @Test func duplicateConcurrentCursorUseHasOneSuccessfulCommit() async throws {
        let server = try OneDriveTestServer("three-pages"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        let first = try await source.list(path: "/"); let cursor = try #require(first.nextCursor)
        let successful = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask { do { _ = try await source.list(path: "/", request: .init(cursor: cursor)); return true } catch { return false } } }
            var count = 0; for await value in group { if value { count += 1 } }; return count
        }
        #expect(successful == 1); await source.disconnect()
    }
    @Test func repeatedNextLinkDoesNotCreateInfiniteCursorChain() async throws {
        let server = try OneDriveTestServer("cycle"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        let first = try await source.list(path: "/"); let cursor = try #require(first.nextCursor)
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/", request: .init(cursor: cursor)) }
        await source.disconnect()
    }
    @Test func limitedParallelPageRequestIsNotMistakenForWholeWalkBudget() async throws {
        let server = try OneDriveTestServer("walk"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        let summary = try await source.walk(path: "/", options: .init(maxEntries: 201)) { _ in }
        #expect(summary.entryCount == 3)
        await #expect(throws: RemoteSyncError.self) { try await source.walk(path: "/", options: .init(maxEntries: 1)) { _ in } }
        await source.disconnect()
    }
}
#endif
