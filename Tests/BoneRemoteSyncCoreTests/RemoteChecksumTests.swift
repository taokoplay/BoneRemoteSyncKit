import Foundation
import Testing
import BoneRemoteSyncCore

@Suite struct RemoteChecksumTests {
    @Test func algorithmsRetainExactBytesAndDistinctIdentity() throws {
        for algorithm in RemoteContentChecksumAlgorithm.allCases {
            let bytes = Data((0..<algorithm.digestByteCount).map(UInt8.init))
            let value = try RemoteContentChecksum(algorithm: algorithm, digest: bytes)
            #expect(try JSONDecoder().decode(RemoteContentChecksum.self, from: JSONEncoder().encode(value)) == value)
            #expect(value.digest == bytes)
            #expect(throws: RemoteSyncError.self) { try RemoteContentChecksum(algorithm: algorithm, digest: Data()) }
        }
        let bytes = Data(repeating: 1, count: 32)
        #expect(try RemoteContentChecksum(algorithm: .sha256, digest: bytes) != RemoteContentChecksum(algorithm: .dropboxContentHash, digest: bytes))
    }

    @Test func decodingCannotBypassDigestLengthValidation() throws {
        for algorithm in RemoteContentChecksumAlgorithm.allCases {
            let malformed = try JSONSerialization.data(withJSONObject: ["algorithm": algorithm.rawValue, "digest": Data([1]).base64EncodedString()])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(RemoteContentChecksum.self, from: malformed) }
        }
    }

    @Test func entryChecksumRoundTripIsIndependentOfETagAndOldMetadata() throws {
        let checksum = try RemoteContentChecksum(algorithm: .sha256, digest: Data(repeating: 0xab, count: 32))
        let entry = RemoteEntry(id: "id", path: nil, name: "file", type: .file, contentChecksums: [checksum])
        #expect(entry.etag == nil)
        #expect(!entry.hasReliableFingerprint)
        #expect(try JSONDecoder().decode(RemoteEntry.self, from: JSONEncoder().encode(entry)) == entry)
        let old = Data(#"{"id":"id","name":"file","type":"file","etag":"not-a-hash"}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteEntry.self, from: old)
        #expect(decoded.contentChecksums == nil)
        #expect(decoded.etag == "not-a-hash")
    }
}
