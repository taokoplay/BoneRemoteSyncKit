import Foundation
import BoneRemoteSyncKit

/// 宿主用统一来源枚举决定展示范围；目录仍按 SDK 的固定顺序排列。
/// 自定义适配器若使用预留来源，应由宿主单独提供其展示项。
public func browserSourceChoices(enabled: Set<RemoteSourceKind>) -> [BoneRemoteSyncSourceType] {
    BoneRemoteSyncIcons.sourceTypes().filter { enabled.contains($0.kind) && $0.kind.hasBuiltInAdapter }
}

/// Host retains both values until its browser/Transfer work has ended.
public func connectKomgaBrowser(
    configuration: KomgaConfiguration,
    credential: RemoteCredential,
    expectedUserID: String? = nil
) async throws -> (source: KomgaSource, browser: RemoteBrowser) {
    let source = KomgaSource(configuration: configuration)
    do {
        try await source.connect(credential, expectedUserID: expectedUserID)
        let browser = try await RemoteBrowser.komga(source)
        return (source, browser)
    } catch {
        await source.disconnect()
        throw error
    }
}

/// This function is identical for files, OPDS, Komga, Kavita and Audiobookshelf.
public func loadBrowserPage(
    browser: RemoteBrowser,
    parent: RemoteBrowseItem? = nil,
    cursor: RemoteBrowseCursor? = nil
) async throws -> RemoteBrowsePage {
    if let cursor { return try await browser.nextPage(cursor) }
    return try await browser.browse(in: parent, pageSize: 50)
}

/// User first chooses a returned download option; no implicit first-format selection.
/// consume must not return until the local file is no longer in use by its reader/player.
public func consumeBrowserDownload(
    browser: RemoteBrowser,
    selection: RemoteBrowseDownload,
    cacheDirectory: URL,
    options: RemoteMaterializationOptions = .init(),
    consume: @escaping @Sendable (URL) async throws -> Void
) async throws {
    let reference = try await browser.prepareDownload(selection)
    let materializer = RemoteFileMaterializer(source: browser.source,
        sourceBinding: browser.sourceBinding, cacheDirectory: cacheDirectory)
    let coordinator = RemoteTransferCoordinator(materializer: materializer)
    do {
        let id = await coordinator.submit(.init(reference: reference, options: options))
        let lease = try await coordinator.wait(for: id)
        try await lease.withAccess { try await consume($0) }
        await coordinator.shutdown()
        await materializer.shutdown()
    } catch {
        await coordinator.shutdown()
        await materializer.shutdown()
        throw error
    }
}

/// Store presentation snapshots only. This does not persist live cursors, native links or credentials.
public func encodeBrowserSnapshots(_ page: RemoteBrowsePage) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(page.items.map(\.snapshot))
}

public func closeKomgaBrowser(source: KomgaSource, browser: RemoteBrowser) async {
    await browser.close()
    await source.disconnect()
}

/// 示例错误，仅说明宿主需要自己处理的选择和预算情况。
public enum UnifiedBrowserExampleError: Error {
    case pageBudgetExceeded
    case sourceMismatch
    case unsupportedSelection
}

/// 逐页消费当前层或当前搜索结果，不累积整个书库、不递归展开子节点。
/// pageSize/query/parent 在一次调用内固定；达到预算仍有下一页时显式抛错。
public func visitBrowserPages(
    browser: RemoteBrowser,
    parent: RemoteBrowseItem? = nil,
    query: String? = nil,
    pageSize: Int = 50,
    maxPages: Int = 100,
    consume: @Sendable (RemoteBrowsePage) async throws -> Void
) async throws {
    guard maxPages > 0 else { throw UnifiedBrowserExampleError.pageBudgetExceeded }
    var page: RemoteBrowsePage
    if let query { page = try await browser.search(query, in: parent, pageSize: pageSize) }
    else { page = try await browser.browse(in: parent, pageSize: pageSize) }
    var count = 1
    while true {
        try Task.checkCancellation()
        try await consume(page)
        guard let cursor = page.nextCursor else { return }
        guard count < maxPages else { throw UnifiedBrowserExampleError.pageBudgetExceeded }
        page = try await browser.nextPage(cursor)
        count += 1
    }
}

