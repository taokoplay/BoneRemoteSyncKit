import Foundation
import Testing
@testable import BoneRemoteSyncCatalog

@Suite struct CatalogRecoveryTests {
    @Test func restartKeepsPublishedDirectoryDiscardsStagingAndInterruptsRun() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/dir", directory: true)])
        try await seed(store, root: root, path: "/dir", entries: [catalogEntry("/dir/old")])
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .subtree)
        let parent = try await store.beginDirectory(run: run, path: "/")
        try await store.stage([catalogEntry("/dir", directory: true), catalogEntry("/new")], ticket: parent)
        _ = try await store.publish(ticket: parent, permit: .init())
        let child = try await store.beginDirectory(run: run, path: "/dir")
        try await store.stage([catalogEntry("/dir/uncommitted")], ticket: child)
        // Reopen with an unfinished run simulates interruption state, not hardware power-loss durability.
        try await store.close()
        let reopened = try fixture.store()
        #expect(try await reopened.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["dir", "new"])
        let cached = try await reopened.listCached(rootID: root.id, directory: "/dir")
        #expect(cached.entries.map(\.name) == ["old"] && cached.state == .stale)
        let counts = try await reopened.perform { db in
            [try db.scalar("SELECT count(*) FROM staged_entries"),
             try db.scalar("SELECT count(*) FROM refresh_runs WHERE state='interrupted' AND ended IS NOT NULL"),
             try db.scalar("SELECT count(*) FROM refresh_directories WHERE state='staging'")]
        }
        #expect(counts == [0, 1, 0])
        let next = try await reopened.beginRun(rootID: root.id, path: "/", scope: .children)
        try await reopened.finishRun(next, state: "cancelled")
        try await reopened.close()
    }
    @Test func connectionFailureMarksExistingCacheStaleWithoutChangingEntries() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/old")])
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets)) // no Local resolver
        let report = try await catalog.refresh(rootID: root.id)
        #expect(report.state == .failed && report.failures.first?.reason == .authorization)
        let cached = try await store.listCached(rootID: root.id, directory: "/")
        #expect(cached.state == .stale && cached.lastAttemptAt != nil && cached.entries.map(\.name) == ["old"])
        try await store.close()
    }
}
