import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncLocal

@Suite struct RemoteListingCoverageTests {
    @Test func lastPageDoesNotImplyCoverage() {
        let page = RemoteListPage(coverage: .partial, entries: [])
        #expect(page.isLastPage)
        #expect(page.coverage == .partial)
    }

    @Test(arguments: [RemoteListingCoverage.partial, .unknown])
    func visitorWalkRejectsIncompletePagesBeforeVisiting(coverage: RemoteListingCoverage) async throws {
        let sink = CoverageSink()
        let source = CoverageSource(coverage: coverage)
        await #expect(throws: RemoteSyncError.self) {
            _ = try await source.walk(path: "/", options: .init()) { await sink.append($0) }
        }
        #expect(await sink.count == 0)
    }

    @Test func localCompleteAndFilteredEmptyDirectoriesRemainComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Coverage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".hidden"))
        let source = LocalFileSource(root: root)
        try await source.connect(.anonymous)
        let visible = try await source.list(path: "/")
        #expect(visible.entries.isEmpty)
        #expect(visible.coverage == .complete)
        let hidden = try await source.list(path: "/", request: .init(includeHidden: true))
        #expect(hidden.entries.map(\.name) == [".hidden"])
        #expect(hidden.coverage == .complete)
        await source.disconnect()
    }

    // Deterministic mapper injection covers a metadata race without relying on filesystem timing.
    @Test func localMapperStopsWhenCancelledBetweenEntries() async throws {
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LocalFileSource.listing(urls: [URL(fileURLWithPath: "/tmp/a")], parent: "/", includeHidden: false) { _, path in
                RemoteEntry(id: path, path: path, name: "a", type: .file)
            }
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
    }

    @Test func localMetadataFailureKeepsSuccessfulItemsButMarksPartial() throws {
        let urls = ["a", "b"].map { URL(fileURLWithPath: "/fixture/\($0)") }
        let page = try LocalFileSource.listing(urls: urls, parent: "/", includeHidden: false) { url, path in
            if url.lastPathComponent == "b" { throw CocoaError(.fileReadNoSuchFile) }
            return .init(id: "a", path: path, name: "a", type: .file)
        }
        #expect(page.entries.map(\.path) == ["/a"])
        #expect(page.coverage == .partial)
    }

    @Test func localUnrepresentableNameCannotBecomeADifferentPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Coverage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("a\\b"))
        let source = LocalFileSource(root: root)
        try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/") }
        await source.disconnect()
    }
}

private actor CoverageSink {
    private(set) var count = 0
    func append(_ entry: RemoteEntry) { count += 1 }
}

private actor CoverageSource: RemoteSource {
    nonisolated let kind: RemoteSourceKind = .local
    nonisolated let capabilities = RemoteCapabilities.readOnly
    let coverage: RemoteListingCoverage
    init(coverage: RemoteListingCoverage) { self.coverage = coverage }
    func connect(_ credential: RemoteCredential) async throws {}
    func disconnect() async {}
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        .init(coverage: coverage, entries: [.init(id: "a", path: "/a", name: "a", type: .file)])
    }
    func stat(path: String) async throws -> RemoteEntry { throw RemoteSyncError.notFound(path: path) }
    func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        throw RemoteSyncError.unsupported(operation: "fixture")
    }
}
