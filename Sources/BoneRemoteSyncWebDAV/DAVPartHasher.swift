import Foundation
import CryptoKit
import Darwin
import BoneRemoteSyncCore

enum DAVPartHasher {
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
    static func verifyPrefix(handle: FileHandle, record: DAVCheckpointRecord,
                             check: @Sendable () throws -> Void) throws -> SHA256 {
        try record.validate()
        try check()
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, UInt64(info.st_dev) == record.partDevice,
              UInt64(info.st_ino) == record.partInode, info.st_size >= record.committedBytes else {
            throw RemoteSyncError.conflict(path: "WebDAV 检查点 part")
        }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var remaining = record.committedBytes
        while remaining > 0 {
            try check()
            let data = try handle.read(upToCount: Int(min(64 * 1024, remaining))) ?? Data()
            guard !data.isEmpty else { throw RemoteSyncError.conflict(path: "WebDAV 检查点 part") }
            hasher.update(data: data)
            remaining -= Int64(data.count)
        }
        try check()
        guard hex(hasher.finalize()) == record.prefixSHA256 else {
            throw RemoteSyncError.conflict(path: "WebDAV 检查点摘要")
        }
        return hasher
    }
}
