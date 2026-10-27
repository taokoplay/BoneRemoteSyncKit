import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

@Suite struct SubtreeRefreshTests {
    @Test func successfulSiblingsPublishAndFailedDirectoryRetainsOldChildren() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let directories = [catalogEntry("/A", directory: true), catalogEntry("/AB", directory: true)]
        try await seed(store, root: root, path: "/", entries: directories)
        try await seed(store, root: root, path: "/A", entries: [catalogEntry("/A/old")])
        try await seed(store, root: root, path: "/AB", entries: [catalogEntry("/AB/old")])
        let source = CatalogSource()
        await source.synchronize(["/A", "/AB"])
        await source.configure(pages: ["/|": .init(coverage: .complete, entries: directories), "/AB|": .init(coverage: .complete, entries: [catalogEntry("/AB/new")])],
            errors: ["/A|": .permissionDenied(path: "/A")], identities: ["/": "root", "/A": "/A", "/AB": "/AB"], delay: 20_000_000)
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .subtree)
        let options = RemoteCatalogRefreshOptions(scope: .subtree, concurrency: 2)
        let result = await CatalogTreeScanner(scanner: .init(store: store, source: source, run: run, options: options, budget: .init(options), permit: .init())).scan()
        #expect(result.state == .partial && result.publishedDirectories == 2)
        #expect(result.failures.map(\.path) == ["/A"])
        #expect(try await store.listCached(rootID: root.id, directory: "/A").entries.map(\.name) == ["old"])
        #expect(try await store.listCached(rootID: root.id, directory: "/AB").entries.map(\.name) == ["new"])
        #expect(await source.peak == 2)
        try await store.finishRun(run, state: result.state.rawValue); try await store.close()
    }
    @Test(arguments: ["depth", "directories", "pages", "cancel"])
    func limitsAndCancellationNeverPublishTruncatedDirectory(scenario: String) async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let source = CatalogSource()
        await source.configure(pages: ["/|": .init(coverage: .complete, entries: [catalogEntry("/child", directory: true)], nextCursor: scenario == "pages" ? "next" : nil),
            "/|next": .init(coverage: .complete, entries: [])], delay: scenario == "cancel" ? 1_000_000_000 : 0)
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .subtree)
        let options = RemoteCatalogRefreshOptions(scope: .subtree, maxDirectories: scenario == "directories" ? 1 : 100, maxDepth: scenario == "depth" ? 0 : 10, maxPagesPerDirectory: 1)
        let task = Task { await CatalogTreeScanner(scanner: .init(store: store, source: source, run: run, options: options, budget: .init(options), permit: .init())).scan() }
        if scenario == "cancel" {
            for _ in 0..<100 { if await !source.requests.isEmpty { break }; try await Task.sleep(nanoseconds: 1_000_000) }
            task.cancel()
        }
        let report = await task.value
        #expect(report.state == (scenario == "cancel" ? .cancelled : .failed))
        #expect(report.publishedDirectories == 0 && !report.failures.isEmpty)
        #expect(try await store.listCached(rootID: root.id, directory: "/").state == .notInitialized)
        try await store.finishRun(run, state: report.state.rawValue); try await store.close()
    }
}
