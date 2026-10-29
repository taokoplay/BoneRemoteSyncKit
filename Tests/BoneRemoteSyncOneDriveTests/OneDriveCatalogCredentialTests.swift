#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive
@testable import BoneRemoteSyncCatalog

private final class TestCredentialMemory: RemoteCredentialStore, @unchecked Sendable {
    let coordinationID = UUID().uuidString
    private let lock = NSLock()
    private var values: [UUID: RemoteCredential] = [:]
    func read(reference: UUID) throws -> RemoteCredential? { lock.withLock { values[reference] } }
    func insert(_ credential: RemoteCredential, reference: UUID) throws {
        try lock.withLock { guard values[reference] == nil else { throw RemoteCredentialStoreError.alreadyExists }; values[reference] = credential }
    }
    func replace(_ credential: RemoteCredential, reference: UUID) throws {
        try lock.withLock { guard values[reference] != nil else { throw RemoteCredentialStoreError.missing }; values[reference] = credential }
    }
    func remove(reference: UUID) throws { _ = lock.withLock { values.removeValue(forKey: reference) } }
}
@Suite(.serialized, .enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveCatalogCredentialTests {
    // Supplemental integration of the actual OneDrive callback with Catalog's fixed-reference handle.
    // Endpoint injection stays inside the adapter's test target, not in the public session factory.
    @Test func rotationIsPersistedOnceAndSurvivesLaterCatalogFailure() async throws {
        let server = try OneDriveTestServer("refresh-slow"); defer { server.cleanUp() }
        let credentials = TestCredentialMemory(); let reference = UUID()
        try credentials.insert(.oauth(accessToken: "OLD", refreshToken: "REFRESH", expiresAt: .distantPast), reference: reference)
        let coordinator = CatalogCredentialCoordinator.shared
        let handle = try coordinator.acquire(store: credentials, reference: reference)
        defer { coordinator.release(handle) }
        let source = server.source { try handle.replace($0.credential) }
        try await source.connect(try #require(try credentials.read(reference: reference)))
        #expect(try await source.connectedDriveID() == "D")
        #expect(throws: RemoteCatalogError.busy) { try coordinator.acquire(store: credentials, reference: reference) }
        let stored = try #require(try credentials.read(reference: reference))
        guard case .oauth(let access, let refresh, let expiry) = stored else { Issue.record("Expected complete OAuth record"); return }
        #expect(access == "NEW" && refresh == "ROTATED" && expiry != nil)
        let database = try SQLiteRemoteCatalogStore(databaseURL: server.file("catalog.sqlite"))
        let profile = try RemoteSourceProfile(displayName: "Fixture", configuration: .oneDrive(clientID: "fixture-client", redirectURI: server.configuration.redirectURI, driveID: "D"), credentialReference: reference)
        try await database.saveProfile(profile)
        try await database.close()
        await #expect(throws: RemoteCatalogError.closed) { try await database.saveProfile(profile) }
        #expect(try credentials.read(reference: reference) == stored)
        await source.disconnect()
        coordinator.release(handle)
        let next = try coordinator.acquire(store: credentials, reference: reference)
        let restored = server.source { try next.replace($0.credential) }
        try await restored.connect(stored)
        await restored.disconnect(); coordinator.release(next)
        #expect(try server.requests().filter { ($0["path"] as? String)?.contains("/token") == true }.count == 1)
        #expect(try credentials.read(reference: reference) == stored)
    }
    @Test func revokedHandleCannotRecreateCredentialDuringRefresh() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }
        let credentials = TestCredentialMemory(); let reference = UUID()
        let old = RemoteCredential.oauth(accessToken: "OLD", refreshToken: "REFRESH", expiresAt: .distantPast)
        try credentials.insert(old, reference: reference)
        let coordinator = CatalogCredentialCoordinator.shared
        let handle = try coordinator.acquire(store: credentials, reference: reference)
        let source = server.source { try handle.replace($0.credential) }
        try coordinator.revoke(store: credentials, reference: reference, remove: true)
        await #expect(throws: RemoteSyncError.self) { try await source.connect(old) }
        #expect(try credentials.read(reference: reference) == nil)
        await source.disconnect(); coordinator.release(handle)
    }
}
#endif
