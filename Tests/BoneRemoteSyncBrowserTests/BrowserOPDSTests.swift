#if os(macOS)
import Foundation
import Darwin
import Testing
import BoneRemoteSyncKit
import BoneRemoteSyncTestSupport

private final class BrowserOPDSFixture: @unchecked Sendable {
    let directory: URL
    let process = Process()
    let stopped = DispatchSemaphore(value: 0)
    private(set) var baseURL: URL!
    private init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoneBrowserTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    static func start() async throws -> BrowserOPDSFixture {
        let value = try BrowserOPDSFixture()
        value.process.executableURL = try PythonFixture.executableURL()
        value.process.arguments = [try #require(Bundle.module.url(forResource: "opds", withExtension: "py", subdirectory: "Fixtures")).path, value.directory.path]
        value.process.standardOutput = FileHandle.nullDevice; value.process.standardError = FileHandle.nullDevice
        let semaphore = value.stopped
        value.process.terminationHandler = { _ in semaphore.signal() }
        try value.process.run()
        for _ in 0..<500 {
            if let raw = try? String(contentsOf: value.directory.appendingPathComponent("port"), encoding: .utf8), let port = Int(raw) {
                value.baseURL = URL(string: "http://127.0.0.1:\(port)")!; return value
            }
            if !value.process.isRunning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        value.stop(); throw URLError(.cannotConnectToHost)
    }
    func source(path: String = "/root") async throws -> OPDSSource {
        let source = OPDSSource(configuration: try .init(rootURL: baseURL.appendingPathComponent(path), allowsInsecureHTTP: true))
        try await source.connect(.basic(username: "reader", password: "fixture"))
        return source
    }
    func paths() throws -> [String] {
        let text = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").compactMap { (try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])?["path"] }
    }
    func stop() {
        if process.isRunning {
            process.terminate()
            if stopped.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL); _ = stopped.wait(timeout: .now() + 3)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { stop() }
}

@Suite(.enabled(if: PythonFixture.isAvailable, "Requires Python 3 HTTP fixture"))
struct BrowserOPDSTests {
    @Test func navigationAndRemotePagesPreserveOrderingAndCoverage() async throws {
        let fixture = try await BrowserOPDSFixture.start(); defer { fixture.stop() }
        let source = try await fixture.source(), browser = try await RemoteBrowser.opds(source)
        var page = try await browser.browse(pageSize: 1), items = [RemoteBrowseItem]()
        while true {
            #expect(page.total == nil && page.coverage == .unknown)
            items += page.items
            guard let cursor = page.nextCursor else { break }
            page = try await browser.nextPage(cursor)
        }
        #expect(items.map(\.metadata.title) == ["Category", "Category", "Book 1", "Book 2", "Book 3"])
        #expect(items[0].id != items[1].id)
        let child = try await browser.browse(in: items[0])
        #expect(child.items.first?.metadata.title == "Book 1")
        let found = try await browser.search("Fixture & Book", in: items[0])
        #expect(found.items.first?.id == items[2].id)
        #expect(try fixture.paths().filter { $0 == "/next" }.count == 1)
        await browser.close(); await source.disconnect()
    }

    @Test func detailArtworkAndSnapshotsDoNotExposeResourceLinks() async throws {
        let fixture = try await BrowserOPDSFixture.start(); defer { fixture.stop() }
        let source = try await fixture.source(), browser = try await RemoteBrowser.opds(source)
        let page = try await browser.browse()
        let book = try #require(page.items.first(where: { $0.metadata.title == "Book 1" }))
        let detail = try await browser.details(for: book)
        #expect(detail.id == book.id && detail.kind == .book)
        #expect(detail.metadata.authors == ["Author"])
        #expect(detail.metadata.summary?.format == .html)
        #expect(detail.metadata.size == nil && detail.metadata.modifiedAt == nil)
        let image = try #require(await browser.artwork(for: detail))
        #expect(image.starts(with: [137, 80, 78, 71]))
        let snapshots = try JSONEncoder().encode(page.items.map(\.snapshot))
        let json = String(decoding: snapshots, as: UTF8.self)
        #expect(!json.contains("fixture-private-link") && !json.contains("/category?") && !json.contains("/file/"))
        #expect(!String(reflecting: detail).contains("fixture-private-link"))
        let decoded = try JSONDecoder().decode([RemoteBrowseSnapshot].self, from: snapshots)
        #expect(decoded == page.items.map(\.snapshot))
        await browser.close(); await source.disconnect()
    }

    @Test func formatsAreSelectedBeforeTransferDownloadsBytes() async throws {
        let fixture = try await BrowserOPDSFixture.start(); defer { fixture.stop() }
        let source = try await fixture.source(), browser = try await RemoteBrowser.opds(source)
        let page = try await browser.browse()
        let book = try #require(page.items.first(where: { $0.metadata.title == "Book 1" }))
        let options = try await browser.downloadOptions(for: book)
        #expect(Set(options.compactMap(\.contentType)) == ["text/plain", "application/pdf"])
        #expect(options.allSatisfy { $0.size == nil })
        let selected = try #require(options.first(where: { $0.contentType == "text/plain" }))
        let reference = try await browser.prepareDownload(selected)
        #expect(try fixture.paths().allSatisfy { !$0.hasPrefix("/file/") })
        let materializer = RemoteFileMaterializer(source: browser.source, sourceBinding: browser.sourceBinding,
            cacheDirectory: fixture.directory.appendingPathComponent("cache"))
        let lease = try await materializer.materialize(reference)
        #expect(try await lease.withAccess { try String(contentsOf: $0, encoding: .utf8) } == "browser fixture book")
        await materializer.shutdown(); await browser.close(); await source.disconnect()
    }

    @Test func reconnectInvalidatesItemsCursorsAndDownloadChoices() async throws {
        let fixture = try await BrowserOPDSFixture.start(); defer { fixture.stop() }
        let source = try await fixture.source(), browser = try await RemoteBrowser.opds(source)
        let page = try await browser.browse(pageSize: 3)
        let cursor = try #require(page.nextCursor)
        let book = try #require(page.items.first(where: { $0.metadata.title == "Book 1" }))
        let selected = try #require(await browser.downloadOptions(for: book).first)
        try await source.connect(.basic(username: "reader", password: "fixture"))
        for operation in [0, 1, 2] {
            do {
                switch operation {
                case 0: _ = try await browser.details(for: book)
                case 1: _ = try await browser.nextPage(cursor)
                default: _ = try await browser.prepareDownload(selected)
                }
                Issue.record("Expected expired binding")
            } catch { #expect((error as? RemoteBrowserError)?.code == .sessionExpired) }
        }
        let fresh = try await RemoteBrowser.opds(source)
        #expect(fresh.sourceBinding != browser.sourceBinding)
        await fresh.close(); await browser.close(); await source.disconnect()
    }

    @Test func absentSearchCapabilityDoesNotTriggerScanning() async throws {
        let fixture = try await BrowserOPDSFixture.start(); defer { fixture.stop() }
        let source = try await fixture.source(path: "/no-search"), browser = try await RemoteBrowser.opds(source)
        #expect(!browser.capabilities.contains(.search))
        let before = try fixture.paths().count
        do { _ = try await browser.search("Fixture"); Issue.record("Expected unsupported search") }
        catch { #expect((error as? RemoteBrowserError)?.code == .unsupported) }
        #expect(try fixture.paths().count == before)
        await browser.close(); await source.disconnect()
    }
}
#endif
