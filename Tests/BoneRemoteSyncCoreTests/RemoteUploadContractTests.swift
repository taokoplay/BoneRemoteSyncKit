import Foundation
import Testing
@testable import BoneRemoteSyncCore

@Suite struct RemoteUploadContractTests {
    private func handle() throws -> RemoteUploadHandle {
        let binding = RemoteSourceBinding(kind: .cloudAPI, identity: "test")
        return try RemoteUploadHandle(source: binding, target: .init(source: binding, path: "/file"),
                                      sourceSize: 10, sourceFingerprint: "digest")
    }

    @Test func decodedCheckpointMustRevalidateItsCounts() throws {
        let value = try RemoteUploadCheckpoint(handle: handle(), confirmedBytes: 2, totalBytes: 10, phase: .uploading)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for (confirmed, total) in [(-1, 10), (11, 10), (1, 11)] {
            json["confirmedBytes"] = confirmed
            json["totalBytes"] = total
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: RemoteSyncError.self) { try JSONDecoder().decode(RemoteUploadCheckpoint.self, from: data) }
        }
    }

    @Test func committedResultRequiresEntryAndCompleteSize() throws {
        let h = try handle()
        #expect(throws: RemoteSyncError.self) {
            try RemoteResumableUploadResult(entry: nil, handle: h, state: .committed, confirmedBytes: 10, totalBytes: 10)
        }
        #expect(throws: RemoteSyncError.self) {
            try RemoteUploadCheckpoint(handle: h, confirmedBytes: 2, totalBytes: 9, phase: .uploading)
        }
    }

    @Test func uploadDefaultsDoNotOverwrite() {
        #expect(!RemoteResumableUploadOptions(snapshotDirectory: URL(fileURLWithPath: "/cache")).overwrite)
    }
}
