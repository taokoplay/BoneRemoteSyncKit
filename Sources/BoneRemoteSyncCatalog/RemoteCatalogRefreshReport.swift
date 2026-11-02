import Foundation
import BoneRemoteSyncCore

/// Catalog 刷新的最终状态。
public enum RemoteCatalogRefreshState: String, Sendable, Codable { case success, partial, failed, cancelled }
/// Catalog 单个目录失败的归一化原因。
public enum RemoteCatalogFailureReason: String, Sendable, Codable {
    case authorization, notFound, permission, incomplete, identityChanged, staleRevision, budget, cancelled, deadline, network, storage, other
    case notConnected, unsupported, rateLimited, conflict, integrity
    static func map(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? RemoteCatalogError {
            switch error {
            case .needsAuthorization: return .authorization
            case .notFound: return .notFound
            case .incompleteListing, .invalidPath: return .incomplete
            case .identityChanged: return .identityChanged
            case .staleRevision: return .staleRevision
            case .budgetExceeded: return .budget
            case .database, .closed, .unsupportedSchema: return .storage
            default: return .other
            }
        }
        if let error = error as? RemoteSyncError {
            switch error {
            case .authenticationFailed: return .authorization
            case .notFound: return .notFound
            case .permissionDenied: return .permission
            case .network: return .network
            case .rateLimited: return .rateLimited
            case .notConnected: return .notConnected
            case .unsupported: return .unsupported
            case .conflict: return .conflict
            case .integrityMismatch, .sourceSnapshotMissing: return .integrity
            case .uploadSessionExpired, .uploadCommitUnknown: return .conflict
            case .secureStorageUnavailable: return .storage
            case .cancelled: return .cancelled
            case .underlying: return .other
            }
        }
        return .other
    }
}
/// 刷新过程中未能成功发布的目录及其失败原因。
public struct RemoteCatalogDirectoryFailure: Sendable, Codable {
    public let path: String
    public let reason: RemoteCatalogFailureReason
}
public struct RemoteCatalogRefreshReport: Sendable {
    /// 本次刷新的唯一 ID。
    public let refreshID: UUID
    /// 刷新的最终状态。
    public let state: RemoteCatalogRefreshState
    /// 刷新开始时间。
    public let startedAt: Date
    /// 刷新结束时间。
    public let finishedAt: Date
    /// 已成功发布的目录数量。
    public let publishedDirectories: Int
    /// 已成功发布的条目数量。
    public let publishedEntries: Int
    /// 按目录聚合的失败原因，不包含底层敏感错误文本。
    public let failures: [RemoteCatalogDirectoryFailure]
    /// 完整 subtree 成功时生成的递归统计；其他刷新类型通常为 `nil`。
    public let storageSummary: RemoteCatalogStorageSummary?

    /// 创建刷新结果。
    ///
    /// - Parameters:
    ///   - refreshID: 本次刷新的唯一 ID。
    ///   - state: 刷新的最终状态。
    ///   - startedAt: 刷新开始时间。
    ///   - finishedAt: 刷新结束时间。
    ///   - publishedDirectories: 已成功发布的目录数量。
    ///   - publishedEntries: 已成功发布的条目数量。
    ///   - failures: 按目录聚合的失败原因。
    ///   - storageSummary: 完整 subtree 成功生成的统计快照。
    public init(refreshID: UUID, state: RemoteCatalogRefreshState, startedAt: Date, finishedAt: Date,
                publishedDirectories: Int, publishedEntries: Int,
                failures: [RemoteCatalogDirectoryFailure], storageSummary: RemoteCatalogStorageSummary? = nil) {
        self.refreshID = refreshID
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.publishedDirectories = publishedDirectories
        self.publishedEntries = publishedEntries
        self.failures = failures
        self.storageSummary = storageSummary
    }
}
