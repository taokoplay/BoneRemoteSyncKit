import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

actor CatalogSource: RemoteSource {
    nonisolated let kind: RemoteSourceKind = .local
    nonisolated let capabilities = RemoteCapabilities.readOnly
    var pages: [String: RemoteListPage] = [:]
    var errors: [String: RemoteSyncError] = [:]
    var identities: [String: String] = ["/": "root"]
    var delay: UInt64 = 0
    var requests: [String] = []
    var active = 0
    var peak = 0
    var synchronizePaths: Set<String> = []
    var arrived: Set<String> = []
    func synchronize(_ paths: Set<String>) { synchronizePaths = paths }
    init() {}
    func configure(pages: [String: RemoteListPage], errors: [String: RemoteSyncError] = [:], identities: [String: String] = ["/": "root"], delay: UInt64 = 0) {
        self.pages = pages; self.errors = errors; self.identities = identities; self.delay = delay
    }
    func connect(_ credential: RemoteCredential) async throws {}
    func disconnect() async {}
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        let key = path + "|" + (request.cursor ?? "")
        requests.append(key); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if synchronizePaths.contains(path) {
            arrived.insert(path)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while arrived != synchronizePaths {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw RemoteSyncError.network("fixture concurrency barrier timed out") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let error = errors[key] { throw error }
        guard let page = pages[key] else { throw RemoteSyncError.notFound(path: path) }
        return page
    }
    func stat(path: String) async throws -> RemoteEntry {
        if let error = errors["stat:" + path] { throw error }
        guard let identity = identities[path] else { throw RemoteSyncError.notFound(path: path) }
        return catalogEntry(path, directory: true, id: identity)
    }
    func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        throw RemoteSyncError.unsupported(operation: "No transfer in catalog")
    }
}

@Suite struct DirectoryRefreshTests {
    @Test func consumesAllPagesIncludingEmptyMiddlePageBeforePublishing() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let source = CatalogSource()
        await source.configure(pages: [
            "/|": .init(coverage: .complete, entries: [catalogEntry("/a")], nextCursor: "next"),
            "/|next": .init(coverage: .complete, entries: [], nextCursor: "last"),
            "/|last": .init(coverage: .complete, entries: [catalogEntry("/b")])
        ])
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        let options = RemoteCatalogRefreshOptions()
        let result = await CatalogDirectoryScanner(store: store, source: source, run: run, options: options, budget: .init(options), permit: .init()).scan(path: "/", depth: 0)
        #expect(result.published == 2 && result.failure == nil)
        #expect(await source.requests == ["/|", "/|next", "/|last"])
        #expect(try await store.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["a", "b"])
        try await store.finishRun(run, state: "success"); try await store.close()
    }

    @Test(arguments: ["second-error", "partial", "unknown", "duplicate-path", "duplicate-id", "cursor-loop", "missing-path", "outside", "budget", "root404", "root403"])
    func failureKeepsPreviousCompleteDirectory(scenario: String) async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/old")])
        let source = CatalogSource()
        var second = RemoteListPage(coverage: .complete, entries: [catalogEntry("/b")])
        var errors: [String: RemoteSyncError] = [:]
        switch scenario {
        case "second-error": errors["/|next"] = .network("fixture")
        case "partial": second = .init(coverage: .partial, entries: [])
        case "unknown": second = .init(coverage: .unknown, entries: [])
        case "duplicate-path": second = .init(coverage: .complete, entries: [catalogEntry("/a")])
        case "duplicate-id": second = .init(coverage: .complete, entries: [catalogEntry("/b", id: "/a")])
        case "cursor-loop": second = .init(coverage: .complete, entries: [], nextCursor: "next")
        case "missing-path": second = .init(coverage: .complete, entries: [.init(id: "bad", path: nil, name: "bad", type: .file)])
        case "outside": second = .init(coverage: .complete, entries: [catalogEntry("/deep/file")])
        case "root404": errors["stat:/"] = .notFound(path: "/")
        case "root403": errors["stat:/"] = .permissionDenied(path: "/")
        default: break
        }
        await source.configure(pages: ["/|": .init(coverage: .complete, entries: [catalogEntry("/a")], nextCursor: "next"), "/|next": second], errors: errors)
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        let options = RemoteCatalogRefreshOptions(maxEntries: scenario == "budget" ? 1 : 100)
        let result = await CatalogDirectoryScanner(store: store, source: source, run: run, options: options, budget: .init(options), permit: .init()).scan(path: "/", depth: 0)
        #expect(result.published == nil && result.failure != nil)
        let cached = try await store.listCached(rootID: root.id, directory: "/")
        #expect(cached.entries.map(\.name) == ["old"] && cached.version == 1 && cached.state == .stale)
        try await store.finishRun(run, state: "failed"); try await store.close()
    }
}
