import Foundation
import Testing
import SQLite3
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

final class CatalogFixture: @unchecked Sendable {
    let directory: URL
    let url: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("catalog.sqlite")
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func store() throws -> SQLiteRemoteCatalogStore { try .init(databaseURL: url) }
    func sql(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw RemoteCatalogError.database(SQLITE_CANTOPEN) }
        defer { sqlite3_close(db) }
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw RemoteCatalogError.database(result) }
    }
}

@Suite struct ProfilePersistenceTests {
    @Test func profilesAndSelectionsSurviveReopenWithoutConnecting() async throws {
        let fixture = try CatalogFixture()
        let store = try fixture.store()
        let profiles = try [
            RemoteSourceProfile(displayName: "本地", configuration: .local(accessReference: "bookmark-1")),
            RemoteSourceProfile(displayName: "NAS", configuration: .webDAV(baseURL: URL(string: "https://example.invalid/dav/")!), credentialReference: UUID()),
            RemoteSourceProfile(displayName: "云盘", configuration: .oneDrive(clientID: "app-id", redirectURI: URL(string: "test://oauth")!, driveID: "D"), credentialReference: UUID())
        ]
        var selections: [RemoteCatalogRoot] = []
        for p in profiles {
            try await store.saveProfile(p)
            let root = try RemoteCatalogRoot(sourceID: p.id, bindingID: p.bindingID, path: "/资料 %_", entryID: "provider-id")
            selections.append(root); try await store.saveRoot(root)
            let page = try await store.listCached(rootID: root.id, directory: root.path)
            #expect(page.state == .notInitialized)
            #expect(page.entries.isEmpty && page.lastSuccessfulAt == nil)
        }
        try await store.close()
        let reopened = try fixture.store()
        for (p, root) in zip(profiles, selections) {
            #expect(try await reopened.profile(id: p.id) == p)
            #expect(try await reopened.root(id: root.id) == root)
        }
        #expect(try await reopened.profiles().count == 3)
        try await reopened.close()
    }

    @Test func invalidConfigurationIsRejectedIncludingDecodedValues() throws {
        let invalid: [RemoteSourceConfiguration] = [
            .local(accessReference: ""), .local(accessReference: "bad\0ref"),
            .webDAV(baseURL: URL(string: "https://user:secret@example.invalid/dav/")!),
            .webDAV(baseURL: URL(string: "file:///tmp/")!),
            .webDAV(baseURL: URL(string: "https://example.invalid/?password=x")!),
            .webDAV(baseURL: URL(string: "https://example.invalid/")!, timeout: .infinity),
            .webDAV(baseURL: URL(string: "https://example.invalid/")!, retry: .init(maxAttempts: 2)),
            .oneDrive(clientID: "", redirectURI: URL(string: "x://oauth")!, driveID: "D"),
            .oneDrive(clientID: "client", redirectURI: URL(string: "x://oauth")!, driveID: "")
        ]
        for configuration in invalid {
            #expect(throws: RemoteCatalogError.invalidConfiguration) {
                try RemoteSourceProfile(displayName: "Test", configuration: configuration)
            }
        }
        #expect(throws: RemoteCatalogError.invalidConfiguration) {
            try RemoteSourceProfile(displayName: "Cloud", configuration: .oneDrive(clientID: "app", redirectURI: URL(string: "x://oauth")!, driveID: "D"))
        }
        for path in ["relative", "/a/../b", "/a\\b", "/x\0y"] {
            #expect(throws: RemoteCatalogError.invalidPath) { try RemoteCatalogRoot(sourceID: UUID(), bindingID: UUID(), path: path, entryID: "id") }
        }
    }

    @Test func revisionsRejectLostUpdatesAndRequireNewBindingForAccountChanges() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store()
        let p = try RemoteSourceProfile(displayName: "A", configuration: .local(accessReference: "one"))
        try await store.saveProfile(p)
        let invalid = try RemoteSourceProfile(id: p.id, bindingID: p.bindingID, configurationRevision: 2, displayName: "B", configuration: .local(accessReference: "two"))
        await #expect(throws: RemoteCatalogError.invalidConfiguration) { try await store.saveProfile(invalid, expectedRevision: 1) }
        let replacement = try RemoteSourceProfile(id: p.id, configurationRevision: 2, displayName: "B", configuration: .local(accessReference: "two"))
        await #expect(throws: RemoteCatalogError.staleRevision) { try await store.saveProfile(replacement, expectedRevision: 0) }
        try await store.saveProfile(replacement, expectedRevision: 1)
        #expect(try await store.profile(id: p.id) == replacement)
        try await store.close()
    }
}

@Suite struct SQLiteStoreTests {
    @Test func unknownSchemaIsNotRecreated() throws {
        let fixture = try CatalogFixture()
        try fixture.sql("CREATE TABLE marker(value TEXT); INSERT INTO marker VALUES ('preserve'); PRAGMA user_version=999;")
        let before = try Data(contentsOf: fixture.url)
        #expect(throws: RemoteCatalogError.unsupportedSchema) { try fixture.store() }
        #expect(try Data(contentsOf: fixture.url) == before)
    }
    @Test func corruptDatabaseIsNotErased() throws {
        let fixture = try CatalogFixture(); let bytes = Data("not-a-database-preserve-me".utf8)
        try bytes.write(to: fixture.url)
        #expect(throws: RemoteCatalogError.self) { try fixture.store() }
        #expect(try Data(contentsOf: fixture.url) == bytes)
    }
    @Test func secondOwnerAndClosedStoreAreRejected() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store()
        #expect(throws: RemoteCatalogError.busy) { try fixture.store() }
        try await store.close()
        await #expect(throws: RemoteCatalogError.closed) { try await store.profiles() }
        let reopened = try fixture.store(); try await reopened.close()
    }
}
