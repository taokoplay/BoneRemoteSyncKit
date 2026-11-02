import Foundation

/// Catalog 某个选定根目录的递归扫描统计快照。
///
/// 这不是实时网盘配额响应；`capacityBytes` 和 `usedBytes` 只有来源提供可靠
/// quota 能力时才会有值。统计来自完整 `subtree` 刷新，可能因远端变化而过期。
public struct RemoteCatalogStorageSummary: Sendable, Codable, Equatable {
    /// 统计所属的 Catalog 根目录 ID。
    public let rootID: UUID
    /// 统计所属的来源路径，通常是 `RemoteCatalogRoot.path`。
    public let path: String
    /// 递归扫描发现的文件数量；没有完成完整扫描时可能为 `nil`。
    public let recursiveFileCount: Int64?
    /// 递归扫描发现的子目录数量，不包含统计根目录自身。
    public let recursiveDirectoryCount: Int64?
    /// 递归文件总字节数；任一文件大小未知时为 `nil`，不会把未知值当作 0。
    public let totalBytes: Int64?
    /// 来源报告的总容量；未提供 quota 能力时为 `nil`。
    public let capacityBytes: Int64?
    /// 来源报告的已用容量；未提供 quota 能力时为 `nil`。
    public let usedBytes: Int64?
    /// 是否由完整 subtree 扫描成功生成。
    public let isComplete: Bool
    /// 统计是否可能已被远端 mutation、失败刷新或缓存失效标记过期。
    public let isStale: Bool
    /// 目录扫描统计的测量时间。
    public let measuredAt: Date?
    /// quota 字段的测量时间。
    public let quotaMeasuredAt: Date?

    /// 创建一个统计快照。
    ///
    /// - Parameters:
    ///   - rootID: 统计所属的 Catalog 根目录 ID。
    ///   - path: 统计所属的来源路径。
    ///   - recursiveFileCount: 递归文件数量；未知时传 `nil`。
    ///   - recursiveDirectoryCount: 递归子目录数量；未知时传 `nil`。
    ///   - totalBytes: 已知文件大小的递归总和；存在未知大小时传 `nil`。
    ///   - capacityBytes: 来源报告的总容量，没有 quota 时传 `nil`。
    ///   - usedBytes: 来源报告的已用容量，没有 quota 时传 `nil`。
    ///   - isComplete: 是否完成完整 subtree 扫描。
    ///   - isStale: 是否已被标记为可能过期。
    ///   - measuredAt: 扫描统计的测量时间。
    ///   - quotaMeasuredAt: quota 数据的测量时间。
    public init(rootID: UUID, path: String, recursiveFileCount: Int64? = nil,
                recursiveDirectoryCount: Int64? = nil, totalBytes: Int64? = nil,
                capacityBytes: Int64? = nil, usedBytes: Int64? = nil,
                isComplete: Bool, isStale: Bool, measuredAt: Date? = nil,
                quotaMeasuredAt: Date? = nil) {
        self.rootID = rootID
        self.path = path
        self.recursiveFileCount = recursiveFileCount
        self.recursiveDirectoryCount = recursiveDirectoryCount
        self.totalBytes = totalBytes
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
        self.isComplete = isComplete
        self.isStale = isStale
        self.measuredAt = measuredAt
        self.quotaMeasuredAt = quotaMeasuredAt
    }
}
