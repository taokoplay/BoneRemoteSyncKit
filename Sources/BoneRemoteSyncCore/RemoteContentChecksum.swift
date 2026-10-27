import Foundation

/// 整文件内容摘要的算法。厂商分块/组合算法与普通 SHA-256 不可互换。
/// MD5、SHA-1、QuickXorHash 仅用于完整性/变化提示，不提供抗恶意碰撞的真实性保证。
public enum RemoteContentChecksumAlgorithm: String, Sendable, Codable, Hashable, CaseIterable {
    case md5
    case sha1
    case sha256
    case dropboxContentHash
    case oneDriveQuickXorHash

    public var digestByteCount: Int {
        switch self {
        case .md5: 16
        case .sha1, .oneDriveQuickXorHash: 20
        case .sha256, .dropboxContentHash: 32
        }
    }
}

/// 来源报告或宿主计算的整文件校验值；不表示 SDK 已验证内容。
/// digest 保存原始字节，不是 hex/Base64 文本。相等性包含算法，ETag 不自动转换为此类型。
public struct RemoteContentChecksum: Sendable, Hashable, Codable {
    public let algorithm: RemoteContentChecksumAlgorithm
    public let digest: Data

    public init(algorithm: RemoteContentChecksumAlgorithm, digest: Data) throws {
        guard digest.count == algorithm.digestByteCount else {
            throw RemoteSyncError.unsupported(operation: "内容摘要长度与算法不符")
        }
        self.algorithm = algorithm
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey { case algorithm, digest }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let algorithm = try values.decode(RemoteContentChecksumAlgorithm.self, forKey: .algorithm)
        let digest = try values.decode(Data.self, forKey: .digest)
        guard digest.count == algorithm.digestByteCount else {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: values, debugDescription: "内容摘要长度与算法不符")
        }
        try self.init(algorithm: algorithm, digest: digest)
    }
}
