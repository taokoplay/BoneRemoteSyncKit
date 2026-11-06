#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncBrowser
import BoneRemoteSyncKit
import BoneRemoteSyncTestSupport

private enum NativeBrowserService: String, CaseIterable, Sendable { case komga, kavita, abs }

@Suite(.enabled(if: PythonFixture.isAvailable, "Requires local Python 3 browser fixture"))
struct NativeBrowserTests {
    private let query = "Fixture & chapter"

    private func browser(_ fixture: NativeBrowserFixture, _ service: NativeBrowserService) async throws -> RemoteBrowser {
        let configuration = try ContentServerConfiguration(baseURL: fixture.url(service.rawValue), allowsInsecureHTTP: true,
                                                            timeout: 5, maxDownloadReferences: 2)
        switch service {
        case .komga:
            let source = KomgaSource(configuration: configuration)
            try await source.connect(.apiToken("fixture-key"))
            return try await .komga(source)
        case .kavita:
            let source = KavitaSource(configuration: configuration)
            try await source.connect(.apiToken("fixture-key"))
            return try await .kavita(source)
        case .abs:
            let source = AudiobookshelfSource(configuration: configuration)
            try await source.connect(.apiToken("fixture-key"))
            return try await .audiobookshelf(source)
        }
    }

    private func firstLeaf(_ browser: RemoteBrowser) async throws -> RemoteBrowseItem {
        var value = try #require(try await browser.browse().items.first)
        for _ in 0..<4 {
            if value.kind == .book || value.kind == .chapter { return value }
            value = try #require(try await browser.browse(in: value).items.first)
        }
        throw NativeBrowserFixture.FixtureError.timeout
    }

    private func expectCode(_ code: RemoteBrowserError.Code, _ operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected browser error \(code.rawValue)") }
        catch { #expect((error as? RemoteBrowserError)?.code == code) }
    }

    private func materialize(_ option: RemoteBrowseDownload, browser: RemoteBrowser,
                             fixture: NativeBrowserFixture, expected: Data) async throws {
        let reference = try await browser.prepareDownload(option)
        #expect(reference.source == browser.sourceBinding)
        let materializer = RemoteFileMaterializer(source: browser.source, sourceBinding: browser.sourceBinding,
            cacheDirectory: fixture.directory.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true))
        do {
            let lease = try await materializer.materialize(reference)
            let data = try Data(contentsOf: lease.url)
            await lease.release()
            await materializer.shutdown()
            #expect(data == expected)
        } catch { await materializer.shutdown(); throw error }
    }

    private func assertSafe(_ item: RemoteBrowseItem) throws {
        let snapshot = String(decoding: try JSONEncoder().encode(item.snapshot), as: UTF8.self)
        #expect(!snapshot.contains("/private/server"))
        #expect(!snapshot.contains("fixture-key"))
        #expect(!snapshot.contains("contentUrl"))
        #expect(!snapshot.contains("/api/items/"))
        #expect(item.id.value.count == 64)
    }

