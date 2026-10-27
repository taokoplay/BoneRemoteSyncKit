import Foundation

public struct RemoteCatalogRefreshOptions: Sendable {
    public let scope: RemoteCatalogRefreshScope
    public let concurrency: Int
    public let pageSize: Int
    public let maxEntries: Int
    public let maxDirectories: Int
    public let maxDepth: Int
    public let maxPagesPerDirectory: Int
    public let timeout: TimeInterval
    public init(scope: RemoteCatalogRefreshScope = .children, concurrency: Int = 4, pageSize: Int = 200,
                maxEntries: Int = 1_000_000, maxDirectories: Int = 100_000, maxDepth: Int = 256,
                maxPagesPerDirectory: Int = 10_000, timeout: TimeInterval = 600) {
        self.scope = scope; self.concurrency = concurrency; self.pageSize = pageSize
        self.maxEntries = maxEntries; self.maxDirectories = maxDirectories; self.maxDepth = maxDepth
        self.maxPagesPerDirectory = maxPagesPerDirectory; self.timeout = timeout
    }
    public func validate() throws {
        guard (1...16).contains(concurrency), (1...10000).contains(pageSize),
              (1...10_000_000).contains(maxEntries), (1...100_000).contains(maxDirectories),
              (0...1024).contains(maxDepth), (1...100_000).contains(maxPagesPerDirectory),
              timeout.isFinite, timeout > 0, timeout <= 86400 else { throw RemoteCatalogError.invalidConfiguration }
    }
}
