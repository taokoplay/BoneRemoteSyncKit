import Foundation
import BoneRemoteSyncCore

// A bounded, operation-local XML tree. No parser or mutable node crosses an actor boundary.
final class OPDSXMLNode {
    enum Part { case text(String), child(OPDSXMLNode) }
    let name: String
    let namespace: String
    let attributes: [String: String]
    let namespaces: [String: String]
    let base: URL
    var parts: [Part] = []
    init(name: String, namespace: String, attributes: [String: String], base: URL, namespaces: [String: String]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes; self.base = base; self.namespaces = namespaces
    }
    var children: [OPDSXMLNode] { parts.compactMap { if case .child(let node) = $0 { node } else { nil } } }
    var text: String { parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined() }
    func children(_ name: String, _ namespace: String = OPDSFeedParser.atom) -> [OPDSXMLNode] {
        children.filter { $0.name == name && $0.namespace == namespace }
    }
    func value(_ name: String, _ namespace: String = OPDSFeedParser.atom) -> String? {
        children(name, namespace).first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Extract display text only through XHTML children, excluding unrelated extensions.
    var xhtmlText: String {
        parts.map { part in
            switch part {
            case .text(let value): return value
            case .child(let child): return child.namespace == "http://www.w3.org/1999/xhtml" ? child.xhtmlText : ""
            }
        }.joined()
    }
    // Preserve XHTML markup and mixed-content order, with explicit element namespaces.
    func markup() -> String {
        let attrs = attributes.filter { !$0.key.hasPrefix("xmlns") }.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(Self.escape($0.value))\"" }.joined()
        let body = parts.map { part in
            switch part { case .text(let value): return Self.escape(value); case .child(let child): return child.markup() }
        }.joined()
        return "<\(name) xmlns=\"\(Self.escape(namespace))\"\(attrs)>\(body)</\(name)>"
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

final class OPDSXMLTree: NSObject, XMLParserDelegate {
    private let configuration: OPDSConfiguration
    private let base: URL
    private var stack: [OPDSXMLNode] = []
    private var root: OPDSXMLNode?
    private var failure: (any Error)?
    private var nodeCount = 0
    private var entryCount = 0
    private var pendingNamespaces: [String: String] = [:]
    init(configuration: OPDSConfiguration, base: URL) { self.configuration = configuration; self.base = base }
    func parse(_ data: Data) throws -> OPDSXMLNode {
        guard data.count <= configuration.maxResponseBytes else { throw OPDSError.resourceLimit }
        // Covers ASCII-compatible UTF-8 and zero-padded UTF-16/32 declarations before libxml processes DTDs.
        let declarationScan = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
            .replacingOccurrences(of: #"(?s)<!--.*?-->|<!\[CDATA\[.*?\]\]>"#, with: "", options: .regularExpression)
        guard !declarationScan.contains("<!DOCTYPE"), !declarationScan.contains("<!ENTITY") else { throw OPDSError.invalidDocument }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.shouldReportNamespacePrefixes = true
        parser.externalEntityResolvingPolicy = .never; parser.delegate = self
        let success = parser.parse()
        if let failure { throw failure }
        guard success, stack.isEmpty, let root else { throw OPDSError.invalidDocument }
        try Task.checkCancellation()
        return root
    }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        pendingNamespaces[prefix] = namespaceURI
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        do {
            try Task.checkCancellation()
            nodeCount += 1
            if name == "entry", namespaceURI == OPDSFeedParser.atom { entryCount += 1 }
            guard stack.count < configuration.maxXMLDepth, nodeCount <= 100_000,
                  entryCount <= configuration.maxEntriesPerPage else { throw OPDSError.resourceLimit }
            let inherited = stack.last?.base ?? base
            let resolved: URL
            if let value = attributes["xml:base"] {
                guard let url = URL(string: value, relativeTo: inherited)?.absoluteURL else { throw OPDSError.invalidURL }
                resolved = url
            } else { resolved = inherited }
            let namespaces = (stack.last?.namespaces ?? [:]).merging(pendingNamespaces) { _, new in new }
            pendingNamespaces.removeAll()
            let node = OPDSXMLNode(name: name, namespace: namespaceURI ?? "", attributes: attributes, base: resolved, namespaces: namespaces)
            if let parent = stack.last { parent.parts.append(.child(node)) }
            else { guard root == nil else { throw OPDSError.invalidDocument }; root = node }
            stack.append(node)
        } catch { failure = error; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.parts.append(.text(string)) }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let value = String(data: data, encoding: .utf8) else { failure = OPDSError.invalidDocument; parser.abortParsing(); return }
        stack.last?.parts.append(.text(value))
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { failure = OPDSError.invalidDocument; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { failure = OPDSError.invalidDocument; parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? {
        failure = OPDSError.invalidDocument; parser.abortParsing(); return nil
    }
}

struct OPDSParsedFeed {
    let id: String
    let title: String
    let updated: Date?
    let updatedRaw: String?
    let items: [OPDSItem]
    let links: [OPDSLink]
}

enum OPDSFeedParser {
    static let atom = "http://www.w3.org/2005/Atom"
    static let opds = "http://opds-spec.org/2010/catalog"
    static let dc = "http://purl.org/dc/terms/"

    static func feed(_ data: Data, url: URL, sessionID: UUID, configuration: OPDSConfiguration) throws -> OPDSParsedFeed {
        let root = try OPDSXMLTree(configuration: configuration, base: url).parse(data)
        guard root.name == "feed", root.namespace == atom else { throw OPDSError.invalidDocument }
        let (id, title, updated, updatedRaw) = try identity(root, configuration: configuration)
        var items: [OPDSItem] = []
        for node in root.children("entry") {
            try Task.checkCancellation()
            let (entryID, entryTitle, _, _) = try identity(node, configuration: configuration)
            let links = try links(node, sessionID: sessionID)
            if links.contains(where: { isAcquisition($0.relation) }) {
                items.append(.publication(try publication(node, links: links, sessionID: sessionID, configuration: configuration)))
            } else {
                // An entry may be a category without a direct downloadable publication.
                items.append(.navigation(.init(id: entryID, title: entryTitle, links: links)))
            }
        }
        return .init(id: id, title: title, updated: updated, updatedRaw: updatedRaw, items: items, links: try links(root, sessionID: sessionID))
    }
    static func entry(_ data: Data, url: URL, sessionID: UUID, configuration: OPDSConfiguration) throws -> OPDSPublication {
        let root = try OPDSXMLTree(configuration: configuration, base: url).parse(data)
        guard root.name == "entry", root.namespace == atom else { throw OPDSError.invalidDocument }
        return try publication(root, links: links(root, sessionID: sessionID), sessionID: sessionID, configuration: configuration)
    }
    private static func identity(_ node: OPDSXMLNode, configuration: OPDSConfiguration) throws -> (String, String, Date?, String?) {
        guard node.children("id").count == 1, node.children("title").count == 1, node.children("updated").count <= 1,
              let id = node.value("id"), !id.isEmpty, let titleNode = node.children("title").first else { throw OPDSError.invalidDocument }
        let raw = node.value("updated")
        let updated = RemoteCreationDate.parse(raw)
        if configuration.compatibility == .strict, updated == nil { throw OPDSError.invalidDocument }
        let title = (titleNode.attributes["type"] == "xhtml" ? titleNode.xhtmlText : titleNode.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw OPDSError.invalidDocument }
        return (id, title, updated, raw)
    }
    private static func isAcquisition(_ relation: String) -> Bool {
        relation == "http://opds-spec.org/acquisition" || relation.hasPrefix("http://opds-spec.org/acquisition/")
    }
    private static func links(_ node: OPDSXMLNode, sessionID: UUID) throws -> [OPDSLink] {
        try node.children("link").map { link in
            guard let href = link.attributes["href"], !href.isEmpty,
                  let url = URL(string: href, relativeTo: link.base)?.absoluteURL else { throw OPDSError.invalidDocument }
            let relation = link.attributes["rel"] ?? "alternate"
            return .init(url: url, relation: relation, mediaType: link.attributes["type"], title: link.attributes["title"],
                         sessionID: sessionID, indirect: !link.children("indirectAcquisition", opds).isEmpty,
                         searchTemplate: relation == "search" && OPDSMedia.isFeed(link.attributes["type"])
                            ? OPDSSearchTemplate(value: href, base: link.base, namespaces: link.namespaces) : nil)
        }
    }
    private static func publication(_ node: OPDSXMLNode, links: [OPDSLink], sessionID: UUID, configuration: OPDSConfiguration) throws -> OPDSPublication {
        let (id, title, updated, updatedRaw) = try identity(node, configuration: configuration)
        let acquisitions = links.filter { isAcquisition($0.relation) }.map { OPDSAcquisition(link: $0) }
        guard !acquisitions.isEmpty else { throw OPDSError.invalidDocument }
        return .init(id: id, title: title, authors: node.children("author").compactMap { $0.value("name") },
                     summary: text(node.children("summary").first), content: text(node.children("content").first),
                     categories: node.children("category").compactMap { $0.attributes["label"] ?? $0.attributes["term"] },
                     language: node.value("language", dc), publisher: node.value("publisher", dc), issued: node.value("issued", dc),
                     updated: updated, updatedRaw: updatedRaw, links: links, acquisitions: acquisitions, sessionID: sessionID)
    }
    private static func text(_ node: OPDSXMLNode?) -> OPDSText? {
        guard let node, node.attributes["src"] == nil,
              let kind = OPDSText.Kind(rawValue: node.attributes["type"] ?? "text") else { return nil }
        if kind == .xhtml {
            let children = node.children.filter { $0.namespace == "http://www.w3.org/1999/xhtml" }
            return .init(kind: kind, value: children.map { $0.markup() }.joined())
        }
        return .init(kind: kind, value: node.text)
    }
}
