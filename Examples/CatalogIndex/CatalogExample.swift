import Foundation
import BoneRemoteSyncKit

/// App-supplied bookmark restoration. A saved path alone is not sandbox authorization.
struct CatalogFolderResolver: RemoteLocalAccessResolver {
    let restore: @Sendable (String) async throws -> RemoteLocalAccessLease
    func resolve(reference: String) async throws -> RemoteLocalAccessLease { try await restore(reference) }
}

/// The caller owns its private directory, Keychain service and bookmark lifecycle.
/// This function performs no remote writes. A failed/partial scan still returns its report.
func catalogLocalIndexExample(
    databaseURL: URL,
    credentials: any RemoteCredentialStore,
    resolver: any RemoteLocalAccessResolver,
    accessReference: String,
    selectedPath: String
) async throws -> RemoteCatalogRefreshReport {
    let store = try SQLiteRemoteCatalogStore(databaseURL: databaseURL)
    do {
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: credentials, localResolver: resolver))
        let profile = try await catalog.saveSource(displayName: "Local library", configuration: .local(accessReference: accessReference))
        let root = try await catalog.selectRoot(sourceID: profile.id, path: selectedPath, defaultScope: .children)
        let report = try await catalog.refresh(rootID: root.id, options: .init(scope: .subtree))
        let page = try await catalog.listCached(rootID: root.id, directory: root.path, query: .init(limit: 100))
        // Render page.state, entries, lastSuccessfulAt. Persist root.id in app navigation as needed.
        _ = page
        _ = try await store.status(rootID: root.id)
        try await store.close()
        return report
    } catch {
        try? await store.close()
        throw error
    }
}

/// On a later launch, display metadata without restoring authorization or connecting a source.
func catalogOfflineExample(databaseURL: URL, rootID: UUID, path: String) async throws -> RemoteCatalogSnapshot {
    let store = try SQLiteRemoteCatalogStore(databaseURL: databaseURL)
    do {
        let page = try await store.listCached(rootID: rootID, directory: path)
        try await store.close()
        return page
    } catch {
        try? await store.close()
        throw error
    }
}
