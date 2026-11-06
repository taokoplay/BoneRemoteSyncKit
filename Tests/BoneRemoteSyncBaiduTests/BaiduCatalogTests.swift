#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncBaidu
@testable import BoneRemoteSyncCatalog

private final class BaiduMemoryCredentials: RemoteCredentialStore, @unchecked Sendable {
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

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python3")) struct BaiduCatalogTests {
    @Test func profileRefreshOfflineIndexAndReadOnlyPermission() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let credentials = BaiduMemoryCredentials()
        let factory = RemoteCatalogSessionFactory(credentials: credentials, baiduSourceFactory: { config, refresh in
            BaiduDriveSource(configuration: config, endpoints: server.endpoints, refreshToken: refresh)
        })
        let store = try SQLiteRemoteCatalogStore(databaseURL: server.file("catalog.sqlite"))
        let catalog = RemoteCatalog(store: store, sessions: factory)
        let profile = try await catalog.saveSource(displayName: "百度测试", configuration: .baidu(configuration: server.configuration, userID: "111"), credential: server.credential)
        #expect(profile.permission == .readOnly && profile.configuration.provider == .baidu)
        let encoded = try JSONEncoder().encode(profile)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("fixture-token"))
        #expect(try JSONDecoder().decode(RemoteSourceProfile.self, from: encoded) == profile)
        let root = try await catalog.selectRoot(sourceID: profile.id, path: "/")
        let report = try await catalog.refresh(rootID: root.id, options: .init(scope: .subtree))
        #expect(report.state == .success)
        let cached = try await catalog.listCached(rootID: root.id, directory: "/")
        #expect(cached.entries.count == 3)
        let session = try await factory.open(profile: profile)
        let writable = try #require(session.source as? any RemoteWritableSource)
        await #expect(throws: RemoteSyncError.self) { try await writable.remove(path: "/a.txt") }
        await session.close()
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "filemanager" })
        try await store.close()
        let reopened = try SQLiteRemoteCatalogStore(databaseURL: server.file("catalog.sqlite"))
        #expect(try await reopened.profile(id: profile.id).configuration == profile.configuration)
        try await reopened.close()
    }
    @Test func wrongAccountStopsBeforeRootMetadata() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let credentials = BaiduMemoryCredentials(), reference = UUID()
        try credentials.insert(server.credential, reference: reference)
        let factory = RemoteCatalogSessionFactory(credentials: credentials, baiduSourceFactory: { config, refresh in
            BaiduDriveSource(configuration: config, endpoints: server.endpoints, refreshToken: refresh)
        })
        let profile = try RemoteSourceProfile(displayName: "Wrong", configuration: .baidu(configuration: server.configuration, userID: "222"), credentialReference: reference)
        await #expect(throws: RemoteCatalogError.identityChanged) { try await factory.open(profile: profile) }
        #expect(try server.requests().count == 1)
    }
    @Test func refreshSavesRotatedCredentialToFixedReference() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let credentials = BaiduMemoryCredentials(), reference = UUID()
        try credentials.insert(.oauth(accessToken: "expired", refreshToken: "old", expiresAt: .distantPast), reference: reference)
        let factory = RemoteCatalogSessionFactory(credentials: credentials, baiduTokenRefresher: { config, uid, old in
            #expect(config == server.configuration && uid == "111" && old.refreshToken == "old")
            return try .init(accessToken: "new", refreshToken: "next", expiresAt: .distantFuture)
        }, baiduSourceFactory: { config, refresh in BaiduDriveSource(configuration: config, endpoints: server.endpoints, refreshToken: refresh) })
        let profile = try RemoteSourceProfile(displayName: "Refresh", configuration: .baidu(configuration: server.configuration, userID: "111"), credentialReference: reference)
        let session = try await factory.open(profile: profile)
        #expect(try credentials.read(reference: reference) == .oauth(accessToken: "new", refreshToken: "next", expiresAt: .distantFuture))
        await session.close()
    }
}
#endif
