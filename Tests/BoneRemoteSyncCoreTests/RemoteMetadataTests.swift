import Foundation
import Testing
@testable import BoneRemoteSyncCore
import BoneRemoteSyncLocal

@Suite struct RemoteMetadataTests {
    @Test func strictCreationParserUsesValidatedCalendarAndOffsetComponents() throws {
        let cases: [(String, TimeInterval)] = [
            ("0001-01-01T00:00:00Z", -62135596800), ("1582-10-05T00:00:00Z", -12220156800),
            ("1582-10-10T00:00:00Z", -12219724800), ("1582-10-15T00:00:00Z", -12219292800),
            ("9999-12-31T00:00:00Z", 253402214400),
            ("1970-01-01T00:00:00Z", 0), ("1970-01-01t00:00:00z", 0),
            ("1970-01-01T00:00:00.125Z", 0.125), ("1970-01-01T08:00:00+08:00", 0),
            ("1969-12-31T19:00:00-05:00", 0), ("2000-02-29T00:00:00Z", 951782400),
            ("1970-01-01T05:30:00+05:30", 0), ("1970-01-01T00:00:00.123456789Z", 0.123456789)
        ]
        for (raw, expected) in cases {
            let actual = try #require(RemoteCreationDate.parse(raw))
            #expect(abs(actual.timeIntervalSince1970 - expected) < 0.000001)
        }
    }

    @Test(arguments: ["", "2026-02-30T00:00:00Z", "2026-10-19T01:02:03Zgarbage", "2026-10-19T01:02:03+99:00",
                      "2026-10-19T01:02:03+08:60", "2026-10-19T24:00:00Z", "2026-10-19T01:60:00Z",
                      "2026-10-19T01:02:60Z", "1900-02-29T00:00:00Z", "0000-01-01T00:00:00Z",
                      "2026-00-01T00:00:00Z", "2026-01-00T00:00:00Z", "2026-10-19T01:02:03.Z",
                      "2026-10-19T01:02:03", "2026-10-19T01:02:03+0800", "2026-10-19T01:02:03Z\n"])
    func strictCreationParserRejectsMalformedValues(raw: String) {
        #expect(RemoteCreationDate.parse(raw) == nil)
    }

    @Test func creationDateIsOptionalAndCodableRemainsCompatible() throws {
        let legacy = Data(#"{"id":"x","path":"/x","name":"x","type":"file","modifiedAt":100}"#.utf8)
        let old = try JSONDecoder().decode(RemoteEntry.self, from: legacy)
        #expect(old.createdAt == nil)
        #expect(old.modifiedAt == Date(timeIntervalSinceReferenceDate: 100))
        let entry = RemoteEntry(id: "x", path: "/x", name: "x", type: .file,
                                modifiedAt: Date(timeIntervalSince1970: 20), createdAt: Date(timeIntervalSince1970: 10))
        #expect(try JSONDecoder().decode(RemoteEntry.self, from: JSONEncoder().encode(entry)) == entry)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(json["fileCategory"] == nil)
    }

    @Test func categoriesUseMIMEThenConservativeExtensionFallback() {
        let cases: [(String, String?, RemoteFileCategory)] = [
            ("renamed.bin", " IMAGE/JPEG ; charset=binary ", .image),
            ("song.jpg", "audio/flac", .audio), ("video", "video/mp4", .video),
            ("vector", "image/svg+xml", .image), ("report", "application/pdf", .document),
            ("sheet", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", .document),
            ("notes", "text/plain", .document), ("data", "application/json", .document),
            ("backup", "application/zip", .archive), ("photo.HEIC", nil, .image),
            ("song.MP3", "application/octet-stream", .audio), ("movie.MOV", "binary/octet-stream", .video),
            ("report.DOCX", nil, .document), ("backup.tar.gz", nil, .archive),
            ("track.ogg", "application/ogg", .unknown),
            ("image.jpg", "application/x-unknown", .unknown), ("image.jpg", "invalid", .image),
            ("photo.jpg", "image/", .image), ("unknown", "image/", .unknown),
            ("README", nil, .unknown), (".jpg", nil, .unknown), ("name.", nil, .unknown),
            ("photo.jpg", "", .image), ("photo.jpg", "   ", .image),
            ("photo.jpg", "image/*", .image), ("photo.jpg", "image/jpeg\r\nX: y", .image),
            ("opaque.bin", nil, .unknown), ("ambiguous.mp4", nil, .video)
        ]
        for (name, mime, expected) in cases {
            let entry = RemoteEntry(id: name, path: nil, name: name, type: .file, contentType: mime)
            #expect(entry.fileCategory == expected, "name=\(name), mime=\(mime ?? "nil")")
        }
        #expect(RemoteEntry(id: "d", path: nil, name: "folder.jpg", type: .directory, contentType: "image/jpeg").fileCategory == .directory)
    }

    @Test func localListStatAndDownloadReportSourceCreationDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoneMetadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("photo.jpg")
        try Data("opaque bytes, not a decoded image".utf8).write(to: input)
        let actual = try #require(input.resourceValues(forKeys: [.creationDateKey]).creationDate)
        let source = LocalFileSource(root: root)
        try await source.connect(.anonymous)
        let listed = try #require(try await source.list(path: "/").entries.first)
        #expect(listed.createdAt == actual)
        #expect(listed.fileCategory == .image)
        #expect(try await source.stat(path: "/photo.jpg").createdAt == actual)
        let downloaded = try await source.download(path: "/photo.jpg", to: root.appendingPathComponent("out"))
        #expect(downloaded.createdAt == actual)
        #expect(try await source.stat(path: "/").createdAt != nil)
        await source.disconnect()
    }
}
