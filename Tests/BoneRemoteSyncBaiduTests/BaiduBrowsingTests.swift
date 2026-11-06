#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncBaidu

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python3")) struct BaiduBrowsingTests {
    @Test(arguments: ["normal", "string-ids", "nested-list"])
    func pagedListAndIDMetadata(_ scenario: String) async throws {
        let server = try BaiduTestServer(scenario); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        #expect(try await source.connectedUserID() == "111")
        let first = try await source.list(path: "/", request: .init(limit: 2))
        #expect(first.entries.count == 1 && first.coverage == .complete)
        let cursor = try #require(first.nextCursor)
        let second = try await source.list(path: "/", request: .init(cursor: cursor, limit: 2))
        #expect(second.entries.count == 2 && second.nextCursor != nil)
        let last = try await source.list(path: "/", request: .init(cursor: second.nextCursor, limit: 2))
        #expect(last.entries.isEmpty && last.nextCursor == nil)
        let file = try await source.stat(path: "/文档 +?.txt")
        #expect(file.id.hasSuffix(":9007199254741005"))
        #expect(file.createdAt != nil && file.modifiedAt != nil && file.etag == nil && file.contentChecksums == nil)
        #expect(try await source.stat(id: file.id) == file)
        let folder = try await source.stat(path: "/folder")
        #expect(try await source.list(parentID: folder.id).entries.count == 1)
        await #expect(throws: BaiduDriveError.invalidCursor) { try await source.list(path: "/", request: .init(cursor: cursor, limit: 2)) }
        await source.disconnect()
    }
    @Test func cursorsAndIDsAreScoped() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let page = try await source.list(path: "/", request: .init(limit: 1))
        let id = try await source.stat(path: "/a.txt").id
        let cursor = try #require(page.nextCursor)
        await #expect(throws: BaiduDriveError.invalidCursor) { try await source.list(path: "/folder", request: .init(cursor: cursor, limit: 1)) }
        await #expect(throws: BaiduDriveError.invalidCursor) { try await source.list(path: "/", request: .init(cursor: cursor, limit: 2)) }
        try await source.connect(.apiToken("other-user"))
        await #expect(throws: BaiduDriveError.invalidReference) { try await source.stat(id: id) }
        await #expect(throws: BaiduDriveError.invalidCursor) { try await source.list(path: "/", request: .init(cursor: cursor, limit: 1)) }
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/", request: .init(limit: 0)) }
        await source.disconnect()
    }
    @Test func abandonedCursorsEvictOldestWithoutBlockingNewListings() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let source = BaiduDriveSource(configuration: server.configuration, endpoints: server.endpoints, cursorCapacity: 2)
        try await source.connect(server.credential)
        let first = try await source.list(path: "/", request: .init(limit: 1))
        let second = try await source.list(path: "/", request: .init(limit: 1))
        let oldest = try #require(first.nextCursor), retained = try #require(second.nextCursor)
        let third = try await source.list(path: "/", request: .init(limit: 1))
        let newest = try #require(third.nextCursor)
        // Reads that need no cursor still succeed while the store is full.
        #expect(try await source.list(path: "/folder").entries.count == 1)
        await #expect(throws: BaiduDriveError.invalidCursor) {
            try await source.list(path: "/", request: .init(cursor: oldest, limit: 1))
        }
        #expect(try await source.list(path: "/", request: .init(cursor: retained, limit: 1)).entries.count == 1)
        #expect(try await source.list(path: "/", request: .init(cursor: newest, limit: 1)).entries.count == 1)
        await #expect(throws: BaiduDriveError.invalidCursor) {
            try await source.list(path: "/", request: .init(cursor: retained, limit: 1))
        }
        await source.disconnect()
    }
    @Test(arguments: ["outside-list", "duplicate-list", "list-error", "huge"])
    func malformedAndFailedListingsNeverBecomeEmptySuccess(_ scenario: String) async throws {
        let server = try BaiduTestServer(scenario); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        await #expect(throws: (any Error).self) { try await source.list(path: "/") }
        await source.disconnect()
    }
    @Test func duplicateLaterPageAndPartialCoverageAreDetected() async throws {
        let server = try BaiduTestServer("duplicate-page"); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let first = try await source.list(path: "/", request: .init(limit: 2))
        await #expect(throws: BaiduDriveError.invalidResponse) { try await source.list(path: "/", request: .init(cursor: first.nextCursor, limit: 2)) }
        await source.disconnect()
        let partial = try BaiduTestServer("partial"); defer { partial.cleanUp() }
        let other = partial.source(); try await other.connect(partial.credential)
        #expect(try await other.list(path: "/").coverage == .partial)
        await other.disconnect()
    }
    @Test(arguments: ["auth", "rate-limit", "api-redirect"])
    func connectionFailsWithoutPublishingSession(_ scenario: String) async throws {
        let server = try BaiduTestServer(scenario); defer { server.cleanUp() }
        let source = server.source()
        await #expect(throws: (any Error).self) { try await source.connect(server.credential) }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.list(path: "/") }
    }
    @Test func disconnectedResponseCannotCrossIntoNewSession() async throws {
        let server = try BaiduTestServer("slow-list"); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let task = Task { try await source.list(path: "/") }
        try await server.waitFor("list")
        await source.disconnect(); try await source.connect(.apiToken("other-user"))
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try await source.connectedUserID() == "222")
        await source.disconnect()
    }
}
#endif
