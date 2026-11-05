import Foundation

/// Preserve the advertised template before Foundation percent-encodes its braces.
struct OPDSSearchTemplate: Sendable, Equatable {
    let value: String
    let base: URL
    let namespaces: [String: String]
}

enum OPDSSearch {
    static let namespace = "http://a9.com/-/spec/opensearch/1.1/"

    static func url(data: Data, base: URL, query: String, count: Int, configuration: OPDSConfiguration) throws -> URL {
        try validate(query: query, count: count, configuration: configuration)
        let root = try OPDSXMLTree(configuration: configuration, base: base).parse(data)
        guard root.name == "OpenSearchDescription", root.namespace == namespace else { throw OPDSError.invalidDocument }
        for node in root.children("Url", namespace) where OPDSMedia.isFeed(node.attributes["type"]) {
            guard (node.attributes["method"] ?? "GET").uppercased() == "GET", let template = node.attributes["template"] else { continue }
            guard let index = nonnegative(node.attributes["indexOffset"] ?? "1"),
                  let page = nonnegative(node.attributes["pageOffset"] ?? "1") else { continue }
            if let url = try? expand(template, base: node.base,
                                    values: parameters(query: query, count: count, index: index, page: page), namespaces: node.namespaces) {
                return try OPDSLocation.validate(url, configuration: configuration, catalog: true)
            }
        }
        throw OPDSError.unsupportedSearch
    }

    static func url(template: OPDSSearchTemplate, query: String, count: Int, configuration: OPDSConfiguration) throws -> URL {
        try validate(query: query, count: count, configuration: configuration)
        guard configuration.compatibility == .compatible else { throw OPDSError.unsupportedSearch }
        // Decode only template delimiters; do not decode literal %26/%2F or a double-encoded placeholder.
        let value = template.value.replacingOccurrences(of: "%7B", with: "{", options: .caseInsensitive)
            .replacingOccurrences(of: "%7D", with: "}", options: .caseInsensitive)
        let url = try expand(value, base: template.base, values: parameters(query: query, count: count), namespaces: template.namespaces)
        return try OPDSLocation.validate(url, configuration: configuration, catalog: true)
    }

    private static func validate(query: String, count: Int, configuration: OPDSConfiguration) throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 4096, (1...configuration.maxEntriesPerPage).contains(count) else { throw OPDSError.unsupportedSearch }
    }
    private static func parameters(query: String, count: Int, index: Int = 1, page: Int = 1) -> [String: String] {
        ["searchTerms": query, "count": String(count), "startIndex": String(index), "startPage": String(page),
         "language": "*", "inputEncoding": "UTF-8", "outputEncoding": "UTF-8",
         "atom:author": "", "atom:contributor": "", "atom:title": ""]
    }
    private static func nonnegative(_ raw: String) -> Int? {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw), value <= 1_000_000_000 else { return nil }
        return value
    }

    static func expand(_ template: String, base: URL, values: [String: String], namespaces: [String: String] = [:]) throws -> URL {
        let regex = try NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        guard !matches.isEmpty else { throw OPDSError.unsupportedSearch }
        var skeleton = template
        var replacements: [(String, String)] = []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")
        var hasTerms = false
        for match in matches.reversed() {
            guard let range = Range(match.range, in: template), let inner = Range(match.range(at: 1), in: template) else { throw OPDSError.unsupportedSearch }
            let raw = String(template[inner]); let optional = raw.hasSuffix("?")
            let qualified = optional ? String(raw.dropLast()) : raw
            let parts = qualified.split(separator: ":", omittingEmptySubsequences: false)
            let name: String?
            if parts.count == 1 { name = qualified }
            else if parts.count == 2, namespaces[String(parts[0])] == namespace { name = String(parts[1]) }
            else if parts.count == 2, namespaces[String(parts[0])] == OPDSFeedParser.atom,
                    ["author", "contributor", "title"].contains(String(parts[1])) { name = "atom:" + parts[1] }
            else { name = nil }
            if name == "searchTerms" { hasTerms = true }
            guard let value = name.flatMap({ values[$0] }) ?? (optional ? "" : nil),
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { throw OPDSError.unsupportedSearch }
            let marker = "opdsplaceholder" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            skeleton.replaceSubrange(range, with: marker)
            replacements.append((marker, encoded))
        }
        guard hasTerms, !skeleton.contains("{"), !skeleton.contains("}"),
              let sample = URL(string: skeleton, relativeTo: base)?.absoluteURL,
              let components = URLComponents(url: sample, resolvingAgainstBaseURL: true), components.fragment == nil else { throw OPDSError.unsupportedSearch }
        for (marker, _) in replacements {
            // Template parameters may affect only a path segment or a query VALUE, never authority or query names.
            let forbidden = [components.scheme, components.host, components.user, components.password].compactMap { $0 }
            guard !forbidden.contains(where: { $0.contains(marker) }),
                  !(components.queryItems ?? []).contains(where: { $0.name.contains(marker) }) else { throw OPDSError.unsupportedSearch }
        }
        var rendered = sample.absoluteString
        for (marker, value) in replacements { rendered = rendered.replacingOccurrences(of: marker, with: value) }
        guard let result = URL(string: rendered) else { throw OPDSError.unsupportedSearch }
        return result
    }
}
