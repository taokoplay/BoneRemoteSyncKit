#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncOPDS

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python 3")) struct OPDSBrowsingTests {
    @Test func browseDetailsSearchAndEmptyMiddlePage() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source("/redirect")
        try await source.connect(.anonymous)
        let first = try await source.browse()
        #expect(first.items.count == 2 && first.navigation.count == 1)
        let book = try #require(first.publications.first)
        #expect(book.acquisitions.count == 3)
        let detail = try await source.publication(book)
        #expect(detail.summary?.value == "完整简介")
        let category = try #require(first.navigation.first?.catalogLinks.first)
        #expect(try await source.browse(category).publications.first?.id == book.id)
        let middle = try await source.nextPage(#require(first.nextCursor))
        #expect(middle.items.isEmpty && middle.nextCursor != nil)
        #expect(try await source.nextPage(#require(middle.nextCursor)).nextCursor == nil)
        let query = "中文 &x=1 /?# +"
        #expect(try await source.search(query).title == query)
        await #expect(throws: OPDSError.unsupportedSearch) { try await source.search(query, in: middle) }
        await source.disconnect()
    }
    @Test func sessionIsolationAndBudgets() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source(pages: 1, references: 1)
        try await source.connect(.anonymous)
        let page = try await source.browse(); let book = try #require(page.publications.first)
        let reference = try await source.prepareDownload(book, acquisition: book.acquisitions[0])
        #expect(!reference.displayLocator.contains("http"))
        await #expect(throws: OPDSError.resourceLimit) { try await source.prepareDownload(book, acquisition: book.acquisitions[1]) }
        await #expect(throws: OPDSError.resourceLimit) { try await source.nextPage(#require(page.nextCursor)) }
        let other = try server.source(); try await other.connect(.anonymous)
        await #expect(throws: OPDSError.invalidReference) { try await other.publication(book) }
        await #expect(throws: OPDSError.invalidCursor) { try await other.nextPage(#require(page.nextCursor)) }
        try await source.connect(.anonymous)
        #expect(try await source.sourceBinding() != reference.source)
        await #expect(throws: OPDSError.invalidReference) { try await source.prepareDownload(book, acquisition: book.acquisitions[0]) }
        if case .path(let path) = reference.locator {
            await #expect(throws: OPDSError.invalidReference) { try await source.stat(path: path) }
        }
        await source.disconnect(); await other.disconnect()
    }
    @Test func cyclesAndResponseBudgetFailExplicitly() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let cycle = try server.source("/cycle")
        await #expect(throws: OPDSError.invalidCursor) { try await cycle.connect(.anonymous) }
        let limited = OPDSSource(configuration: try .init(rootURL: server.url("/large"), allowsInsecureHTTP: true, maxResponseBytes: 100))
        await #expect(throws: OPDSError.resourceLimit) { try await limited.connect(.anonymous) }
        await #expect(throws: RemoteSyncError.notConnected) { try await limited.browse() }
    }
    @Test func reconnectDuringConnectDoesNotPublishOldResult() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source("/slow-feed")
        let old = Task { try await source.connect(.anonymous) }
        try await server.waitForRequest("/slow-feed")
        await source.disconnect()
        try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.cancelled) { try await old.value }
        #expect(try await source.browse().publications.count == 1)
        await source.disconnect()
    }
    @Test func authenticationAndHTTPPolicies() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let auth = try server.source("/auth")
        await #expect(throws: RemoteSyncError.self) { try await auth.connect(.anonymous) }
        try await auth.connect(.basic(username: "user", password: "pass"))
        #expect(try await auth.browse().publications.count == 1)
        await auth.disconnect()
        let cross = try server.source("/cross-feed")
        await #expect(throws: OPDSError.disallowedOrigin) { try await cross.connect(.anonymous) }
        let loop = try server.source("/redirect-loop")
        await #expect(throws: OPDSError.redirectLimit) { try await loop.connect(.anonymous) }
        for code in [403, 404, 429, 500] {
            let source = try server.source("/status/\(code)")
            await #expect(throws: RemoteSyncError.self) { try await source.connect(.anonymous) }
        }
        let port = try #require(server.baseURL.port)
        let allowed = OPDSSource(configuration: try .init(rootURL: server.url("/cross-feed"), allowsInsecureHTTP: true,
                                                         allowedCatalogOrigins: [URL(string: "http://localhost:\(port)")!]))
        try await allowed.connect(.basic(username: "user", password: "pass"))
        let requests = try server.requests()
        #expect(requests.last?["authorization"] is NSNull)
        #expect(requests.allSatisfy { $0["cookie"] is NSNull })
        await allowed.disconnect()
    }
}
#endif
