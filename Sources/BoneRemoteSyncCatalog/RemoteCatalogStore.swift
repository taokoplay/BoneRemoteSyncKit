import Foundation

/// Catalog 的离线持久化协议；写操作使用版本号拒绝过期写入。
public protocol RemoteCatalogStore: Sendable {
    /// 保存来源配置，可使用 expectedRevision 防止覆盖并发修改。
    func saveProfile(_ profile: RemoteSourceProfile, expectedRevision: Int64?) async throws
    /// 读取指定来源配置。
    func profile(id: UUID) async throws -> RemoteSourceProfile
    /// 读取全部来源配置。
    func profiles() async throws -> [RemoteSourceProfile]
    /// 保存已选择的 Catalog 根目录。
    func saveRoot(_ root: RemoteCatalogRoot, expectedRevision: Int64?) async throws
    /// 读取指定根目录。
    func root(id: UUID) async throws -> RemoteCatalogRoot
    /// 读取来源下的全部根目录选择。
    func roots(sourceID: UUID) async throws -> [RemoteCatalogRoot]
    /// 查询离线缓存目录，不触发远端刷新。
    func listCached(rootID: UUID, directory: String, query: RemoteCatalogQuery) async throws -> RemoteCatalogSnapshot
    /// 查询最近一次完整子树扫描的统计快照。
    func storageSummary(rootID: UUID) async throws -> RemoteCatalogStorageSummary?
    /// 将目录缓存和统计标记为过期。
    func invalidateCache(rootID: UUID, directory: String?) async throws
    /// 清除指定根目录的缓存索引。
    func clearIndex(rootID: UUID) async throws
    /// 删除来源配置及其关联的根目录和缓存。
    func removeProfile(id: UUID) async throws
}
