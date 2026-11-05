import Foundation

/// 远端简介是不可信内容；宿主渲染 HTML/XHTML 前必须自行净化。
public struct OPDSText: Sendable, Equatable {
    public enum Kind: String, Sendable { case text, html, xhtml }
    public let kind: Kind
    public let value: String
}

/// 会话内发现的链接。URL 可能含临时查询参数，不应记录或持久化。
public struct OPDSLink: Sendable, Equatable {
    public let url: URL
    public let relation: String
    public let mediaType: String?
    public let title: String?
    let sessionID: UUID
    let indirect: Bool
    let searchTemplate: OPDSSearchTemplate?
}

public struct OPDSAcquisition: Sendable, Equatable {
    public let link: OPDSLink
    /// 首期支持的直接文件类型；其他获取方式仍保留在模型中。
    public var isDirectDownload: Bool {
        ["http://opds-spec.org/acquisition", "http://opds-spec.org/acquisition/open-access"].contains(link.relation)
            && !link.indirect && Self.directTypes.contains(OPDSMedia.base(link.mediaType))
    }
    static let directTypes: Set<String> = [
        "application/epub+zip", "application/pdf", "application/x-cbz", "application/vnd.comicbook+zip",
        "application/x-cbr", "application/vnd.comicbook-rar", "application/zip", "application/x-mobipocket-ebook",
        "application/octet-stream", "text/plain", "audio/mpeg", "audio/mp4", "image/jpeg", "image/png"
    ]
}

public struct OPDSPublication: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let authors: [String]
    public let summary: OPDSText?
    public let content: OPDSText?
    public let categories: [String]
    public let language: String?
    public let publisher: String?
    public let issued: String?
    /// 书目更新时间，不代表文件版本。缺失、无时区或无效时为 nil。
    public let updated: Date?
    /// 服务端的原始时间文本；不推断本地时区或补当前时间。
    public let updatedRaw: String?
    public let links: [OPDSLink]
    public let acquisitions: [OPDSAcquisition]
    let sessionID: UUID
    public var detailLink: OPDSLink? {
        links.first { $0.relation == "alternate" && OPDSMedia.isEntry($0.mediaType) }
    }
    public var imageLinks: [OPDSLink] {
        links.filter { ["http://opds-spec.org/image", "http://opds-spec.org/image/thumbnail"].contains($0.relation) }
    }
}

public struct OPDSNavigationItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let links: [OPDSLink]
    public var catalogLinks: [OPDSLink] { links.filter { OPDSMedia.isFeed($0.mediaType) } }
}

/// 使用 items 保持服务端的条目顺序。
public enum OPDSItem: Sendable, Equatable {
    case navigation(OPDSNavigationItem)
    case publication(OPDSPublication)
}

/// 不透明分页上下文；只在签发它的来源会话中有效，不支持序列化。
public struct OPDSPageCursor: Sendable, Equatable {
    let sessionID: UUID
    let nextURL: URL
    let visited: Set<URL>
    let pageCount: Int
}

public struct OPDSPage: Sendable, Equatable {
    public let id: String
    public let title: String
    /// 缺失、无时区或无效时为 nil。
    public let updated: Date?
    public let updatedRaw: String?
    public let items: [OPDSItem]
    public let links: [OPDSLink]
    /// nil 只表示当前 Feed 无下一页，不证明全书库完整。
    public let nextCursor: OPDSPageCursor?
    let sessionID: UUID
    public var publications: [OPDSPublication] {
        items.compactMap { if case .publication(let value) = $0 { value } else { nil } }
    }
    public var navigation: [OPDSNavigationItem] {
        items.compactMap { if case .navigation(let value) = $0 { value } else { nil } }
    }
}

enum OPDSMedia {
    static func base(_ value: String?) -> String {
        (value ?? "").split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    }
    static func parameter(_ key: String, in value: String?) -> String? {
        for part in (value ?? "").split(separator: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == key {
                return pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"" )).lowercased()
            }
        }
        return nil
    }
    static func isEntry(_ value: String?) -> Bool { base(value) == "application/atom+xml" && parameter("type", in: value) == "entry" }
    static func isFeed(_ value: String?) -> Bool { base(value) == "application/atom+xml" && !isEntry(value) }
}
