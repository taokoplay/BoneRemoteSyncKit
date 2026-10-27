import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncLocal
import BoneRemoteSyncWebDAV
import BoneRemoteSyncOneDrive

/// Fixed-binding sessions are private to Catalog; callers cannot reconnect a scanning source to another account.
public final class RemoteCatalogSessionFactory: Sendable {
    let credentials: any RemoteCredentialStore
    let localResolver: (any RemoteLocalAccessResolver)?
    public init(credentials: any RemoteCredentialStore, localResolver: (any RemoteLocalAccessResolver)? = nil) {
        self.credentials = credentials; self.localResolver = localResolver
    }
    func open(profile: RemoteSourceProfile) async throws -> CatalogSession {
        try profile.validate()
        let coordinator = CatalogCredentialCoordinator.shared
        var handle: CatalogCredentialHandle?
        var local: RemoteLocalAccessLease?
        var source: (any RemoteSource)?
        do {
            let credential: RemoteCredential
            if let reference = profile.credentialReference {
                handle = try coordinator.acquire(store: credentials, reference: reference)
                do {
                    guard let saved = try credentials.read(reference: reference) else { throw RemoteCatalogError.needsAuthorization }
                    credential = saved
                } catch { throw RemoteCatalogError.needsAuthorization }
            } else { credential = .anonymous }
            switch profile.configuration {
            case .local(let reference):
                guard let localResolver else { throw RemoteCatalogError.needsAuthorization }
                local = try await localResolver.resolve(reference: reference)
                source = LocalFileSource(root: local!.rootURL)
            case .webDAV(let url, let timeout, let retry):
                guard case .anonymous = credential else {
                    guard case .basic = credential else { throw RemoteCatalogError.needsAuthorization }
                    source = try WebDAVSource(baseURL: url, timeout: timeout, retryPolicy: retry.adapterPolicy)
                    break
                }
                source = try WebDAVSource(baseURL: url, timeout: timeout, retryPolicy: retry.adapterPolicy)
            case .oneDrive(let client, let redirect, _, let timeout):
                guard case .oauth = credential, let fixedHandle = handle else { throw RemoteCatalogError.needsAuthorization }
                source = OneDriveSource(configuration: try .init(clientID: client, redirectURI: redirect, timeout: timeout)) {
                    try fixedHandle.replace($0.credential)
                }
            }
            let connected = source!
            try await connected.connect(credential)
            if case .oneDrive(_, _, let expected, _) = profile.configuration {
                guard let drive = connected as? OneDriveSource,
                      try await drive.connectedDriveID() == expected else { throw RemoteCatalogError.identityChanged }
            }
            try Task.checkCancellation()
            let fixedHandle = handle; let access = local
            return CatalogSession(source: connected) {
                if let fixedHandle { coordinator.release(fixedHandle) }
                access?.release()
            }
        } catch {
            if let source { await source.disconnect() }
            if let handle { coordinator.release(handle) }
            local?.release()
            throw error
        }
    }

    /// Serialize revocation/removal with rotation callbacks and revoke any active fixed handle first.
    public func revokeCredential(reference: UUID, remove: Bool = false) throws {
        try CatalogCredentialCoordinator.shared.revoke(store: credentials, reference: reference, remove: remove)
    }
}

final class CatalogSession: @unchecked Sendable {
    let source: any RemoteSource
    private let closeAction: @Sendable () -> Void
    private let lock = NSLock()
    private var didClose = false
    init(source: any RemoteSource, close: @escaping @Sendable () -> Void) { self.source = source; closeAction = close }
    func close() async {
        let shouldClose = lock.withLock { if didClose { return false }; didClose = true; return true }
        if shouldClose { await source.disconnect(); closeAction() }
    }
    deinit {
        // A final safety net releases host leases and revokes callbacks. Catalog always awaits close explicitly.
        let shouldClose = lock.withLock { if didClose { return false }; didClose = true; return true }
        if shouldClose { closeAction() }
    }
}

final class CatalogCredentialCoordinator: @unchecked Sendable {
    static let shared = CatalogCredentialCoordinator()
    private let lock = NSLock()
    private var handles: [String: CatalogCredentialHandle] = [:]
    private func key(store: any RemoteCredentialStore, reference: UUID) -> String { store.coordinationID + ":" + reference.uuidString }
    func acquire(store: any RemoteCredentialStore, reference: UUID) throws -> CatalogCredentialHandle {
        try lock.withLock {
            let key = key(store: store, reference: reference)
            guard handles[key] == nil else { throw RemoteCatalogError.busy }
            let handle = CatalogCredentialHandle(reference: reference, store: store)
            handles[key] = handle
            return handle
        }
    }
    func release(_ handle: CatalogCredentialHandle) {
        lock.withLock {
            let key = key(store: handle.store, reference: handle.reference)
            handle.revoke()
            if handles[key] === handle { handles[key] = nil }
        }
    }
    func revoke(store: any RemoteCredentialStore, reference: UUID, remove: Bool) throws {
        try lock.withLock {
            handles[key(store: store, reference: reference)]?.revoke()
            if remove { try store.remove(reference: reference) }
        }
    }
}
