import Foundation
import BoneRemoteSyncCore

/// Catalog 刷新范围：只刷新根目录子项，或递归刷新整个子树。
public enum RemoteCatalogRefreshScope: String, Sendable, Codable { case children, subtree }

/// 已保存的 Catalog 根目录选择及其来源绑定信息。
public struct RemoteCatalogRoot: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public let bindingID: UUID
    public let selectionRevision: Int64
    public let path: String
    public let entryID: String
    public let includeHidden: Bool
    public let defaultScope: RemoteCatalogRefreshScope

    /// The host or Catalog selection operation must verify this is a directory in the bound source.
    public init(id: UUID = UUID(), sourceID: UUID, bindingID: UUID, selectionRevision: Int64 = 1,
                path: String, entryID: String, includeHidden: Bool = false,
                defaultScope: RemoteCatalogRefreshScope = .children) throws {
        self.id = id; self.sourceID = sourceID; self.bindingID = bindingID
        self.selectionRevision = selectionRevision; self.path = path; self.entryID = entryID
        self.includeHidden = includeHidden; self.defaultScope = defaultScope
        try validate()
    }
    /// 校验路径、选择版本和来源条目标识是否满足持久化约束。
    public func validate() throws {
        try CatalogValidation.path(path)
        // Local/WebDAV use an empty relative ID for the source root.
        guard selectionRevision > 0, selectionRevision < Int64.max,
              CatalogValidation.text(entryID, max: 32768, allowEmpty: path == "/") else {
            throw RemoteCatalogError.invalidConfiguration
        }
    }
}

/// Catalog 缓存状态；`stale` 表示需要显式刷新，不能直接当作实时结果。
public enum RemoteCatalogCacheState: String, Sendable { case notInitialized, current, stale }

/// Catalog 缓存查询参数。
public struct RemoteCatalogQuery: Sendable {
    public let limit: Int
    public let pageToken: String?
    /// 创建缓存查询；`pageToken` 由上一次查询返回，只能用于同一 root 和目录。
    public init(limit: Int = 100, pageToken: String? = nil) { self.limit = limit; self.pageToken = pageToken }
}

/// Catalog 返回的离线目录快照及分页状态。
public struct RemoteCatalogSnapshot: Sendable {
    public let entries: [RemoteEntry]
    public let state: RemoteCatalogCacheState
    public let version: Int64
    public let lastSuccessfulAt: Date?
    public let lastAttemptAt: Date?
    public let nextPageToken: String?
}
