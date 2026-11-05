import Foundation

/// URL policy shared by catalog parsing and the independent OPDS transport.
enum OPDSLocation {
    static func validate(_ url: URL, configuration: OPDSConfiguration, catalog: Bool) throws -> URL {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw OPDSError.invalidURL
        }
        guard scheme != "http" || configuration.allowsInsecureHTTP else { throw OPDSError.invalidURL }
        components.scheme = scheme
        components.fragment = nil
        guard let result = components.url else { throw OPDSError.invalidURL }
        if catalog, !sameOrigin(result, configuration.rootURL),
           !configuration.allowedCatalogOrigins.contains(where: { sameOrigin(result, $0) }) {
            throw OPDSError.disallowedOrigin
        }
        return result
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = origin(lhs), let right = origin(rhs) else { return false }
        return left.scheme == right.scheme && left.host == right.host && left.port == right.port
    }

    static func resolve(_ value: String, relativeTo base: URL) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return URL(string: value, relativeTo: base)?.absoluteURL
    }

    private static func origin(_ url: URL) -> (scheme: String, host: String, port: Int)? {
        guard let components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        return (scheme, host, port)
    }
}
