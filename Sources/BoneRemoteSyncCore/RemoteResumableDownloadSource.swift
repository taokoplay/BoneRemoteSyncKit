import Foundation

/// The destination is committed in both cases. Cleanup failure must not be retried
/// as an ordinary failed download or interpreted as a rollback.
/// 受管理恢复下载的最终提交状态；目标安装完成后，清理失败不代表下载回滚。
public enum RemoteDownloadCommitState: String, Sendable, Codable {
    case committed
    case committedCleanupPending
}

/// 恢复下载返回的条目和提交状态。
public struct RemoteResumableDownloadResult: Sendable {
    public let entry: RemoteEntry
    public let state: RemoteDownloadCommitState
    public init(entry: RemoteEntry, state: RemoteDownloadCommitState) {
        self.entry = entry; self.state = state
    }
}

/// Read-only observation of a provider-owned checkpoint, not an instruction to
/// append at an offset. The provider must revalidate before every continuation.
public struct RemoteDownloadCheckpoint: Sendable {
    /// 来源检查点所处阶段。
    public enum Phase: String, Sendable { case downloading, readyToInstall, committedCleanupPending }
    public let reference: RemoteFileReference
    public let destination: URL
    public let version: RemoteVersion
    public let expectedSize: Int64
    public let confirmedBytes: Int64
    public let phase: Phase

    public init(reference: RemoteFileReference, destination: URL, version: RemoteVersion,
                expectedSize: Int64, confirmedBytes: Int64, phase: Phase) throws {
        guard destination.isFileURL, version.source == reference.source,
              version.locator == reference.locator, version.strength == .strongConditional,
              expectedSize >= 0, confirmedBytes >= 0, confirmedBytes <= expectedSize,
              phase == .downloading || confirmedBytes == expectedSize else {
            throw RemoteSyncError.conflict(path: "download-checkpoint")
        }
        self.reference = reference; self.destination = destination; self.version = version
        self.expectedSize = expectedSize; self.confirmedBytes = confirmedBytes; self.phase = phase
    }
}

/// No resume offset is accepted. Only durable, provider-confirmed checkpoints
/// may determine the continuation point. Caller serializes target access.
public struct RemoteResumableDownloadOptions: Sendable {
    public var checkpointIntervalBytes: Int64
    public var overwrite: Bool
    public var progress: (@Sendable (Int64) -> Void)?
    public init(checkpointIntervalBytes: Int64 = 8 * 1024 * 1024, overwrite: Bool = false,
                progress: (@Sendable (Int64) -> Void)? = nil) {
        self.checkpointIntervalBytes = checkpointIntervalBytes; self.overwrite = overwrite; self.progress = progress
    }
}

/// Optional managed recovery contract. Manual offset support or a capabilities
/// flag alone does not imply conformance. Credentials and checkpoint formats
/// remain provider-owned; the host keeps the source session's identity stable.
/// 可选的来源受管恢复下载协议；续传位置必须来自来源确认的检查点。
public protocol RemoteResumableDownloadSource: RemoteSource {
    /// 校验恢复下载参数、来源绑定和目标资格，不执行下载。
    func validateResumableDownload(_ reference: RemoteFileReference, options: RemoteResumableDownloadOptions) throws
    /// 从来源确认的检查点继续下载，并原子提交最终目标。
    func downloadResuming(_ reference: RemoteFileReference, to destination: URL,
                          options: RemoteResumableDownloadOptions) async throws -> RemoteResumableDownloadResult
    /// Validates persisted binding, file identity and prefix. Remote freshness is
    /// checked by downloadResuming, not promised by this observation.
    func downloadCheckpoint(_ reference: RemoteFileReference, destination: URL) async throws -> RemoteDownloadCheckpoint?
}
