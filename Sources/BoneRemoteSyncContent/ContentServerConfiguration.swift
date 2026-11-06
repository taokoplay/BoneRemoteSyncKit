import Foundation

/// 自建内容服务配置。baseURL 指向服务根，可包含反向代理子路径；不含凭据。
public struct ContentServerConfiguration: Sendable, Codable, Hashable {
    public let baseURL: URL
    public let allowsInsecureHTTP: Bool
    /// 单次操作总超时，包括等待 requestInterval；取消后先排空网络回调再返回。
    public let timeout: TimeInterval
    public let maxConcurrentRequests: Int
    /// 同一连接内 API、图片与下载请求的最小放行间隔（秒）；0 不延迟。
    public let requestInterval: TimeInterval
    public let maxResponseBytes: Int
    public let maxDownloadReferences: Int

    public init(baseURL: URL, allowsInsecureHTTP: Bool = false, timeout: TimeInterval = 60,
                maxConcurrentRequests: Int = 3, requestInterval: TimeInterval = 0,
                maxResponseBytes: Int = 8 * 1024 * 1024, maxDownloadReferences: Int = 256) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 86400,
              (1...8).contains(maxConcurrentRequests), requestInterval.isFinite,
              (0...86400).contains(requestInterval), (1024...32 * 1024 * 1024).contains(maxResponseBytes),
              (1...4096).contains(maxDownloadReferences) else { throw ContentServerError.invalidConfiguration }
        self.baseURL = try ContentLocation.base(baseURL, allowsInsecureHTTP: allowsInsecureHTTP)
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.timeout = timeout
        self.maxConcurrentRequests = maxConcurrentRequests
        self.requestInterval = requestInterval
        self.maxResponseBytes = maxResponseBytes
        self.maxDownloadReferences = maxDownloadReferences
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, allowsInsecureHTTP, timeout, maxConcurrentRequests, requestInterval, maxResponseBytes, maxDownloadReferences
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(baseURL: values.decode(URL.self, forKey: .baseURL),
                      allowsInsecureHTTP: values.decode(Bool.self, forKey: .allowsInsecureHTTP),
                      timeout: values.decode(TimeInterval.self, forKey: .timeout),
                      maxConcurrentRequests: values.decode(Int.self, forKey: .maxConcurrentRequests),
                      requestInterval: values.decode(TimeInterval.self, forKey: .requestInterval),
                      maxResponseBytes: values.decode(Int.self, forKey: .maxResponseBytes),
                      maxDownloadReferences: values.decode(Int.self, forKey: .maxDownloadReferences))
    }
}

/// 不携带远端 URL、响应正文或凭据的内容服务错误。
public enum ContentServerError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidResponse, invalidReference, invalidCursor, resourceLimit, redirectRejected, identityChanged
}

/// 有界的一页内容；page 为从 0 开始的 SDK 页号，不能据此推导远端删除。
public struct ContentPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let page: Int
    public let pageSize: Int
    public let total: Int?
    public let hasNextPage: Bool
    public init(items: [Item], page: Int, pageSize: Int, total: Int?, hasNextPage: Bool) {
        self.items = items; self.page = page; self.pageSize = pageSize
        self.total = total; self.hasNextPage = hasNextPage
    }
}

/// 交给宿主播放器的短期认证请求。包含敏感 headers，不要记录、持久化或跨主机转发。
/// SDK 不执行播放；宿主负责播放器的重定向策略、Range 请求和任务生命周期。
public struct ContentStreamRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let headers: [String: String]
    package init(url: URL, headers: [String: String]) { self.url = url; self.headers = headers }
    public func urlRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.allHTTPHeaderFields = headers
        return request
    }
    public var description: String { "ContentStreamRequest(***)" }
    public var debugDescription: String { description }
}
