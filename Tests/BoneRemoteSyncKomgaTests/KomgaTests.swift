#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncContent
import BoneRemoteSyncKomga
import BoneRemoteSyncTransfer
import BoneRemoteSyncTestSupport

private enum FixtureError: Error { case launchTimeout, markerTimeout, invalidReference }

private struct RecordedRequest: Decodable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: String
    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    var query: [URLQueryItem] { URLComponents(string: path)?.queryItems ?? [] }
    func json() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any] }
}

private func stopFixtureProcess(_ process: Process, _ terminated: DispatchSemaphore) {
    if process.isRunning {
        process.terminate()
        if terminated.wait(timeout: .now() + 3) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 3)
        }
    }
}

private final class KomgaFixture: @unchecked Sendable {
    let directory: URL
    let process = Process()
    let terminated = DispatchSemaphore(value: 0)
    let baseURL: URL

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoneKomgaTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = try PythonFixture.executableURL()
        let script = Bundle.module.url(forResource: "komga", withExtension: "py", subdirectory: "Fixtures")!
        process.arguments = [script.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let semaphore = terminated
        process.terminationHandler = { _ in semaphore.signal() }
        do { try process.run() }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let portURL = directory.appendingPathComponent("port")
        var port: Int?
        do {
            for _ in 0..<250 {
                if let text = try? String(contentsOf: portURL, encoding: .utf8), let value = Int(text) { port = value; break }
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            stopFixtureProcess(process, semaphore)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        guard let port else {
            stopFixtureProcess(process, semaphore)
            try? FileManager.default.removeItem(at: directory)
            throw FixtureError.launchTimeout
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)/proxy/komga/")!
    }
    func stop() {
        stopFixtureProcess(process, terminated)
        try? FileManager.default.removeItem(at: directory)
    }
    func source(maxReferences: Int = 256) throws -> KomgaSource {
        KomgaSource(configuration: try .init(baseURL: baseURL, allowsInsecureHTTP: true, timeout: 5,
                                             maxDownloadReferences: maxReferences))
    }
    func requests() throws -> [RecordedRequest] {
        let text = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(RecordedRequest.self, from: Data($0.utf8)) }
    }
    func waitFor(_ marker: String) async throws {
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw FixtureError.markerTimeout
    }
}

private func path(_ reference: RemoteFileReference) throws -> String {
    guard case .path(let value) = reference.locator else { throw FixtureError.invalidReference }
    return value
}

@Suite(.serialized, .enabled(if: PythonFixture.isAvailable, "Python 3 is required for Komga HTTP fixtures"))
struct KomgaTests {
    @Test func authenticationHeadersIdentityAndMount() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source()
        #expect(source.kind == .komga)
        #expect(!source.capabilities.list && source.capabilities.download && !source.capabilities.rangedDownload)
        try await source.connect(.basic(username: "reader@example.invalid", password: "fixture-password"), expectedUserID: "u1")
        #expect(try await source.connectedUserID() == "u1")
        let user = try await source.currentUser()
        #expect(user.canDownloadFiles && user.canStreamPages)
        _ = try await source.libraries()
        let basic = "Basic " + Data("reader@example.invalid:fixture-password".utf8).base64EncodedString()
        let basicRequests = try fixture.requests()
        #expect(basicRequests.allSatisfy { $0.header("Authorization") == basic && $0.header("X-API-Key") == nil })
        let oldBinding = try await source.sourceBinding()
        try await source.connect(.apiToken("fixture-key"))
        #expect(try await source.sourceBinding() != oldBinding)
        _ = try await source.libraries()
        let keyRequests = try fixture.requests().dropFirst(basicRequests.count)
        #expect(keyRequests.allSatisfy { $0.header("X-API-Key") == "fixture-key" && $0.header("Authorization") == nil })
        #expect(try fixture.requests().allSatisfy { $0.path.hasPrefix("/proxy/komga/api/") && $0.header("Cookie") == nil })
        #expect(basicRequests.first?.path == "/proxy/komga/api/v2/users/me")
        await source.disconnect()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.libraries() }
    }

    @Test func nativeBrowsingPaginationSearchAndSafeMetadata() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(); try await source.connect(.apiToken("fixture-key"))
        let library = try await source.library(id: "l1")
        #expect(try await source.libraries() == [library])
        let first = try await source.series(libraryID: "l1", pageSize: 1)
        let second = try await source.series(libraryID: "l1", page: 1, pageSize: 1)
        #expect(first.items.map(\.id) == ["s1"] && first.hasNextPage && first.total == 2)
        #expect(second.items.map(\.id) == ["s2"] && !second.hasNextPage)
        let series = try await source.series(id: "s1", libraryID: "l1")
        #expect(series.metadata.publisher == "Publisher")
        let books = try await source.books(libraryID: "l1", seriesID: "s1", pageSize: 2,
                                            sort: [.init(.number), .init(.title, .descending)])
        #expect(books.items.map(\.id) == ["b1", "b2"] && books.hasNextPage && books.total == 3)
        let next = try await source.books(seriesID: "s1", page: 1, pageSize: 2)
        #expect(next.items.map(\.id) == ["epub"] && !next.hasNextPage)
        #expect(try await source.books(libraryID: "unshared").items.isEmpty)
        let found = try await source.books(seriesID: "s1", search: "  b2  ")
        #expect(found.items.map(\.id) == ["b2"])
        #expect(try await source.series(libraryID: "l1", search: "s2").items.map(\.id) == ["s2"])
        let book = try await source.book(id: "b1", seriesID: "s1", libraryID: "l1")
        #expect(book.metadata.number == "1" && book.metadata.numberSort == 1.5 && book.number == 1)
        #expect(book.metadata.releaseDate == "2024-02-29" && book.metadata.authors?.first?.role == "writer")
        #expect(book.created != nil && book.lastModified != nil)
        for data in [try JSONEncoder().encode(library), try JSONEncoder().encode(series), try JSONEncoder().encode(book)] {
            let encoded = String(decoding: data, as: UTF8.self)
            #expect(!encoded.contains("DO-NOT-EXPOSE") && !encoded.contains("\"url\"") && !encoded.contains("\"root\""))
        }
        let requests = try fixture.requests()
        let request = try #require(requests.first { $0.path.contains("books/list") })
        #expect(request.method == "POST" && request.header("Content-Type") == "application/json")
        #expect(request.query.filter { $0.name == "sort" }.compactMap(\.value) == ["metadata.numberSort,asc", "metadata.title,desc"])
        let condition = try #require(try request.json()["condition"] as? [String: Any])
        let allOf = try #require(condition["allOf"] as? [[String: [String: String]]])
        #expect(allOf == [["libraryId": ["operator": "is", "value": "l1"]], ["seriesId": ["operator": "is", "value": "s1"]]])
        let search = try #require(requests.first { $0.body.contains("b2") && $0.path.contains("list") })
        #expect(try search.json()["fullTextSearch"] as? String == "b2")
        #expect(!search.query.contains { $0.name == "sort" })
        await source.disconnect()
    }

    @Test func coversPageDirectoryAndPDFImages() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(); try await source.connect(.apiToken("fixture-key"))
        let cover = try await source.bookCover(bookID: "b1")
        #expect(cover.prefix(2) == Data([0xff, 0xd8]))
        #expect(try await source.seriesCover(seriesID: "s1") == cover)
        let pages = try await source.pages(bookID: "pdf")
        #expect(pages.map(\.number) == [1, 2, 3] && pages[0].width == 1)
        #expect(try await source.pageImage(bookID: "pdf", page: 2) == cover)
        #expect(try await source.pages(bookID: "epub").isEmpty)
        await #expect(throws: RemoteSyncError.unsupported(operation: "Komga EPUB page images; use the original EPUB file")) {
            try await source.pageImage(bookID: "epub", page: 1)
        }
        await #expect(throws: ContentServerError.invalidReference) { try await source.pageImage(bookID: "b1", page: 0) }
        await #expect(throws: ContentServerError.invalidReference) { try await source.pageImage(bookID: "b1", page: 4) }
        await #expect(throws: ContentServerError.invalidResponse) { try await source.pages(bookID: "bad-pages") }
        await #expect(throws: RemoteSyncError.notFound(path: "Content resource")) { try await source.bookCover(bookID: "missing-cover") }
        let image = try #require(try fixture.requests().first { $0.path.contains("/pages/2?") })
        #expect(image.header("Accept") == "image/jpeg")
        #expect(image.query.contains(.init(name: "contentNegotiation", value: "false")))
        #expect(image.query.contains(.init(name: "convert", value: "jpeg")))
        await source.disconnect()
    }

    @Test func explicitPageProgressAndEPUBRules() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(); try await source.connect(.apiToken("fixture-key"))
        #expect(try await source.readProgress(bookID: "b1") == nil)
        #expect(try await source.readProgress(bookID: "epubzero")?.page == 0)
        try await source.updateReadProgress(bookID: "b1", page: 2)
        #expect(try await source.readProgress(bookID: "b1")?.page == 2)
        #expect(try await source.readProgress(bookID: "b1")?.completed == false)
        try await source.updateReadProgress(bookID: "b1", page: 3)
        #expect(try await source.readProgress(bookID: "b1")?.completed == true)
        try await source.resetReadProgress(bookID: "b1")
        #expect(try await source.readProgress(bookID: "b1") == nil)
        try await source.markRead(bookID: "epub")
        #expect(try await source.readProgress(bookID: "epub")?.completed == true)
        #expect(try await source.progression(bookID: "epub")?.locator.href == "")
        try await source.resetReadProgress(bookID: "epub")
        #expect(try await source.progression(bookID: "epub") == nil)
        try await source.updateReadProgress(bookID: "divina", page: 2)
        await #expect(throws: RemoteSyncError.unsupported(operation: "Komga EPUB page progress; use updateProgression(bookID:progression:)")) {
            try await source.updateReadProgress(bookID: "epub", page: 1)
        }
        for page in [0, -1, 4, Int.max] {
            await #expect(throws: ContentServerError.invalidReference) { try await source.updateReadProgress(bookID: "b1", page: page) }
        }
        let progressRequests = try fixture.requests().filter { $0.path.hasSuffix("/read-progress") }
        #expect(!progressRequests.contains { $0.method == "GET" })
        #expect(progressRequests.filter { $0.method == "PATCH" }.map(\.body).contains("{\"completed\":true}"))
        #expect(progressRequests.filter { $0.method == "DELETE" }.allSatisfy { $0.body.isEmpty })
        await source.disconnect()
    }

    @Test func readiumRoundTripNoRecordConflictAndValidation() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(); try await source.connect(.apiToken("fixture-key"))
        #expect(try await source.progression(bookID: "epub") == nil)
        let value = KomgaReadiumProgression(modified: Date(timeIntervalSince1970: 1_900_000_000.125),
            device: .init(id: "reader-device", name: "Fixture Reader"),
            locator: .init(href: "OEBPS/chapter.xhtml", type: "application/xhtml+xml", title: "Chapter",
                           locations: .init(fragments: ["p1"], progression: 0.25, position: 1, totalProgression: 0.1),
                           text: .init(after: "after", before: "before", highlight: "two\nlines"), koboSpan: "span"))
        try await source.updateProgression(bookID: "epub", progression: value)
        #expect(try await source.progression(bookID: "epub") == value)
        #expect(try await source.readProgress(bookID: "epub")?.page == 0)
        #expect(try await source.readProgress(bookID: "epub")?.deviceId == "reader-device")
        await #expect(throws: RemoteSyncError.conflict(path: "Content resource")) {
            try await source.updateProgression(bookID: "epub", progression: value)
        }
        for fraction in [Double.nan, .infinity, -0.1, 1.1] {
            let invalid = KomgaReadiumProgression(modified: value.modified, device: value.device,
                locator: .init(href: "OEBPS/chapter.xhtml", type: "application/xhtml+xml", locations: .init(progression: fraction)))
            await #expect(throws: ContentServerError.invalidReference) { try await source.updateProgression(bookID: "epub", progression: invalid) }
        }
        let pdf = KomgaReadiumProgression(modified: value.modified, device: value.device,
                                          locator: .init(href: "page2", type: "application/pdf", locations: .init(position: 2)))
        try await source.updateProgression(bookID: "pdf", progression: pdf)
        #expect(try await source.progression(bookID: "pdf") == pdf)
        let invalidPDF = KomgaReadiumProgression(modified: value.modified, device: value.device,
                                                locator: .init(href: "page4", type: "application/pdf", locations: .init(position: 4)))
        await #expect(throws: ContentServerError.invalidReference) { try await source.updateProgression(bookID: "pdf", progression: invalidPDF) }
        try await source.resetReadProgress(bookID: "epub")
        #expect(try await source.progression(bookID: "epub") == nil)
        let puts = try fixture.requests().filter { $0.method == "PUT" }
        #expect(puts.count == 3) // Includes the conflict, with no automatic replay.
        #expect(puts.allSatisfy { $0.header("Content-Type") == "application/vnd.readium.progression+json" })
        let modified = try #require(try puts[0].json()["modified"] as? String)
        #expect(modified.hasSuffix("Z") && modified.contains(".125"))
        await source.disconnect()
    }

    @Test func registeredDownloadsTransferAndReconnect() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(); try await source.connect(.apiToken("fixture-key"))
        let reference = try await source.prepareDownload(bookID: "b1")
        let entry = try await source.stat(path: path(reference))
        #expect(entry.name == "b1.cbz" && entry.etag == nil && entry.modifiedAt == nil && entry.createdAt == nil)
        let destination = fixture.directory.appendingPathComponent("book.cbz")
        try await source.download(entry, to: destination)
        let data = try Data(contentsOf: destination)
        #expect(data.prefix(4) == Data([0x50, 0x4b, 3, 4]) && Int64(data.count) == entry.size)
        try await source.download(entry, to: destination)
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: try await source.sourceBinding(),
                                                  cacheDirectory: fixture.directory.appendingPathComponent("cache"))
        let lease = try await materializer.materialize(reference)
        #expect(try Data(contentsOf: lease.url) == data)
        #expect(lease.version == nil)
        await lease.release()
        await materializer.shutdown()
        let forged = RemoteEntry(id: entry.id, path: entry.path, name: "forged.cbz", type: .file, size: entry.size)
        await #expect(throws: ContentServerError.invalidReference) { try await source.download(forged, to: destination) }
        await #expect(throws: RemoteSyncError.unsupported(operation: "Komga download resume/conditional request")) {
            try await source.download(entry, to: destination, options: .init(resumeFrom: 0))
        }
        await #expect(throws: RemoteSyncError.unsupported(operation: "Komga download resume/conditional request")) {
            try await source.download(entry, to: destination, options: .init(expectedETag: "version"))
        }
        #expect(try await source.readProgress(bookID: "b1") == nil)
        let downloads = try fixture.requests().filter { $0.path.hasSuffix("/file") }
        #expect(downloads.count == 3 && downloads.allSatisfy { $0.header("Range") == nil && $0.header("Accept") == "*/*" })
        try await source.connect(.apiToken("other-key"), expectedUserID: "u2")
        #expect(try await source.sourceBinding() != reference.source)
        await #expect(throws: ContentServerError.invalidReference) { try await source.stat(path: path(reference)) }
        await #expect(throws: ContentServerError.invalidReference) { try await source.download(entry, to: destination) }
        #expect(try Data(contentsOf: destination) == data)
        await source.disconnect()
    }

    @Test func identityGuardsAndDownloadPermission() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(maxReferences: 1)
        await #expect(throws: ContentServerError.identityChanged) {
            try await source.connect(.apiToken("fixture-key"), expectedUserID: "u2")
        }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.sourceBinding() }
        try await source.connect(.apiToken("switch-key"))
        await #expect(throws: ContentServerError.identityChanged) { try await source.connectedUserID() }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.libraries() }
        try await source.connect(.apiToken("nodownload-key"))
        #expect(try await source.currentUser().canDownloadFiles == false)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "Komga file download")) { try await source.prepareDownload(bookID: "b1") }
        try await source.connect(.apiToken("fixture-key"))
        _ = try await source.prepareDownload(bookID: "b1")
        await #expect(throws: ContentServerError.resourceLimit) { try await source.prepareDownload(bookID: "b2") }
        await source.disconnect()
    }

    @Test func invalidResponsesIDsRelationsAndInputs() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(); try await source.connect(.apiToken("fixture-key"))
        for id in ["wrong-id", "negative", "malformed", "bad-date"] {
            await #expect(throws: ContentServerError.invalidResponse) { try await source.book(id: id) }
        }
        await #expect(throws: ContentServerError.invalidResponse) { try await source.library(id: "wrong-id") }
        await #expect(throws: ContentServerError.invalidResponse) { try await source.series(id: "wrong-id") }
        await #expect(throws: ContentServerError.invalidResponse) { try await source.series(id: "s1", libraryID: "l2") }
        await #expect(throws: ContentServerError.invalidResponse) { try await source.book(id: "b1", seriesID: "s2") }
        await #expect(throws: ContentServerError.invalidResponse) { try await source.book(id: "b1", libraryID: "l2") }
        for query in ["__bad-page", "__bad-total", "__partial", "__wrong-parent", "__duplicate"] {
            await #expect(throws: ContentServerError.invalidResponse) { try await source.series(libraryID: "l1", search: query) }
            await #expect(throws: ContentServerError.invalidResponse) { try await source.books(libraryID: "l1", search: query) }
        }
        await #expect(throws: ContentServerError.invalidResponse) { try await source.books(seriesID: "s1", search: "__wrong-series") }
        let count = try fixture.requests().count
        await #expect(throws: ContentServerError.invalidCursor) { try await source.books(page: -1) }
        await #expect(throws: ContentServerError.invalidCursor) { try await source.series(pageSize: 501) }
        await #expect(throws: ContentServerError.invalidReference) { try await source.books(search: " \n ") }
        await #expect(throws: ContentServerError.invalidReference) { try await source.book(id: "../b1") }
        #expect(try fixture.requests().count == count)
        await source.disconnect()
    }

    @Test func httpErrorsDoNotExposeResponseBodies() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source()
        await #expect(throws: RemoteSyncError.authenticationFailed(reason: "Content service authentication failed")) {
            try await source.connect(.apiToken("incorrect-fixture-key"))
        }
        try await source.connect(.apiToken("fixture-key"))
        let expectations: [(Int, any Error)] = [
            (401, RemoteSyncError.authenticationFailed(reason: "Content service authentication failed")),
            (403, RemoteSyncError.permissionDenied(path: "Content resource")),
            (404, RemoteSyncError.notFound(path: "Content resource")),
            (409, RemoteSyncError.conflict(path: "Content resource")),
            (429, RemoteSyncError.rateLimited(retryAfter: nil)),
            (500, RemoteSyncError.network("Content service HTTP 500")),
            (400, ContentServerError.invalidResponse)
        ]
        for (status, expected) in expectations {
            do {
                _ = try await source.book(id: "http\(status)")
                Issue.record("Expected HTTP failure")
            } catch {
                if let expected = expected as? RemoteSyncError { #expect(error as? RemoteSyncError == expected) }
                else { #expect(error as? ContentServerError == .invalidResponse) }
                let text = String(describing: error)
                #expect(!text.contains("sensitive-server-body") && !text.contains("fixture-key") && !text.contains("127.0.0.1"))
            }
        }
        await source.disconnect()
    }

    @Test func reconnectCancelsMetadataWithoutPublishingOldResults() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(); try await source.connect(.apiToken("fixture-key"))
        let old = Task { try await source.book(id: "slow") }
        try await fixture.waitFor("metadata-started")
        try await source.connect(.apiToken("other-key"))
        await #expect(throws: RemoteSyncError.cancelled) { try await old.value }
        #expect(try await source.connectedUserID() == "u2")
        await source.disconnect()
    }

    @Test func cancelledConnectDoesNotResetNewConnection() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source()
        let old = Task { try await source.connect(.apiToken("slow-connect-key")) }
        try await fixture.waitFor("connect-started")
        await #expect(throws: RemoteSyncError.notConnected) { try await source.libraries() }
        old.cancel()
        try await source.connect(.apiToken("fixture-key"))
        await #expect(throws: RemoteSyncError.cancelled) { try await old.value }
        #expect(try await source.connectedUserID() == "u1")
        #expect(try await source.libraries().count == 1)
        await source.disconnect()
    }

    @Test func downloadCancellationAndReconnectPreserveDestination() async throws {
        let fixture = try await KomgaFixture(); defer { fixture.stop() }
        let source = try fixture.source(); try await source.connect(.apiToken("fixture-key"))
        let reference = try await source.prepareDownload(bookID: "slow-file")
        let entry = try await source.stat(path: path(reference))
        let destination = fixture.directory.appendingPathComponent("existing.cbz")
        let original = Data("original destination".utf8)
        try original.write(to: destination)
        let transfer = Task { try await source.download(entry, to: destination) }
        try await fixture.waitFor("file-started")
        transfer.cancel()
        try await source.connect(.apiToken("other-key"))
        await #expect(throws: RemoteSyncError.cancelled) { try await transfer.value }
        #expect(try Data(contentsOf: destination) == original)
        let fresh = try await source.prepareDownload(bookID: "b1")
        try await source.download(path: path(fresh), to: destination)
        #expect(try Data(contentsOf: destination) != original)
        await source.disconnect()
    }
}
#endif
