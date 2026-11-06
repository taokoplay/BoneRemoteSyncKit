#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncContent
import BoneRemoteSyncKavita
import BoneRemoteSyncTestSupport

@Suite(.enabled(if: PythonFixture.isAvailable, "Requires Python 3"))
struct KavitaLifecycleTests {
    @Test(arguments: ["Account/login", "Account"])
    func pendingConnectCannotPublishAfterReconnect(_ delayed: String) async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source()
        try server.configure(["delayPath": delayed])
        let old = Task { try await source.connect(.basic(username: "fixture-user", password: "fixture-password")) }
        try await server.waitForRequest(delayed)
        await #expect(throws: RemoteSyncError.notConnected) { try await source.libraries() }
        await source.disconnect()
        try server.configure([:])
        try await source.connect(.apiToken("other-key"))
        try server.release()
        await #expect(throws: (any Error).self) { try await old.value }
        #expect(try await source.connectedUserID() == 43)
        #expect(try await source.currentTokens() == nil)
        #expect(try await source.libraries().count == 1)
        await source.disconnect()
    }

    @Test func canceledLoginLeavesNoConnectedSession() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source()
        try server.configure(["delayPath": "Account/login"])
        let login = Task { try await source.connect(.basic(username: "fixture-user", password: "fixture-password")) }
        try await server.waitForRequest("Account/login")
        login.cancel()
        await #expect(throws: (any Error).self) { try await login.value }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.connectedUserID() }
        try server.configure([:]); try server.release()
        try await source.connect(.apiToken("fixture-key"))
        #expect(try await source.connectedUserID() == 42)
        await source.disconnect()
    }

    @Test func delayedMetadataCannotEscapeOldConnection() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        try server.configure(["delayPath": "Library/libraries"])
        let reading = Task { try await source.libraries() }
        try await server.waitForRequest("Library/libraries")
        try server.configure([:])
        try await source.connect(.apiToken("other-key"))
        try server.release()
        await #expect(throws: (any Error).self) { try await reading.value }
        #expect(try await source.connectedUserID() == 43)
        await source.disconnect()
    }

    @Test(arguments: [false, true])
    func canceledOrReconnectedDownloadDoesNotInstall(_ reconnect: Bool) async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let chapter = try await source.chapterReference(chapterID: 34)
        let reference = try await source.prepareDownload(chapter)
        let entry = try await kavitaEntry(source, reference)
        let destination = server.file("cancelled.epub")
        try server.configure(["delayPath": "Download/chapter"])
        let download = Task { try await source.download(entry, to: destination) }
        try await server.waitForRequest("Download/chapter")
        if reconnect {
            try await source.connect(.apiToken("other-key"))
        } else {
            download.cancel()
        }
        await #expect(throws: (any Error).self) { try await download.value }
        try server.configure([:]); try server.release()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let freshChapter = try await source.chapterReference(chapterID: 34)
        let freshFile = try await source.prepareDownload(freshChapter)
        let freshEntry = try await kavitaEntry(source, freshFile)
        _ = try await source.download(freshEntry, to: destination)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: server.file("raw.epub")))
        await source.disconnect()
    }

    @Test func refreshIsSerializedAndDisconnectCancelsIt() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source()
        try await source.connectJWT(.init(accessToken: "fixture-jwt", refreshToken: "fixture-refresh"))
        try server.configure(["delayPath": "Account/refresh-token"])
        let refreshing = Task { try await source.refreshTokens() }
        try await server.waitForRequest("Account/refresh-token")
        await #expect(throws: RemoteSyncError.rateLimited(retryAfter: nil)) { try await source.refreshTokens() }
        await source.disconnect()
        try server.configure([:])
        try await source.connect(.apiToken("other-key"))
        try server.release()
        await #expect(throws: (any Error).self) { try await refreshing.value }
        #expect(try await source.connectedUserID() == 43)
        #expect(try await source.currentTokens() == nil)
        #expect(try server.requests("Account/refresh-token").count == 1)
        await source.disconnect()
    }

    @Test func refreshCannotChangeIdentity() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source()
        try await source.connectJWT(.init(accessToken: "fixture-jwt", refreshToken: "fixture-refresh"))
        try server.configure(["refreshIdentity": true])
        await #expect(throws: ContentServerError.identityChanged) { try await source.refreshTokens() }
        #expect(try await source.connectedUserID() == 42)
        #expect(try await source.currentTokens()?.accessToken == "fixture-jwt")
        #expect(try server.requests("Account/refresh-token").count == 1)
        await source.disconnect()
    }

    @Test func chapterReferenceIsNotPortableToAnotherSource() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(), other = try server.source()
        try await source.connect(.apiToken("fixture-key"))
        try await other.connect(.apiToken("fixture-key"))
        let chapter = try await source.chapterReference(chapterID: 34)
        await #expect(throws: ContentServerError.invalidReference) { try await other.updateProgress(chapter, pageNum: 1) }
        #expect(try server.requests("Reader/progress").isEmpty)
        await source.disconnect(); await other.disconnect()
    }
}
#endif
