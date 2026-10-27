import Foundation
import Testing
@testable import BoneRemoteSyncCatalog

@Suite struct CatalogIsolationReviewTests {
    @Test func retiredBindingCannotResurrectCachedAccount() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let old = try await store.profile(id: root.sourceID)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/private-old")])
        let next = try RemoteSourceProfile(id: old.id, configurationRevision: 2, displayName: "Next", configuration: .local(accessReference: "B"))
        try await store.saveProfile(next, expectedRevision: 1)
        for config in [old.configuration, .local(accessReference: "C")] {
            let reused = try RemoteSourceProfile(id: old.id, bindingID: old.bindingID, configurationRevision: 3, displayName: "Invalid reuse", configuration: config)
            await #expect(throws: RemoteCatalogError.invalidConfiguration) { try await store.saveProfile(reused, expectedRevision: 2) }
        }
        await #expect(throws: RemoteCatalogError.staleRevision) { try await store.listCached(rootID: root.id, directory: "/") }
        try await store.close()
    }
    @Test func oldBindingIndexCanBeClearedOfflineWithoutRemovingNewProfile() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/private-old")])
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        let ticket = try await store.beginDirectory(run: run, path: "/")
        try await store.stage([catalogEntry("/unpublished")], ticket: ticket)
        let next = try RemoteSourceProfile(id: root.sourceID, configurationRevision: 2, displayName: "New", configuration: .local(accessReference: "B"))
        try await store.saveProfile(next, expectedRevision: 1)
        try await store.clearIndex(rootID: root.id)
        #expect(try await store.profile(id: root.sourceID) == next)
        #expect(try await store.roots(sourceID: root.sourceID).map(\.id) == [root.id])
        let rows = try await store.perform { db in
            try ["catalog_entries", "refresh_runs", "staged_entries"].map { try db.scalar("SELECT count(*) FROM \($0)") }
        }
        #expect(rows == [0, 0, 0])
        await #expect(throws: RemoteCatalogError.staleRevision) { try await store.listCached(rootID: root.id, directory: "/") }
        await #expect(throws: RemoteCatalogError.staleRevision) { try await store.publish(ticket: ticket, permit: .init()) }
        try await store.close()
    }
    @Test func longValidPathCanConsumeItsOwnPageToken() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store()
        let path = "/" + String(repeating: "a", count: 7000)
        let root = try await fixture.selected(store, path: path)
        try await seed(store, root: root, path: path, entries: [catalogEntry(path + "/a"), catalogEntry(path + "/b")])
        let first = try await store.listCached(rootID: root.id, directory: path, query: .init(limit: 1))
        let second = try await store.listCached(rootID: root.id, directory: path, query: .init(limit: 1, pageToken: first.nextPageToken))
        #expect(second.entries.map(\.name) == ["b"])
        try await store.close()
    }
    @Test func reselectRootAfterRebindingUsesNewSelectionRevision() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets, localResolver: TestAccessResolver(url: fixture.directory, probe: ReleaseProbe())))
        _ = try await catalog.saveSource(displayName: "New", configuration: .local(accessReference: "new"), replacing: root.sourceID, expectedRevision: 1)
        let selected = try await catalog.selectRoot(sourceID: root.sourceID, path: "/", replacing: root.id, expectedRevision: 1)
        #expect(selected.id == root.id && selected.selectionRevision == 2 && selected.bindingID != root.bindingID)
        #expect(try await store.listCached(rootID: root.id, directory: "/").state == .notInitialized)
        try await store.close()
    }
    @Test func cancellationDuringTransactionRollsBackBeforeFinalCommit() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let permit = CatalogCommitPermit()
        await #expect(throws: CancellationError.self) {
            try await store.perform { db in
                try db.transaction(permit: permit) {
                    try db.execute("UPDATE catalog_directories SET version=5 WHERE root=?", [.uuid(root.id)])
                    permit.cancel()
                }
            }
        }
        #expect(try await store.listCached(rootID: root.id, directory: "/").version == 0)
        try await store.close()
    }
}
