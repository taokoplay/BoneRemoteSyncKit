import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncOPDS

struct OPDSBrowserAdapter: BrowserAdapter {
    let provider: OPDSSource
    let binding: RemoteSourceBinding
    let root: OPDSPage
    var source: any RemoteSource { provider }
    var rootCapabilities: RemoteBrowseCapabilities { capabilities(root) }

    func validateSession() async throws {
        guard try await provider.sourceBinding() == binding else { throw RemoteBrowserError(code: .sessionExpired) }
    }
    func page(_ request: BrowserRequest) async throws -> BrowserResult {
        let value: OPDSPage
        if let cursor = request.opdsCursor { value = try await provider.nextPage(cursor) }
        else {
            let scope: OPDSPage
            if let parent = request.parent {
                guard case .opdsNavigation(_, let link?) = parent else { throw RemoteBrowserError(code: .unsupported) }
                scope = try await provider.browse(link)
            } else { scope = try await provider.browse(refresh: true) }
            try await validateSession()
            if let query = request.query { value = try await provider.search(query, in: scope, count: request.pageSize) }
            else { value = scope }
        }
        try await validateSession()
        var records: [BrowserRecord] = []
        for item in value.items {
            switch item {
            case .publication(let publication): records.append(record(publication))
            case .navigation(let navigation):
                if navigation.catalogLinks.isEmpty { records.append(record(navigation, link: nil)) }
                else {
                    var seen = Set<URL>()
                    for link in navigation.catalogLinks where seen.insert(link.url).inserted {
                        records.append(record(navigation, link: link))
                    }
                }
            }
        }
        var next: BrowserContinuation?
        if let cursor = value.nextCursor { var nextRequest = request.next(); nextRequest.opdsCursor = cursor; next = .request(nextRequest) }
        // An OPDS feed does not prove exhaustive coverage, even when it has no next link.
        return .init(records: records, total: nil, coverage: .unknown, capabilities: capabilities(value), next: next)
    }
    func details(_ node: BrowserNode) async throws -> BrowserRecord {
        switch node {
        case .opdsPublication(let publication):
            let value = try await provider.publication(publication)
            try await validateSession()
            return record(value)
        case .opdsNavigation(let navigation, let link): return record(navigation, link: link)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }
    func artwork(_ node: BrowserNode) async throws -> Data? {
        guard case .opdsPublication(let original) = node else { return nil }
        let publication = try await provider.publication(original)
        try await validateSession()
        let data = try await provider.cover(publication)
        try await validateSession()
        return data
    }
    func downloads(_ node: BrowserNode) async throws -> [BrowserDownloadRecord] {
        guard case .opdsPublication(let original) = node else { return [] }
        let publication = try await provider.publication(original)
        try await validateSession()
        var result: [BrowserDownloadRecord] = [], seen = Set<String>()
        for acquisition in publication.acquisitions where acquisition.isDirectDownload {
            let mime = mediaType(acquisition.link.mediaType)
            let key = BrowserMapping.key(publication.id, acquisition.link.url.absoluteString, mime ?? "", acquisition.link.relation)
            guard seen.insert(key).inserted else { continue }
            result.append(.init(key: key, title: acquisition.link.title ?? mime ?? publication.title,
                filename: nil, contentType: mime, size: nil, kind: .originalFile, locator: .opds(publication, acquisition)))
        }
        return result
    }
    func prepare(_ download: BrowserDownloadRecord) async throws -> RemoteFileReference {
        guard case .opds(let publication, let acquisition) = download.locator else { throw RemoteBrowserError(code: .invalidReference) }
        let reference = try await provider.prepareDownload(publication, acquisition: acquisition)
        try await validateSession()
        return reference
    }
    func nativeReference(_ node: BrowserNode) async throws -> RemoteBrowseNativeReference {
        switch node {
        case .opdsPublication(let publication):
            let value = try await provider.publication(publication)
            try await validateSession()
            return .opds(.publication(value))
        case .opdsNavigation(let navigation, _): return .opds(.navigation(navigation))
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }
    private func capabilities(_ page: OPDSPage) -> RemoteBrowseCapabilities {
        page.links.contains(where: { $0.relation == "search" }) ? [.browse, .search] : [.browse]
    }
    private func record(_ navigation: OPDSNavigationItem, link: OPDSLink?) -> BrowserRecord {
        var metadata = RemoteBrowseMetadata(title: navigation.title)
        metadata.subtitle = link?.title
        return .init(key: BrowserMapping.key(navigation.id, link?.url.absoluteString ?? ""), kind: .navigation,
                     metadata: metadata, capabilities: link == nil ? [] : [.browse, .search], node: .opdsNavigation(navigation, link))
    }
    private func record(_ publication: OPDSPublication) -> BrowserRecord {
        var metadata = RemoteBrowseMetadata(title: publication.title)
        metadata.authors = publication.authors; metadata.subtitle = publication.authors.first
        metadata.tags = publication.categories; metadata.language = publication.language
        metadata.publicationDate = publication.issued
        metadata.modifiedAt = publication.updated; metadata.modifiedAtRaw = publication.updatedRaw
        if let text = publication.summary ?? publication.content {
            let format: RemoteBrowseText.Format
            switch text.kind { case .text: format = .text; case .html: format = .html; case .xhtml: format = .xhtml }
            metadata.summary = .init(text.value, format: format)
        }
        let choices = publication.acquisitions.filter(\.isDirectDownload)
        if choices.count == 1 { metadata.contentType = mediaType(choices[0].link.mediaType) }
        var caps: RemoteBrowseCapabilities = []
        if !choices.isEmpty || publication.detailLink != nil { caps.insert(.download) }
        if !publication.imageLinks.isEmpty || publication.detailLink != nil { caps.insert(.artwork) }
        return .init(key: BrowserMapping.key(publication.id), kind: .book, metadata: metadata,
                     capabilities: caps, node: .opdsPublication(publication))
    }
    private func mediaType(_ text: String?) -> String? {
        text?.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}
