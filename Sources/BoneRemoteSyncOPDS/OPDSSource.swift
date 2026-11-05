import Foundation
import BoneRemoteSyncCore

/// OPDS 1.2 只读内容来源。浏览使用专用 API；RemoteSource 仅桥接已选定的文件。
public actor OPDSSource: RemoteSource {
    public nonisolated let kind: RemoteSourceKind = .opds
    public nonisolated let capabilities: RemoteCapabilities
    public nonisolated let configuration: OPDSConfiguration

    struct Context: Sendable { let id: UUID; let client: OPDSHTTPClient }
    struct Resource { let entry: RemoteEntry; let url: URL; let mediaType: String }
    var context: Context?
    private var rootPage: OPDSPage?
    var resources: [String: Resource] = [:]
    var destinations = Set<String>()

    public init(configuration: OPDSConfiguration) {
        self.configuration = configuration
        capabilities = .init(list: false, stat: true, download: true, maxConcurrentTransfers: configuration.maxConcurrentTransfers)
    }

    /// 获取并验证根 Feed。重连使旧书目、链接、分页和文件引用失效。
    public func connect(_ credential: RemoteCredential) async throws {
        reset()
        let client = try OPDSHTTPClient(configuration: configuration, credential: credential)
        let current = Context(id: UUID(), client: client)
        context = current
        do {
            let page = try await loadPage(configuration.rootURL, context: current)
            try check(current)
            rootPage = page
        } catch {
            if context?.id == current.id { reset() }
            throw Self.mapped(error)
        }
    }

    /// 取消在途请求并使引用失效；已返回的本地 lease 由 Transfer 管理。
    public func disconnect() async { reset() }

    private func reset() {
        context?.client.cancel(); context = nil; rootPage = nil; resources.removeAll()
        // Do not clear destination locks until the cancelled download actually exits.
    }

    public func sourceBinding() throws -> RemoteSourceBinding {
        let current = try connected()
        return .init(kind: .opds, identity: current.id.uuidString)
    }

    /// 返回连接时的根页面；refresh=true 时重新请求根 Feed。
    public func browse(refresh: Bool = false) async throws -> OPDSPage {
        let current = try connected()
        if !refresh, let rootPage { return rootPage }
        let page = try await loadPage(configuration.rootURL, context: current)
        try check(current); rootPage = page
        return page
    }

    /// 跟随当前会话发现的 Feed 链接，不展开为目录树。
    public func browse(_ link: OPDSLink) async throws -> OPDSPage {
        let current = try connected()
        guard link.sessionID == current.id, OPDSMedia.isFeed(link.mediaType) else { throw OPDSError.invalidReference }
        return try await loadPage(link.url, context: current)
    }

    public func nextPage(_ cursor: OPDSPageCursor) async throws -> OPDSPage {
        let current = try connected()
        guard cursor.sessionID == current.id else { throw OPDSError.invalidCursor }
        guard cursor.pageCount < configuration.maxPages else { throw OPDSError.resourceLimit }
        return try await loadPage(cursor.nextURL, context: current, visited: cursor.visited, pageCount: cursor.pageCount)
    }

    public func publication(_ item: OPDSPublication) async throws -> OPDSPublication {
        let current = try connected()
        guard item.sessionID == current.id else { throw OPDSError.invalidReference }
        guard let link = item.detailLink else { return item }
        let response = try await current.client.send(link.url)
        try check(current)
        let complete = try OPDSFeedParser.entry(response.data, url: response.response.url ?? link.url,
                                               sessionID: current.id, configuration: configuration)
        guard complete.id == item.id else { throw OPDSError.invalidDocument }
        return complete
    }

    /// 搜索入口来自指定页面，省略时使用根 Feed；不扫描分类以猜测接口。
    public func search(_ query: String, in page: OPDSPage? = nil, count: Int = 100) async throws -> OPDSPage {
        let current = try connected()
        guard let page = page ?? rootPage, page.sessionID == current.id else { throw OPDSError.invalidReference }
        let searchLinks = page.links.filter { $0.relation == "search" }
        if let link = searchLinks.first(where: { OPDSMedia.base($0.mediaType) == "application/opensearchdescription+xml" }) {
            let response = try await current.client.send(link.url)
            try check(current)
            let url = try OPDSSearch.url(data: response.data, base: response.response.url ?? link.url,
                                        query: query, count: count, configuration: configuration)
            return try await loadPage(url, context: current)
        }
        guard let template = searchLinks.compactMap(\.searchTemplate).first else { throw OPDSError.unsupportedSearch }
        let url = try OPDSSearch.url(template: template, query: query, count: count, configuration: configuration)
        return try await loadPage(url, context: current)
    }

    /// 显式选定书目的一种格式；返回不含远端 URL 的会话内文件引用。
    public func prepareDownload(_ publication: OPDSPublication, acquisition: OPDSAcquisition) throws -> RemoteFileReference {
        let current = try connected()
        guard publication.sessionID == current.id, acquisition.link.sessionID == current.id,
              publication.acquisitions.contains(acquisition) else { throw OPDSError.invalidReference }
        guard acquisition.isDirectDownload else { throw OPDSError.unsupportedAcquisition }
        guard resources.count < configuration.maxDownloadReferences else { throw OPDSError.resourceLimit }
        let url = try OPDSLocation.validate(acquisition.link.url, configuration: configuration, catalog: false)
        let identifier = UUID().uuidString
        let path = "/resources/" + identifier
        let mediaType = OPDSMedia.base(acquisition.link.mediaType)
        let entry = RemoteEntry(id: identifier, path: path, name: Self.filename(publication.title, mediaType: mediaType),
                                type: .file, contentType: mediaType)
        resources[path] = .init(entry: entry, url: url, mediaType: mediaType)
        return .init(source: .init(kind: .opds, identity: current.id.uuidString), path: path)
    }

    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        _ = try connected()
        throw RemoteSyncError.unsupported(operation: "OPDS 使用 browse，不提供文件目录树")
    }

    /// 返回已登记描述；不执行 HEAD，不保证文件的远端实时元数据。
    public func stat(path: String) async throws -> RemoteEntry {
        _ = try connected()
        guard let resource = resources[path] else { throw OPDSError.invalidReference }
        return resource.entry
    }

    func connected() throws -> Context {
        guard let context, rootPage != nil else { throw RemoteSyncError.notConnected }
        try check(context)
        return context
    }
    func check(_ current: Context) throws {
        guard !Task.isCancelled, context?.id == current.id else { throw RemoteSyncError.cancelled }
    }

    private func loadPage(_ rawURL: URL, context current: Context, visited: Set<URL> = [], pageCount: Int = 0) async throws -> OPDSPage {
        do {
            let url = try OPDSLocation.validate(rawURL, configuration: configuration, catalog: true)
            guard !visited.contains(url) else { throw OPDSError.invalidCursor }
            let response = try await current.client.send(url)
            try check(current)
            let finalURL = try OPDSLocation.validate(response.response.url ?? url, configuration: configuration, catalog: true)
            guard !visited.contains(finalURL) else { throw OPDSError.invalidCursor }
            let parsed = try OPDSFeedParser.feed(response.data, url: finalURL, sessionID: current.id, configuration: configuration)
            let next = parsed.links.filter { $0.relation == "next" }
            guard next.count <= 1 else { throw OPDSError.invalidDocument }
            let seen = visited.union([url, finalURL])
            var cursor: OPDSPageCursor?
            if let link = next.first {
                let target = try OPDSLocation.validate(link.url, configuration: configuration, catalog: true)
                guard !seen.contains(target) else { throw OPDSError.invalidCursor }
                cursor = .init(sessionID: current.id, nextURL: target, visited: seen, pageCount: pageCount + 1)
            }
            return .init(id: parsed.id, title: parsed.title, updated: parsed.updated, updatedRaw: parsed.updatedRaw,
                         items: parsed.items, links: parsed.links, nextCursor: cursor, sessionID: current.id)
        } catch { throw Self.mapped(error) }
    }

    static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return RemoteSyncError.cancelled }
        return error
    }
    private static func filename(_ title: String, mediaType: String) -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let safe = String(title.components(separatedBy: unsafe).joined(separator: "_").prefix(100))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = ["application/epub+zip": "epub", "application/pdf": "pdf", "application/x-cbz": "cbz",
                   "application/vnd.comicbook+zip": "cbz", "application/x-cbr": "cbr", "application/vnd.comicbook-rar": "cbr",
                   "application/zip": "zip", "text/plain": "txt", "application/x-mobipocket-ebook": "mobi",
                   "audio/mpeg": "mp3", "audio/mp4": "m4a", "image/jpeg": "jpg", "image/png": "png"][mediaType] ?? "bin"
        return (safe.isEmpty || safe == "." || safe == ".." ? "publication" : safe) + "." + ext
    }
}
