import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncOPDS
import BoneRemoteSyncKomga
import BoneRemoteSyncKavita
import BoneRemoteSyncAudiobookshelf

/// Common browsing over a source already connected by the host. Does not own source authentication.
public actor RemoteBrowser {
    public nonisolated let source: any RemoteSource
    public nonisolated let sourceBinding: RemoteSourceBinding
    public nonisolated let capabilities: RemoteBrowseCapabilities
    public nonisolated let options: RemoteBrowserOptions
    private let adapter: any BrowserAdapter
    private let owner = UUID()
    private var closed = false
    private struct Operation: Sendable {
        let cancel: @Sendable () -> Void
        let drain: @Sendable () async -> Void
    }
    private var operations: [UUID: Operation] = [:]

    init(adapter: any BrowserAdapter, options: RemoteBrowserOptions = .default) {
        self.adapter = adapter; self.source = adapter.source; self.sourceBinding = adapter.binding
        self.capabilities = adapter.rootCapabilities; self.options = options
    }

    /// The host owns the file-source lifetime. Do not reconnect/rebind it while this browser is open.
    /// A validation closure can observe a host session generation as well as its binding.
    public static func files(_ source: any RemoteSource, binding: RemoteSourceBinding, rootPath: String = "/",
                             options: RemoteBrowserOptions = .default,
                             validateBinding: (@Sendable () async throws -> RemoteSourceBinding)? = nil) throws -> RemoteBrowser {
        guard source.capabilities.list, source.capabilities.stat else { throw RemoteBrowserError(code: .unsupported) }
        guard source.kind == binding.kind, !binding.identity.isEmpty,
              !rootPath.contains("\0") else { throw RemoteBrowserError(code: .invalidInput) }
        return .init(adapter: FileBrowserAdapter(source: source, binding: binding,
            rootPath: RemotePath.normalize(rootPath), bindingValidator: validateBinding), options: options)
    }
    public static func opds(_ source: OPDSSource, options: RemoteBrowserOptions = .default) async throws -> RemoteBrowser {
        do {
            let binding = try await source.sourceBinding()
            let root = try await source.browse()
            guard try await source.sourceBinding() == binding else { throw RemoteBrowserError(code: .sessionExpired) }
            return .init(adapter: OPDSBrowserAdapter(provider: source, binding: binding, root: root), options: options)
        } catch { throw RemoteBrowserError.mapped(error) }
    }
    public static func komga(_ source: KomgaSource, options: RemoteBrowserOptions = .default) async throws -> RemoteBrowser {
        do {
            let binding = try await source.sourceBinding()
            let user = try await source.currentUser()
            guard try await source.sourceBinding() == binding else { throw RemoteBrowserError(code: .sessionExpired) }
            return .init(adapter: KomgaBrowserAdapter(provider: source, binding: binding, user: user), options: options)
        } catch { throw RemoteBrowserError.mapped(error) }
    }
    public static func kavita(_ source: KavitaSource, options: RemoteBrowserOptions = .default) async throws -> RemoteBrowser {
        do {
            let binding = try await source.sourceBinding()
            let account = try await source.account()
            guard try await source.sourceBinding() == binding else { throw RemoteBrowserError(code: .sessionExpired) }
            return .init(adapter: KavitaBrowserAdapter(provider: source, binding: binding, account: account), options: options)
        } catch { throw RemoteBrowserError.mapped(error) }
    }
    public static func audiobookshelf(_ source: AudiobookshelfSource, options: RemoteBrowserOptions = .default) async throws -> RemoteBrowser {
        do {
            let binding = try await source.sourceBinding()
            let user = try await source.currentUser()
            guard try await source.sourceBinding() == binding else { throw RemoteBrowserError(code: .sessionExpired) }
            return .init(adapter: AudiobookshelfBrowserAdapter(provider: source, binding: binding, user: user), options: options)
        } catch { throw RemoteBrowserError.mapped(error) }
    }

    public func browse(in parent: RemoteBrowseItem? = nil, pageSize: Int = 50,
                       includeHidden: Bool = false) async throws -> RemoteBrowsePage {
        try validate(pageSize: pageSize)
        if let parent { try validate(parent); guard parent.capabilities.contains(.browse) else { throw RemoteBrowserError(code: .unsupported) } }
        let request = BrowserRequest(parent: parent?.record.node, query: nil, pageSize: pageSize, includeHidden: includeHidden)
        let result = try await perform { try await $0.page(request) }
        return try page(result, offset: 0, size: pageSize, count: 1)
    }
    public func search(_ query: String, in parent: RemoteBrowseItem? = nil,
                       pageSize: Int = 50) async throws -> RemoteBrowsePage {
        try validate(pageSize: pageSize)
        if let parent { try validate(parent) }
        guard (parent?.capabilities ?? capabilities).contains(.search) else { throw RemoteBrowserError(code: .unsupported) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 2048,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw RemoteBrowserError(code: .invalidInput) }
        let request = BrowserRequest(parent: parent?.record.node, query: query, pageSize: pageSize)
        let result = try await perform { try await $0.page(request) }
        return try page(result, offset: 0, size: pageSize, count: 1)
    }
    public func nextPage(_ cursor: RemoteBrowseCursor) async throws -> RemoteBrowsePage {
        try checkOpen()
        guard cursor.owner == owner else { throw RemoteBrowserError(code: .invalidReference) }
        guard cursor.pageCount < options.maxPageCount else { throw RemoteBrowserError(code: .resourceLimit) }
        switch cursor.continuation {
        case .request(let request):
            let result = try await perform { try await $0.page(request) }
            return try page(result, offset: 0, size: cursor.pageSize, count: cursor.pageCount + 1)
        case .buffered(let result, let offset):
            // Buffered content is still tied to the live connection, not an offline browsing cache.
            try await perform { try await $0.validateSession() }
            return try page(result, offset: offset, size: cursor.pageSize, count: cursor.pageCount + 1)
        }
    }
    public func details(for item: RemoteBrowseItem) async throws -> RemoteBrowseItem {
        try validate(item)
        let record = try await perform { try await $0.details(item.record.node) }
        guard record.key == item.record.key, record.kind == item.kind else { throw RemoteBrowserError(code: .invalidResponse) }
        return makeItem(record)
    }
    /// Nil means no artwork interface/link is available. Network/authentication errors still throw.
    public func artwork(for item: RemoteBrowseItem) async throws -> Data? {
        try validate(item)
        return try await perform { adapter in
            guard item.capabilities.contains(.artwork) else { return nil }
            return try await adapter.artwork(item.record.node)
        }
    }
    /// Enumerates choices without registering downloads, downloading bytes or updating progress.
    public func downloadOptions(for item: RemoteBrowseItem) async throws -> [RemoteBrowseDownload] {
        try validate(item)
        let records: [BrowserDownloadRecord] = try await perform { adapter in
            guard item.capabilities.contains(.download) else { return [] }
            return try await adapter.downloads(item.record.node)
        }
        guard records.count <= options.maxBufferedItems else { throw RemoteBrowserError(code: .resourceLimit) }
        guard Set(records.map(\.key)).count == records.count,
              records.allSatisfy({ $0.size.map { $0 >= 0 } ?? true }) else { throw RemoteBrowserError(code: .invalidResponse) }
        return records.map { record in
            .init(id: .init(source: sourceBinding, kind: .file, value: record.key), title: record.title,
                  filename: record.filename, contentType: record.contentType, size: record.size, kind: record.kind,
                  owner: owner, record: record)
        }
    }
    /// Bridges one explicit choice to the existing Transfer API. The reference has the same sourceBinding.
    public func prepareDownload(_ option: RemoteBrowseDownload) async throws -> RemoteFileReference {
        try checkOpen()
        guard option.owner == owner else { throw RemoteBrowserError(code: .invalidReference) }
        let reference = try await perform { try await $0.prepare(option.record) }
        guard reference.source == sourceBinding else { throw RemoteBrowserError(code: .invalidResponse) }
        return reference
    }
    public func nativeReference(for item: RemoteBrowseItem) async throws -> RemoteBrowseNativeReference {
        try validate(item)
        return try await perform { try await $0.nativeReference(item.record.node) }
    }
    /// Cancels and drains this browser's operations; does not disconnect or mutate the original source.
    public func close() async {
        closed = true
        let pending = Array(operations.values)
        for operation in pending { operation.cancel() }
        for operation in pending { await operation.drain() }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (any BrowserAdapter) async throws -> T) async throws -> T {
        do {
            try checkOpen()
            guard operations.count < options.maxConcurrentOperations else { throw RemoteBrowserError(code: .rateLimited) }
            let adapter = self.adapter, id = UUID()
            let task = Task {
                try Task.checkCancellation()
                try await adapter.validateSession()
                try Task.checkCancellation()
                let result = try await body(adapter)
                try await adapter.validateSession()
                try Task.checkCancellation()
                return result
            }
            operations[id] = .init(cancel: { task.cancel() }, drain: { _ = await task.result })
            defer { operations.removeValue(forKey: id) }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try checkOpen()
            return result
        } catch { throw RemoteBrowserError.mapped(error) }
    }
    private func checkOpen() throws {
        guard !closed else { throw RemoteBrowserError(code: .sessionExpired) }
        guard !Task.isCancelled else { throw RemoteBrowserError(code: .cancelled) }
    }
    private func validate(_ item: RemoteBrowseItem) throws {
        try checkOpen()
        guard item.owner == owner else { throw RemoteBrowserError(code: .invalidReference) }
    }
    private func validate(pageSize: Int) throws {
        try checkOpen()
        guard (1...500).contains(pageSize) else { throw RemoteBrowserError(code: .invalidInput) }
    }
    private func makeItem(_ record: BrowserRecord) -> RemoteBrowseItem {
        .init(snapshot: .init(id: .init(source: sourceBinding, kind: record.kind, value: record.key),
                              metadata: record.metadata, capabilities: record.capabilities), owner: owner, record: record)
    }
    private func page(_ result: BrowserResult, offset: Int, size: Int, count: Int) throws -> RemoteBrowsePage {
        try checkOpen()
        guard result.records.count <= options.maxBufferedItems else { throw RemoteBrowserError(code: .resourceLimit) }
        guard offset >= 0, offset <= result.records.count, result.total.map({ $0 >= 0 }) ?? true,
              Set(result.records.map { "\($0.kind.rawValue):\($0.key)" }).count == result.records.count else {
            throw RemoteBrowserError(code: .invalidResponse)
        }
        let end = min(result.records.count, offset + size)
        let continuation: BrowserContinuation? = end < result.records.count ? .buffered(result, offset: end) : result.next
        let cursor = continuation.map { RemoteBrowseCursor(owner: owner, continuation: $0, pageSize: size, pageCount: count) }
        return .init(items: result.records[offset..<end].map(makeItem), nextCursor: cursor, total: result.total,
                     coverage: result.coverage, capabilities: result.capabilities)
    }
}
