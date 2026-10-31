import Foundation

/// A bundled PNG icon that can be used by source pickers and drive lists.
public enum BoneRemoteSyncIcon: String, CaseIterable, Sendable, Hashable {
    case googleDrive = "google-drive"
    case aliyun
    case baidu
    case onedrive
    case icloud
    case webdav

    public var resourceName: String { rawValue }

    /// Returns the packaged 400×400 PNG URL.
    public var url: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "png", subdirectory: "icon.bundle")
    }

    /// Reads the packaged PNG bytes.
    public func data() throws -> Data {
        guard let url else { throw BoneRemoteSyncIconError.missingResource(rawValue) }
        return try Data(contentsOf: url)
    }
}

public enum BoneRemoteSyncIconError: Error, Sendable, Equatable {
    case missingResource(String)
}

/// One row for a source picker. `icon` is optional for source kinds without a bundled artwork.
public struct BoneRemoteSyncSourceType: Sendable, Hashable, Identifiable {
    public let kind: RemoteSourceKind
    public let displayName: String
    public let icon: BoneRemoteSyncIcon?

    public var id: RemoteSourceKind { kind }

    public init(kind: RemoteSourceKind, displayName: String? = nil, icon: BoneRemoteSyncIcon? = nil) {
        self.kind = kind
        self.displayName = displayName ?? kind.displayName
        self.icon = icon ?? kind.iconResourceName.flatMap(BoneRemoteSyncIcon.init(rawValue:))
    }
}

/// A named cloud provider row. This list can include providers whose adapters are not yet implemented.
public struct BoneRemoteSyncDriveType: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let icon: BoneRemoteSyncIcon
    public let kind: RemoteSourceKind

    public init(id: String, displayName: String, icon: BoneRemoteSyncIcon, kind: RemoteSourceKind = .cloudAPI) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.kind = kind
    }
}

public extension BoneRemoteSyncSourceType {
    /// All source kinds, in the stable `RemoteSourceKind.allCases` order.
    static var all: [BoneRemoteSyncSourceType] {
        RemoteSourceKind.allCases.map { .init(kind: $0) }
    }
}

/// Resource and source-picker helpers exported by the umbrella SDK.
public enum BoneRemoteSyncIcons {
    public static func icon(for kind: RemoteSourceKind) -> BoneRemoteSyncIcon? {
        kind.iconResourceName.flatMap(BoneRemoteSyncIcon.init(rawValue:))
    }

    public static func iconURL(for kind: RemoteSourceKind) -> URL? {
        icon(for: kind)?.url
    }

    public static func iconData(for kind: RemoteSourceKind) throws -> Data {
        guard let icon = icon(for: kind) else {
            throw BoneRemoteSyncIconError.missingResource(kind.rawValue)
        }
        return try icon.data()
    }

    public static func sourceTypes() -> [BoneRemoteSyncSourceType] {
        BoneRemoteSyncSourceType.all
    }

    /// All bundled cloud provider icons, including providers not yet connected to an adapter.
    public static func driveTypes() -> [BoneRemoteSyncDriveType] {
        [
            .init(id: "google-drive", displayName: "Google Drive", icon: .googleDrive),
            .init(id: "aliyun", displayName: "阿里云盘", icon: .aliyun),
            .init(id: "baidu", displayName: "百度网盘", icon: .baidu),
            .init(id: "onedrive", displayName: "OneDrive", icon: .onedrive),
            .init(id: "icloud", displayName: "iCloud Drive", icon: .icloud, kind: .iCloud),
            .init(id: "webdav", displayName: "WebDAV", icon: .webdav, kind: .webdav),
        ]
    }
}
