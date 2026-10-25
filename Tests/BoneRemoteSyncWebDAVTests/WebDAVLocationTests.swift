import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite struct WebDAVLocationTests {
    @Test func encodesEachPathComponentWithoutChangingOriginOrRoot() throws {
        let location = try WebDAVLocation(baseURL: URL(string: "https://example.com/remote.php/dav/files/alice/")!)
        let url = try location.url(for: "/资料/a #?%.txt")
        #expect(url.absoluteString == "https://example.com/remote.php/dav/files/alice/%E8%B5%84%E6%96%99/a%20%23%3F%25.txt")
        #expect(try location.url(for: "/a/../../etc").path == "/remote.php/dav/files/alice/etc")
    }

    @Test func hostRootUsesOneSlashAndRetainsChildren() throws {
        let location = try WebDAVLocation(baseURL: URL(string: "https://example.com/")!)
        #expect(location.baseURL.absoluteString == "https://example.com/")
        #expect(try location.url(for: "/").absoluteString == "https://example.com/")
        #expect(try location.url(for: "/a").absoluteString == "https://example.com/a")
        #expect(location.path(for: "/a", relativeTo: location.baseURL) == "/a")
    }

    @Test(arguments: ["ftp://example.com/dav", "https://user:secret@example.com/dav", "https://example.com/dav?q=1", "https://example.com/dav#frag", "https://example.com/a/%2f/b", "https://example.com/a/%2e%2e/b"])
    func rejectsAmbiguousOrCredentialBearingBaseURL(raw: String) throws {
        #expect(throws: (any Error).self) { try WebDAVLocation(baseURL: URL(string: raw)!) }
    }

    @Test func mapsOnlyUnambiguousSameOriginHrefsInsideRoot() throws {
        let location = try WebDAVLocation(baseURL: URL(string: "https://example.com/dav/")!)
        let request = try location.url(for: "/资料")
        #expect(location.path(for: "/dav/%E8%B5%84%E6%96%99/a%20b.txt", relativeTo: request) == "/资料/a b.txt")
        #expect(location.path(for: "https://example.com/dav/资料/a.txt", relativeTo: request) == "/资料/a.txt")
        #expect(location.path(for: "a.txt", relativeTo: request) == "/资料/a.txt")
        for href in ["https://evil.example/dav/a", "/dav2/a", "/dav/%2e%2e/a", "/dav/a%2fb", "/dav/a%5cb", "/dav/a?x=1", "/dav/%00", "//evil.example/dav/a"] {
            #expect(location.path(for: href, relativeTo: request) == nil, "Should reject \(href)")
        }
    }

    @Test func nullAndBackslashHrefCannotChangeRemotePath() throws {
        let location = try WebDAVLocation(baseURL: URL(string: "https://example.com/dav/")!)
        #expect(throws: (any Error).self) { try location.url(for: "/bad\0name") }
        #expect(location.path(for: "/dav/a\\b", relativeTo: location.baseURL) == nil)
    }
}
