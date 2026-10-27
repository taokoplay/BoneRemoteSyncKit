import Foundation
import BoneRemoteSyncCore

// Internal stage marker. Public initialization always unwraps and rethrows the original error.
struct CatalogRecoveryFailure: Error { let underlying: any Error }

extension RemoteCatalogError: RemoteLogClassifiableError {
    public var remoteLogCode: RemoteLogCode {
        switch self {
        case .invalidConfiguration: .invalidConfiguration
        case .invalidPath: .invalidPath
        case .unsupportedSchema: .unsupportedSchema
        case .database: .database
        case .closed: .closed
        case .notFound: .notFound
        case .staleRevision: .staleRevision
        case .invalidPageToken: .invalidPageToken
        case .busy: .busy
        case .needsAuthorization: .authorization
        case .incompleteListing: .incomplete
        case .identityChanged: .identityChanged
        case .budgetExceeded: .budget
        case .interrupted: .interrupted
        }
    }
    public var remoteLogNumericCode: Int32? {
        if case .database(let code) = self { return code }
        return nil
    }
}

extension RemoteCredentialStoreError: RemoteLogClassifiableError {
    public var remoteLogCode: RemoteLogCode {
        switch self {
        case .unavailable: .credentialUnavailable
        case .missing: .credentialMissing
        case .alreadyExists: .credentialExists
        case .invalidRecord: .credentialInvalid
        case .revoked: .credentialRevoked
        }
    }
    public var remoteLogNumericCode: Int32? {
        if case .unavailable(let status) = self { return status }
        return nil
    }
}

extension RemoteCatalogFailureReason {
    var logCode: RemoteLogCode {
        switch self {
        case .authorization: .authorization
        case .notFound: .notFound
        case .permission: .permission
        case .incomplete: .incomplete
        case .identityChanged: .identityChanged
        case .staleRevision: .staleRevision
        case .budget: .budget
        case .cancelled: .cancelled
        case .deadline: .deadline
        case .network: .network
        case .notConnected: .notConnected
        case .unsupported: .unsupported
        case .rateLimited: .rateLimited
        case .conflict: .conflict
        case .integrity: .integrity
        case .storage: .storage
        case .other: .unknown
        }
    }
}

extension RemoteLogger {
    /// At most one event per fixed reason. Never log per-entry paths or retain the report in a sink.
    func recordRefreshReport(_ report: RemoteCatalogRefreshReport) {
        var counts: [RemoteLogCode: Int] = [:]
        var order: [RemoteLogCode] = []
        for failure in report.failures {
            let code = failure.reason.logCode
            if counts[code] == nil { order.append(code) }
            counts[code, default: 0] += 1
        }
        for code in order {
            emit(.init(component: .catalog, operation: .refresh, code: code,
                       correlationID: report.refreshID, occurrenceCount: counts[code]!))
        }
    }
}
