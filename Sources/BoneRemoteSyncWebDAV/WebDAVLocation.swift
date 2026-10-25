import Foundation
import BoneRemoteSyncCore

/// WebDAV 请求和 href 均约束到同一 origin 和 collection 根；不使用服务器提供的 href 发起请求。
struct WebDAVLocation: Sendable {
    let baseURL: URL
    private let rootComponents: [String]

    init(baseURL: URL) throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let path = Self.decodePath(components.percentEncodedPath) else {
            throw RemoteSyncError.unsupported(operation: "无效的 WebDAV 根 URL")
        }
        rootComponents = path
        components.percentEncodedPath = path.isEmpty ? "/" : Self.encode(path) + "/"
        guard let url = components.url else { throw RemoteSyncError.unsupported(operation: "无效的 WebDAV 根 URL") }
        self.baseURL = url
    }

    func url(for path: String) throws -> URL {
        guard !path.utf8.contains(0) else { throw RemoteSyncError.permissionDenied(path: path) }
        let relative = RemotePath.relative(path).split(separator: "/").map(String.init)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        if !relative.isEmpty { components.percentEncodedPath = Self.encode(rootComponents + relative) }
        guard let url = components.url else { throw RemoteSyncError.permissionDenied(path: path) }
        return url
    }

    func path(for href: String, relativeTo requestURL: URL) -> String? {
        // requestURL 表示 collection 时，子项相对 href 必须基于其末尾斜杠解析。
        guard !href.contains("\\"), !href.utf8.contains(0),
              let raw = URLComponents(string: href),
              raw.user == nil, raw.password == nil, raw.query == nil, raw.fragment == nil,
              Self.decodePath(raw.percentEncodedPath) != nil else { return nil }
        let collection = requestURL.absoluteString.hasSuffix("/") ? requestURL : requestURL.appendingPathComponent("")
        guard let url = URL(string: href, relativeTo: collection)?.absoluteURL,
              Self.sameOrigin(url, baseURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let decoded = Self.decodePath(components.percentEncodedPath),
              decoded.starts(with: rootComponents) else { return nil }
        let suffix = decoded.dropFirst(rootComponents.count)
        return "/" + suffix.joined(separator: "/")
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    private static func decodePath(_ encoded: String) -> [String]? {
        var result: [String] = []
        for part in encoded.split(separator: "/", omittingEmptySubsequences: true) {
            guard let decoded = String(part).removingPercentEncoding,
                  decoded != ".", decoded != "..", !decoded.contains("/"),
                  !decoded.contains("\\"), !decoded.utf8.contains(0) else { return nil }
            result.append(decoded)
        }
        return result
    }

    private static func encode(_ components: [String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return "/" + components.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved)! }.joined(separator: "/")
    }
}
