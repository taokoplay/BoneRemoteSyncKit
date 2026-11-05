import Foundation
import Testing
@testable import BoneRemoteSyncOPDS

@Suite struct OPDSParserTests {
    let base = URL(string: "https://books.example/catalog/root")!
    let session = UUID()
    static let entry = """
    <a:entry xmlns:a="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:o="http://opds-spec.org/2010/catalog" xmlns:x="urn:unknown" xml:base="../content/">
      <a:id>urn:book:1</a:id><a:title>书<x:noise>BAD</x:noise>名</a:title><a:updated>2026-11-01T00:00:00Z</a:updated>
      <a:author><a:name>作者</a:name><x:name>BAD</x:name></a:author><dc:language>zh</dc:language><dc:publisher>出版社</dc:publisher><dc:issued>2024</dc:issued>
      <a:summary type="text">摘要</a:summary><a:content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">前<b>中</b>后</div></a:content>
      <a:category term="fiction" label="小说"/>
      <a:link rel="alternate" href="detail" type='application/atom+xml; profile=opds-catalog; type="entry"'/>
      <a:link rel="http://opds-spec.org/image/thumbnail" href="cover.jpg" type="image/jpeg"/>
      <a:link rel="http://opds-spec.org/acquisition" href="book.epub" type="Application/EPUB+ZIP"/>
      <a:link rel="http://opds-spec.org/acquisition/open-access" href="book.pdf" type="application/pdf"/>
      <a:link rel="http://opds-spec.org/acquisition/buy" href="buy" type="text/html"/>
      <a:link rel="http://opds-spec.org/acquisition" href="indirect" type="application/epub+zip"><o:indirectAcquisition type="application/epub+zip"/></a:link>
    </a:entry>
    """
    func parse(_ xml: String, configuration: OPDSConfiguration? = nil) throws -> OPDSPublication {
        try OPDSFeedParser.entry(Data(xml.utf8), url: base, sessionID: session,
                                 configuration: configuration ?? OPDSConfiguration(rootURL: base))
    }
    @Test func validXHTMLTitleAndLiteralDeclarationsAreAccepted() throws {
        let xml = Self.entry.replacingOccurrences(of: "<a:title>书<x:noise>BAD</x:noise>名</a:title>",
            with: "<a:title type=\"xhtml\"><div xmlns=\"http://www.w3.org/1999/xhtml\">书<b>名</b><x:noise>BAD</x:noise></div></a:title>")
            .replacingOccurrences(of: "<a:summary type=\"text\">摘要</a:summary>",
            with: "<!-- literal <!ENTITY example> --><a:summary><![CDATA[<!DOCTYPE html>]]></a:summary>")
        let book = try parse(xml)
        #expect(book.title == "书名")
        #expect(book.summary?.value == "<!DOCTYPE html>")
    }
    @Test func namespacedOpenSearchStandardParametersAreSupported() throws {
        let xml = """
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/" xmlns:os="http://a9.com/-/spec/opensearch/1.1/">
        <Url type="application/atom+xml" template="/search?q={os:searchTerms}&amp;n={os:count}"/>
        </OpenSearchDescription>
        """
        let url = try OPDSSearch.url(data: Data(xml.utf8), base: base, query: "中文", count: 7, configuration: .init(rootURL: base))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems == [.init(name: "q", value: "中文"), .init(name: "n", value: "7")])
    }


    @Test func namespacesBaseMetadataAndAcquisitionSemantics() throws {
        let book = try parse(Self.entry)
        #expect(book.title == "书名")
        #expect(book.authors == ["作者"])
        #expect(book.language == "zh" && book.publisher == "出版社" && book.issued == "2024")
        #expect(book.categories == ["小说"])
        #expect(book.detailLink?.url.absoluteString == "https://books.example/content/detail")
        #expect(book.imageLinks.count == 1)
        #expect(book.acquisitions.map(\.isDirectDownload) == [true, true, false, false])
        #expect(book.content?.kind == .xhtml)
        #expect(book.content?.value.contains("前<b") == true)
        #expect(book.content?.value.contains("中</b>后") == true)
    }
    @Test(arguments: ["<notxml", "<feed/>", "", "<html><body>login</body></html>"])
    func invalidDocumentsAreNotEmptySuccess(_ xml: String) throws {
        #expect(throws: OPDSError.invalidDocument) { try parse(xml) }
    }
    @Test func requiredMetadataAndDTDRejected() throws {
        #expect(throws: OPDSError.invalidDocument) { try parse(Self.entry.replacingOccurrences(of: "<a:id>urn:book:1</a:id>", with: "")) }
        #expect(throws: OPDSError.invalidDocument) {
            try parse(Self.entry.replacingOccurrences(of: "2026-11-01", with: "2026-02-30"), configuration: .init(rootURL: base, compatibility: .strict))
        }
        let xml = "<!DOCTYPE entry [<!ENTITY ex SYSTEM 'file:///etc/passwd'>]>" + Self.entry
        #expect(throws: OPDSError.invalidDocument) { try parse(xml) }
        let utf16 = try #require(xml.data(using: .utf16))
        #expect(throws: OPDSError.invalidDocument) {
            try OPDSFeedParser.entry(utf16, url: base, sessionID: session, configuration: .init(rootURL: base))
        }
    }
    @Test func budgetsRejectRatherThanTruncate() throws {
        #expect(throws: OPDSError.resourceLimit) { try parse(Self.entry, configuration: .init(rootURL: base, maxResponseBytes: 10)) }
        #expect(throws: OPDSError.resourceLimit) { try parse(Self.entry, configuration: .init(rootURL: base, maxXMLDepth: 2)) }
        let xml = "<feed xmlns='http://www.w3.org/2005/Atom'><id>f</id><title>f</title><updated>2026-01-01T00:00:00Z</updated>" + Self.entry + Self.entry + "</feed>"
        #expect(throws: OPDSError.resourceLimit) {
            try OPDSFeedParser.feed(Data(xml.utf8), url: base, sessionID: session, configuration: .init(rootURL: base, maxEntriesPerPage: 1))
        }
    }
    @Test func textAndHTMLRemainTypedAndUnexecuted() throws {
        let html = Self.entry.replacingOccurrences(of: "<a:summary type=\"text\">摘要</a:summary>", with: "<a:summary type=\"html\">&lt;b&gt;摘要&lt;/b&gt;</a:summary>")
        #expect(try parse(html).summary == OPDSText(kind: .html, value: "<b>摘要</b>"))
    }
    @Test func searchEscapesReservedCharactersAndRejectsUnsupportedLocations() throws {
        let query = "中文 &x=1/#?+.."
        let url = try OPDSSearch.expand("/search/{searchTerms}?q={searchTerms}&optional={other?}", base: base, values: ["searchTerms": query])
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: true))
        #expect(components.queryItems?.first?.value == query)
        #expect(components.host == "books.example")
        #expect(components.fragment == nil)
        for template in ["https://{searchTerms}/x", "/search?{searchTerms}=1", "/search?q={searchTerms}&x={required}", "/search#q={searchTerms}"] {
            #expect(throws: OPDSError.unsupportedSearch) { try OPDSSearch.expand(template, base: base, values: ["searchTerms": query]) }
        }
    }
    @Test func configurationHasValidatedBudgetsAndOrigins() throws {
        #expect(throws: OPDSError.invalidConfiguration) { try OPDSConfiguration(rootURL: URL(string: "http://books.example")!) }
        #expect(throws: OPDSError.invalidConfiguration) { try OPDSConfiguration(rootURL: base, maxDownloadReferences: 0) }
        #expect(throws: OPDSError.invalidConfiguration) { try OPDSConfiguration(rootURL: base, allowedCatalogOrigins: [URL(string: "https://cdn.example/path")!]) }
    }
}
