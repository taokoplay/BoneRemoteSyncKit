#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncContent
import BoneRemoteSyncKavita
import BoneRemoteSyncTestSupport

@Suite(.enabled(if: PythonFixture.isAvailable, "Requires Python 3"))
struct KavitaBrowsingTests {
    @Test func passwordLoginVerifiesAccountAndRefreshesExplicitly() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.basic(username: "fixture-user", password: "fixture-password"))
        #expect(try await source.connectedUserID() == 42)
        #expect(try await source.account().roles == ["Login", "Download"])
        let tokens = try #require(await source.currentTokens())
        #expect(tokens.accessToken == "fixture-jwt" && tokens.refreshToken == "fixture-refresh")
        #expect(!String(reflecting: tokens).contains("fixture-jwt"))
        #expect(!String(describing: tokens).contains("fixture-refresh"))
        #expect(Mirror(reflecting: tokens).children.count == 1)
        let chapter = try await source.chapterReference(chapterID: 34)
        let oldBinding = try await source.sourceBinding()
        let fresh = try await source.refreshTokens()
        #expect(fresh.accessToken == "refreshed-jwt" && fresh.refreshToken == "refreshed-refresh")
        #expect(try await source.sourceBinding() != oldBinding)
        await #expect(throws: ContentServerError.invalidReference) { try await source.progress(chapter) }
        _ = try await source.libraries()
        let login = try #require(server.requests("Account/login").first)
        #expect(login["authorization"] is NSNull)
        #expect((login["body"] as? [String: String]) == ["username": "fixture-user", "password": "fixture-password"])
        let accounts = try server.requests("Account")
        #expect(accounts.count == 2)
        #expect(accounts[0]["authorization"] as? String == "Bearer fixture-jwt")
        #expect(accounts[1]["authorization"] as? String == "Bearer refreshed-jwt")
        #expect(try server.requests("Account/refresh-token").count == 1)
        await source.disconnect()
    }

    @Test func apiKeyUsesHeaderAndPreservesMountAndInputKey() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.apiToken("fixture-key"), expectedUserID: 42)
        #expect(try await source.currentTokens() == nil)
        #expect(source.kind == .kavita && !source.capabilities.list && source.capabilities.stat && source.capabilities.download)
        #expect(try await source.libraries().first?.name == "Books")
        for request in try server.requests() {
            #expect(request["key"] as? String == "fixture-key")
            #expect(request["authorization"] is NSNull)
            #expect((request["path"] as? String)?.hasPrefix("/kavita/api/") == true)
            #expect((request["query"] as? [String: String])?["apiKey"] == nil)
        }
        #expect(try server.requests("Account/login").isEmpty)
        await #expect(throws: RemoteSyncError.self) { try await source.refreshTokens() }
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/") }
        await source.disconnect()
    }

    @Test func explicitJWTAndExpectedIdentityAndAuthenticationErrors() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source()
        try await source.connectJWT(.init(accessToken: "fixture-jwt", refreshToken: "fixture-refresh"), expectedUserID: 42)
        #expect(try await source.connectedUserID() == 42)
        await #expect(throws: ContentServerError.identityChanged) {
            try await source.connect(.apiToken("other-key"), expectedUserID: 42)
        }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.connectedUserID() }
        await #expect(throws: RemoteSyncError.self) { try await source.connect(.apiToken("invalid-fictional-key")) }
        await #expect(throws: RemoteSyncError.self) {
            try await source.connect(.basic(username: "fixture-user", password: "wrong"))
        }
        #expect(try server.requests("Account/login").count == 1)
        await source.disconnect()
    }

    @Test func paginationSearchHierarchyAndMetadata() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let first = try await source.series(libraryID: 1, pageSize: 2)
        #expect(first.page == 0 && first.pageSize == 2 && first.total == 3 && first.hasNextPage)
        #expect(first.items.map(\.id) == [12, 13])
        #expect(first.items[1].format.rawValue == 91)
        let last = try await source.series(libraryID: 1, page: 1, pageSize: 2)
        #expect(last.items.map(\.id) == [14] && !last.hasNextPage)
        let search = try await source.searchSeries("  Fixture & 星  ", libraryID: 1, pageSize: 2)
        #expect(search.items.count == 2)
        let body = try #require(server.requests("Series/v2").last?["body"] as? [String: Any])
        let statements = try #require(body["statements"] as? [[String: Any]])
        #expect(statements[2]["value"] as? String == "Fixture & 星")
        #expect(statements[2]["comparison"] as? Int == 7)
        let empty = try await source.searchSeries("empty", libraryID: 1)
        #expect(empty.items.isEmpty && empty.total == 0 && !empty.hasNextPage)
        let details = try await source.series(seriesID: 12)
        #expect(details.wordCount == 5_000_000_000 && details.originalName == "Original")
        let volumes = try await source.volumes(seriesID: 12)
        #expect(volumes.count == 1 && volumes[0].minNumber == 1.5)
        #expect(try await source.volume(volumeID: 23).chapters.count == 4)
        let chapter = try await source.chapter(chapterID: 34)
        #expect(chapter.minNumber == 1.5 && chapter.summary == "Fixture summary")
        #expect(chapter.wordCount == 5_000_000_001 && chapter.writers?.first?.name == "Writer")
        #expect(chapter.writers?.first?.roles?.isEmpty == true)
        #expect(chapter.genres?.first?.title == "Adventure" && chapter.language == "en")
        #expect(chapter.files[0].name == "book.epub")
        #expect(!String(reflecting: chapter).contains("/secret/server"))
        #expect(!String(reflecting: details).contains("/private/server"))
        let reference = try await source.chapterReference(chapterID: 34)
        #expect(reference.libraryID == 1 && reference.seriesID == 12 && reference.volumeID == 23 && reference.chapterID == 34)
        #expect(try await source.bookInfo(reference).bookTitle == "Fixture book")
        let toc = try await source.bookChapters(reference)
        #expect(toc[0].page == 0 && toc[0].children?.first?.page == 1)
        await source.disconnect()
    }

    @Test(arguments: ["missing", "malformed", "wrongPage", "wrongSize", "wrongTotal", "negative", "partial", "duplicate", "wrongLibrary"])
    func invalidPaginationIsNotAnUnboundedList(_ failure: String) async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        try server.configure(["pagination": failure])
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        await #expect(throws: ContentServerError.invalidResponse) { try await source.series(libraryID: 1, pageSize: 2) }
        #expect(try server.requests("Series/v2").count == 1)
        await source.disconnect()
    }

    @Test func invalidInputsFailBeforeNetworkAndMalformedDetailsFail() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let before = try server.requests().count
        await #expect(throws: ContentServerError.self) { try await source.series(libraryID: 0) }
        await #expect(throws: ContentServerError.self) { try await source.series(libraryID: 1, page: -1) }
        await #expect(throws: ContentServerError.self) { try await source.series(libraryID: 1, pageSize: 0) }
        await #expect(throws: ContentServerError.self) { try await source.series(libraryID: 1, pageSize: 501) }
        await #expect(throws: ContentServerError.self) { try await source.searchSeries(" \n ", libraryID: 1) }
        await #expect(throws: ContentServerError.self) { try await source.chapter(chapterID: Int.max) }
        #expect(try server.requests().count == before)
        try server.configure(["malformedChapter": true])
        await #expect(throws: ContentServerError.invalidResponse) { try await source.chapter(chapterID: 34) }
        try server.configure(["wrongChapterID": true])
        await #expect(throws: ContentServerError.invalidResponse) { try await source.chapter(chapterID: 34) }
        await source.disconnect()
    }
}
#endif
