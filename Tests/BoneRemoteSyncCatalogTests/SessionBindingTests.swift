import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

final class ReleaseProbe: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
struct TestAccessResolver: RemoteLocalAccessResolver {
    let url: URL
    let probe: ReleaseProbe
    func resolve(reference: String) async throws -> RemoteLocalAccessLease {
        try RemoteLocalAccessLease(rootURL: url) { probe.record() }
    }
}

@Suite struct SessionBindingTests {
    @Test func localLeaseCoversSessionAndReleasesExactlyOnce() async throws {
        let fixture = try CatalogFixture(); let backend = MemorySecurityBackend()
        let credentials = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: backend)
        let probe = ReleaseProbe(); let resolver = TestAccessResolver(url: fixture.directory, probe: probe)
        let factory = RemoteCatalogSessionFactory(credentials: credentials, localResolver: resolver)
        let profile = try RemoteSourceProfile(displayName: "Local", configuration: .local(accessReference: "bookmark"))
        let session = try await factory.open(profile: profile)
        #expect(probe.count == 0)
        #expect(try await session.source.stat(path: "/").isDirectory)
        await session.close(); await session.close()
        #expect(probe.count == 1)
        let failing = RemoteCatalogSessionFactory(credentials: credentials, localResolver: TestAccessResolver(url: fixture.directory.appendingPathComponent("missing"), probe: probe))
        await #expect(throws: RemoteSyncError.self) { try await failing.open(profile: profile) }
        #expect(probe.count == 2)
    }
    @Test func sharedCredentialReferenceAllowsOnlyOneActiveOwnerAcrossFactories() throws {
        let backend = MemorySecurityBackend(); let service = "test.\(UUID())"
        let a = try KeychainRemoteCredentialStore(service: service, backend: backend)
        let b = try KeychainRemoteCredentialStore(service: service, backend: backend)
        let reference = UUID(); try a.insert(.apiToken("first"), reference: reference)
        let coordinator = CatalogCredentialCoordinator.shared
        let first = try coordinator.acquire(store: a, reference: reference)
        #expect(throws: RemoteCatalogError.busy) { try coordinator.acquire(store: b, reference: reference) }
        try first.replace(.apiToken("rotated"))
        coordinator.release(first)
        let second = try coordinator.acquire(store: b, reference: reference)
        #expect(try b.read(reference: reference) == .apiToken("rotated"))
        #expect(throws: RemoteCredentialStoreError.revoked) { try first.replace(.apiToken("old-late")) }
        try coordinator.revoke(store: b, reference: reference, remove: true)
        #expect(throws: RemoteCredentialStoreError.revoked) { try second.replace(.apiToken("late")) }
        // Revocation does not permit another source while the old source is still active.
        #expect(throws: RemoteCatalogError.busy) { try coordinator.acquire(store: a, reference: reference) }
        coordinator.release(second)
        #expect(try a.read(reference: reference) == nil)
    }
    @Test func missingSecretsRequireAuthorizationBeforeConnecting() async throws {
        let backend = MemorySecurityBackend(); let credentials = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: backend)
        let factory = RemoteCatalogSessionFactory(credentials: credentials)
        let profile = try RemoteSourceProfile(displayName: "Cloud", configuration: .oneDrive(clientID: "app", redirectURI: URL(string: "test://auth")!, driveID: "D"), credentialReference: UUID())
        await #expect(throws: RemoteCatalogError.needsAuthorization) { try await factory.open(profile: profile) }
    }
}
