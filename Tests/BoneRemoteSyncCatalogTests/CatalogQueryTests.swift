import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

extension CatalogFixture {
    func selected(_ store: SQLiteRemoteCatalogStore, path: String = "/") async throws -> RemoteCatalogRoot {
        let profile = try RemoteSourceProfile(displayName: "Fixture", configuration: .local(accessReference: UUID().uuidString))
        try await store.saveProfile(profile)
        let root = try RemoteCatalogRoot(sourceID: profile.id, bindingID: profile.bindingID, path: path, entryID: "root")
        try await store.saveRoot(root)
        return root
    }
}

// Query-layer tests seed records directly; end-to-end publication is tested separately.
func seed(_ store: SQLiteRemoteCatalogStore, root: RemoteCatalogRoot, path: String, entries: [RemoteEntry]) async throws {
    try await store.perform { db in
        try db.transaction {
            let parent = try db.rawDirectory(rootID: root.id, path: path)
            try db.execute("DELETE FROM catalog_entries WHERE root=? AND parent=?", [.uuid(root.id), .text(path)])
            for entry in entries {
                try db.execute("INSERT INTO catalog_entries(root,parent,parent_epoch,path,provider_id,directory,name,payload) VALUES(?,?,?,?,?,?,?,?)",
                    [.uuid(root.id), .text(path), .text(parent.epoch), .text(entry.path!), .text(entry.id),
                     .integer(entry.isDirectory ? 1 : 0), .text(entry.name), .blob(try CatalogValidation.encode(entry))])
                if entry.isDirectory {
                    try db.execute("INSERT OR REPLACE INTO catalog_directories(root,path,epoch,parent_epoch,provider_id) VALUES(?,?,?,?,?)",
                        [.uuid(root.id), .text(entry.path!), .uuid(UUID()), .text(parent.epoch), .text(entry.id)])
                }
            }
            try db.execute("UPDATE catalog_directories SET version=version+1,success=1234,attempt=1234,stale=0 WHERE root=? AND path=?",
                           [.uuid(root.id), .text(path)])
        }
    }
}
func catalogEntry(_ path: String, directory: Bool = false, id: String? = nil) -> RemoteEntry {
    .init(id: id ?? path, path: path, name: RemotePath.name(of: path), type: directory ? .directory : .file)
}

@Suite struct CatalogQueryTests {
    @Test func deterministicPagesAreBoundToDirectoryVersionAndQuery() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let entries = [catalogEntry("/z", directory: true), catalogEntry("/中"), catalogEntry("/A"), catalogEntry("/a"), catalogEntry("/%_")]
        try await seed(store, root: root, path: "/", entries: entries)
        let first = try await store.listCached(rootID: root.id, directory: "/", query: .init(limit: 2))
        #expect(first.state == .current && first.version == 1)
        #expect(first.entries.map(\.path) == ["/z", "/%_"])
        let token = try #require(first.nextPageToken)
        let second = try await store.listCached(rootID: root.id, directory: "/", query: .init(limit: 2, pageToken: token))
        #expect(second.entries.map(\.path) == ["/A", "/a"])
        let last = try await store.listCached(rootID: root.id, directory: "/", query: .init(limit: 2, pageToken: second.nextPageToken))
        #expect(last.entries.map(\.path) == ["/中"] && last.nextPageToken == nil)
        await #expect(throws: RemoteCatalogError.invalidPageToken) {
            try await store.listCached(rootID: root.id, directory: "/", query: .init(limit: 3, pageToken: token))
        }
        try await seed(store, root: root, path: "/", entries: [])
        await #expect(throws: RemoteCatalogError.invalidPageToken) {
            try await store.listCached(rootID: root.id, directory: "/", query: .init(limit: 2, pageToken: token))
        }
        let empty = try await store.listCached(rootID: root.id, directory: "/")
        #expect(empty.state == .current && empty.entries.isEmpty && empty.lastSuccessfulAt != nil)
        try await store.close()
    }
    @Test func rootsAreIsolatedAndClearingOnlyIndexKeepsConfiguration() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store()
        let a = try await fixture.selected(store); let b = try await fixture.selected(store)
        try await seed(store, root: a, path: "/", entries: [catalogEntry("/a")])
        #expect(try await store.listCached(rootID: b.id, directory: "/").state == .notInitialized)
        try await store.clearIndex(rootID: a.id)
        #expect(try await store.listCached(rootID: a.id, directory: "/").state == .notInitialized)
        #expect(try await store.root(id: a.id) == a)
        #expect(try await store.profiles().count == 2)
        try await store.close()
    }
    @Test func ancestorMembershipAndIdentityMustBeCurrent() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/A", directory: true), catalogEntry("/AB", directory: true)])
        try await seed(store, root: root, path: "/A", entries: [catalogEntry("/A/%_", directory: true)])
        try await seed(store, root: root, path: "/A/%_", entries: [catalogEntry("/A/%_/old")])
        try await seed(store, root: root, path: "/AB", entries: [catalogEntry("/AB/keep")])
        // Simulate a parent publication removing only /A. /AB and %/_ must not be treated as prefix patterns.
        try await store.perform { db in try db.execute("DELETE FROM catalog_entries WHERE root=? AND path='/A'", [.uuid(root.id)]); return () }
        await #expect(throws: RemoteCatalogError.notFound) { try await store.listCached(rootID: root.id, directory: "/A/%_") }
        #expect(try await store.listCached(rootID: root.id, directory: "/AB").entries.map(\.name) == ["keep"])
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/A", directory: true, id: "new")])
        await #expect(throws: RemoteCatalogError.notFound) { try await store.listCached(rootID: root.id, directory: "/A/%_") }
        try await store.close()
    }
    @Test func settingsUpdatePreservesRootsAndRebindHidesOldCache() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        let profile = try await store.profile(id: root.sourceID)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/old")])
        let updated = try RemoteSourceProfile(id: profile.id, bindingID: profile.bindingID, configurationRevision: 2,
                                             displayName: "Rename", configuration: profile.configuration)
        try await store.saveProfile(updated, expectedRevision: 1)
        let cached = try await store.listCached(rootID: root.id, directory: "/")
        #expect(cached.entries.map(\.name) == ["old"] && cached.state == .stale)
        let rebound = try RemoteSourceProfile(id: profile.id, configurationRevision: 3, displayName: "Other", configuration: .local(accessReference: "other"))
        try await store.saveProfile(rebound, expectedRevision: 2)
        await #expect(throws: RemoteCatalogError.staleRevision) { try await store.listCached(rootID: root.id, directory: "/") }
        try await store.close()
    }
    @Test func decodedConfigurationIsRevalidatedAndPrivateValuesAreNotInErrors() async throws {
        let fixture = try CatalogFixture(); let store = try fixture.store(); let root = try await fixture.selected(store)
        try await store.perform { db in
            _ = try db.execute("UPDATE source_profiles SET payload=? WHERE id=?", [.blob(Data("invalid-secret-marker".utf8)), .uuid(root.sourceID)])
        }
        do { _ = try await store.profile(id: root.sourceID); Issue.record("Invalid payload accepted") }
        catch { #expect(!String(describing: error).contains("secret-marker")) }
        try await store.close()
    }
}
