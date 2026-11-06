import Foundation
import CryptoKit
import BoneRemoteSyncCore

enum BDLocation {
    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16384 && !token.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
    }
    static func path(_ raw: String) throws -> String {
        guard raw.utf8.count <= 4096, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteSyncError.unsupported(operation: "百度网盘路径无效")
        }
        return RemotePath.normalize(raw)
    }
    static func remote(_ path: String, configuration: BaiduDriveConfiguration) throws -> String {
        let path = try self.path(path)
        return path == "/" ? configuration.rootPath : configuration.rootPath + path
    }
    static func local(_ raw: String, configuration: BaiduDriveConfiguration) throws -> String {
        guard raw == RemotePath.normalize(raw), raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              raw == configuration.rootPath || raw.hasPrefix(configuration.rootPath + "/") else { throw BaiduDriveError.invalidResponse }
        return raw == configuration.rootPath ? "/" : String(raw.dropFirst(configuration.rootPath.count))
    }
    static func binding(userID: String, configuration: BaiduDriveConfiguration) -> String {
        let parts = [configuration.appKey, userID, configuration.rootPath].map { "\($0.utf8.count):\($0)" }.joined()
        return "baidu:" + SHA256.hash(data: Data(parts.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func entryID(_ fsid: String, binding: String) -> String { binding + ":" + fsid }
    static func fsid(_ id: String, binding: String) throws -> String {
        let prefix = binding + ":"
        guard id.hasPrefix(prefix), let result = BDJSON.string(String(id.dropFirst(prefix.count))).uintString,
              id == prefix + result else { throw BaiduDriveError.invalidReference }
        return result
    }
    static func serviceURL(_ url: URL, endpoints: BDEndpoints) throws -> URL {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: true),
              c.user == nil, c.password == nil, c.fragment == nil,
              let host = c.host?.lowercased(), !host.isEmpty,
              c.port.map({ (1...65535).contains($0) }) ?? true else { throw BaiduDriveError.invalidResponse }
        if endpoints.allowsLoopback, c.scheme == "http", host == "127.0.0.1", url.port == endpoints.api.port { return url }
        let trusted = host == "pan.baidu.com" || host == "pcs.baidu.com" || host.hasSuffix(".pcs.baidu.com")
            || host == "baidupcs.com" || host.hasSuffix(".baidupcs.com")
        guard c.scheme == "https", c.port == nil || c.port == 443, trusted else { throw BaiduDriveError.invalidResponse }
        return url
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
    static func url(_ base: URL, parameters: [String: String]) throws -> URL {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: true), c.query == nil else { throw BaiduDriveError.invalidResponse }
        c.percentEncodedQuery = form(parameters)
        guard let url = c.url else { throw BaiduDriveError.invalidResponse }
        return url
    }
    static func form(_ parameters: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return parameters.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }
    static func download(_ raw: String, token: String, endpoints: BDEndpoints) throws -> URL {
        guard let original = URL(string: raw) else { throw BaiduDriveError.invalidResponse }
        let url = try serviceURL(original, endpoints: endpoints)
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true),
              !(c.queryItems ?? []).contains(where: { $0.name.lowercased() == "access_token" }) else { throw BaiduDriveError.invalidResponse }
        let suffix = form(["access_token": token])
        c.percentEncodedQuery = c.percentEncodedQuery.map { $0.isEmpty ? suffix : $0 + "&" + suffix } ?? suffix
        guard let result = c.url else { throw BaiduDriveError.invalidResponse }
        return result
    }
}
