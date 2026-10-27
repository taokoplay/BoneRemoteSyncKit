#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

@Suite struct OneDriveIDAddressingTests {
    @Test func stableIDSurvivesRenameAndDownloadsWithoutOldPath() async throws {
        let server = try OneDriveTestServer("renamed"); defer { server.cleanUp() }
        let concrete = server.source(); let source: any RemoteIDAddressableSource = concrete
        try await source.connect(server.credential)
        let original = try await source.stat(path: "/old-name.bin")
        let current = try await source.stat(id: original.id)
        #expect(current.id == original.id)
        #expect(current.name == "renamed.bin")
        #expect(current.path == nil)
        #expect(source.capabilities.idAddressing)
        let result = try await source.download(id: current.id, to: server.file("output"))
        #expect(result.path == nil)
        #expect(try Data(contentsOf: server.file("output")).count == 1048576)
        let calls = try server.requests().compactMap { $0["path"] as? String }
        #expect(calls.filter { $0.contains("root:/old-name.bin") }.count == 1)
        #expect(calls.filter { $0 == "/v1.0/drives/D/items/file" }.count >= 3)
        await source.disconnect()
    }

    @Test func parentIDPaginationReturnsNoInventedPathsAndKeepsCursorBinding() async throws {
        let server = try OneDriveTestServer("three-pages"); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let root = try await source.stat(path: "/")
        let first = try await source.list(parentID: root.id, request: .init(limit: 2))
        #expect(first.entries.count == 2)
        #expect(first.entries.allSatisfy { $0.path == nil })
        let cursor = try #require(first.nextCursor)
        let count = try server.requests().count
        for invalid in [RemoteListRequest(cursor: cursor, limit: 3), RemoteListRequest(cursor: cursor, limit: 2, includeHidden: true)] {
            await #expect(throws: RemoteSyncError.self) { try await source.list(parentID: root.id, request: invalid) }
        }
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/", request: .init(cursor: cursor, limit: 2)) }
        let folder = try #require(first.entries.first { $0.isDirectory })
        await #expect(throws: RemoteSyncError.self) { try await source.list(parentID: folder.id, request: .init(cursor: cursor, limit: 2)) }
        #expect(try server.requests().count == count)
        let second = try await source.list(parentID: root.id, request: .init(cursor: cursor, limit: 2))
        #expect(second.entries.map(\.name) == ["middle.txt"])
        #expect(second.entries.allSatisfy { $0.path == nil })
        await #expect(throws: RemoteSyncError.self) { try await source.list(parentID: root.id, request: .init(cursor: cursor, limit: 2)) }
        let third = try await source.list(parentID: root.id, request: .init(cursor: second.nextCursor, limit: 2))
        #expect(third.entries.map(\.name) == ["last.txt"])
        #expect(third.isLastPage)
        let pathPage = try await source.list(path: "/")
        await #expect(throws: RemoteSyncError.self) { try await source.list(parentID: root.id, request: .init(cursor: pathPage.nextCursor)) }
        let old = try await source.list(parentID: root.id)
        try await source.connect(server.credential)
        await #expect(throws: RemoteSyncError.self) { try await source.list(parentID: root.id, request: .init(cursor: old.nextCursor)) }
        await source.disconnect()
    }

    @Test func wrongIDsFailBeforeNetworkAndFilesCannotBeListed() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }
        let source = server.source()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(id: "bad") }
        try await source.connect(server.credential)
        let count = try server.requests().count
        for id in ["file", "/file", "onedrive:bad", ODLocation.identity(drive: "other", item: "file")] {
            await #expect(throws: RemoteSyncError.self) { try await source.stat(id: id) }
            await #expect(throws: RemoteSyncError.self) { try await source.list(parentID: id) }
        }
        #expect(try server.requests().count == count)
        await #expect(throws: RemoteSyncError.self) { try await source.list(parentID: ODLocation.identity(drive: "D", item: "file")) }
        let missing = ODLocation.identity(drive: "D", item: "missing")
        await #expect(throws: RemoteSyncError.self) { try await source.stat(id: missing) }
        await source.disconnect()
    }

    @Test(arguments: ["evil-next", "other-next", "duplicate", "bad-name", "remote"])
    func unsafeIDPagesFailClosed(scenario: String) async throws {
        let server = try OneDriveTestServer(scenario); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        await #expect(throws: RemoteSyncError.self) { try await source.list(parentID: ODLocation.identity(drive: "D", item: "root")) }
        await source.disconnect()
    }
}
#endif
