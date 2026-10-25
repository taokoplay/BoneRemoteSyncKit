import Foundation
import BoneRemoteSyncCore

struct DAVResponse: Sendable {
    var href = ""
    var status: Int?
    var hasProperties = false
    var isDirectory = false
    var size: Int64?
    var modifiedAt: Date?
    var etag: String?
    var contentType: String?
}

/// 仅合并成功 propstat 中的 DAV 属性；不把失败/缺失属性的 response 伪装成空文件。
final class DAVMultiStatusParser: NSObject, XMLParserDelegate {
    private struct Node { let name: String; let namespace: String; var text = "" }
    private var stack: [Node] = []
    private var responses: [DAVResponse] = []
    private var current = DAVResponse()
    private var properties = DAVResponse()
    private var propStatus: Int?
    private var seenRoot = false
    private var failed = false

    private let dateParser: DAVHTTPDateParser

    private init(makeDateFormatter: () -> DateFormatter) {
        dateParser = DAVHTTPDateParser(makeDateFormatter: makeDateFormatter)
        super.init()
    }

    static func parse(_ data: Data, makeDateFormatter: () -> DateFormatter = { DateFormatter() }) throws -> [DAVResponse] {
        guard data.count <= 16 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw RemoteSyncError.underlying("WebDAV XML 编码、大小或实体声明不受支持")
        }
        let delegate = DAVMultiStatusParser(makeDateFormatter: makeDateFormatter)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.seenRoot, !delegate.failed else {
            throw RemoteSyncError.underlying("WebDAV 返回了无效的 multistatus XML")
        }
        return delegate.responses
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let namespace = namespaceURI ?? ""
        stack.append(Node(name: name, namespace: namespace))
        guard stack.count <= 32, responses.count < 100_000 else { failed = true; parser.abortParsing(); return }
        if stack.count == 1 {
            guard name == "multistatus", namespace == "DAV:" else { failed = true; parser.abortParsing(); return }
            seenRoot = true
        }
        guard namespace == "DAV:" else { return }
        if matches(["multistatus", "response"]) { current = DAVResponse() }
        if matches(["multistatus", "response", "propstat"]) { properties = DAVResponse(); propStatus = nil }
        if matches(["multistatus", "response", "propstat", "prop", "resourcetype", "collection"]) {
            properties.isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { if !stack.isEmpty { stack.removeLast() } }
        guard let node = stack.last, namespaceURI == "DAV:" else { return }
        let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(["multistatus", "response", "href"]) { current.href = value }
        if matches(["multistatus", "response", "status"]) { current.status = Self.status(value) }
        if matches(["multistatus", "response", "propstat", "status"]) { propStatus = Self.status(value) }
        let propertyPrefix = ["multistatus", "response", "propstat", "prop"]
        if stack.count == 5, Array(stack.dropLast()).map(\.name) == propertyPrefix,
           stack.dropLast().allSatisfy({ $0.namespace == "DAV:" }) {
            switch name {
            case "resourcetype": properties.hasProperties = true
            case "getcontentlength":
                if let size = Int64(value), size >= 0 { properties.size = size }
            case "getlastmodified": properties.modifiedAt = dateParser.parse(value)
            case "getetag": properties.etag = value.isEmpty ? nil : value
            case "getcontenttype": properties.contentType = value.isEmpty ? nil : value
            default: break
            }
        }
        if matches(["multistatus", "response", "propstat"]), let status = propStatus, (200..<300).contains(status) {
            if properties.hasProperties { current.hasProperties = true; current.isDirectory = properties.isDirectory }
            if let size = properties.size { current.size = size }
            if let date = properties.modifiedAt { current.modifiedAt = date }
            if let etag = properties.etag { current.etag = etag }
            if let type = properties.contentType { current.contentType = type }
        }
        if matches(["multistatus", "response"]) { responses.append(current) }
    }

    private func matches(_ names: [String]) -> Bool {
        stack.count == names.count && stack.map(\.name) == names && stack.allSatisfy { $0.namespace == "DAV:" }
    }

    private static func status(_ value: String) -> Int? {
        let parts = value.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }
}

/// HTTP 头的单次解析入口；不跨请求共享可变 formatter。
enum DAVHTTPDate {
    static func parse(_ value: String) -> Date? {
        DAVHTTPDateParser().parse(value)
    }
}

/// 一次 XML 解析独占一组 formatter，既复用昂贵的配置，也不引入全局共享状态。
private final class DAVHTTPDateParser {
    private let formatters: [DateFormatter]

    init(makeDateFormatter: () -> DateFormatter = { DateFormatter() }) {
        formatters = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"].map { format in
            let formatter = makeDateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }

    func parse(_ value: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
