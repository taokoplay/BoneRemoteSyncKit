import Foundation

/// 条目类型。只区分文件和目录，符号链接按解析结果归类，避免上层到处判空。
public enum RemoteEntryType: String, Sendable, Codable, Hashable {
    case file
    case directory
}

/// 跨来源统一的文件条目。
///
/// `id` 与 `path` 是两套标识，不能混用：
/// - 路径型来源（SMB / WebDAV / FTP / 本地）两者基本一致，`id` 为来源内的相对路径；
/// - 云盘用 fileId，`path` 可能缺失或不稳定；
/// - DLNA 只有 ObjectID，没有真实路径。
///
/// 因此业务侧凡是要"定位一个条目"，一律用 `id`；凡是需要展示或做同步比较，才用 `path`。
public struct RemoteEntry: Sendable, Hashable, Codable, Identifiable {
    /// 来源内部稳定标识。同一来源内唯一，跨来源不保证。
    public let id: String
    /// 来源内绝对路径（以 "/" 开头，根为 "/"）。来源不支持时为 nil。
    public let path: String?
    /// 展示名，不含路径。
    public let name: String
    public let type: RemoteEntryType
    /// 目录通常为 nil。
    public let size: Int64?
    public let modifiedAt: Date?
    /// 来源报告的条目创建时间；不是拍摄/录制时间。缺失或无效时为 nil。
    /// Local 为文件系统创建时间，WebDAV 为 DAV creationdate，OneDrive 为 driveItem.createdDateTime。
    public let createdAt: Date?
    /// 变更检测主依据。缺失时上层必须退化为 size + modifiedAt。
    public let etag: String?
    public let contentType: String?
    /// 可选的整文件内容校验值；nil 表示来源未提供。独立于 ETag，不代表下载已校验。
    public let contentChecksums: [RemoteContentChecksum]?

    public init(
        id: String,
        path: String?,
        name: String,
        type: RemoteEntryType,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        etag: String? = nil,
        contentType: String? = nil,
        createdAt: Date? = nil,
        contentChecksums: [RemoteContentChecksum]? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.type = type
        self.size = size
        self.modifiedAt = modifiedAt
        self.etag = etag
        self.contentType = contentType
        self.createdAt = createdAt
        self.contentChecksums = contentChecksums
    }

    public var isDirectory: Bool { type == .directory }
}

extension RemoteEntry {
    /// 同一来源内，能否用元数据判断"内容未变化"。
    /// 没有 etag 也没有 mtime 的来源，必须走全量比对，不能在同步引擎里假装增量。
    public var hasReliableFingerprint: Bool {
        etag != nil || modifiedAt != nil
    }
}
