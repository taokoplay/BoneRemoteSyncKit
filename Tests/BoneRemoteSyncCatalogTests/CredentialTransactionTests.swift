import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

@Suite struct CredentialTransactionTests {
    @Test func newBindingSecretIsExclusiveAndDatabaseFailureDoesNotDamageOldSecret() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store()
        let backend = MemorySecurityBackend(); let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: backend)
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets))
        let config = RemoteSourceConfiguration.webDAV(baseURL: URL(string: "https://example.invalid/dav/")!)
        let original = try await catalog.saveSource(displayName: "NAS", configuration: config, credential: .basic(username: "user", password: "ORIGINAL_SECRET"))
        let originalRef = try #require(original.credentialReference)
        try await store.perform { db in
            try db.script("CREATE TRIGGER reject_profile_update BEFORE UPDATE ON source_profiles BEGIN SELECT RAISE(ABORT,'injected'); END;")
        }
        await #expect(throws: RemoteCatalogError.self) {
            try await catalog.saveSource(displayName: "New", configuration: config, credential: .basic(username: "other", password: "NEW_SECRET"), replacing: original.id, expectedRevision: 1)
        }
        #expect(try secrets.read(reference: originalRef) == .basic(username: "user", password: "ORIGINAL_SECRET"))
        #expect(try await store.profile(id: original.id) == original)
        // Token rotation is independent of DB bookkeeping. Never undo a safely saved rotated credential.
        let handle = CatalogCredentialHandle(reference: originalRef, store: secrets)
        try handle.replace(.basic(username: "user", password: "ROTATED_SECRET"))
        await #expect(throws: RemoteCatalogError.self) {
            let update = try RemoteSourceProfile(id: original.id, bindingID: original.bindingID, configurationRevision: 2,
                displayName: "Rename", configuration: config, credentialReference: originalRef)
            try await store.saveProfile(update, expectedRevision: 1)
        }
        #expect(try secrets.read(reference: originalRef) == .basic(username: "user", password: "ROTATED_SECRET"))
        try await store.close()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fixture.url.path + suffix)
            if let bytes = try? Data(contentsOf: url) {
                for marker in ["ORIGINAL_SECRET", "NEW_SECRET", "ROTATED_SECRET"] { #expect(bytes.range(of: Data(marker.utf8)) == nil) }
            }
        }
    }
    @Test func restartDoesNotGarbageCollectUnknownOrphanSecrets() async throws {
        let fixture = try CatalogFixture(); let backend = MemorySecurityBackend()
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: backend)
        let orphan = UUID(); try secrets.insert(.apiToken("orphan"), reference: orphan)
        let store = try fixture.store(); try await store.close()
        let reopened = try fixture.store()
        #expect(try secrets.read(reference: orphan) == .apiToken("orphan"))
        try await reopened.close()
    }
}
