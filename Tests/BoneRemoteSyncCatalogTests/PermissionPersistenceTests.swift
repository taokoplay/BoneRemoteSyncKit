import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

@Suite struct PermissionPersistenceTests {
    @Test(arguments: Array(UInt(0)..<16))
    func selectedPermissionsSurviveDatabaseReopen(rawValue: UInt) async throws {
        let fixture = try CatalogFixture()
        let store = try fixture.store()
        let profile = try RemoteSourceProfile(displayName: "Local", configuration: .local(accessReference: "bookmark"),
            permission: RemoteAccessPermission(rawValue: rawValue))
        #expect(profile.permission == RemoteAccessPermission(rawValue: rawValue).union(.readOnly))
        try await store.saveProfile(profile)
        try await store.close()
        let reopened = try fixture.store()
        #expect(try await reopened.profile(id: profile.id) == profile)
        #expect(try await reopened.profiles().first?.permission == profile.permission)
        try await reopened.close()
    }

    @Test(arguments: ["readOnly", "editor", "missing", "null"])
    func profilesRejectRoleStringsAndMissingPermissions(value: String) async throws {
        let profile = try RemoteSourceProfile(displayName: "Invalid", configuration: .local(accessReference: "bookmark"))
        let fixture = try CatalogFixture()
        let store = try fixture.store()
        try await store.saveProfile(profile)
        try await store.close()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        if value == "missing" { json.removeValue(forKey: "permission") }
        else if value == "null" { json["permission"] = NSNull() }
        else { json["permission"] = value }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteSourceProfile.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(profile.permission == .readOnly)
        let payload = try JSONSerialization.data(withJSONObject: json)
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        try fixture.sql("UPDATE source_profiles SET payload=X'\(hex)'")
        let reopened = try fixture.store()
        await #expect(throws: RemoteCatalogError.invalidConfiguration) { try await reopened.profile(id: profile.id) }
        await #expect(throws: RemoteCatalogError.invalidConfiguration) { try await reopened.profiles() }
        try await reopened.close()
    }

    @Test(arguments: Array(UInt(0)..<16))
    func decodedProfilesRestoreRequiredReadPermission(rawValue: UInt) throws {
        let profile = try RemoteSourceProfile(displayName: "Decoded", configuration: .local(accessReference: "bookmark"))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let selection = RemoteAccessPermission(rawValue: rawValue)
        json["permission"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection))
        let decoded = try JSONDecoder().decode(RemoteSourceProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.permission == selection.union(.readOnly))
    }

    @Test func savedCombinationIsEnforcedByCatalogSession() async throws {
        let fixture = try CatalogFixture()
        let store = try fixture.store()
        let credentials = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let factory = RemoteCatalogSessionFactory(credentials: credentials,
            localResolver: TestAccessResolver(url: fixture.directory, probe: ReleaseProbe()))
        let catalog = RemoteCatalog(store: store, sessions: factory)
        let profile = try await catalog.saveSource(displayName: "Read and create", configuration: .local(accessReference: "bookmark"),
            permission: .create)
        #expect(try await catalog.store.profiles().first?.permission == [.readOnly, .create])
        let session = try await factory.open(profile: store.profile(id: profile.id))
        let writable = try #require(session.source as? any RemoteWritableSource)
        try await writable.makeDirectory(path: "/created")
        #expect(try await session.source.stat(path: "/created").isDirectory)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/created")) { try await writable.remove(path: "/created") }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/created")) { try await writable.move(from: "/created", to: "/moved") }
        #expect(!session.source.capabilities.remove && !session.source.capabilities.move)
        await session.close()
        let defaultProfile = try await catalog.saveSource(displayName: "Default", configuration: .local(accessReference: "default"))
        #expect(defaultProfile.permission == .readOnly)
        let defaultSession = try await factory.open(profile: defaultProfile)
        #expect(try await defaultSession.source.stat(path: "/").isDirectory)
        let defaultWritable = try #require(defaultSession.source as? any RemoteWritableSource)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/denied")) {
            try await defaultWritable.makeDirectory(path: "/denied")
        }
        #expect(!defaultSession.source.capabilities.upload && !defaultSession.source.capabilities.remove)
        await defaultSession.close()
        try await store.close()
    }
}
