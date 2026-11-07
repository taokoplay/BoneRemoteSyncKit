import Foundation
import Testing
import BoneRemoteSyncKit
@testable import BoneRemoteSyncBrowser

private actor BrowserFileFixture: RemoteIDAddressableSource {
    nonisolated let kind: RemoteSourceKind
    nonisolated let capabilities: RemoteCapabilities
    let entries: [RemoteEntry]
    var requests: [RemoteListRequest] = []
    var addressedIDs: [String] = []
    var coverage: RemoteListingCoverage = .complete
    var nativePaging = false
    var blocking = false
    var failure: (any Error)?
    var substituteID = false
    var isConnected = true
    init(kind: RemoteSourceKind = .local, ids: Bool = false, count: Int = 5) {
        self.kind = kind
        capabilities = .init(idAddressing: ids)
        entries = (0..<count).map { .init(id: "id-\($0)", path: ids ? nil : "/file-\($0)", name: "file-\($0)", type: .file,
                                         size: 4, modifiedAt: Date(timeIntervalSince1970: 123), contentType: "text/plain") }
    }
    func configure(coverage: RemoteListingCoverage = .complete, nativePaging: Bool = false, blocking: Bool = false,
                   failure: (any Error)? = nil, substituteID: Bool = false) {
        self.coverage = coverage; self.nativePaging = nativePaging; self.blocking = blocking
        self.failure = failure; self.substituteID = substituteID
    }
    func connect(_ credential: RemoteCredential) async throws { isConnected = true }
    func disconnect() async { isConnected = false }
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        requests.append(request)
        while blocking { try await Task.sleep(nanoseconds: 5_000_000) }
        if let failure { throw failure }
        guard isConnected else { throw RemoteSyncError.notConnected }
        if nativePaging {
            return .init(coverage: coverage, entries: request.cursor == nil ? Array(entries.prefix(3)) : Array(entries.dropFirst(3)),
                         nextCursor: request.cursor == nil ? "native-next" : nil)
        }
        return .init(coverage: coverage, entries: entries)
    }
    func list(parentID: String, request: RemoteListRequest) async throws -> RemoteListPage {
        addressedIDs.append(parentID)
        return try await list(path: "/", request: request)
    }
    func stat(path: String) async throws -> RemoteEntry {
        guard let entry = entries.first(where: { $0.path == path }) else { throw RemoteSyncError.notFound(path: path) }
        return substituteID ? .init(id: "different", path: path, name: entry.name, type: entry.type) : entry
    }
    func stat(id: String) async throws -> RemoteEntry {
        addressedIDs.append(id)
        guard let entry = entries.first(where: { $0.id == id }) else { throw RemoteSyncError.notFound(path: "fixture") }
        return entry
    }
    func download(_ entry: RemoteEntry, to url: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        try Data("file".utf8).write(to: url); return entry
    }
    func waitForRequest() async throws {
        for _ in 0..<500 {
            if !requests.isEmpty { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw URLError(.timedOut)
    }
}

private actor BrowserBindingFixture {
    var value: RemoteSourceBinding
    init(_ value: RemoteSourceBinding) { self.value = value }
    func change() { value = .init(kind: value.kind, identity: "new-session") }
}

private func expectBrowserCode(_ code: RemoteBrowserError.Code, _ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected browser error \(code.rawValue)") }
    catch { #expect((error as? RemoteBrowserError)?.code == code) }
}

@Suite struct BrowserFileTests {
    @Test(arguments: [RemoteSourceKind.local, .iCloud, .webdav, .oneDrive, .baidu])
    func fileSourcesUseOneDisplayShape(kind: RemoteSourceKind) async throws {
        let source = BrowserFileFixture(kind: kind)
        let browser = try RemoteBrowser.files(source, binding: .init(kind: kind, identity: "account"))
        let page = try await browser.browse(pageSize: 5)
        #expect(page.items.count == 5 && page.total == 5 && page.coverage == .complete)
        let first = try #require(page.items.first)
        #expect(first.kind == .file && first.metadata.size == 4 && first.metadata.modifiedAt == Date(timeIntervalSince1970: 123))
        #expect(first.capabilities == [.download])
        #expect(try await browser.details(for: first).id == first.id)
        #expect(try await browser.artwork(for: first) == nil)
        await expectBrowserCode(.unsupported) { _ = try await browser.search("file") }
        let saved = try JSONEncoder().encode(first.snapshot)
        #expect(try JSONDecoder().decode(RemoteBrowseSnapshot.self, from: saved) == first.snapshot)
        await browser.close()
        #expect(await source.isConnected)
    }

    @Test func bufferedTailThenNativeCursorNeverDropsItems() async throws {
        let source = BrowserFileFixture()
        await source.configure(coverage: .partial, nativePaging: true)
        let browser = try RemoteBrowser.files(source, binding: .init(kind: .local, identity: "paging"))
        var page = try await browser.browse(pageSize: 2, includeHidden: true)
        var names = page.items.map(\.metadata.title)
        #expect(page.total == nil)
        while let cursor = page.nextCursor {
            page = try await browser.nextPage(cursor)
            #expect(page.coverage == .partial)
            names += page.items.map(\.metadata.title)
        }
        #expect(names == (0..<5).map { "file-\($0)" })
        let requests = await source.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.includeHidden && $0.limit == 2 })
        #expect(requests[1].cursor == "native-next")
        await browser.close()
    }

    @Test func stableIDsWorkWithMissingPaths() async throws {
        let source = BrowserFileFixture(kind: .oneDrive, ids: true)
        let browser = try RemoteBrowser.files(source, binding: .init(kind: .oneDrive, identity: "drive"))
        let item = try #require(await browser.browse().items.first)
        let option = try #require(await browser.downloadOptions(for: item).first)
        let reference = try await browser.prepareDownload(option)
        #expect(reference.locator == .itemID("id-0"))
        #expect(try await browser.details(for: item).id == item.id)
        guard case .file(let native) = try await browser.nativeReference(for: item) else { Issue.record("Missing native file reference"); return }
        #expect(native == reference)
        #expect(await source.addressedIDs.count == 4)
        await browser.close()
    }

    @Test func foreignHandlesAreRejectedAndIDsAreSourceScoped() async throws {
        let source = BrowserFileFixture()
        let first = try RemoteBrowser.files(source, binding: .init(kind: .local, identity: "one"))
        let second = try RemoteBrowser.files(source, binding: .init(kind: .local, identity: "two"))
        let page = try await first.browse(pageSize: 1)
        let item = try #require(page.items.first), cursor = try #require(page.nextCursor)
        let option = try #require(await first.downloadOptions(for: item).first)
        let other = try #require(await second.browse().items.first)
        #expect(item.id != other.id)
        await expectBrowserCode(.invalidReference) { _ = try await second.details(for: item) }
        await expectBrowserCode(.invalidReference) { _ = try await second.nextPage(cursor) }
        await expectBrowserCode(.invalidReference) { _ = try await second.prepareDownload(option) }
        await first.close(); await second.close()
    }

    @Test func hostBindingChangeInvalidatesEvenBufferedPages() async throws {
        let source = BrowserFileFixture(), binding = RemoteSourceBinding(kind: .local, identity: "original")
        let host = BrowserBindingFixture(binding)
        let browser = try RemoteBrowser.files(source, binding: binding, validateBinding: { await host.value })
        let page = try await browser.browse(pageSize: 1)
        let cursor = try #require(page.nextCursor)
        await host.change()
        await expectBrowserCode(.sessionExpired) { _ = try await browser.nextPage(cursor) }
        #expect(await source.requests.count == 1)
        await browser.close()
    }

    @Test func limitsAndInvalidInputFailExplicitly() async throws {
        let source = BrowserFileFixture()
        let binding = RemoteSourceBinding(kind: .local, identity: "limits")
        let small = try RemoteBrowser.files(source, binding: binding, options: .init(maxBufferedItems: 2))
        await expectBrowserCode(.invalidInput) { _ = try await small.browse(pageSize: 0) }
        #expect(await source.requests.isEmpty)
        await expectBrowserCode(.resourceLimit) { _ = try await small.browse() }
        let onePage = try RemoteBrowser.files(source, binding: binding, options: .init(maxPageCount: 1))
        let cursor = try #require(await onePage.browse(pageSize: 1).nextCursor)
        await expectBrowserCode(.resourceLimit) { _ = try await onePage.nextPage(cursor) }
        #expect(throws: RemoteBrowserError.self) { try RemoteBrowserOptions(maxConcurrentOperations: 0) }
        #expect(throws: RemoteBrowserError.self) { try RemoteBrowser.files(source, binding: .init(kind: .webdav, identity: "wrong")) }
        await small.close(); await onePage.close()
    }

    @Test func closeCancelsAndDrainsOnlyBrowserOperations() async throws {
        let source = BrowserFileFixture()
        await source.configure(blocking: true)
        let browser = try RemoteBrowser.files(source, binding: .init(kind: .local, identity: "closing"))
        let loading = Task { try await browser.browse() }
        try await source.waitForRequest()
        await browser.close()
        await expectBrowserCode(.cancelled) { _ = try await loading.value }
        await expectBrowserCode(.sessionExpired) { _ = try await browser.browse() }
        #expect(await source.isConnected)
        await browser.close()
    }

    @Test func operationBudgetAndConsumerCancellationLeaveBrowserUsable() async throws {
        let source = BrowserFileFixture()
        await source.configure(blocking: true)
        let browser = try RemoteBrowser.files(source, binding: .init(kind: .local, identity: "limited"),
                                               options: .init(maxConcurrentOperations: 1))
        let loading = Task { try await browser.browse() }
        try await source.waitForRequest()
        await expectBrowserCode(.rateLimited) { _ = try await browser.browse() }
        loading.cancel()
        await expectBrowserCode(.cancelled) { _ = try await loading.value }
        await source.configure()
        #expect(try await browser.browse().items.count == 5)
        await browser.close()
    }

    @Test func nativeFailuresHaveUniformCodesAndRedactedDescriptions() async throws {
        let source = BrowserFileFixture()
        let browser = try RemoteBrowser.files(source, binding: .init(kind: .local, identity: "errors"))
        await source.configure(failure: RemoteSyncError.rateLimited(retryAfter: 3))
        do { _ = try await browser.browse(); Issue.record("Expected rate limit") }
        catch let error as RemoteBrowserError {
            #expect(error.code == .rateLimited && error.retryAfter == 3)
            #expect(error.underlyingError as? RemoteSyncError == .rateLimited(retryAfter: 3))
        }
        await source.configure(failure: RemoteSyncError.authenticationFailed(reason: "private-token"))
        do { _ = try await browser.browse(); Issue.record("Expected authentication error") }
        catch let error as RemoteBrowserError {
            #expect(error.code == .authentication)
            #expect(!String(reflecting: error).contains("private-token"))
            #expect(!String(describing: Mirror(reflecting: error).children.map(\.value)).contains("private-token"))
        }
        await browser.close()
    }

    @Test func replacedIdentityIsNotReturnedAsOriginalDetails() async throws {
        let source = BrowserFileFixture()
        let browser = try RemoteBrowser.files(source, binding: .init(kind: .local, identity: "identity"))
        let item = try #require(await browser.browse().items.first)
        await source.configure(substituteID: true)
        await expectBrowserCode(.invalidReference) { _ = try await browser.details(for: item) }
        await browser.close()
    }

    @Test func localDirectoryAndTransferWorkThroughUnifiedBrowser() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneBrowserTests-\(UUID())")
        let root = workspace.appendingPathComponent("source"), cache = workspace.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("real local file".utf8).write(to: root.appendingPathComponent("folder/book.txt"))
        let source = LocalFileSource(root: root)
        try await source.connect(.anonymous)
        let browser = try RemoteBrowser.files(source, binding: .init(kind: .local, identity: "local-session"))
        let directory = try #require(await browser.browse().items.first)
        #expect(directory.kind == .directory && directory.capabilities == [.browse])
        #expect(try await browser.downloadOptions(for: directory).isEmpty)
        let book = try #require(await browser.browse(in: directory).items.first)
        let option = try #require(await browser.downloadOptions(for: book).first)
        let reference = try await browser.prepareDownload(option)
        let materializer = RemoteFileMaterializer(source: browser.source, sourceBinding: browser.sourceBinding, cacheDirectory: cache)
        let lease = try await materializer.materialize(reference)
        #expect(try await lease.withAccess { try String(contentsOf: $0, encoding: .utf8) } == "real local file")
        await materializer.shutdown(); await browser.close(); await source.disconnect()
    }
}
