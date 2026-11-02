import Foundation
import BoneRemoteSyncCore

/// Explicit target exclusion for recovery. All participants accessing a target
/// (including low-level provider callers) must cooperate with the same lock domain.
/// 恢复下载目标的协作锁协议；所有访问同一目标的参与者必须使用同一锁域。
public protocol RemoteDownloadDestinationLocking: Sendable {
    /// 获取本地目标排他租约。
    func acquire(destination: URL) async throws -> RemoteDownloadDestinationLease
}
/// 恢复下载目标租约；release 会等待底层清理完成。
public struct RemoteDownloadDestinationLease: Sendable {
    private let releaser: LeaseReleaser
    /// 创建目标租约。
    public init(release: @escaping @Sendable () async -> Void) { releaser = LeaseReleaser(action: release) }
    /// 释放目标租约；重复调用安全。
    public func release() async { await releaser.release() }
}

/// Explicit recoverable download to a caller-owned local destination. Separate
/// from cache materialization and the in-memory coordinator queue: no lease,
/// automatic retry, connect/disconnect, or background scheduling is implied.
/// 显式恢复下载服务；不自动排队、重连、重试或管理后台任务。
public struct RemoteDownloadRecovery: Sendable {
    public let binding: RemoteSourceBinding
    private let source: any RemoteSource
    private let destinationLocks: any RemoteDownloadDestinationLocking

    /// 创建恢复下载服务并绑定固定来源和目标锁。
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

    /// 按来源确认的检查点恢复到调用方指定的本地目标。
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

    /// 读取当前来源确认的恢复检查点，不会继续下载。
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
