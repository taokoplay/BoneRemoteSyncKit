import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOPDS

@Suite struct OPDSCompatibilityParserTests {
    let base = URL(string: "https://books.example/opds")!
    let dateElement = "<a:updated>2026-11-01T00:00:00Z</a:updated>"

    @Test(arguments: [nil, "", "2020-06-20T16:40:44", "2026-02-30T00:00:00Z", "not a date"] as [String?])
    func unknownDatesStayUnknownAndPreserveRaw(_ raw: String?) throws {
        let xml = OPDSParserTests.entry.replacingOccurrences(of: dateElement, with: raw.map { "<a:updated>\($0)</a:updated>" } ?? "")
        let book = try OPDSFeedParser.entry(Data(xml.utf8), url: base, sessionID: UUID(), configuration: .init(rootURL: base))
        #expect(book.updated == nil)
        #expect(book.updatedRaw == raw)
        #expect(book.id == "urn:book:1" && book.acquisitions.count == 4)
        #expect(throws: OPDSError.invalidDocument) {
            try OPDSFeedParser.entry(Data(xml.utf8), url: base, sessionID: UUID(), configuration: .init(rootURL: base, compatibility: .strict))
        }
    }

    @Test func missingFeedAndNavigationDatesDoNotDiscardEntries() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><id>root</id><title>Library</title>
        <entry><id>authors</id><title>Authors</title><link href="authors" type="application/atom+xml"/></entry>
        </feed>
        """
        let page = try OPDSFeedParser.feed(Data(xml.utf8), url: base, sessionID: UUID(), configuration: .init(rootURL: base))
        #expect(page.updated == nil && page.updatedRaw == nil && page.items.count == 1)
        #expect(throws: OPDSError.invalidDocument) {
            try OPDSFeedParser.feed(Data(xml.utf8), url: base, sessionID: UUID(), configuration: .init(rootURL: base, compatibility: .strict))
        }
    }

    @Test func validOffsetDatesKeepTheirInstantAndOriginalText() throws {
        let raw = "2026-11-01T01:00:00+01:00"
        let xml = OPDSParserTests.entry.replacingOccurrences(of: dateElement, with: "<a:updated>\(raw)</a:updated>")
        let book = try OPDSFeedParser.entry(Data(xml.utf8), url: base, sessionID: UUID(), configuration: .init(rootURL: base))
        let original = try OPDSFeedParser.entry(Data(OPDSParserTests.entry.utf8), url: base, sessionID: UUID(), configuration: .init(rootURL: base))
        #expect(book.updated != nil && book.updated == original.updated && book.updatedRaw == raw)
    }

    @Test func compatibilityDoesNotAcceptAmbiguousIdentityOrDuplicateDates() throws {
        let variants = [
            OPDSParserTests.entry.replacingOccurrences(of: "<a:id>urn:book:1</a:id>", with: ""),
            OPDSParserTests.entry.replacingOccurrences(of: "<a:id>urn:book:1</a:id>", with: "<a:id>one</a:id><a:id>two</a:id>"),
            OPDSParserTests.entry.replacingOccurrences(of: dateElement, with: dateElement + dateElement)
        ]
        for xml in variants {
            #expect(throws: OPDSError.invalidDocument) {
                try OPDSFeedParser.entry(Data(xml.utf8), url: base, sessionID: UUID(), configuration: .init(rootURL: base))
            }
        }
    }

    @Test(arguments: ["https://{searchTerms}/search", "/search?{searchTerms}=q", "/search?q={searchTerms}#{count}", "/search?q={searchTerms}&x={required}", "/search?q=%257BsearchTerms%257D"])
    func directTemplatesRejectUnsafeOrUnsupportedExpansions(_ raw: String) throws {
        let template = OPDSSearchTemplate(value: raw, base: base, namespaces: [:])
        #expect(throws: OPDSError.unsupportedSearch) {
            try OPDSSearch.url(template: template, query: "x&admin=1", count: 5, configuration: .init(rootURL: base))
        }
    }

    @Test func keywordSearchLeavesKnownAtomFiltersUnrestricted() throws {
        let xml = """
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/" xmlns:book="http://www.w3.org/2005/Atom">
        <Url type="application/atom+xml;profile=opds-catalog" template="/search?q={searchTerms}&amp;author={book:author}&amp;translator={book:contributor}&amp;title={book:title}"/>
        </OpenSearchDescription>
        """
        let url = try OPDSSearch.url(data: Data(xml.utf8), base: base, query: "ballady", count: 5, configuration: .init(rootURL: base))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems == [
            .init(name: "q", value: "ballady"), .init(name: "author", value: ""),
            .init(name: "translator", value: ""), .init(name: "title", value: "")
        ])
        let foreign = xml.replacingOccurrences(of: "http://www.w3.org/2005/Atom", with: "urn:unknown")
        #expect(throws: OPDSError.unsupportedSearch) {
            try OPDSSearch.url(data: Data(foreign.utf8), base: base, query: "ballady", count: 5, configuration: .init(rootURL: base))
        }
    }
}

#if os(macOS)
import BoneRemoteSyncTestSupport

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python 3")) struct OPDSCompatibilityHTTPTests {
    func source(_ server: OPDSTestServer, path: String, mode: OPDSCompatibilityMode = .compatible, bytes: Int = 8 * 1024 * 1024) throws -> OPDSSource {
        OPDSSource(configuration: try .init(rootURL: server.url(path), allowsInsecureHTTP: true, maxResponseBytes: bytes, compatibility: mode))
    }

    @Test func compatibleMetadataFlowsThroughPublicPageAndFileReference() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, path: "/compat/metadata")
        try await source.connect(.anonymous)
        let page = try await source.browse(); let book = try #require(page.publications.first)
        #expect(page.updated == nil && page.updatedRaw == nil)
        #expect(book.updated == nil && book.updatedRaw == "2026-11-01T00:00:00")
        let reference = try await source.prepareDownload(book, acquisition: book.acquisitions[0])
        if case .path(let path) = reference.locator {
            let entry = try await source.stat(path: path)
            #expect(entry.modifiedAt == nil && entry.etag == nil && !entry.hasReliableFingerprint)
        } else { Issue.record("Expected session path") }
        await source.disconnect()
        let strict = try self.source(server, path: "/compat/metadata", mode: .strict)
        await #expect(throws: OPDSError.invalidDocument) { try await strict.connect(.anonymous) }
    }

    @Test(arguments: ["text/html", "text/plain", "application/octet-stream", "application/xhtml+xml", "missing"])
    func mislabeledAtomRequiresCompatibleMode(_ type: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let path = "/compat/mime?type=\(type.replacingOccurrences(of: "+", with: "%2B"))"
        let source = try source(server, path: path)
        try await source.connect(.anonymous)
        #expect(try await source.browse().publications.count == 1)
        await source.disconnect()
        let strict = try self.source(server, path: path, mode: .strict)
        await #expect(throws: OPDSError.unexpectedContentType) { try await strict.connect(.anonymous) }
    }

    @Test(arguments: ["html", "foreign", "entity"])
    func MIMEFallbackRejectsHTMLForeignXMLAndEntities(_ shape: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, path: "/compat/mime?shape=\(shape)")
        await #expect(throws: OPDSError.self) { try await source.connect(.anonymous) }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.browse() }
    }

    @Test func MIMEFallbackRetainsByteLimitAndDoesNotAcceptJSON() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let limited = try source(server, path: "/compat/mime?shape=large", bytes: 100)
        await #expect(throws: OPDSError.resourceLimit) { try await limited.connect(.anonymous) }
        let json = try source(server, path: "/compat/mime?type=application/json")
        await #expect(throws: OPDSError.unexpectedContentType) { try await json.connect(.anonymous) }
    }

    @Test(arguments: ["raw", "encoded", "namespaced", "relative"])
    func directSearchEncodesQueryAndKeepsFixedValues(_ kind: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, path: "/compat/direct?kind=\(kind)")
        try await source.connect(.anonymous)
        let query = "中文 &x=1/#?+%"
        let result = try await source.search(query, count: 7)
        #expect(result.title == query && result.publications.count == 1)
        let requests = try server.requests(); let path = try #require(requests.last?["path"] as? String)
        let items = try #require(URLComponents(string: "http://fixture" + path)?.queryItems)
        if kind != "relative" {
            #expect(items.first(where: { $0.name == "fixed" })?.value == "a&b")
            #expect(items.first(where: { $0.name == "slash" })?.value == "/")
            #expect(items.first(where: { $0.name == "count" })?.value == "7")
        }
        #expect(!items.contains(where: { $0.name == "x" }))
        await source.disconnect()
        let strict = try self.source(server, path: "/compat/direct?kind=\(kind)", mode: .strict)
        try await strict.connect(.anonymous)
        await #expect(throws: OPDSError.unsupportedSearch) { try await strict.search(query) }
        await strict.disconnect()
    }

    @Test func directSearchHonorsOriginAndRejectsOldSession() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try source(server, path: "/compat/direct?kind=cross")
        try await source.connect(.anonymous)
        let page = try await source.browse()
        await #expect(throws: OPDSError.disallowedOrigin) { try await source.search("test") }
        #expect(try server.requests().count == 1)
        try await source.connect(.anonymous)
        await #expect(throws: OPDSError.invalidReference) { try await source.search("test", in: page) }
        await source.disconnect()
    }
}
#endif
