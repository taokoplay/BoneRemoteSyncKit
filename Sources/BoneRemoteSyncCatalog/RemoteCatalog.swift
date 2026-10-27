import Foundation
import BoneRemoteSyncCore

/// Optional persistence/coordinator layer. No operation installs a persistent background schedule or performs remote mutations.
public actor RemoteCatalog {
    public let store: SQLiteRemoteCatalogStore
    let sessions: RemoteCatalogSessionFactory
    private var activeRoots: Set<UUID> = []
    public init(store: SQLiteRemoteCatalogStore, sessions: RemoteCatalogSessionFactory) { self.store = store; self.sessions = sessions }

    /// Creates a new exclusive secret reference before switching the database binding.
    /// Rebinding never overwrites an existing secret. Old references remain for explicit host cleanup.
    @discardableResult
    public func saveSource(displayName: String, configuration: RemoteSourceConfiguration,
                           credential: RemoteCredential? = nil, replacing sourceID: UUID? = nil,
                           expectedRevision: Int64? = nil) async throws -> RemoteSourceProfile {
        let correlationID = UUID()
        do {
            try configuration.validate()
            switch (configuration, credential) {
            case (.local, nil), (.webDAV, nil), (.webDAV, .some(.anonymous)),
                 (.webDAV, .some(.basic)), (.oneDrive, .some(.oauth)): break
            default: throw RemoteCatalogError.invalidConfiguration
            }
            let previous: RemoteSourceProfile?
            if let sourceID {
                previous = try await store.profile(id: sourceID)
                guard expectedRevision == previous?.configurationRevision else { throw RemoteCatalogError.staleRevision }
            } else {
                guard expectedRevision == nil else { throw RemoteCatalogError.staleRevision }
                previous = nil
            }
            // Hold an exclusive use lease across the binding switch. Do not revoke a shared in-flight rotation.
            let oldLease: CatalogCredentialHandle?
            if let oldReference = previous?.credentialReference {
                oldLease = try CatalogCredentialCoordinator.shared.acquire(store: sessions.credentials, reference: oldReference)
            } else { oldLease = nil }
            defer { if let oldLease { CatalogCredentialCoordinator.shared.release(oldLease) } }
            let reference = credential.map { _ in UUID() }
            let profile = try RemoteSourceProfile(id: sourceID ?? UUID(), configurationRevision: (previous?.configurationRevision ?? 0) + 1,
                displayName: displayName, configuration: configuration, credentialReference: reference)
            if let credential, let reference { try sessions.credentials.insert(credential, reference: reference) }
            do {
                try Task.checkCancellation()
                try await store.saveProfile(profile, expectedRevision: expectedRevision)
                return profile
            } catch {
                // Compensate only our fresh exclusive item, and only with positive proof it is not referenced.
                // If the database cannot be read (or the process exits here), preserve the orphan for host reconciliation.
                if let reference, let profiles = try? await store.profiles(),
                   !profiles.contains(where: { $0.credentialReference == reference }) {
                    try? sessions.credentials.remove(reference: reference)
                }
                throw error
            }
        } catch {
            store.logger.record(error, component: .catalog, operation: .saveSource, correlationID: correlationID)
            throw error
        }
    }

    /// Connects with restored authorization, verifies the selection, then saves path + provider ID.
    @discardableResult
    public func selectRoot(sourceID: UUID, path: String, includeHidden: Bool = false,
                           defaultScope: RemoteCatalogRefreshScope = .children,
                           replacing rootID: UUID? = nil, expectedRevision: Int64? = nil) async throws -> RemoteCatalogRoot {
        let correlationID = UUID()
        do {
            try CatalogValidation.path(path)
            if let rootID {
                guard let expectedRevision, expectedRevision > 0, expectedRevision < Int64.max - 1 else { throw RemoteCatalogError.staleRevision }
                let old = try await store.selectionForManagement(id: rootID)
                guard old.sourceID == sourceID, old.selectionRevision == expectedRevision else { throw RemoteCatalogError.staleRevision }
            } else if expectedRevision != nil { throw RemoteCatalogError.staleRevision }
            let profile = try await store.profile(id: sourceID)
            let session = try await sessions.open(profile: profile)
            let entry: RemoteEntry
            do {
                entry = try await session.source.stat(path: path)
                guard entry.isDirectory, entry.path == path else { throw RemoteCatalogError.identityChanged }
                try Task.checkCancellation()
                await session.close()
            } catch { await session.close(); throw error }
            guard try await store.profile(id: sourceID) == profile else { throw RemoteCatalogError.staleRevision }
            if rootID == nil && expectedRevision != nil { throw RemoteCatalogError.staleRevision }
            let root = try RemoteCatalogRoot(id: rootID ?? UUID(), sourceID: sourceID, bindingID: profile.bindingID,
                selectionRevision: (expectedRevision ?? 0) + 1, path: path, entryID: entry.id,
                includeHidden: includeHidden, defaultScope: defaultScope)
            try await store.saveRoot(root, expectedRevision: expectedRevision)
            return root
        } catch {
            store.logger.record(error, component: .catalog, operation: .selectRoot, correlationID: correlationID)
            throw error
        }
    }

    /// Explicitly refreshes a directory or subtree. Cached queries never invoke this operation.
    public func refresh(rootID: UUID, directory: String? = nil, options: RemoteCatalogRefreshOptions? = nil) async throws -> RemoteCatalogRefreshReport {
        var correlationID = UUID()
        do {
            guard activeRoots.insert(rootID).inserted else { throw RemoteCatalogError.busy }
            defer { activeRoots.remove(rootID) }
            try Task.checkCancellation()
            let root = try await store.root(id: rootID)
            let options = options ?? .init(scope: root.defaultScope)
            try options.validate()
            let run = try await store.beginRun(rootID: rootID, path: directory ?? root.path, scope: options.scope)
            correlationID = run.id
            let coordinator = CatalogRefreshCoordinator(store: store, sessions: sessions, run: run, options: options)
            let report = await coordinator.runRefresh()
            // These are scan outcomes, not evidence that run bookkeeping has committed.
            store.logger.recordRefreshReport(report)
            do { try await store.finishRun(run, state: report.state.rawValue, failures: report.failures) }
            catch { try? await store.finishRun(run, state: "interrupted"); throw error }
            return report
        } catch {
            store.logger.record(error, component: .catalog, operation: .refresh, correlationID: correlationID)
            throw error
        }
    }

    public func listCached(rootID: UUID, directory: String, query: RemoteCatalogQuery = .init()) async throws -> RemoteCatalogSnapshot {
        let correlationID = UUID()
        do {
            return try await store.listCached(rootID: rootID, directory: directory, query: query)
        } catch {
            store.logger.record(error, component: .catalog, operation: .listCached, correlationID: correlationID)
            throw error
        }
    }
}
