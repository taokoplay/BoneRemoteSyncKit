import Foundation
import Testing
@testable import BoneRemoteSyncCatalog

@Suite struct CatalogStatusTests {
    @Test func finishedAndInterruptedRunStatusSurvivesReopening() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store(); let root = try await fixture.selected(store)
        #expect(try await store.status(rootID: root.id).latestRun == nil)
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .subtree)
        let ticket = try await store.beginDirectory(run: run, path: "/")
        try await store.stage([catalogEntry("/a")], ticket: ticket)
        _ = try await store.publish(ticket: ticket, permit: .init())
        try await store.finishRun(run, state: "success")
        let success = try await store.status(rootID: root.id)
        #expect(success.lastFullSubtreeSuccessfulAt != nil && success.latestRun?.state == "success")
        #expect(success.latestRun?.publishedDirectories == 1 && success.latestRun?.publishedEntries == 1)
        _ = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        try await store.close()
        let reopened = try fixture.store(); let interrupted = try await reopened.status(rootID: root.id)
        #expect(interrupted.latestRun?.state == "interrupted" && interrupted.latestRun?.finishedAt != nil)
        #expect(interrupted.lastFullSubtreeSuccessfulAt == success.lastFullSubtreeSuccessfulAt)
        try await reopened.close()
    }
    @Test func configurationChangeCompletesInterruptedRunAndDiscardsStaging() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store(); let root = try await fixture.selected(store)
        let old = try await store.profile(id: root.sourceID)
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .children)
        let ticket = try await store.beginDirectory(run: run, path: "/")
        try await store.stage([catalogEntry("/unpublished")], ticket: ticket)
        let updated = try RemoteSourceProfile(id: old.id, bindingID: old.bindingID, configurationRevision: 2,
            displayName: "Renamed", configuration: old.configuration)
        try await store.saveProfile(updated, expectedRevision: 1)
        let status = try await store.status(rootID: root.id)
        #expect(status.latestRun?.state == "interrupted")
        #expect(status.latestRun?.finishedAt != nil)
        let staging = try await store.perform { db in
            try db.scalar("SELECT count(*) FROM staged_entries") + db.scalar("SELECT count(*) FROM refresh_directories WHERE state='staging'")
        }
        #expect(staging == 0)
        await #expect(throws: RemoteCatalogError.staleRevision) { try await store.publish(ticket: ticket, permit: .init()) }
        try await store.finishRun(run, state: "failed")
        #expect(try await store.status(rootID: root.id).latestRun?.state == "interrupted")
        try await store.close()
        let reopened = try fixture.store()
        #expect(try await reopened.status(rootID: root.id).latestRun?.finishedAt == status.latestRun?.finishedAt)
        try await reopened.close()
    }
    @Test func failureReasonIsPersistedWithoutUnderlyingMessage() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets))
        _ = try await catalog.refresh(rootID: root.id)
        let status = try await store.status(rootID: root.id)
        #expect(status.latestRun?.failures.first?.reason == .authorization)
        #expect(status.latestRun?.state == "failed")
        try await store.close()
    }
}
