#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncOPDS

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python 3")) struct OPDSCoverTests {
    private static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=")!
    private static let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"><rect width=\"1\" height=\"1\"/></svg>".utf8)

    private func source(_ server: OPDSTestServer, image: String? = nil, thumbnail: String? = nil,
                        limit: Int = 8 * 1024 * 1024, concurrent: Int = 3) throws -> OPDSSource {
        var url = URLComponents(url: server.url("/artwork/catalog"), resolvingAgainstBaseURL: false)!
        url.queryItems = [("image", image), ("thumbnail", thumbnail)].compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        return OPDSSource(configuration: try .init(rootURL: #require(url.url), allowsInsecureHTTP: true,
                                                  maxResponseBytes: limit, maxConcurrentTransfers: concurrent))
    }

    private func publication(_ source: OPDSSource) async throws -> OPDSPublication {
        try #require(await source.browse().publications.first)
    }

    @Test func noImageReturnsNilWithoutFollowingDetailOrRequestingNetwork() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server)
        try await source.connect(.anonymous)
        let book = try await publication(source)
        #expect(book.detailLink != nil)
        #expect(try await source.cover(book) == nil)
        #expect(try server.requests().count == 1)
        await source.disconnect()
    }

    @Test(arguments: ["/artwork/image", "/artwork/unknown", "/artwork/svg"])
    func imageResponsesReturnCompleteData(_ path: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: path)
        try await source.connect(.anonymous)
        let book = try await publication(source)
        #expect(book.imageLinks.first?.mediaType == nil)
        #expect(try await source.cover(book) == (path == "/artwork/svg" ? Self.svg : Self.image))
        let requests = try server.requests()
        #expect(requests.count == 2)
        #expect(requests.last?["accept"] as? String == "image/*")
        #expect(requests.allSatisfy { $0["authorization"] is NSNull && $0["cookie"] is NSNull })
        await source.disconnect()
    }

    @Test func thumbnailTakesPriorityRegardlessOfLinkOrder() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: "/artwork/image", thumbnail: "/artwork/thumbnail")
        try await source.connect(.anonymous)
        let book = try await publication(source)
        #expect(book.imageLinks.first?.relation == "http://opds-spec.org/image")
        #expect(try await source.cover(book) == Self.image)
        #expect(try server.requests().last?["path"] as? String == "/artwork/thumbnail")
        #expect(try !server.requests().contains { $0["path"] as? String == "/artwork/image" })
        await source.disconnect()
    }

    @Test(arguments: ["same", "direct", "redirect", "return"])
    func basicCredentialsStayAtTheOriginalOrigin(_ route: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let port = try #require(server.baseURL.port)
        let paths = ["same": "/artwork/image", "direct": "http://localhost:\(port)/artwork/image",
                     "redirect": "/artwork/cross", "return": "/artwork/cross-return"]
        let target = try #require(paths[route])
        let source = try source(server, image: target)
        try await source.connect(.basic(username: "user", password: "pass"))
        #expect(try await source.cover(publication(source)) == Self.image)
        let requests = try server.requests()
        let basic = "Basic " + Data("user:pass".utf8).base64EncodedString()
        #expect(requests.first?["authorization"] as? String == basic)
        if route == "same" {
            #expect(requests.last?["authorization"] as? String == basic)
        } else {
            let anonymousStart = route == "direct" ? 1 : 2
            if route != "direct" { #expect(requests[1]["authorization"] as? String == basic) }
            #expect(requests.count > anonymousStart)
            #expect(requests.dropFirst(anonymousStart).allSatisfy { $0["authorization"] is NSNull })
        }
        #expect(requests.allSatisfy { $0["cookie"] is NSNull })
        await source.disconnect()
    }

    @Test(arguments: ["application/atom+xml", "application/xml", "text/xml", "text/html",
                      "application/octet-stream", "application/json", "missing", "image/", "image/*", "image/png/extra"])
    func nonImageAndInvalidMIMENeverUseCatalogCompatibility(_ mime: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        var target = URLComponents()
        target.path = "/artwork/mime"
        target.queryItems = [.init(name: "type", value: mime)]
        let path = try #require(target.string)
        let source = try source(server, image: path)
        try await source.connect(.anonymous)
        let book = try await publication(source)
        await #expect(throws: OPDSError.unexpectedContentType) { try await source.cover(book) }
        await source.disconnect()
    }

    @Test func failedThumbnailDoesNotSilentlyFetchAnotherImage() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: "/artwork/image", thumbnail: "/artwork/mime")
        try await source.connect(.anonymous)
        let book = try await publication(source)
        await #expect(throws: OPDSError.unexpectedContentType) { try await source.cover(book) }
        #expect(try server.requests().count == 2)
        await source.disconnect()
    }

    @Test(arguments: ["/artwork/large", "/artwork/large-unknown"])
    func knownAndUnknownLengthsRespectResponseBudget(_ path: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: path, limit: 2048)
        try await source.connect(.anonymous)
        let book = try await publication(source)
        await #expect(throws: OPDSError.resourceLimit) { try await source.cover(book) }
        await source.disconnect()
    }

    @Test(arguments: ["/artwork/short", "/artwork/partial", "/artwork/ranged", "/artwork/encoded"])
    func incompleteOrTransformedResponsesAreRejected(_ path: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: path)
        try await source.connect(.anonymous)
        let book = try await publication(source)
        if path == "/artwork/short" || path == "/artwork/encoded" {
            // URLSession may reject framing/decoding before delivering response headers.
            await #expect(throws: RemoteSyncError.self) { try await source.cover(book) }
        } else {
            await #expect(throws: RemoteSyncError.integrityMismatch(path: "OPDS resource")) { try await source.cover(book) }
        }
        await source.disconnect()
    }

    @Test(arguments: ["file:///cover", "ftp://localhost/cover", "http://user:secret@127.0.0.1/cover",
                      "http://127.0.0.1:0/cover", "http://127.0.0.1:65536/cover"])
    func unsafeImageURLsAndRedirectsAreRejected(_ target: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        var redirect = URLComponents()
        redirect.path = "/artwork/redirect"
        redirect.queryItems = [.init(name: "target", value: target)]
        for path in [target, try #require(redirect.string)] {
            let source = try source(server, image: path)
            try await source.connect(.anonymous)
            let book = try await publication(source)
            await #expect { try await source.cover(book) } throws: { error in
                if let error = error as? OPDSError { return error == .invalidURL }
                // Some system versions reject a non-HTTP redirect before the delegate.
                if let error = error as? RemoteSyncError, case .network = error { return path != target }
                return false
            }
            await source.disconnect()
        }
        #expect(try server.requests().count == 3)
    }

    @Test func imageRedirectsKeepTheExistingHopLimit() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: "/redirect-loop")
        try await source.connect(.anonymous)
        let book = try await publication(source)
        await #expect(throws: OPDSError.redirectLimit) { try await source.cover(book) }
        #expect(try server.requests().filter { $0["path"] as? String == "/redirect-loop" }.count == 6)
        await source.disconnect()
    }

    @Test(arguments: [false, true])
    func disconnectedReconnectedAndForeignPublicationsAreRejected(_ hasImage: Bool) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: hasImage ? "/artwork/image" : nil)
        let other = try self.source(server)
        try await source.connect(.anonymous)
        try await other.connect(.anonymous)
        let book = try await publication(source)
        await #expect(throws: OPDSError.invalidReference) { try await other.cover(book) }
        await source.disconnect()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.cover(book) }
        try await source.connect(.anonymous)
        await #expect(throws: OPDSError.invalidReference) { try await source.cover(book) }
        #expect(try server.requests().count == 3)
        await source.disconnect(); await other.disconnect()
    }

    @Test(arguments: [false, true])
    func taskCancellationAndReconnectCannotReturnOldCover(_ reconnect: Bool) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: "/artwork/slow")
        try await source.connect(.anonymous)
        let book = try await publication(source)
        let pending = Task { try await source.cover(book) }
        try await server.waitForRequest("/artwork/slow")
        if reconnect {
            await source.disconnect()
            try await source.connect(.anonymous)
        } else {
            pending.cancel()
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await pending.value }
        if reconnect {
            await #expect(throws: OPDSError.invalidReference) { try await source.cover(book) }
        }
        #expect(try await source.cover(publication(source)) == Self.image)
        await source.disconnect()
    }

    @Test func imageRequestsShareTheSourceConcurrencyBudget() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, image: "/artwork/slow", concurrent: 1)
        try await source.connect(.anonymous)
        let book = try await publication(source)
        let pending = Task { try await source.cover(book) }
        try await server.waitForRequest("/artwork/slow")
        await #expect(throws: OPDSError.resourceLimit) { try await source.cover(book) }
        await #expect(throws: OPDSError.resourceLimit) { try await source.browse(refresh: true) }
        pending.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await pending.value }
        #expect(try await source.cover(book) == Self.image)
        await source.disconnect()
    }
}
#endif
