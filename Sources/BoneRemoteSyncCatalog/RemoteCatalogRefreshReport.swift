import Foundation
import BoneRemoteSyncCore

public enum RemoteCatalogRefreshState: String, Sendable, Codable { case success, partial, failed, cancelled }
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
            case .integrityMismatch: return .integrity
            case .cancelled: return .cancelled
            case .underlying: return .other
            }
        }
        return .other
    }
}
public struct RemoteCatalogDirectoryFailure: Sendable, Codable {
    public let path: String
    public let reason: RemoteCatalogFailureReason
}
public struct RemoteCatalogRefreshReport: Sendable {
    public let refreshID: UUID
    public let state: RemoteCatalogRefreshState
    public let startedAt: Date
    public let finishedAt: Date
    public let publishedDirectories: Int
    public let publishedEntries: Int
    public let failures: [RemoteCatalogDirectoryFailure]
}
