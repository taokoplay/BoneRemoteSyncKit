import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

@Suite struct DirectoryPublicationTests {
    @Test func stagingIsInvisibleAndPublicationChangesOnlyCompleteDirectory() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/old")])
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        let ticket = try await store.beginDirectory(run: run, path: "/")
        try await store.stage([catalogEntry("/new")], ticket: ticket)
        #expect(try await store.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["old"])
        #expect(try await store.publish(ticket: ticket, permit: .init()) == 1)
        #expect(try await store.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["new"])
        try await store.finishRun(run, state: "success")
        try await store.close()
        let reopened = try fixture.store()
        #expect(try await reopened.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["new"])
        try await reopened.close()
    }
    @Test func cancelledAndInvalidatedRunsCannotCommitAndFailedStagingKeepsOldVersion() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/old")])
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        let ticket = try await store.beginDirectory(run: run, path: "/")
        try await store.stage([catalogEntry("/new")], ticket: ticket)
        let permit = CatalogCommitPermit(); permit.cancel()
        await #expect(throws: CancellationError.self) { try await store.publish(ticket: ticket, permit: permit) }
        await #expect(throws: RemoteCatalogError.self) { try await store.stage([catalogEntry("/new")], ticket: ticket) }
        try await store.failDirectory(ticket: ticket)
        #expect(try await store.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["old"])
        try await store.clearIndex(rootID: root.id)
        await #expect(throws: RemoteCatalogError.self) { try await store.publish(ticket: ticket, permit: .init()) }
        #expect(try await store.listCached(rootID: root.id, directory: "/").state == .notInitialized)
        try await store.close()
    }
    @Test func databaseFaultRollsBackPublicationAndLateOldDirectoryCannotReappear() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/dir", directory: true)])
        try await seed(store, root: root, path: "/dir", entries: [catalogEntry("/dir/old")])
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .subtree)
        let old = try await store.beginDirectory(run: run, path: "/dir")
        try await store.stage([catalogEntry("/dir/late")], ticket: old)
        let parent = try await store.beginDirectory(run: run, path: "/")
        try await store.stage([catalogEntry("/new")], ticket: parent)
        try await store.perform { db in try db.script("CREATE TRIGGER fail_publish BEFORE UPDATE OF version ON catalog_directories BEGIN SELECT RAISE(ABORT,'fault'); END;") }
        await #expect(throws: RemoteCatalogError.self) { try await store.publish(ticket: parent, permit: .init()) }
        #expect(try await store.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["dir"])
        try await store.perform { db in try db.script("DROP TRIGGER fail_publish") }
        _ = try await store.publish(ticket: parent, permit: .init())
        await #expect(throws: RemoteCatalogError.self) { try await store.publish(ticket: old, permit: .init()) }
        await #expect(throws: RemoteCatalogError.notFound) { try await store.listCached(rootID: root.id, directory: "/dir") }
        try await store.finishRun(run, state: "partial")
        try await store.close()
    }
    @Test func metadataUnchangedDoesNotRewriteEntryRecord() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let entry = catalogEntry("/same")
        try await seed(store, root: root, path: "/", entries: [entry])
        try await store.perform { db in try db.script("CREATE TRIGGER reject_unchanged BEFORE UPDATE ON catalog_entries BEGIN SELECT RAISE(ABORT,'unnecessary write'); END;") }
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        let ticket = try await store.beginDirectory(run: run, path: "/")
        try await store.stage([entry], ticket: ticket)
        _ = try await store.publish(ticket: ticket, permit: .init())
        try await store.finishRun(run, state: "success")
        try await store.close()
    }
}
