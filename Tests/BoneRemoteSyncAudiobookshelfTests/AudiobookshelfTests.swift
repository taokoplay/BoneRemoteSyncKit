#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncContent
import BoneRemoteSyncAudiobookshelf
import BoneRemoteSyncTransfer
import BoneRemoteSyncTestSupport

@Suite(.enabled(if: PythonFixture.isAvailable, "Requires local Python 3 HTTP fixture"))
struct AudiobookshelfTests {
    private func source(_ fixture: ABSFixture, references: Int = 256) throws -> AudiobookshelfSource {
        AudiobookshelfSource(configuration: try .init(baseURL: fixture.baseURL, allowsInsecureHTTP: true,
            timeout: 5, maxConcurrentRequests: 3, maxDownloadReferences: references))
    }
    private func connected(_ fixture: ABSFixture) async throws -> AudiobookshelfSource {
        let source = try source(fixture)
        try await source.connect(.apiToken("fixture-api"), expectedUserID: "user-1")
        return source
    }
    private func path(_ reference: RemoteFileReference) throws -> String {
        guard case .path(let path) = reference.locator else { throw ContentServerError.invalidReference }
        return path
    }

    @Test func loginUsesModernTokensAndVerifiesIdentity() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try source(f)
        try await s.connect(.basic(username: "fixture-reader", password: "fixture-password"), expectedUserID: "user-1")
        #expect(try await s.connectedUserID() == "user-1")
        let user = try await s.currentUser()
        #expect(user.permissions.download)
        #expect(!String(reflecting: user).contains("legacy-token"))
        let tokens = try #require(await s.authenticationTokens())
        #expect(tokens.accessToken == "fixture-access")
        #expect(tokens.refreshToken == "fixture-refresh")
        #expect(!String(describing: tokens).contains("fixture-access"))
        #expect(!String(reflecting: tokens).contains("fixture-refresh"))
        let log = try f.requests()
        #expect(log[0].path == "/abs/login")
        #expect(log[0].returnTokens == "true")
        #expect(log[0].authorization == nil)
        #expect(log[0].body?["username"] == .string("fixture-reader"))
        #expect(log[0].body?["password"] == .string("fixture-password"))
        #expect(log.dropFirst().allSatisfy { $0.authorization == "Bearer fixture-access" })
        #expect(log.allSatisfy { !$0.path.contains("token=") })
        await s.disconnect()
    }

    @Test func staticTokenAndExpectedAccountGuard() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try await connected(f)
        #expect(try f.requests().first?.authorization == "Bearer fixture-api")
        let first = try await s.sourceBinding()
        try await s.connect(.apiToken("fixture-api"), expectedUserID: "user-1")
        #expect(try await s.sourceBinding() != first)
        await #expect(throws: ContentServerError.identityChanged) {
            try await s.connect(.apiToken("fixture-api"), expectedUserID: "other-user")
        }
        await #expect(throws: RemoteSyncError.notConnected) { try await s.connectedUserID() }
        await s.disconnect()
    }

    @Test func loginUserMustMatchMe() async throws {
        let f = try await ABSFixture.start(mode: "login-identity"); defer { f.stop() }
        let s = try source(f)
        await #expect(throws: ContentServerError.identityChanged) {
            try await s.connect(.basic(username: "fixture-reader", password: "fixture-password"))
        }
        await #expect(throws: RemoteSyncError.notConnected) { try await s.libraries() }
    }

    @Test func browseSearchDetailsAndCoverPreserveMount() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try await connected(f)
        let libraries = try await s.libraries()
        #expect(libraries.map(\.id) == ["lib-books", "lib-podcasts"])
        let first = try await s.items(libraryID: "lib-books", page: 0, pageSize: 1)
        let last = try await s.items(libraryID: "lib-books", page: 1, pageSize: 1)
        let beyond = try await s.items(libraryID: "lib-books", page: 2, pageSize: 1)
        #expect(first.hasNextPage && first.total == 2 && first.page == 0)
        #expect(last.items.first?.id == "book-2" && !last.hasNextPage)
        #expect(beyond.items.isEmpty && !beyond.hasNextPage)
        #expect(first.items.first?.files == nil)
        let search = try await s.search(libraryID: "lib-books", query: "  Fixture & chapter  ", limit: 3)
        #expect(search.books.first?.id == "book-1")
        #expect(search.podcasts.isEmpty)
        let book = try await s.item(id: "book-1")
        #expect(book.metadata.authors?.first?.name == "A. Writer")
        #expect(book.metadata.narrators == ["A. Reader"])
        #expect(book.metadata.series?.first?.sequence == "1")
        #expect(book.tracks?.map(\.fileID) == ["101", "102"])
        #expect(book.chapters?.first?.end == 60)
        #expect(!String(reflecting: book).contains("/srv/private"))
        let episode = try await s.episode(itemID: "podcast-1", episodeID: "episode-1")
        #expect(episode.audioFile?.id == "201" && episode.publishedAt == 1_700_000_000_000)
        let podcasts = try await s.search(libraryID: "lib-podcasts", query: "Fixture & chapter")
        #expect(podcasts.podcasts.first?.episodes?.count == 1)
        let cover = try await s.cover(itemID: "book-1", width: 200)
        #expect(cover.starts(with: [137, 80, 78, 71]))
        #expect(try f.requests().allSatisfy { $0.path.hasPrefix("/abs/") && $0.authorization == "Bearer fixture-api" })
        await s.disconnect()
    }

    @Test func concreteFilesMaterializeAndRejectForgedOrStaleEntries() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try await connected(f)
        let reference = try await s.prepareDownload(itemID: "book-1", fileID: "102")
        let entry = try await s.stat(path: path(reference))
        #expect(entry.name == "102.mp3" && entry.size == Int64(Data("ID3fixture-audio".utf8).count))
        #expect(entry.etag == nil && entry.modifiedAt == nil)
        let materializer = RemoteFileMaterializer(source: s, sourceBinding: try await s.sourceBinding(),
            cacheDirectory: f.directory.appendingPathComponent("cache", isDirectory: true))
        let lease = try await materializer.materialize(reference)
        #expect(try Data(contentsOf: lease.url) == Data("ID3fixture-audio".utf8))
        await lease.release()
        await materializer.shutdown()
        let destination = f.directory.appendingPathComponent("forged.mp3")
        let forged = RemoteEntry(id: entry.id, path: entry.path, name: "changed.mp3", type: .file, size: entry.size)
        await #expect(throws: ContentServerError.invalidReference) { try await s.download(forged, to: destination) }
        await #expect(throws: Error.self) {
            try await s.download(entry, to: destination, options: .init(resumeFrom: 0))
        }
        await #expect(throws: ContentServerError.invalidReference) {
            try await s.prepareDownload(itemID: "book-1", fileID: "missing")
        }
        let trackRef = try await s.prepareTrackDownload(itemID: "book-1", trackIndex: 1)
        #expect(try await s.stat(path: path(trackRef)).name == "101.mp3")
        let log = try f.requests()
        #expect(log.contains { $0.path == "/abs/api/items/book-1/file/102/download" })
        #expect(log.allSatisfy { $0.method == "GET" })
        try await s.connect(.apiToken("fixture-api"))
        await #expect(throws: Error.self) { try await s.stat(path: path(reference)) }
        await #expect(throws: Error.self) { try await s.download(entry, to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        await s.disconnect()
    }

    @Test func explicitProgressReadWriteForBookAndEpisode() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try await connected(f)
        #expect(try await s.mediaProgress(itemID: "book-1") == nil)
        try await s.updateMediaProgress(itemID: "book-1", update: .init(currentTime: 12, duration: 60, progress: 0.2))
        let saved = try #require(await s.mediaProgress(itemID: "book-1"))
        #expect(saved.currentTime == 12 && saved.progress == 0.2 && saved.userId == "user-1")
        try await s.updateMediaProgress(itemID: "podcast-1", episodeID: "episode-1", update: .init(isFinished: true))
        let ep = try #require(await s.mediaProgress(itemID: "podcast-1", episodeID: "episode-1"))
        #expect(ep.episodeId == "episode-1" && ep.isFinished)
        let patches = try f.requests().filter { $0.method == "PATCH" }
        #expect(patches.count == 2)
        #expect(patches[0].body?["currentTime"] == .number(12))
        #expect(patches[1].body == ["isFinished": .bool(true)])
        let count = try f.requests().count
        await #expect(throws: Error.self) { try await s.updateMediaProgress(itemID: "book-1", update: .init(currentTime: .nan)) }
        await #expect(throws: Error.self) { try await s.updateMediaProgress(itemID: "book-1", update: .init(progress: 1.1)) }
        await #expect(throws: Error.self) { try await s.updateMediaProgress(itemID: "book-1", update: .init()) }
        #expect(try f.requests().count == count)
        await s.disconnect()
    }

    @Test func directPlaybackRequestsSyncAndClose() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try await connected(f)
        let session = try await s.createPlaybackSession(itemID: "book-1")
        #expect(session.tracks.count == 2 && session.duration == 60)
        #expect(session.tracks[1].track.startOffset == 30)
        let request = session.tracks[0].request
        #expect(request.url.path == "/abs/api/items/book-1/file/101")
        #expect(request.headers["Authorization"] == "Bearer fixture-api")
        #expect(!String(reflecting: request).contains("fixture-api"))
        let hostTransport = URLSession(configuration: .ephemeral)
        defer { hostTransport.invalidateAndCancel() }
        let (bytes, _) = try await hostTransport.data(for: request.urlRequest())
        #expect(bytes == Data("ID3fixture-audio".utf8))
        try await s.syncPlaybackSession(session, update: .init(currentTime: 7, timeListened: 3, duration: 60))
        try await s.closePlaybackSession(session, update: .init(currentTime: 8, timeListened: 1))
        await #expect(throws: ContentServerError.invalidReference) {
            try await s.syncPlaybackSession(session, update: .init(currentTime: 8, timeListened: 0))
        }
        let writes = try f.requests().filter { $0.method == "POST" }
        #expect(writes.count == 3)
        #expect(writes[0].body?["forceDirectPlay"] == .bool(true))
        #expect(writes[1].path == "/abs/api/session/\(session.id)/sync")
        #expect(writes[1].body?["timeListened"] == .number(3))
        #expect(writes[2].path.hasSuffix("/close"))
        await s.disconnect()
    }

    @Test func podcastPlaybackAndOldSessionGuards() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try await connected(f)
        let old = try await s.createPlaybackSession(itemID: "book-1")
        let podcast = try await s.createPlaybackSession(itemID: "podcast-1", episodeID: "episode-1")
        #expect(podcast.episodeID == "episode-1" && podcast.tracks.first?.track.fileID == "201")
        await #expect(throws: ContentServerError.invalidReference) { try await s.closePlaybackSession(old) }
        let ref = try await s.prepareTrackDownload(itemID: "podcast-1", trackIndex: 1, episodeID: "episode-1")
        #expect(try await s.stat(path: path(ref)).name == "201.mp3")
        let other = try await connected(f)
        await #expect(throws: ContentServerError.invalidReference) { try await other.closePlaybackSession(podcast) }
        try await s.connect(.apiToken("fixture-api"))
        await #expect(throws: ContentServerError.invalidReference) { try await s.closePlaybackSession(podcast) }
        #expect(try f.requests().contains { $0.path == "/abs/api/items/podcast-1/play/episode-1" })
        await s.disconnect(); await other.disconnect()
    }

    @Test(arguments: ["transcode", "hls", "foreign-track", "session-identity"])
    func rejectsUnsafePlaybackResponses(mode: String) async throws {
        let f = try await ABSFixture.start(mode: mode); defer { f.stop() }
        let s = try await connected(f)
        await #expect(throws: Error.self) { try await s.createPlaybackSession(itemID: "book-1") }
        #expect(try f.requests().filter { $0.method == "POST" }.count == 1)
        await s.disconnect()
    }

    @Test(arguments: ["bad-page", "bad-search", "bad-item", "malformed", "unauthorized", "bad-progress", "bad-track-index"])
    func rejectsMalformedAndErrorResponses(mode: String) async throws {
        let f = try await ABSFixture.start(mode: mode); defer { f.stop() }
        let s = try await connected(f)
        switch mode {
        case "bad-page": await #expect(throws: Error.self) { try await s.items(libraryID: "lib-books") }
        case "bad-search": await #expect(throws: Error.self) { try await s.search(libraryID: "lib-books", query: "Fixture & chapter") }
        case "bad-item", "bad-track-index": await #expect(throws: Error.self) { try await s.item(id: "book-1") }
        case "bad-progress":
            try await s.updateMediaProgress(itemID: "book-1", update: .init(currentTime: 1))
            await #expect(throws: ContentServerError.invalidResponse) { try await s.mediaProgress(itemID: "book-1") }
        default: await #expect(throws: Error.self) { try await s.libraries() }
        }
        await s.disconnect()
    }

    @Test func validatesBoundsPermissionsAndReferenceLimit() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try source(f, references: 1)
        try await s.connect(.apiToken("fixture-api"))
        let count = try f.requests().count
        await #expect(throws: Error.self) { try await s.items(libraryID: "lib-books", page: -1) }
        await #expect(throws: Error.self) { try await s.items(libraryID: "lib-books", pageSize: 501) }
        await #expect(throws: Error.self) { try await s.search(libraryID: "lib-books", query: " ") }
        await #expect(throws: Error.self) { try await s.item(id: "../escape") }
        await #expect(throws: Error.self) { try await s.cover(itemID: "book-1", width: -1) }
        #expect(try f.requests().count == count)
        _ = try await s.prepareDownload(itemID: "book-1", fileID: "101")
        await #expect(throws: ContentServerError.resourceLimit) { try await s.prepareDownload(itemID: "book-1", fileID: "102") }
        await s.disconnect()
        let denied = try await ABSFixture.start(mode: "no-download"); defer { denied.stop() }
        let restricted = try await connected(denied)
        await #expect(throws: Error.self) { try await restricted.prepareDownload(itemID: "book-1", fileID: "101") }
        await restricted.disconnect()
    }

    @Test func cancelledRequestAndSupersededLoginDoNotResetNewConnection() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try await connected(f)
        let request = Task { try await s.item(id: "slow") }
        try await f.waitForRequest(containing: "/api/items/slow?")
        request.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await request.value }
        #expect(try await s.connectedUserID() == "user-1")
        let login = Task { try await s.connect(.basic(username: "slow-reader", password: "fixture-password")) }
        try await f.waitForRequest(containing: "/abs/login")
        await #expect(throws: RemoteSyncError.notConnected) { try await s.libraries() }
        try await s.connect(.apiToken("fixture-api"), expectedUserID: "user-1")
        await #expect(throws: Error.self) { try await login.value }
        #expect(try await s.connectedUserID() == "user-1")
        #expect(try await s.libraries().count == 2)
        await s.disconnect()
    }

    @Test func disconnectPreventsLateDownloadInstall() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = try await connected(f)
        let reference = try await s.prepareDownload(itemID: "slow-download", fileID: "101")
        let entry = try await s.stat(path: path(reference))
        let destination = f.directory.appendingPathComponent("keep.mp3")
        try Data("original".utf8).write(to: destination)
        let request = Task { try await s.download(entry, to: destination) }
        try await f.waitForRequest(containing: "/file/101/download")
        await s.disconnect()
        try await s.connect(.apiToken("fixture-api"))
        await #expect(throws: Error.self) { try await request.value }
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
        #expect(try await s.connectedUserID() == "user-1")
        await s.disconnect()
    }
    @Test func excludedAudioDoesNotBlockDetailsDownloadOrPlayback() async throws {
        let f = try await ABSFixture.start(mode: "excluded-audio"); defer { f.stop() }
        let s = try await connected(f)
        let item = try await s.item(id: "book-1")
        #expect(item.audioFiles?.first(where: { $0.id == "103" })?.index == -1)
        #expect(item.tracks?.map(\.fileID) == ["101", "102"])
        let reference = try await s.prepareTrackDownload(itemID: "book-1", trackIndex: 2)
        let entry = try await s.stat(path: path(reference))
        let destination = f.directory.appendingPathComponent("selected.mp3")
        _ = try await s.download(entry, to: destination)
        #expect(try Data(contentsOf: destination) == Data("ID3fixture-audio".utf8))
        let session = try await s.createPlaybackSession(itemID: "book-1")
        #expect(session.tracks.count == 2)
        try await s.closePlaybackSession(session)
        await s.disconnect()
    }

    @Test func closeRejectedBeforeAdmissionPreservesSessionHandle() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = AudiobookshelfSource(configuration: try .init(baseURL: f.baseURL, allowsInsecureHTTP: true,
            timeout: 5, maxConcurrentRequests: 1))
        try await s.connect(.apiToken("fixture-api"))
        let session = try await s.createPlaybackSession(itemID: "book-1")
        let blocker = Task { try await s.item(id: "slow") }
        try await f.waitForRequest(containing: "/api/items/slow?")
        await #expect(throws: RemoteSyncError.rateLimited(retryAfter: nil)) { try await s.closePlaybackSession(session) }
        #expect(try !f.requests().contains { $0.path.hasSuffix("/close") })
        _ = try await blocker.value
        try await s.syncPlaybackSession(session, update: .init(currentTime: 7, timeListened: 3))
        try await s.closePlaybackSession(session)
        #expect(try f.requests().filter { $0.path.hasSuffix("/close") }.count == 1)
        await s.disconnect()
    }

    @Test func closeCancelledDuringAdmissionWaitPreservesSessionHandle() async throws {
        let f = try await ABSFixture.start(); defer { f.stop() }
        let s = AudiobookshelfSource(configuration: try .init(baseURL: f.baseURL, allowsInsecureHTTP: true,
            timeout: 5, requestInterval: 0.4))
        try await s.connect(.apiToken("fixture-api"))
        let session = try await s.createPlaybackSession(itemID: "book-1")
        let closing = Task { try await s.closePlaybackSession(session) }
        try await Task.sleep(nanoseconds: 30_000_000)
        closing.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await closing.value }
        #expect(try !f.requests().contains { $0.path.hasSuffix("/close") })
        try await s.syncPlaybackSession(session, update: .init(currentTime: 7, timeListened: 3))
        try await s.closePlaybackSession(session)
        await s.disconnect()
    }

    @Test func submittedCloseFailureStillInvalidatesHandle() async throws {
        let f = try await ABSFixture.start(mode: "close-error"); defer { f.stop() }
        let s = try await connected(f)
        let session = try await s.createPlaybackSession(itemID: "book-1")
        await #expect(throws: RemoteSyncError.network("Content service HTTP 500")) { try await s.closePlaybackSession(session) }
        await #expect(throws: ContentServerError.invalidReference) { try await s.closePlaybackSession(session) }
        #expect(try f.requests().filter { $0.path.hasSuffix("/close") }.count == 1)
        await s.disconnect()
    }

}
#endif
