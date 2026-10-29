#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVSourceTests {
    @Test func connectedSourceListsOnlyDirectVisibleChildrenAndCanWalk() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.list(path: "/") }
        try await source.connect(.anonymous)
        let page = try await source.list(path: "/")
        #expect(Set(page.entries.map(\.name)) == ["folder", "资料", "hello.txt", "empty.txt"])
        #expect(page.entries.prefix(2).allSatisfy { $0.isDirectory })
        #expect(page.nextCursor == nil)
        let hidden = try await source.list(path: "/", request: .init(includeHidden: true))
        #expect(hidden.entries.contains { $0.name == ".hidden" })
        var paths: [String] = []
        for try await entry in source.walk(path: "/") { paths.append(entry.path!) }
        #expect(Set(paths) == ["/folder", "/资料", "/hello.txt", "/empty.txt", "/folder/child.txt", "/资料/a #?%.txt"])
        let requests = try server.requests()
        #expect(requests.first?["depth"] as? String == "0")
        #expect(requests.dropFirst().contains { $0["depth"] as? String == "1" })
        await source.disconnect()
        await source.disconnect()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/hello.txt") }
    }

    @Test func statUsesEscapedPathAndPreservesMetadata() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let entry = try await source.stat(path: "/资料/a #?%.txt")
        #expect(entry.path == "/资料/a #?%.txt")
        #expect(entry.id == "资料/a #?%.txt")
        #expect(entry.name == "a #?%.txt")
        #expect(entry.size == 15)
        #expect(entry.etag == "\"v1\"")
        #expect(entry.modifiedAt == Date(timeIntervalSince1970: 1792458000))
        #expect(try server.requests().last?["path"] as? String == "/dav/%E8%B5%84%E6%96%99/a%20%23%3F%25.txt")
        await source.disconnect()
    }

    @Test func basicAuthenticationFailureDoesNotLeaveConnectedSession() async throws {
        let server = try WebDAVTestServer(root: "auth")
        defer { server.cleanUp() }
        let source = try server.source()
        await #expect(throws: (any Error).self) { try await source.connect(.basic(username: "alice", password: "wrong")) }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.list(path: "/") }
        try await source.connect(.basic(username: "alice", password: "secret"))
        let page = try await source.list(path: "/")
        #expect(!page.entries.isEmpty)
        #expect(try server.requests().last?["authorization"] as? String == "Basic YWxpY2U6c2VjcmV0")
        await #expect(throws: RemoteSyncError.authenticationFailed(reason: "WebDAV 凭据类型不受支持")) { try await source.connect(.apiToken("not-used")) }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/") }
    }

    @Test func doesNotFollowRedirectOrForwardAuthorization() async throws {
        let server = try WebDAVTestServer(root: "redirect")
        defer { server.cleanUp() }
        let source = try server.source()
        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV 重定向；请使用最终地址")) {
            try await source.connect(.basic(username: "alice", password: "secret"))
        }
        let requests = try server.requests()
        #expect(requests.count == 1)
        #expect(requests[0]["path"] as? String == "/redirect/")
    }

    @Test func mapsHTTPFailuresAndDeclaresImplementedCapabilities() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.notFound(path: "/missing")) { try await source.stat(path: "/missing") }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/forbidden")) { try await source.stat(path: "/forbidden") }
        await #expect(throws: RemoteSyncError.rateLimited(retryAfter: 7)) { try await source.stat(path: "/limited") }
        await #expect(throws: RemoteSyncError.conflict(path: "/precondition")) { try await source.stat(path: "/precondition") }
        await #expect(throws: (any Error).self) { try await source.list(path: "/hello.txt") }
        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV 游标分页")) { try await source.list(path: "/", request: .init(cursor: "fake")) }
        await #expect(throws: RemoteSyncError.unsupported(operation: "分页大小必须大于0")) { try await source.list(path: "/", request: .init(limit: 0)) }
        #expect(source.capabilities.rangedDownload)
        #expect(source.capabilities.upload && source.capabilities.copy && source.capabilities.remove)
        #expect(source.capabilities.makeDirectory && source.capabilities.move)
        #expect(!source.capabilities.resumableUpload)
        await source.disconnect()
    }

    @Test(arguments: ["badxml", "oversized", "file-root"])
    func connectionRequiresValidRootCollection(root: String) async throws {
        let server = try WebDAVTestServer(root: root)
        defer { server.cleanUp() }
        let source = try server.source()
        await #expect(throws: (any Error).self) { try await source.connect(.anonymous) }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.list(path: "/") }
    }
}
#endif
