import Foundation

/// Identifies the namespace in which a remote locator is meaningful.
///
/// `identity` is an opaque, non-secret provider/account/root identifier. It must
/// not contain access tokens, cookies, signed URLs, or other credentials.
public struct RemoteSourceBinding: Sendable, Hashable, Codable {
    public let kind: RemoteSourceKind
    public let identity: String

    public init(kind: RemoteSourceKind, identity: String) {
        self.kind = kind
        self.identity = identity
    }
}

/// A source-specific way to locate one remote item.
public enum RemoteLocator: Sendable, Hashable, Codable {
    case path(String)
    case itemID(String)

    public init(path: String) {
        self = .path(RemotePath.normalize(path))
    }

    public init(itemID: String) {
        self = .itemID(itemID)
    }
}

/// A remote file identity used by higher-level file services.
///
/// The binding prevents a path or provider ID observed in one account/root from
/// being silently reused against another source session.
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
public enum RemoteVersionStrength: String, Sendable, Hashable, Codable {
    /// The source can use this value as an atomic conditional operation.
    case strongConditional
    /// The value can detect many changes but is not an atomic write condition.
    case metadataFingerprint
    /// The value was observed but the source does not promise change detection.
    case observedOnly
}

/// A source- and locator-scoped opaque version value. It is not a content checksum.
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
public enum RemoteReadConsistency: Sendable, Hashable, Codable {
    case latestObserved
    case requireVersion(RemoteVersion)
}

/// Write condition for a higher-level upload operation.
public enum RemoteWriteCondition: Sendable, Hashable, Codable {
    case createOnly
    case replace
    case replaceIfVersion(RemoteVersion)
}
