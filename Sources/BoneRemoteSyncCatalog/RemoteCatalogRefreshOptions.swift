import Foundation

/// Catalog 显式刷新参数，统一限制并发、请求间隔、目录规模、分页、深度和总时限。
public struct RemoteCatalogRefreshOptions: Sendable {
    public let scope: RemoteCatalogRefreshScope
    public let concurrency: Int
    /// 同一轮扫描的 list/stat 调用之间的最小放行间隔，单位秒；0 不延迟。
    /// 所有目录任务共享，范围 0...86400；等待计入 timeout，且可取消。
    /// 不限制连接/认证、选根预检、适配器内部重试或其他刷新任务。
    /// 请求可能重叠；需串行扫描时同时设置 concurrency = 1。
    public let requestInterval: TimeInterval
    public let pageSize: Int
    public let maxEntries: Int
    public let maxDirectories: Int
    public let maxDepth: Int
    public let maxPagesPerDirectory: Int
    public let timeout: TimeInterval
    /// 创建刷新参数；所有预算会在刷新开始前统一校验。
    public init(scope: RemoteCatalogRefreshScope = .children, concurrency: Int = 4, pageSize: Int = 200,
                maxEntries: Int = 1_000_000, maxDirectories: Int = 100_000, maxDepth: Int = 256,
                maxPagesPerDirectory: Int = 10_000, timeout: TimeInterval = 600,
                requestInterval: TimeInterval = 0) {
        self.scope = scope; self.concurrency = concurrency; self.pageSize = pageSize
        self.maxEntries = maxEntries; self.maxDirectories = maxDirectories; self.maxDepth = maxDepth
        self.maxPagesPerDirectory = maxPagesPerDirectory; self.timeout = timeout
        self.requestInterval = requestInterval
    }
    /// 校验刷新预算，非法参数会抛出 `RemoteCatalogError.invalidConfiguration`。
    public func validate() throws {
        guard (1...16).contains(concurrency), (1...10000).contains(pageSize),
              (1...10_000_000).contains(maxEntries), (1...100_000).contains(maxDirectories),
              (0...1024).contains(maxDepth), (1...100_000).contains(maxPagesPerDirectory),
              timeout.isFinite, timeout > 0, timeout <= 86400,
              requestInterval.isFinite, requestInterval >= 0, requestInterval <= 86400 else {
            throw RemoteCatalogError.invalidConfiguration
        }
    }
}
