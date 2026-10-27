import Foundation
import Testing
@testable import BoneRemoteSyncCatalog

actor GatedResolver: RemoteLocalAccessResolver {
    let url: URL
    var calls = 0
    var delay: UInt64 = 0
    init(_ url: URL) { self.url = url }
    func setDelay(_ value: UInt64) { delay = value }
    func resolve(reference: String) async throws -> RemoteLocalAccessLease {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return try .init(rootURL: url, release: {})
    }
}

@Suite struct CatalogIntegrationTests {
    @Test func publicRefreshCachesLocalTreeAndReopensOffline() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let upstream = fixture.directory.appendingPathComponent("upstream")
        try FileManager.default.createDirectory(at: upstream.appendingPathComponent("child"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: upstream.appendingPathComponent("child/file.txt"))
        let store = try fixture.store()
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let resolver = GatedResolver(upstream)
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets, localResolver: resolver))
        let profile = try await catalog.saveSource(displayName: "Local", configuration: .local(accessReference: "bookmark"))
        let root = try await catalog.selectRoot(sourceID: profile.id, path: "/", defaultScope: .subtree)
        let report = try await catalog.refresh(rootID: root.id)
        #expect(report.state == .success && report.publishedDirectories == 2 && report.publishedEntries == 2)
        #expect(try await catalog.listCached(rootID: root.id, directory: "/child").entries.map(\.name) == ["file.txt"])
        let calls = await resolver.calls
        try await store.close()
        let reopened = try fixture.store()
        #expect(try await reopened.listCached(rootID: root.id, directory: "/child").state == .current)
        #expect(await resolver.calls == calls)
        try await reopened.close()
    }
    @Test func rootIsSingleFlightAndTimeoutPreservesCache() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store()
        let secrets = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let resolver = GatedResolver(fixture.directory)
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: secrets, localResolver: resolver))
        let profile = try await catalog.saveSource(displayName: "Local", configuration: .local(accessReference: "bookmark"))
        let root = try await catalog.selectRoot(sourceID: profile.id, path: "/")
        await resolver.setDelay(5_000_000_000)
        let task = Task { try await catalog.refresh(rootID: root.id, options: .init(timeout: 0.1)) }
        for _ in 0..<100 { if await resolver.calls == 2 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        await #expect(throws: RemoteCatalogError.busy) { try await catalog.refresh(rootID: root.id) }
        let report = try await task.value
        #expect(report.state == .failed && report.publishedDirectories == 0)
        #expect(report.failures.first?.reason.rawValue == "deadline")
        #expect(try await store.listCached(rootID: root.id, directory: "/").state == .notInitialized)
        await resolver.setDelay(0)
        #expect(try await catalog.refresh(rootID: root.id).state == .success)
        try await store.close()
    }
}
