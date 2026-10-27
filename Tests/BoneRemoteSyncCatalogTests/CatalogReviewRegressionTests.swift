import Foundation
import Darwin
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

@Suite struct CatalogReviewRegressionTests {
    @Test func rebindWhileSharedReferenceActiveMustNotRevokeItsRotation() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store()
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets))
        let config = RemoteSourceConfiguration.webDAV(baseURL: URL(string: "https://example.invalid/")!)
        let original = try await catalog.saveSource(displayName: "A", configuration: config, credential: .basic(username: "a", password: "old"))
        let reference = try #require(original.credentialReference)
        let peer = try RemoteSourceProfile(bindingID: original.bindingID, displayName: "B", configuration: config, credentialReference: reference)
        try await store.saveProfile(peer)
        let handle = try CatalogCredentialCoordinator.shared.acquire(store: secrets, reference: reference)
        defer { CatalogCredentialCoordinator.shared.release(handle) }
        await #expect(throws: RemoteCatalogError.busy) {
            try await catalog.saveSource(displayName: "NewA", configuration: config, credential: .basic(username: "new", password: "new"), replacing: original.id, expectedRevision: 1)
        }
        try handle.replace(.basic(username: "a", password: "rotated"))
        #expect(try secrets.read(reference: reference) == .basic(username: "a", password: "rotated"))
        #expect(try await store.profile(id: original.id) == original)
        try await store.close()
    }
    @Test func newBindingCannotReuseOldCredentialEvenWithoutPeers() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let reference = UUID()
        let old = try RemoteSourceProfile(displayName: "Cloud", configuration: .oneDrive(clientID: "client1", redirectURI: URL(string: "x://auth")!, driveID: "D"), credentialReference: reference)
        try await store.saveProfile(old)
        let new = try RemoteSourceProfile(id: old.id, configurationRevision: 2, displayName: "Cloud", configuration: .oneDrive(clientID: "client2", redirectURI: URL(string: "x://auth")!, driveID: "D"), credentialReference: reference)
        await #expect(throws: RemoteCatalogError.invalidConfiguration) { try await store.saveProfile(new, expectedRevision: 1) }
        #expect(try await store.profile(id: old.id) == old)
        try await store.close()
    }
    // Supplemental validation of the reviewed overflow guard; no intentional process crash is used.
    @Test func invalidSelectionRevisionsFailBeforeResolvingAccess() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let probe = ReleaseProbe()
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets, localResolver: TestAccessResolver(url: fixture.directory, probe: probe)))
        for revision: Int64 in [.max, -1, 0] {
            await #expect(throws: RemoteCatalogError.staleRevision) {
                try await catalog.selectRoot(sourceID: root.sourceID, path: "/", replacing: root.id, expectedRevision: revision)
            }
        }
        #expect(probe.count == 0)
        try await store.close()
    }
    @Test func hardLinkedDatabaseIsRejectedBeforeOpeningAnotherWAL() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store()
        defer { withExtendedLifetime(fixture) {} }
        let profile = try RemoteSourceProfile(displayName: "Preserved", configuration: .local(accessReference: "local"))
        try await store.saveProfile(profile)
        try await store.close()
        let alias = fixture.directory.appendingPathComponent("alias.sqlite")
        // Creating a hard link to an already-open SQLite file violates the host ownership contract.
        // Test admission using a closed database instead; this also covers aliases before any owner exists.
        #expect(Darwin.link(fixture.url.path, alias.path) == 0)
        #expect(throws: RemoteCatalogError.invalidConfiguration) { try SQLiteRemoteCatalogStore(databaseURL: alias) }
        #expect(throws: RemoteCatalogError.invalidConfiguration) { try fixture.store() }
        #expect(!FileManager.default.fileExists(atPath: alias.path + "-wal"))
        #expect(Darwin.unlink(alias.path) == 0)
        let reopened = try fixture.store()
        #expect(try await reopened.profile(id: profile.id) == profile)
        try await reopened.close()
    }
}
