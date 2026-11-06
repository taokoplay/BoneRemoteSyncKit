import Foundation
import BoneRemoteSyncCore

package enum ContentValidation {
    package static func id(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 2048, ![".", ".."].contains(value),
              !value.contains("/"), !value.contains("\\"), !value.contains("%"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ContentServerError.invalidReference
        }
        return value
    }
    package static func pagination(page: Int, pageSize: Int) throws {
        guard (0...1_000_000).contains(page), (1...500).contains(pageSize) else { throw ContentServerError.invalidCursor }
    }
    package static func search(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.utf8.count <= 2048,
              !result.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ContentServerError.invalidReference
        }
        return result
    }
    package static func token(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 32768,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw RemoteSyncError.authenticationFailed(reason: "Invalid content service credential")
        }
        return value
    }
    package static func filename(_ value: String, fallback: String = "download") -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = value.components(separatedBy: unsafe).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        for character in cleaned {
            guard name.utf8.count + character.utf8.count <= 180 else { break }
            name.append(character)
        }
        return name.isEmpty || [".", ".."].contains(name) ? fallback : name
    }
}

package enum ContentCoding {
    package static func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw ContentServerError.invalidResponse }
    }
    package static func decode<T: Decodable>(_ type: T.Type, from response: ContentHTTPResponse) throws -> T {
        do { return try JSONDecoder().decode(type, from: response.data) }
        catch { throw ContentServerError.invalidResponse }
    }
}

struct ContentLocation {
    static func base(_ url: URL, allowsInsecureHTTP: Bool) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme == "https" || (allowsInsecureHTTP && scheme == "http"),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              url.absoluteString.utf8.count <= 8192 else { throw ContentServerError.invalidConfiguration }
        do { try validatePath(components.percentEncodedPath) }
        catch { throw ContentServerError.invalidConfiguration }
        components.scheme = scheme; components.host = host.lowercased()
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        else if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        guard let result = components.url else { throw ContentServerError.invalidConfiguration }
        return result
    }

    static func validate(_ url: URL, configuration: ContentServerConfiguration) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let base = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == base.scheme?.lowercased(),
              components.host?.lowercased() == base.host?.lowercased(), port(components) == port(base),
              components.user == nil, components.password == nil, components.fragment == nil,
              url.absoluteString.utf8.count <= 32768 else { throw ContentServerError.invalidReference }
        try validatePath(components.percentEncodedPath)
        let path = components.percentEncodedPath
        guard path.hasPrefix(base.percentEncodedPath) || path == String(base.percentEncodedPath.dropLast()) else {
            throw ContentServerError.invalidReference
        }
        return url
    }

    static func url(configuration: ContentServerConfiguration, path: [String], query: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: true)!
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let parts = try path.map { try ContentValidation.id($0).addingPercentEncoding(withAllowedCharacters: allowed)! }
        components.percentEncodedPath += parts.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        guard let result = components.url else { throw ContentServerError.invalidReference }
        return try validate(result, configuration: configuration)
    }

    static func serviceURL(_ value: String, configuration: ContentServerConfiguration) throws -> URL {
        guard !value.isEmpty, !value.hasPrefix("//"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parsed = URLComponents(string: value), parsed.fragment == nil,
              parsed.user == nil, parsed.password == nil else { throw ContentServerError.invalidReference }
        try validatePath(parsed.percentEncodedPath)
        if parsed.scheme != nil {
            guard let url = parsed.url else { throw ContentServerError.invalidReference }
            return try validate(url, configuration: configuration)
        }
        guard parsed.host == nil else { throw ContentServerError.invalidReference }
        let base = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: true)!
        let relative: String
        if value.hasPrefix(base.percentEncodedPath), base.percentEncodedPath != "/" {
            relative = String(value.dropFirst(base.percentEncodedPath.count))
        } else { relative = value.hasPrefix("/") ? String(value.dropFirst()) : value }
        guard let url = URL(string: relative, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw ContentServerError.invalidReference
        }
        return try validate(url, configuration: configuration)
    }

    private static func port(_ components: URLComponents) -> Int { components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80) }
    private static func validatePath(_ raw: String) throws {
        guard !raw.contains("\\"), !raw.contains("//") else { throw ContentServerError.invalidReference }
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            guard let decoded = String(part).removingPercentEncoding,
                  ![".", ".."].contains(decoded), !decoded.contains("/"), !decoded.contains("\\"), !decoded.contains("%"),
                  !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ContentServerError.invalidReference
            }
        }
    }
}
