import Foundation
import BoneRemoteSyncCore

extension WebDAVSource {
    /// Managed checkpoint download. The caller must serialize destination access across source instances and processes.
    public func downloadResumable(path: String, to destination: URL,
                                  options: WebDAVResumableDownloadOptions) async throws -> RemoteEntry {
        try await downloadResumable(path: path, to: destination, options: options, hooks: .none)
    }

    func downloadResumable(path: String, to destination: URL, options: WebDAVResumableDownloadOptions,
                           hooks: DAVRecoveryTestHooks, runtime: DAVRetryRuntime = .live) async throws -> RemoteEntry {
        try await downloadResumableResult(path: path, to: destination, options: options, hooks: hooks, runtime: runtime).entry
    }

    /// Returns the local commit outcome separately from checkpoint cleanup.
    public func downloadResumableResult(path: String, to destination: URL,
                                        options: WebDAVResumableDownloadOptions) async throws -> RemoteResumableDownloadResult {
        try await downloadResumableResult(path: path, to: destination, options: options, hooks: .none)
    }

    func downloadResumableResult(path: String, to destination: URL, options: WebDAVResumableDownloadOptions,
                                 hooks: DAVRecoveryTestHooks, runtime: DAVRetryRuntime = .live) async throws -> RemoteResumableDownloadResult {
        try options.validate()
        let (session, version) = try context()
        let path = RemotePath.normalize(path)
        guard path.utf8.count <= 16 * 1024 else { throw RemoteSyncError.unsupported(operation: "WebDAV 恢复路径过长") }
        let target = try WebDAVDownloadTarget(destination: destination)
        let lockedPaths = target.reservedPaths
        guard activeDestinations.isDisjoint(with: lockedPaths) else { throw RemoteSyncError.conflict(path: destination.path) }
        activeDestinations.formUnion(lockedPaths)
        defer { activeDestinations.subtract(lockedPaths) }
        let scope = DAVOperationScope(pool: session, policy: retryPolicy, runtime: runtime)
        do {
            let binding = DAVCheckpointBinding(sourceNamespace: options.sourceNamespace, root: location.baseURL.absoluteString,
                                               remotePath: path, destination: target.lockKey)
            var statRequest = try request(path: path, method: "PROPFIND")
            statRequest.setValue("0", forHTTPHeaderField: "Depth")
            statRequest.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            statRequest.httpBody = Data(Self.propfindBody.utf8)
            let worker = DAVResumableDownloadWorker(session: session, target: target, binding: binding, options: options,
                                                    policy: retryPolicy, scope: scope, path: path, hooks: hooks)
            let prepared = try await worker.run(statRequest: statRequest, getRequest: request(path: path, method: "GET"), location: location)
            try hooks.call(.beforeInstall)
            // Generation, absolute deadline and file identity are checked without an await before rename.
            try checkGeneration(version)
            try scope.check()
            try target.verifyManagedIdentity(handle: prepared.handle, record: prepared.record, installed: prepared.alreadyInstalled)
            if !prepared.alreadyInstalled { try target.install(handle: prepared.handle, overwrite: options.overwrite) }
            // Rename is logical success. Cleanup failure must not misreport an installed target as failed.
            do {
                try hooks.call(.installedBeforeCleanup)
                try prepared.store.removeIfMatching(prepared.record)
            } catch {
                return RemoteResumableDownloadResult(entry: prepared.entry, state: .committedCleanupPending)
            }
            return RemoteResumableDownloadResult(entry: prepared.entry, state: .committed)
        } catch { throw DAVHTTP.mapped(error, localPath: destination.path) }
    }
}
