import Foundation
import BoneRemoteSyncCore

/// Explicit target exclusion for recovery. All participants accessing a target
/// (including low-level provider callers) must cooperate with the same lock domain.
public protocol RemoteDownloadDestinationLocking: Sendable {
    func acquire(destination: URL) async throws -> RemoteDownloadDestinationLease
}

public struct RemoteDownloadDestinationLease: Sendable {
    private let releaser: LeaseReleaser
    public init(release: @escaping @Sendable () async -> Void) { releaser = LeaseReleaser(action: release) }
    public func release() async { await releaser.release() }
}

/// Explicit recoverable download to a caller-owned local destination. Separate
/// from cache materialization and the in-memory coordinator queue: no lease,
/// automatic retry, connect/disconnect, or background scheduling is implied.
public struct RemoteDownloadRecovery: Sendable {
    public let binding: RemoteSourceBinding
    private let source: any RemoteSource
    private let destinationLocks: any RemoteDownloadDestinationLocking

    public init(source: any RemoteSource, binding: RemoteSourceBinding,
                destinationLocks: any RemoteDownloadDestinationLocking) {
        self.source = source; self.binding = binding; self.destinationLocks = destinationLocks
    }

    private func provider(_ reference: RemoteFileReference,
                          options: RemoteResumableDownloadOptions) throws -> any RemoteResumableDownloadSource {
        guard reference.source == binding, source.kind == binding.kind else {
            throw RemoteSyncError.conflict(path: "download-binding")
        }
        guard let provider = source as? any RemoteResumableDownloadSource else {
            throw RemoteSyncError.unsupported(operation: "来源不支持受管理恢复下载")
        }
        try provider.validateResumableDownload(reference, options: options)
        return provider
    }

    public func download(_ reference: RemoteFileReference, to destination: URL,
                         options: RemoteResumableDownloadOptions = .init()) async throws -> RemoteResumableDownloadResult {
        let provider = try provider(reference, options: options)
        let lock = try await destinationLocks.acquire(destination: destination)
        do {
            try Task.checkCancellation()
            let result = try await provider.downloadResuming(reference, to: destination, options: options)
            // No cancellation check after commit: release exclusion and return the receipt.
            await lock.release()
            return result
        } catch {
            await lock.release()
            if error is CancellationError { throw RemoteSyncError.cancelled }
            throw error
        }
    }

    public func checkpoint(_ reference: RemoteFileReference, destination: URL) async throws -> RemoteDownloadCheckpoint? {
        let provider = try provider(reference, options: .init())
        let lock = try await destinationLocks.acquire(destination: destination)
        do {
            try Task.checkCancellation()
            let checkpoint = try await provider.downloadCheckpoint(reference, destination: destination)
            await lock.release()
            return checkpoint
        } catch {
            await lock.release()
            if error is CancellationError { throw RemoteSyncError.cancelled }
            throw error
        }
    }
}
