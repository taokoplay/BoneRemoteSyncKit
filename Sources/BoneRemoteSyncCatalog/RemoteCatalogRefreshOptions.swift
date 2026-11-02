import Foundation

/// Catalog 显式刷新参数，统一限制并发、目录规模、分页、深度和总时限。
public struct RemoteCatalogRefreshOptions: Sendable {
    public let scope: RemoteCatalogRefreshScope
    public let concurrency: Int
    public let pageSize: Int
    public let maxEntries: Int
    public let maxDirectories: Int
    public let maxDepth: Int
    public let maxPagesPerDirectory: Int
    public let timeout: TimeInterval
    /// 创建刷新参数；所有预算会在刷新开始前统一校验。
    public init(scope: RemoteCatalogRefreshScope = .children, concurrency: Int = 4, pageSize: Int = 200,
                maxEntries: Int = 1_000_000, maxDirectories: Int = 100_000, maxDepth: Int = 256,
                maxPagesPerDirectory: Int = 10_000, timeout: TimeInterval = 600) {
        self.scope = scope; self.concurrency = concurrency; self.pageSize = pageSize
        self.maxEntries = maxEntries; self.maxDirectories = maxDirectories; self.maxDepth = maxDepth
        self.maxPagesPerDirectory = maxPagesPerDirectory; self.timeout = timeout
    }
    /// 校验刷新预算，非法参数会抛出 `RemoteCatalogError.invalidConfiguration`。
    public func validate() throws {
        guard (1...16).contains(concurrency), (1...10000).contains(pageSize),
              (1...10_000_000).contains(maxEntries), (1...100_000).contains(maxDirectories),
              (0...1024).contains(maxDepth), (1...100_000).contains(maxPagesPerDirectory),
              timeout.isFinite, timeout > 0, timeout <= 86400 else { throw RemoteCatalogError.invalidConfiguration }
    }
}
