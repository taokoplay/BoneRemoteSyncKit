import Foundation
import CryptoKit
import BoneRemoteSyncCore

struct DAVCheckpointBinding: Codable, Sendable, Equatable {
    let sourceNamespaceHash: String
    let rootHash: String
    let remotePathHash: String
    let destinationHash: String
    init(sourceNamespace: String, root: String, remotePath: String, destination: String) {
        func hash(_ text: String) -> String { DAVPartHasher.hex(SHA256.hash(data: Data(text.utf8))) }
        sourceNamespaceHash = hash(sourceNamespace); rootHash = hash(root)
        remotePathHash = hash(remotePath); destinationHash = hash(destination)
    }
    var isValid: Bool { [sourceNamespaceHash, rootHash, remotePathHash, destinationHash].allSatisfy(DAVCheckpointRecord.isDigest) }
}

enum DAVCheckpointPhase: String, Codable, Sendable { case downloading, readyToInstall }

struct DAVCheckpointRecord: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var phase: DAVCheckpointPhase = .downloading
    let binding: DAVCheckpointBinding
    let etag: String
    let expectedSize: Int64
    var committedBytes: Int64
    var prefixSHA256: String
    let partDevice: UInt64
    let partInode: UInt64
    var modifiedAt: Date? = nil
    var contentType: String? = nil

    func validate() throws {
        guard schemaVersion == 1, binding.isValid, WebDAVSource.isStrongETag(etag), etag.utf8.count <= 4096,
              expectedSize >= 0, committedBytes >= 0, committedBytes <= expectedSize,
              Self.isDigest(prefixSHA256), partInode > 0,
              phase != .readyToInstall || committedBytes == expectedSize,
              contentType.map({ $0.utf8.count <= 1024 }) ?? true,
              modifiedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw RemoteSyncError.conflict(path: "WebDAV 检查点")
        }
    }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
