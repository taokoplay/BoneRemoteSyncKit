import Foundation

/// 兼容模式只影响书目元数据、目录 MIME 和直接搜索模板，不改变来源授权或下载安全规则。
public enum OPDSCompatibilityMode: Sendable {
    /// 接受公开书库常见变体，保留未知时间，不伪造元数据。
    case compatible
    /// 要求有效的 Atom 更新时间、目录 MIME 和 OpenSearch 描述文档。
    case strict
}

/// OPDS 1.2 客户端预算。HTTP 必须显式启用；ATS 仍由宿主配置。
public struct OPDSConfiguration: Sendable {
    public let rootURL: URL
    public let timeout: TimeInterval
    public let allowsInsecureHTTP: Bool
    public let allowedCatalogOrigins: [URL]
    public let maxResponseBytes: Int
    public let maxEntriesPerPage: Int
    public let maxXMLDepth: Int
    public let maxPages: Int
    public let maxDownloadReferences: Int
    public let maxConcurrentTransfers: Int
    public let compatibility: OPDSCompatibilityMode

    public init(rootURL: URL, timeout: TimeInterval = 60, allowsInsecureHTTP: Bool = false,
                allowedCatalogOrigins: [URL] = [], maxResponseBytes: Int = 8 * 1024 * 1024,
                maxEntriesPerPage: Int = 5_000, maxXMLDepth: Int = 64, maxPages: Int = 1_000,
                maxDownloadReferences: Int = 10_000, maxConcurrentTransfers: Int = 3,
                compatibility: OPDSCompatibilityMode = .compatible) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 86_400,
              (1...64 * 1024 * 1024).contains(maxResponseBytes),
              (1...100_000).contains(maxEntriesPerPage), (2...256).contains(maxXMLDepth),
              (1...100_000).contains(maxPages), (1...100_000).contains(maxDownloadReferences),
              (1...16).contains(maxConcurrentTransfers) else { throw OPDSError.invalidConfiguration }
        for url in [rootURL] + allowedCatalogOrigins {
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || (scheme == "http" && allowsInsecureHTTP),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.fragment == nil else { throw OPDSError.invalidConfiguration }
            if let port = url.port, !(1...65535).contains(port) { throw OPDSError.invalidConfiguration }
        }
        guard allowedCatalogOrigins.allSatisfy({ ($0.path.isEmpty || $0.path == "/") && $0.query == nil }) else {
            throw OPDSError.invalidConfiguration
        }
        self.rootURL = rootURL; self.timeout = timeout; self.allowsInsecureHTTP = allowsInsecureHTTP
        self.allowedCatalogOrigins = allowedCatalogOrigins; self.maxResponseBytes = maxResponseBytes
        self.maxEntriesPerPage = maxEntriesPerPage; self.maxXMLDepth = maxXMLDepth; self.maxPages = maxPages
        self.maxDownloadReferences = maxDownloadReferences; self.maxConcurrentTransfers = maxConcurrentTransfers
        self.compatibility = compatibility
    }
}
