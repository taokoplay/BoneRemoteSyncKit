import Foundation

/// 来源绑定标识，限定路径或条目 ID 的账号、主盘和根目录命名空间。
public struct RemoteSourceBinding: Sendable, Hashable, Codable {
    public let kind: RemoteSourceKind
    public let identity: String

    public init(kind: RemoteSourceKind, identity: String) {
        self.kind = kind
        self.identity = identity
    }
}

/// A source-specific way to locate one remote item.
/// 来源内定位条目的方式：路径或来源提供的稳定条目 ID。
public enum RemoteLocator: Sendable, Hashable, Codable {
    case path(String)
    case itemID(String)

    /// 使用来源路径创建定位器，并自动规范化路径。
    public init(path: String) {
        self = .path(RemotePath.normalize(path))
    }

    /// 使用来源稳定条目 ID 创建定位器。
    public init(itemID: String) {
        self = .itemID(itemID)
    }
}

/// 高层文件服务使用的远端文件引用；绑定防止跨账号或跨来源复用定位信息。
public struct RemoteFileReference: Sendable, Hashable, Codable {
    public let source: RemoteSourceBinding
    public let locator: RemoteLocator

    public init(source: RemoteSourceBinding, locator: RemoteLocator) {
        self.source = source
        if case .path(let path) = locator { self.locator = .path(RemotePath.normalize(path)) }
        else { self.locator = locator }
    }

    public init(source: RemoteSourceBinding, path: String) {
        self.init(source: source, locator: RemoteLocator(path: path))
    }

    public init(source: RemoteSourceBinding, itemID: String) {
        self.init(source: source, locator: RemoteLocator(itemID: itemID))
    }

    private enum CodingKeys: String, CodingKey { case source, locator }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try values.decode(RemoteSourceBinding.self, forKey: .source),
                  locator: try values.decode(RemoteLocator.self, forKey: .locator))
    }

    /// A caller-supplied display path/identifier for diagnostics. It is not a globally
    /// unique identity and must not be used as a credential or URL.
    public var displayLocator: String {
        switch locator {
        case .path(let path): return path
        case .itemID(let id): return "id:\(id)"
        }
    }
}

/// Strength of a source-issued version observation.
/// 来源返回的版本强度，决定是否可以用于条件读写。
public enum RemoteVersionStrength: String, Sendable, Hashable, Codable {
    /// The source can use this value as an atomic conditional operation.
    case strongConditional
    /// The value can detect many changes but is not an atomic write condition.
    case metadataFingerprint
    /// The value was observed but the source does not promise change detection.
    case observedOnly
}

/// 来源和定位器范围内的不透明版本值，不是内容摘要。
public struct RemoteVersion: Sendable, Hashable, Codable {
    public let source: RemoteSourceBinding
    public let locator: RemoteLocator
    public let value: String
    public let strength: RemoteVersionStrength

    public init(source: RemoteSourceBinding, locator: RemoteLocator, value: String, strength: RemoteVersionStrength) {
        self.source = source
        self.locator = RemoteFileReference(source: source, locator: locator).locator
        self.value = value
        self.strength = strength
    }

    private enum CodingKeys: String, CodingKey { case source, locator, value, strength }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try c.decode(RemoteSourceBinding.self, forKey: .source),
                  locator: try c.decode(RemoteLocator.self, forKey: .locator),
                  value: try c.decode(String.self, forKey: .value),
                  strength: try c.decode(RemoteVersionStrength.self, forKey: .strength))
    }
}

/// Read consistency requested by a higher-level file operation.
/// 高层文件操作要求的读取一致性。
public enum RemoteReadConsistency: Sendable, Hashable, Codable {
    case latestObserved
    case requireVersion(RemoteVersion)
}

/// Write condition for a higher-level upload operation.
/// 高层上传操作使用的目标写入条件。
public enum RemoteWriteCondition: Sendable, Hashable, Codable {
    case createOnly
    case replace
    case replaceIfVersion(RemoteVersion)
}
