import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite struct DAVCreationMetadataTests {
    @Test(arguments: ["2026-10-19T01:02:03Z", "2026-10-19T01:02:03.125Z", "2026-10-19T09:02:03+08:00"])
    func parsesCreationDateOnlyFromSuccessfulDAVProperties(raw: String) throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:" xmlns:e="urn:other"><d:response><d:href>/dav/a</d:href>
        <d:propstat><d:prop><d:creationdate>2020-01-01T00:00:00Z</d:creationdate></d:prop><d:status>HTTP/1.1 404 Error</d:status></d:propstat>
        <d:propstat><d:prop><d:resourcetype/><e:creationdate>2020-01-01T00:00:00Z</e:creationdate><d:creationdate>\(raw)</d:creationdate></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        </d:response></d:multistatus>
        """
        let value = try #require(DAVMultiStatusParser.parse(Data(xml.utf8)).first)
        #expect(value.createdAt == ISODate(raw))
        #expect(value.modifiedAt == nil)
    }

    @Test(arguments: ["", "invalid", "Mon, 19 Oct 2026 01:02:03 GMT", "2026-02-30T01:02:03Z", "2026-10-19T01:02:03Zgarbage", "2026-10-19T01:02:03+99:00", "2026-10-19T24:00:00Z", "2026-13-01T00:00:00Z", "1900-02-29T00:00:00Z", "2026-10-19T01:02:03+08:60"])
    func invalidCreationDateDoesNotInventATime(raw: String) throws {
        let xml = """
        <multistatus xmlns="DAV:"><response><href>/dav/a</href><propstat><prop><resourcetype/><creationdate>\(raw)</creationdate><getlastmodified>Tue, 20 Oct 2026 01:00:00 GMT</getlastmodified></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>
        """
        let value = try #require(DAVMultiStatusParser.parse(Data(xml.utf8)).first)
        #expect(value.createdAt == nil)
        #expect(value.modifiedAt != nil)
    }

    @Test func missingFailedAndForeignCreationPropertiesRemainNil() throws {
        let xml = """
        <multistatus xmlns="DAV:" xmlns:e="urn:other"><response><href>/dav/a</href>
        <propstat><prop><creationdate>2020-01-01T00:00:00Z</creationdate></prop><status>HTTP/1.1 404 Error</status></propstat>
        <propstat><prop><resourcetype/><e:creationdate>2020-01-01T00:00:00Z</e:creationdate></prop><status>HTTP/1.1 200 OK</status></propstat>
        </response></multistatus>
        """
        #expect(try DAVMultiStatusParser.parse(Data(xml.utf8)).first?.createdAt == nil)
    }

    @Test func checkpointOptionalDateDecodesOldRecordsAndRoundTrips() throws {
        let f = try CheckpointFileFixture(); defer { f.cleanUp() }
        var record = f.record
        record.createdAt = Date(timeIntervalSince1970: 123)
        let bytes = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(DAVCheckpointRecord.self, from: bytes).createdAt == record.createdAt)
        var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        old.removeValue(forKey: "createdAt")
        let decoded = try JSONDecoder().decode(DAVCheckpointRecord.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.createdAt == nil)
        try decoded.validate()
        record.createdAt = Date(timeIntervalSince1970: .infinity)
        #expect(throws: RemoteSyncError.self) { try record.validate() }
    }
}

private func ISODate(_ raw: String) -> Date? {
    let parser = ISO8601DateFormatter()
    if let value = parser.date(from: raw) { return value }
    parser.formatOptions.insert(.withFractionalSeconds)
    return parser.date(from: raw)
}

#if os(macOS)
@Suite(.serialized) struct WebDAVMetadataTests {
    @Test(arguments: [false, true])
    func downloadingCheckpointRetainsKnownDateWhenServerOmitsIt(legacy: Bool) async throws {
        let server = try WebDAVTestServer(root: "no-creation"); defer { server.cleanUp() }
        var pair = try RecoveryPair(server: server)
        if !legacy {
            pair.record.createdAt = Date(timeIntervalSince1970: 123)
            try pair.store.save(pair.record)
        }
        let source = try server.source()
        try await source.connect(.anonymous)
        #expect(try await source.stat(path: "/hello.txt").createdAt == nil)
        let result = try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"))
        #expect(result.createdAt == pair.record.createdAt)
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 1)
        await source.disconnect()
    }

    @Test(arguments: [false, true])
    func readyCheckpointRetainsStoredDateWithoutInventingLegacyDate(legacy: Bool) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        var pair = try RecoveryPair(server: server, committed: 26, phase: .readyToInstall,
                                    content: Data("abcdefghijklmnopqrstuvwxyz".utf8))
        if !legacy {
            pair.record.createdAt = ISODate("2026-10-19T01:02:03.125Z")
            try pair.store.save(pair.record)
        }
        let source = try server.source()
        try await source.connect(.anonymous)
        let entry = try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"))
        #expect(entry.createdAt == pair.record.createdAt)
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        await source.disconnect()
    }

    @Test func listStatOrdinaryAndManagedDownloadsPreserveCreationDate() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let expected = ISODate("2026-10-19T01:02:03.125Z")
        #expect(try await source.stat(path: "/hello.txt").createdAt == expected)
        #expect(try await source.list(path: "/").entries.allSatisfy { $0.createdAt == expected })
        let ordinary = try await source.download(path: "/hello.txt", to: server.file("ordinary"))
        #expect(ordinary.createdAt == expected)
        let managed = try await source.downloadResumable(path: "/hello.txt", to: server.file("managed"), options: .init(sourceNamespace: "metadata"))
        #expect(managed.createdAt == expected)
        #expect(try server.requests().filter { $0["method"] as? String == "PROPFIND" }.allSatisfy { $0["asksCreationDate"] as? Bool == true })
        await source.disconnect()
    }
}
#endif
