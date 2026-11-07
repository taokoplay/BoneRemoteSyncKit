import Foundation

/// 可用于来源选择器和网盘列表的内置 PNG 图标。
public enum BoneRemoteSyncIcon: String, CaseIterable, Sendable, Hashable {
    case googleDrive = "google-drive"
    case aliyun
    case baidu
    case onedrive
    case icloud
    case webdav

    /// bundle 中的资源名，不含文件扩展名。
    public var resourceName: String { rawValue }

    /// 返回随 Swift Package 分发的 400×400 PNG URL。
    public var url: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "png", subdirectory: "icon.bundle")
    }

    /// 读取当前图标的 PNG 数据。
    /// - Returns: PNG 文件数据。
    /// - Throws: `BoneRemoteSyncIconError.missingResource`，当资源不存在时抛出。
    public func data() throws -> Data {
        guard let url else { throw BoneRemoteSyncIconError.missingResource(rawValue) }
        return try Data(contentsOf: url)
    }
}

/// 图标资源缺失错误。
public enum BoneRemoteSyncIconError: Error, Sendable, Equatable {
    case missingResource(String)
}

/// 来源选择器中的一项；没有内置图标的预留来源，其 `icon` 为 `nil`。
public struct BoneRemoteSyncSourceType: Sendable, Hashable, Identifiable {
    /// 来源类型枚举。
    public let kind: RemoteSourceKind
    /// 默认英文显示名称，宿主可自行本地化。
    public let displayName: String
    /// 对应的内置图标；没有资源时为 `nil`。
    public let icon: BoneRemoteSyncIcon?

    public var id: RemoteSourceKind { kind }

    /// 创建来源类型展示项。
    /// - Parameters:
    ///   - kind: 来源类型。
    ///   - displayName: 自定义显示名称；省略时使用 `kind.displayName`。
    ///   - icon: 自定义图标；省略时根据 `kind.iconResourceName` 推导。
    public init(kind: RemoteSourceKind, displayName: String? = nil, icon: BoneRemoteSyncIcon? = nil) {
        self.kind = kind
        self.displayName = displayName ?? kind.displayName
        self.icon = icon ?? kind.iconResourceName.flatMap(BoneRemoteSyncIcon.init(rawValue:))
    }
}

/// 一个可展示的网盘类型项；列表可以包含尚未实现原生适配器的网盘。
public struct BoneRemoteSyncDriveType: Sendable, Hashable, Identifiable {
    /// 与来源实例、绑定共用的强类型标识，不另存一份字符串 ID。
    public var id: RemoteSourceKind { kind }
    /// 默认显示名称，宿主可自行本地化。
    public let displayName: String
    /// 对应的内置图标。
    public let icon: BoneRemoteSyncIcon
    /// 精确来源标识；每个厂商网盘使用独立枚举值。
    public let kind: RemoteSourceKind

    /// 创建网盘类型项。
    /// - Parameters:
    ///   - kind: 精确的来源类型。
    ///   - displayName: 默认显示名称。
    ///   - icon: 对应的内置图标。
    public init(kind: RemoteSourceKind, displayName: String, icon: BoneRemoteSyncIcon) {
        self.displayName = displayName
        self.icon = icon
        self.kind = kind
    }
}

public extension BoneRemoteSyncSourceType {
    /// 按稳定的 `RemoteSourceKind.allCases` 顺序返回全部来源类型。
    static var all: [BoneRemoteSyncSourceType] {
        RemoteSourceKind.allCases.map { .init(kind: $0) }
    }
}

/// 统一入口提供的图标和来源选择器辅助方法。
public enum BoneRemoteSyncIcons {
    /// 根据来源类型返回对应的内置图标。
    /// - Parameter kind: 要查询的来源类型。
    /// - Returns: 对应图标；没有内置资源时返回 `nil`。
    public static func icon(for kind: RemoteSourceKind) -> BoneRemoteSyncIcon? {
        kind.iconResourceName.flatMap(BoneRemoteSyncIcon.init(rawValue:))
    }

    /// 根据来源类型返回 bundle 中图标 PNG 的 URL。
    /// - Parameter kind: 要查询的来源类型。
    /// - Returns: 图标资源 URL；没有内置资源时返回 `nil`。
    public static func iconURL(for kind: RemoteSourceKind) -> URL? {
        icon(for: kind)?.url
    }

    /// 读取来源类型对应的 PNG 图标数据。
    /// - Parameter kind: 要读取的来源类型。
    /// - Returns: PNG 数据。
    /// - Throws: `BoneRemoteSyncIconError.missingResource`，当来源没有内置图标时抛出。
    public static func iconData(for kind: RemoteSourceKind) throws -> Data {
        guard let icon = icon(for: kind) else {
            throw BoneRemoteSyncIconError.missingResource(kind.rawValue)
        }
        return try icon.data()
    }

    /// 返回全部来源类型及其默认显示信息和图标。
    /// - Returns: 按 `RemoteSourceKind.allCases` 排序的来源类型列表。
    public static func sourceTypes() -> [BoneRemoteSyncSourceType] {
        BoneRemoteSyncSourceType.all
    }

    /// 返回全部内置网盘图标目录项。
    ///
    /// 列表可以包含尚未接入原生适配器的网盘；它只描述 UI 展示信息。
    /// - Returns: 网盘类型列表。
    public static func driveTypes() -> [BoneRemoteSyncDriveType] {
        [
            .init(kind: .googleDrive, displayName: "Google Drive", icon: .googleDrive),
            .init(kind: .aliyun, displayName: "阿里云盘", icon: .aliyun),
            .init(kind: .baidu, displayName: "百度网盘", icon: .baidu),
            .init(kind: .oneDrive, displayName: "OneDrive", icon: .onedrive),
            .init(kind: .iCloud, displayName: "iCloud Drive", icon: .icloud),
            .init(kind: .webdav, displayName: "WebDAV", icon: .webdav),
        ]
    }
}