/// 保留 live item 供选择与后续操作；snapshot 仅用于离线展示。
public func loadBrowserSelection(
    browser: RemoteBrowser, item: RemoteBrowseItem
) async throws -> (detail: RemoteBrowseItem, artwork: Data?, downloads: [RemoteBrowseDownload]) {
    let detail = try await browser.details(for: item)
    // 本示例将封面网络错误向上传递；UI 可将封面加载拆成独立任务并展示占位图。
    let artwork = try await browser.artwork(for: detail)
    let downloads = try await browser.downloadOptions(for: detail)
    return (detail, artwork, downloads)
}

public func decodeBrowserSnapshots(_ data: Data) throws -> [RemoteBrowseSnapshot] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([RemoteBrowseSnapshot].self, from: data)
}

// 原生调用期间，宿主必须串行管理重连/换账号；实例检查不是跨 await 的连接锁。
/// 仅在用户实际阅读后显式调用；currentPage 为 Komga 页码，不用于普通 EPUB。
public func saveBrowserKomgaPage(
    browser: RemoteBrowser, item: RemoteBrowseItem, source: KomgaSource, currentPage: Int
) async throws {
    guard let original = browser.source as? KomgaSource, original === source else { throw UnifiedBrowserExampleError.sourceMismatch }
    guard case .komgaBook(let bookID) = try await browser.nativeReference(for: item) else {
        throw UnifiedBrowserExampleError.unsupportedSelection
    }
    try await source.updateReadProgress(bookID: bookID, page: currentPage)
}

/// 必须传真实阅读引擎产生的 Readium 位置；不把展示 progress 百分比反推 locator。
public func saveBrowserKomgaEPUB(
    browser: RemoteBrowser, item: RemoteBrowseItem, source: KomgaSource, position: KomgaReadiumProgression
) async throws {
    guard let original = browser.source as? KomgaSource, original === source else { throw UnifiedBrowserExampleError.sourceMismatch }
    guard case .komgaBook(let bookID) = try await browser.nativeReference(for: item) else {
        throw UnifiedBrowserExampleError.unsupportedSelection
    }
    try await source.updateProgression(bookID: bookID, progression: position)
}

/// bookScrollID 是 Kavita DOM XPath；EPUB pageNum 为 reading-order 索引。
public func saveBrowserKavitaPosition(
    browser: RemoteBrowser, item: RemoteBrowseItem, source: KavitaSource,
    pageNum: Int, bookScrollID: String? = nil
) async throws {
    guard let original = browser.source as? KavitaSource, original === source else { throw UnifiedBrowserExampleError.sourceMismatch }
    guard case .kavitaChapter(let chapter) = try await browser.nativeReference(for: item) else {
        throw UnifiedBrowserExampleError.unsupportedSelection
    }
    try await source.updateProgress(chapter, pageNum: pageNum, bookScrollID: bookScrollID)
}

/// 开始整个书籍或节目的直放会话。选择一个音轨时仍返回所属内容的完整会话轨道列表。
/// 宿主保留 session、执行轨道请求、提交实际收听增量，结束时显式 closePlaybackSession。
public func beginBrowserPlayback(
    browser: RemoteBrowser, item: RemoteBrowseItem, source: AudiobookshelfSource,
    supportedMimeTypes: [String]
) async throws -> AudiobookshelfPlaybackSession {
    guard let original = browser.source as? AudiobookshelfSource, original === source else { throw UnifiedBrowserExampleError.sourceMismatch }
    let itemID: String
    let episodeID: String?
    switch try await browser.nativeReference(for: item) {
    case .audiobookshelfItem(let id): itemID = id; episodeID = nil
    case .audiobookshelfEpisode(let id, let episode): itemID = id; episodeID = episode
    case .audiobookshelfTrack(let id, let episode, _, _): itemID = id; episodeID = episode
    default: throw UnifiedBrowserExampleError.unsupportedSelection
    }
    return try await source.createPlaybackSession(itemID: itemID, episodeID: episodeID,
                                                  supportedMimeTypes: supportedMimeTypes)
}
