import Foundation
import Testing
@testable import BoneRemoteSyncCore

@Suite struct RemoteDownloadCheckpointTests {
    @Test func checkpointRejectsUnscopedOrImpossibleObservations() throws {
        let binding = RemoteSourceBinding(kind: .webdav, identity: "test")
        let reference = RemoteFileReference(source: binding, path: "/file")
        let destination = URL(fileURLWithPath: "/local/output")
        let version = RemoteVersion(source: binding, locator: reference.locator, value: "v1", strength: .strongConditional)
        let invalidVersions = [
            RemoteVersion(source: .init(kind: .webdav, identity: "other"), locator: reference.locator, value: "v1", strength: .strongConditional),
            RemoteVersion(source: binding, locator: .path("/other"), value: "v1", strength: .strongConditional),
            RemoteVersion(source: binding, locator: reference.locator, value: "v1", strength: .observedOnly)
        ]
        for invalid in invalidVersions {
            #expect(throws: RemoteSyncError.self) {
                try RemoteDownloadCheckpoint(reference: reference, destination: destination, version: invalid,
                    expectedSize: 10, confirmedBytes: 5, phase: .downloading)
            }
        }
        for (size, confirmed) in [(Int64(-1), Int64(0)), (10, -1), (10, 11)] {
            #expect(throws: RemoteSyncError.self) {
                try RemoteDownloadCheckpoint(reference: reference, destination: destination, version: version,
                    expectedSize: size, confirmedBytes: confirmed, phase: .downloading)
            }
        }
        #expect(throws: RemoteSyncError.self) {
            try RemoteDownloadCheckpoint(reference: reference, destination: destination, version: version,
                expectedSize: 10, confirmedBytes: 5, phase: .readyToInstall)
        }
        let empty = try RemoteDownloadCheckpoint(reference: reference, destination: destination, version: version,
            expectedSize: 0, confirmedBytes: 0, phase: .readyToInstall)
        #expect(empty.confirmedBytes == 0)
    }
}
