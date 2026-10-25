import Foundation
import Darwin
import BoneRemoteSyncCore

/// Never persist or expose Graph nextLinks / pre-authorized URLs as entry IDs or cursors.
enum ODLocation {
    static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved)! }
    static func endpoint(_ suffix: String, base: URL) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath += suffix; return parts.url!
    }
    static func item(_ id: String, drive: String, base: URL) -> URL { endpoint("drives/\(encoded(drive))/items/\(encoded(id))", base: base) }
    static func path(_ path: String, drive: String, base: URL) throws -> URL {
        guard !path.contains("\0"), path.utf8.count <= 16384 else { throw RemoteSyncError.unsupported(operation: "OneDrive 路径") }
        let suffix = path == "/" ? "root" : "root:/" + path.dropFirst().split(separator: "/").map { encoded(String($0)) }.joined(separator: "/")
        return endpoint("drives/\(encoded(drive))/" + suffix, base: base)
    }
    /// Upload address for one file under an existing parent item ID.
    static func upload(parent: String, name: String, drive: String, base: URL) -> URL {
        endpoint("drives/\(encoded(drive))/items/\(encoded(parent)):/\(encoded(name)):/content", base: base)
    }
    static func children(parent: String, drive: String, base: URL) -> URL {
        endpoint("drives/\(encoded(drive))/items/\(encoded(parent))/children", base: base)
    }
    static func identity(drive: String, item: String) -> String {
        "onedrive:" + (try! JSONEncoder().encode([drive, item])).base64EncodedString()
    }
    static func itemID(_ id: String, drive: String) throws -> String {
        guard id.hasPrefix("onedrive:"), id.utf8.count < 16384,
              let data = Data(base64Encoded: String(id.dropFirst(9))), let values = try? JSONDecoder().decode([String].self, from: data),
              values.count == 2, values[0] == drive, !values[1].isEmpty else { throw RemoteSyncError.unsupported(operation: "OneDrive 条目标识不属于当前主盘") }
        return values[1]
    }
    static func validateGraph(_ url: URL, base: URL) throws {
        guard url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.absoluteString.utf8.count <= 32768,
              URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath.hasPrefix(URLComponents(url: base, resolvingAgainstBaseURL: false)!.percentEncodedPath) else {
            throw RemoteSyncError.unsupported(operation: "OneDrive Graph 地址不可信")
        }
    }
    static func next(_ raw: String, resource: URL, base: URL) throws -> URL {
        guard let url = URL(string: raw) else { throw RemoteSyncError.unsupported(operation: "OneDrive 分页地址无效") }
        try validateGraph(url, base: base)
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.percentEncodedPath == URLComponents(url: resource, resolvingAgainstBaseURL: false)!.percentEncodedPath,
              parts.query != nil else { throw RemoteSyncError.unsupported(operation: "OneDrive 分页资源不一致") }
        return url
    }
    static func download(_ raw: String, endpoints: ODEndpoints) throws -> URL {
        guard let url = URL(string: raw), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, raw.utf8.count <= 32768 else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 下载地址无效")
        }
        if endpoints.allowsLoopback, url.scheme == "http", host == "127.0.0.1", url.port == endpoints.graph.port { return url }
        // inet_aton accepts legacy one-/two-/three-/four-part, octal and hex IPv4.
        // Reject every locally parseable numeric form without doing DNS or network I/O.
        var ipv4 = in_addr()
        let numericIPv4 = host.withCString { inet_aton($0, &ipv4) != 0 }
        guard url.scheme == "https", url.port == nil || url.port == 443,
              !numericIPv4, !host.contains(":"), !host.contains("["), !host.hasSuffix("."),
              host.split(separator: ".").last?.allSatisfy({ $0.isNumber }) == false,
              host.contains("."), !host.hasSuffix(".localhost"), host != "localhost",
              !host.hasSuffix(".local"), !host.hasSuffix(".internal") else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 下载地址不可信")
        }
        return url
    }
}
