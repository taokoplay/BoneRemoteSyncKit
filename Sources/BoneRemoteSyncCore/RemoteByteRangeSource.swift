import Foundation

/// A nonempty half-open byte interval. Bounded responses keep memory independent
/// of whole-file size. This is not the open-ended resumeFrom download contract.
public struct RemoteByteRange: Sendable, Hashable {
    public static let maximumLength: Int64 = 8 * 1024 * 1024
    public let offset: Int64
    public let length: Int64
    public var endExclusive: Int64 { offset + length }

    public init(offset: Int64, length: Int64) throws {
        guard offset >= 0, length > 0, length <= Self.maximumLength,
              offset <= Int64.max - length else {
            throw RemoteSyncError.unsupported(operation: "无效的有界字节区间")
        }
        self.offset = offset
        self.length = length
    }
}

/// Only this error allows an opt-in caller to fall back before any segment is
/// installed. Authentication, version conflicts, malformed responses and network
/// failures must NOT be translated into unavailable.
/// 分片读取失败分类；只有该错误允许可选分片下载回退到普通下载。
public enum RemoteByteRangeError: Error, Sendable, Equatable {
    case unavailable
}

/// Optional plug-in for single-file segmented downloads. No provider imports are
/// required by the transfer engine. Conforming alone is not server capability proof.
/// 可选的单文件分片下载来源协议；实现必须保证区间、版本和响应长度严格匹配。
public protocol RemoteByteRangeSource: RemoteSource {
    /// An opaque strong conditional-read version, or nil if this entry cannot be
    /// read consistently by ranges. No I/O. An ETag is not necessarily a checksum.
    /// 返回条目当前可用于条件区间读取的强版本；不执行 I/O。
    func byteRangeVersion(for entry: RemoteEntry) -> String?

    /// Return exactly range.length bytes from the requested offset of this entry's
    /// version. Validate bounds against entry.size, atomically enforce the version,
    /// and verify actual returned interval/total size/version and body length.
    /// Never return a full-body 200, a short response, or bytes of another version.
    /// Bound received bytes to the requested length; promptly cancel on overflow,
    /// task cancellation or session disconnect. Calls may execute concurrently.
    /// No filesystem writes, auto-connect, or credentials in returned errors.
    /// 读取指定版本中的一个有界字节区间，返回长度必须与请求完全一致。
    func readBytes(_ entry: RemoteEntry, range: RemoteByteRange,
                   requiringVersion: String) async throws -> Data
}
