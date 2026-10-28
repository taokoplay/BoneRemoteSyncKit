import Foundation
import BoneRemoteSyncCore

extension WebDAVSource: RemoteResumableDownloadSource {
    public nonisolated func validateResumableDownload(_ reference: RemoteFileReference,
                                                      options: RemoteResumableDownloadOptions) throws {
        guard reference.source.kind == .webdav, case .path(let path) = reference.locator,
              path.utf8.count <= 16 * 1024 else {
            throw RemoteSyncError.unsupported(operation: "WebDAV 恢复下载需要绑定的路径引用")
        }
        try WebDAVResumableDownloadOptions(sourceNamespace: reference.source.identity,
            checkpointIntervalBytes: options.checkpointIntervalBytes).validate()
    }

    public func downloadResuming(_ reference: RemoteFileReference, to destination: URL,
                                 options: RemoteResumableDownloadOptions) async throws -> RemoteResumableDownloadResult {
        try validateResumableDownload(reference, options: options)
        guard case .path(let path) = reference.locator else { preconditionFailure("validated path") }
        return try await downloadResumableResult(path: path, to: destination,
            options: .init(sourceNamespace: reference.source.identity,
                checkpointIntervalBytes: options.checkpointIntervalBytes,
                overwrite: options.overwrite, progress: options.progress))
    }

    public func downloadCheckpoint(_ reference: RemoteFileReference, destination: URL) async throws -> RemoteDownloadCheckpoint? {
        try validateResumableDownload(reference, options: .init())
        guard case .path(let path) = reference.locator else { preconditionFailure("validated path") }
        let (_, generation) = try context()
        let target = try WebDAVDownloadTarget(destination: destination)
        guard activeDestinations.isDisjoint(with: target.reservedPaths) else {
            throw RemoteSyncError.conflict(path: "download-checkpoint")
        }
        let binding = DAVCheckpointBinding(sourceNamespace: reference.source.identity,
            root: location.baseURL.absoluteString, remotePath: path, destination: target.lockKey)
        activeDestinations.formUnion(target.reservedPaths)
        defer { activeDestinations.subtract(target.reservedPaths) }
        let checkpoint = try await Self.inspectCheckpoint(reference, target: target, binding: binding)
        try checkGeneration(generation)
        return checkpoint
    }

    private nonisolated static func inspectCheckpoint(_ reference: RemoteFileReference, target: WebDAVDownloadTarget,
                                                       binding: DAVCheckpointBinding) async throws -> RemoteDownloadCheckpoint? {
        try Task.checkCancellation()
        let store = DAVCheckpointStore(target: target, binding: binding)
        guard let record = try store.load() else {
            guard try WebDAVDownloadTarget.information(target.part) == nil else {
                throw RemoteSyncError.conflict(path: "download-checkpoint")
            }
            return nil
        }
        let partExists = try WebDAVDownloadTarget.information(target.part) != nil
        let installed = record.phase == .readyToInstall && !partExists
        let handle = try target.openManagedPart(installed: installed)
        defer { try? handle.close() }
        try target.verifyManagedIdentity(handle: handle, record: record, installed: installed)
        _ = try DAVPartHasher.verifyPrefix(handle: handle, record: record, check: { try Task.checkCancellation() })
        try target.verifyManagedIdentity(handle: handle, record: record, installed: installed)
        guard try store.load() == record else { throw RemoteSyncError.conflict(path: "download-checkpoint") }
        return try RemoteDownloadCheckpoint(reference: reference, destination: target.destination,
            version: RemoteVersion(source: reference.source, locator: reference.locator, value: record.etag, strength: .strongConditional),
            expectedSize: record.expectedSize, confirmedBytes: record.committedBytes,
            phase: installed ? .committedCleanupPending : (record.phase == .readyToInstall ? .readyToInstall : .downloading))
    }
}