    @Test func komgaHierarchySearchMetadataAndOriginalDownload() async throws {
        let f = try await NativeBrowserFixture.start(); defer { f.stop() }
        let b = try await browser(f, .komga)
        #expect(b.capabilities == [.browse, .search])
        let library = try #require(try await b.browse(pageSize: 1).items.first)
        #expect(library.kind == .library && !library.capabilities.contains(.download))
        #expect(try await b.artwork(for: library) == nil)
        let series = try #require(try await b.browse(in: library, pageSize: 1).items.first)
        #expect(series.kind == .series && series.capabilities.contains(.search))
        #expect(!series.capabilities.contains(.nativeProgress))
        let books = try await b.browse(in: series, pageSize: 1)
        let book = try #require(books.items.first)
        let next = try await b.nextPage(try #require(books.nextCursor))
        let epub = try #require(next.items.first)
        #expect(!next.hasNextPage && next.total == 2)
        #expect(book.kind == .book && !book.capabilities.contains(.browse))
        #expect(book.metadata.authors == ["Writer"] && book.metadata.tags == ["book-tag"])
        #expect(book.metadata.pageCount == 4 && book.metadata.progress == 0.5)
        #expect(book.metadata.summary?.format == .html)
        #expect(book.metadata.createdAt != nil && book.metadata.modifiedAt == nil)
        #expect(book.metadata.publicationDate == "2024-02-29")
        #expect(epub.metadata.createdAt == nil && epub.metadata.progress == nil && epub.metadata.pageCount == nil)
        #expect(epub.metadata.summary?.format == .text)
        #expect(try await b.details(for: book).id == book.id)
        #expect(try await b.artwork(for: book)?.starts(with: [255, 216]) == true)
        if case .komgaBook(let id) = try await b.nativeReference(for: book) { #expect(id == "b1") }
        else { Issue.record("Expected Komga book reference") }
        for parent in [nil, library, series] as [RemoteBrowseItem?] {
            let found = try await b.search(query, in: parent, pageSize: 1)
            let last = try await b.nextPage(try #require(found.nextCursor))
            #expect(found.items.first?.id == book.id && last.items.first?.id == epub.id)
            #expect(!last.hasNextPage)
        }
        let searches = try f.requests().filter { $0.body.contains("fullTextSearch") }
        #expect(searches.count == 6)
        for request in searches { #expect(try request.json()["fullTextSearch"] as? String == query) }
        #expect(searches.map { $0.query["page"] } == ["0", "1", "0", "1", "0", "1"])
        let seriesFilter = try #require(try searches.last?.json()["condition"] as? [String: Any])
        #expect((seriesFilter["allOf"] as? [[String: Any]])?.count == 2)
        // Reference budget is two: repeated option enumeration must never consume it.
        for _ in 0..<4 { #expect(try await b.downloadOptions(for: book).count == 1) }
        let option = try #require(try await b.downloadOptions(for: book).first)
        #expect(option.kind == .originalFile && option.filename == "b1.cbz")
        #expect(option.size == Int64(try f.data("original.bin").count))
        try await materialize(option, browser: b, fixture: f, expected: f.data("original.bin"))
        try assertSafe(book)
        #expect(try f.requests().allSatisfy { $0.method == "GET" || $0.path.hasSuffix("/list") })
        await b.close()
        #expect(try await (b.source as! KomgaSource).sourceBinding() == b.sourceBinding)
        await b.source.disconnect()
    }

    @Test func kavitaHierarchyBufferedPagesMetadataAndZIPChoice() async throws {
        let f = try await NativeBrowserFixture.start(); defer { f.stop() }
        let b = try await browser(f, .kavita)
        #expect(b.capabilities == [.browse])
        await expectCode(.unsupported) { _ = try await b.search(query) }
        let library = try #require(try await b.browse().items.first)
        let search = try await b.search(query, in: library, pageSize: 1)
        let lastSearch = try await b.nextPage(try #require(search.nextCursor))
        #expect(search.total == 2 && !lastSearch.hasNextPage)
        let series = try #require(search.items.first)
        #expect(series.kind == .series && !series.capabilities.contains(.search))
        #expect(series.metadata.createdAt == nil && series.metadata.createdAtRaw == "2024-01-01T12:00:00")
        #expect(series.metadata.modifiedAt != nil)
        await expectCode(.unsupported) { _ = try await b.search(query, in: series) }
        let volumes = try await b.browse(in: series, pageSize: 1)
        let volume = try #require(volumes.items.first)
        let volumeTail = try await b.nextPage(try #require(volumes.nextCursor))
        let emptyVolume = try #require(volumeTail.items.first)
        #expect(volume.kind == .volume && !emptyVolume.capabilities.contains(.browse))
        let chapters = try await b.browse(in: volume, pageSize: 1)
        let epub = try #require(chapters.items.first)
        let second = try await b.nextPage(try #require(chapters.nextCursor))
        let archive = try #require(second.items.first)
        let third = try await b.nextPage(try #require(second.nextCursor))
        #expect(chapters.total == 3 && !third.hasNextPage)
        #expect(epub.kind == .chapter && epub.metadata.progress == nil && epub.metadata.pageCount == nil)
        #expect(epub.metadata.summary?.format == .html && epub.metadata.authors == ["Writer"])
        #expect(epub.metadata.language == "en" && epub.metadata.publicationDate == "2024")
        #expect(epub.metadata.createdAt == nil && epub.metadata.createdAtRaw != nil && epub.metadata.modifiedAt != nil)
        #expect(archive.metadata.progress == 0.5 && archive.metadata.pageCount == 4)
        #expect(third.items.first?.metadata.progress == nil)
        #expect(try await b.details(for: epub).id == epub.id)
        #expect(try await b.artwork(for: epub)?.starts(with: [137, 80, 78, 71]) == true)
        if case .kavitaChapter(let ref) = try await b.nativeReference(for: epub) {
            #expect(ref.libraryID == 1 && ref.seriesID == 12 && ref.volumeID == 23 && ref.chapterID == 34)
        } else { Issue.record("Expected Kavita chapter ancestry") }
        for _ in 0..<4 { #expect(try await b.downloadOptions(for: archive).count == 1) }
        let original = try #require(try await b.downloadOptions(for: epub).first)
        let zip = try #require(try await b.downloadOptions(for: archive).first)
        #expect(original.kind == .originalFile && original.filename == "book.epub" && original.contentType == "application/epub+zip")
        #expect(zip.kind == .archive && zip.size == nil && zip.contentType == "application/zip")
        #expect(zip.filename == "chapter-35.zip")
        try await materialize(original, browser: b, fixture: f, expected: f.data("original.bin"))
        try await materialize(zip, browser: b, fixture: f, expected: f.data("archive.zip"))
        let searches = try f.requests().filter { $0.path == "/kavita/api/Series/v2" }
        #expect(searches.map { $0.query["PageNumber"] } == ["1", "2"])
        for request in searches {
            let statements = try #require(try request.json()["statements"] as? [[String: Any]])
            #expect(statements.contains { $0["field"] as? Int == 19 && $0["value"] as? String == "1" })
            #expect(statements.contains { $0["field"] as? Int == 1 && $0["value"] as? String == query })
        }
        try assertSafe(epub)
        #expect(try f.requests().allSatisfy { $0.method == "GET" || $0.path.hasSuffix("/Series/v2") })
        await b.close(); await b.source.disconnect()
    }

    @Test func audiobookshelfHierarchySearchFilesAndMetadata() async throws {
        let f = try await NativeBrowserFixture.start(); defer { f.stop() }
        let b = try await browser(f, .abs)
        await expectCode(.unsupported) { _ = try await b.search(query) }
        let libraries = try await b.browse(pageSize: 1)
        let library = try #require(libraries.items.first)
        let libraryTail = try await b.nextPage(try #require(libraries.nextCursor))
        let podcastLibrary = try #require(libraryTail.items.first)
        #expect(libraries.total == 2 && library.kind == .library)
        let page = try await b.browse(in: library, pageSize: 1)
        let book = try #require(page.items.first)
        let last = try await b.nextPage(try #require(page.nextCursor))
        let emptyBook = try #require(last.items.first)
        #expect(!last.hasNextPage && last.total == 2)
        let emptyDetails = try await b.details(for: emptyBook)
        #expect(!emptyDetails.capabilities.contains(.browse) && !emptyDetails.capabilities.contains(.nativePlayback))
        #expect(!emptyDetails.capabilities.contains(.download))
        let details = try await b.details(for: book)
        #expect(details.id == book.id && details.kind == .book)
        #expect(details.metadata.authors == ["Writer"] && details.metadata.narrators == ["Narrator"])
        #expect(details.metadata.summary?.format == .html && details.metadata.duration == 60)
        #expect(details.metadata.publicationDate == "2024" && details.metadata.createdAt == nil && details.metadata.modifiedAt == nil)
        #expect(details.metadata.progress == 0.5 && details.capabilities.contains(.nativePlayback))
        let children = try await b.browse(in: book, pageSize: 2)
        #expect(children.items.map(\.kind) == [.track, .track])
        let childrenTail = try await b.nextPage(try #require(children.nextCursor))
        let companion = try #require(childrenTail.items.first)
        #expect(companion.kind == .file && children.total == 3)
        let track = children.items[1]
        #expect(!track.capabilities.contains(.browse))
        if case .audiobookshelfTrack(let item, let episode, let index, let file) = try await b.nativeReference(for: track) {
            #expect(item == "book-1" && episode == nil && index == 2 && file == "102")
        } else { Issue.record("Expected concrete track reference") }
        for _ in 0..<4 { #expect(try await b.downloadOptions(for: book).count == 3) }
        let choices = try await b.downloadOptions(for: book)
        #expect(choices.map(\.filename) == ["101.mp3", "102.mp3", "ebook.epub"])
        #expect(choices.map(\.kind) == [.audioFile, .audioFile, .originalFile])
        #expect(Set(choices.map(\.id)).count == 3)
        #expect(try await b.downloadOptions(for: track).map(\.filename) == ["102.mp3"])
        #expect(try await b.downloadOptions(for: companion).map(\.filename) == ["ebook.epub"])
        try await materialize(choices[1], browser: b, fixture: f, expected: Data("ID3native-track-102".utf8))
        #expect(try await b.artwork(for: details)?.starts(with: [137, 80, 78, 71]) == true)
        for parent in [library, podcastLibrary] {
            let result = try await b.search(query, in: parent, pageSize: 1)
            #expect(result.total == nil && result.coverage == .unknown && !result.hasNextPage)
            #expect(result.items.count == 1)
        }
        let podcast = try #require(try await b.browse(in: podcastLibrary).items.first)
        #expect(podcast.kind == .podcast && !podcast.capabilities.contains(.nativePlayback))
        let episodes = try await b.browse(in: podcast)
        let episode = episodes.items[0]
        #expect(episode.kind == .episode && episode.metadata.summary?.format == .html)
        #expect(episode.metadata.publicationDate == "2023-11-14T22:13:20Z")
        #expect(!episodes.items[1].capabilities.contains(.browse) && !episodes.items[1].capabilities.contains(.nativePlayback))
        let episodeTrack = try #require(try await b.browse(in: episode).items.first)
        #expect(episodeTrack.kind == .track && episodeTrack.id != track.id)
        let episodeChoices = try await b.downloadOptions(for: podcast)
        #expect(episodeChoices.count == 1 && episodeChoices[0].filename == "201.mp3")
        #expect(try await b.downloadOptions(for: episode).count == 1)
        try await materialize(episodeChoices[0], browser: b, fixture: f, expected: Data("ID3native-track-201".utf8))
        try assertSafe(details); try assertSafe(episodeTrack)
        #expect(try f.requests().allSatisfy { $0.method == "GET" })
        await b.close(); await b.source.disconnect()
    }

    @Test(arguments: NativeBrowserService.allCases)
    private func scopeParentChangesAndSessionExpiry(_ service: NativeBrowserService) async throws {
        let f = try await NativeBrowserFixture.start(); defer { f.stop() }
        let b = try await browser(f, service)
        let leaf = try await firstLeaf(b)
        let option = try #require(try await b.downloadOptions(for: leaf).first)
        let other = try await browser(f, service)
        await expectCode(.invalidReference) { _ = try await other.details(for: leaf) }
        await expectCode(.invalidReference) { _ = try await other.prepareDownload(option) }
        await other.close(); await other.source.disconnect()
        try f.state(["moved": true])
        await expectCode(.invalidReference) { _ = try await b.details(for: leaf) }
        await expectCode(.invalidReference) { _ = try await b.downloadOptions(for: leaf) }
        await expectCode(.invalidReference) { _ = try await b.nativeReference(for: leaf) }
        if service == .kavita { await expectCode(.invalidReference) { _ = try await b.prepareDownload(option) } }
        try f.state([:])
        try await b.source.connect(.apiToken("fixture-key"))
        await expectCode(.sessionExpired) { _ = try await b.details(for: leaf) }
        await expectCode(.sessionExpired) { _ = try await b.prepareDownload(option) }
        await b.close(); await b.source.disconnect()
    }

    @Test(arguments: NativeBrowserService.allCases)
    private func permissionsAndMissingArtwork(_ service: NativeBrowserService) async throws {
        let f = try await NativeBrowserFixture.start(); defer { f.stop() }
        try f.state(["noDownload": true])
        let b = try await browser(f, service)
        let leaf = try await firstLeaf(b)
        #expect(!leaf.capabilities.contains(.download))
        #expect(try await b.downloadOptions(for: leaf).isEmpty)
        try f.state(["missingCover": true])
        await expectCode(.notFound) { _ = try await b.artwork(for: leaf) }
        await b.close(); await b.source.disconnect()
    }

    @Test func kavitaReconnectDuringAncestorResolutionDoesNotContinueInNewSession() async throws {
        let f = try await NativeBrowserFixture.start(); defer { f.stop() }
        let b = try await browser(f, .kavita)
        let leaf = try await firstLeaf(b)
        try f.state(["delayPath": "/kavita/api/Series/chapter"])
        let operation = Task { try await b.nativeReference(for: leaf) }
        try await f.waitFor("delayed")
        let before = try f.requests().filter { $0.path == "/kavita/api/Series/volume" }.count
        try await b.source.connect(.apiToken("fixture-key"))
        try f.release()
        do { _ = try await operation.value; Issue.record("Old resolution unexpectedly survived reconnect") }
        catch { #expect(error is RemoteBrowserError) }
        let after = try f.requests().filter { $0.path == "/kavita/api/Series/volume" }.count
        #expect(before == after)
        await b.close(); await b.source.disconnect()
    }
}
#endif
