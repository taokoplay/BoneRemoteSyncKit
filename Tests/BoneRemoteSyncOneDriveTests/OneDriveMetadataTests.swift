import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct ODMetadataTests {
    @Test(arguments: ["2026-10-19T01:02:03Z", "2026-10-19T01:02:03.125Z", "2026-10-19T09:02:03+08:00", "invalid", ""])
    func mapsDriveItemCreationDateWithoutUsingFileSystemOrModifiedTime(raw: String) throws {
        let json: [String: Any] = ["id": "x", "name": "x", "file": ["mimeType": "image/jpeg"],
            "createdDateTime": raw, "lastModifiedDateTime": "2026-10-20T00:00:00Z",
            "fileSystemInfo": ["createdDateTime": "2020-01-01T00:00:00Z"]]
        let item = try JSONDecoder().decode(ODItem.self, from: JSONSerialization.data(withJSONObject: json))
        let parser = ISO8601DateFormatter()
        let whole = parser.date(from: raw)
        parser.formatOptions.insert(.withFractionalSeconds)
        let expected = whole ?? parser.date(from: raw)
        let entry = item.entry(drive: "D", path: "/x")
        #expect(entry.createdAt == expected)
        #expect(entry.modifiedAt != nil)
        #expect(entry.fileCategory == .image)
    }

    @Test(arguments: ["2026-02-30T01:02:03Z", "2026-10-19T01:02:03Zgarbage", "2026-10-19T01:02:03+99:00", "2026-10-19T24:00:00Z", "2026-13-01T00:00:00Z", "1900-02-29T00:00:00Z", "2026-10-19T01:02:03+08:60"])
    func malformedCreationDateIsRejected(raw: String) throws {
        let json: [String: Any] = ["id": "x", "name": "x", "file": [:], "createdDateTime": raw]
        let item = try JSONDecoder().decode(ODItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(item.entry(drive: "D", path: "/x").createdAt == nil)
    }

    @Test func wrongOptionalCreationDateJSONTypeDoesNotBreakAnItem() throws {
        for raw: Any in [123, true, ["value": "bad"], [1, 2]] {
            let json: [String: Any] = ["id": "x", "name": "x", "file": [:], "createdDateTime": raw]
            let item = try JSONDecoder().decode(ODItem.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(item.entry(drive: "D", path: "/x").createdAt == nil)
        }
    }

    @Test func missingCreationDateStaysNil() throws {
        let data = Data(#"{"id":"x","name":"x","file":{},"lastModifiedDateTime":"2026-10-20T00:00:00Z","fileSystemInfo":{"createdDateTime":"2020-01-01T00:00:00Z"}}"#.utf8)
        #expect(try JSONDecoder().decode(ODItem.self, from: data).entry(drive: "D", path: "/x").createdAt == nil)
    }
}

#if os(macOS)
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveMetadataTests {
    @Test func publicListStatAndDownloadCarryCreationDate() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }
        let source = server.source()
        try await source.connect(server.credential)
        let expected = ISO8601DateFormatter().date(from: "2026-10-19T01:02:03Z")
        let page = try await source.list(path: "/")
        #expect(page.entries.allSatisfy { $0.createdAt == expected })
        let file = try await source.stat(path: "/file")
        #expect(file.createdAt == expected)
        let result = try await source.download(file, to: server.file(), options: .init())
        #expect(result.createdAt == expected)
        await source.disconnect()
    }
}
#endif
