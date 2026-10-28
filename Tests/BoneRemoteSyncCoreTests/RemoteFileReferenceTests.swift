import Foundation
import Testing
import BoneRemoteSyncCore

@Suite struct RemoteFileReferenceTests {
    @Test func pathReferencesNormalizeWithoutChangingBinding() throws {
        let binding = RemoteSourceBinding(kind: .webdav, identity: "dav-account-root")
        let reference = RemoteFileReference(source: binding, path: "folder/../file.txt")

        #expect(reference.source == binding)
        #expect(reference.locator == .path("/file.txt"))
        #expect(reference.displayLocator == "/file.txt")
    }

    @Test func itemReferencesRemainDistinctFromPaths() {
        let binding = RemoteSourceBinding(kind: .cloudAPI, identity: "personal-drive")
        let path = RemoteFileReference(source: binding, path: "/file.txt")
        let item = RemoteFileReference(source: binding, itemID: "file-id")

        #expect(path != item)
        #expect(item.displayLocator == "id:file-id")
    }

    @Test func versionStrengthAndSourceBindingSurviveCodableRoundTrip() throws {
        let binding = RemoteSourceBinding(kind: .local, identity: "application-root")
        let version = RemoteVersion(source: binding, locator: .path("/file.txt"), value: "42-1000", strength: .metadataFingerprint)
        let encoded = try JSONEncoder().encode(version)
        let decoded = try JSONDecoder().decode(RemoteVersion.self, from: encoded)

        #expect(decoded == version)
        #expect(decoded.strength == .metadataFingerprint)
        #expect(decoded.source == binding)
    }

    @Test func decodedReferencesAndVersionsKeepCanonicalPaths() throws {
        let binding = RemoteSourceBinding(kind: .local, identity: "root")
        let reference = RemoteFileReference(source: binding, locator: .path("a/../file"))
        #expect(reference.locator == .path("/file"))
        let version = RemoteVersion(source: binding, locator: .path("/file"), value: "v", strength: .metadataFingerprint)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(version)) as? [String: Any])
        object["locator"] = ["path": ["_0": "folder/../file"]]
        let decoded = try JSONDecoder().decode(RemoteVersion.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == version)
    }

    @Test func decodingProgressCannotBypassNonnegativeInvariants() throws {
        let data = Data(#"{"phase":"transferring","completedBytes":-1,"totalBytes":-2,"attempt":-3,"sequence":0}"#.utf8)
        let progress = try JSONDecoder().decode(RemoteTransferProgress.self, from: data)
        #expect(progress.completedBytes == 0)
        #expect(progress.totalBytes == 0)
        #expect(progress.attempt == 0)
    }

    @Test func transferSnapshotOnlyTerminalPhasesAreTerminal() {
        let id = UUID()
        let active = RemoteTransferSnapshot(id: id, phase: .transferring)
        let completed = RemoteTransferSnapshot(id: id, phase: .completed)
        let cancelled = RemoteTransferSnapshot(id: id, phase: .cancelled)

        #expect(!active.isTerminal)
        #expect(completed.isTerminal)
        #expect(cancelled.isTerminal)
    }
}
