import Foundation

public enum RemoteLogLevel: String, Sendable, Codable {
    case info, warning, error
    var rank: Int { switch self { case .info: 0; case .warning: 1; case .error: 2 } }
}
public enum RemoteLogComponent: String, Sendable, Codable { case core, local, webDAV, oneDrive, catalog, sqlite, credentials }
public enum RemoteLogOperation: String, Sendable, Codable {
    case connect, list, stat, walk, download, upload, makeDirectory, remove, move, copy
    case databaseOpen, databaseRecovery, databaseClose, saveSource, selectRoot, refresh, listCached
    case saveProfile, loadProfile, loadRoots, saveRoot, status, clearIndex, removeProfile
    case credentialRead, credentialInsert, credentialReplace, credentialRemove
}
public enum RemoteLogCode: String, Sendable, Codable {
    case notConnected = "source.not_connected"
    case authentication = "source.authentication"
    case notFound = "resource.not_found"
    case permission = "resource.permission"
    case unsupported = "operation.unsupported"
    case rateLimited = "source.rate_limited"
    case network = "source.network"
    case conflict = "resource.conflict"
    case integrity = "resource.integrity"
    case cancelled = "operation.cancelled"
    case unknown = "error.unknown"
    case invalidConfiguration = "catalog.invalid_configuration"
    case invalidPath = "catalog.invalid_path"
    case unsupportedSchema = "storage.unsupported_schema"
    case database = "storage.sqlite"
    case closed = "storage.closed"
    case staleRevision = "catalog.stale_revision"
    case invalidPageToken = "catalog.invalid_page_token"
    case busy = "operation.busy"
    case authorization = "catalog.authorization_required"
    case incomplete = "catalog.incomplete_listing"
    case identityChanged = "catalog.identity_changed"
    case budget = "catalog.budget_exceeded"
    case interrupted = "catalog.interrupted"
    case deadline = "operation.deadline"
    case storage = "storage.failure"
    case credentialUnavailable = "credential.unavailable"
    case credentialMissing = "credential.missing"
    case credentialExists = "credential.already_exists"
    case credentialInvalid = "credential.invalid_record"
    case credentialRevoked = "credential.revoked"

    public var level: RemoteLogLevel {
        switch self {
        case .cancelled: .info
        case .notConnected, .notFound, .unsupported, .rateLimited, .conflict, .staleRevision,
             .invalidPageToken, .busy, .budget, .interrupted: .warning
        default: .error
        }
    }
}

/// Modules may classify their errors without returning raw descriptions or arbitrary fields.
public protocol RemoteLogClassifiableError: Error {
    var remoteLogCode: RemoteLogCode { get }
    var remoteLogNumericCode: Int32? { get }
}
extension RemoteLogClassifiableError {
    public var remoteLogNumericCode: Int32? { nil }
}

/// A bounded, allowlisted diagnostic record. No raw error, message, resource identifier or metadata dictionary.
public struct RemoteLogEvent: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let level: RemoteLogLevel
    public let component: RemoteLogComponent
    public let operation: RemoteLogOperation
    public let code: RemoteLogCode
    public let correlationID: UUID?
    /// SQLite extended result code or Security OSStatus only for SDK-generated events.
    public let numericCode: Int32?
    public let occurrenceCount: Int

    public init(component: RemoteLogComponent, operation: RemoteLogOperation, code: RemoteLogCode,
                correlationID: UUID? = nil, numericCode: Int32? = nil, occurrenceCount: Int = 1) {
        schemaVersion = 1; timestamp = Date(); level = code.level
        self.component = component; self.operation = operation; self.code = code
        self.correlationID = correlationID; self.numericCode = numericCode; self.occurrenceCount = max(1, occurrenceCount)
    }
}

/// Optional synchronous delivery. The host sink must be thread-safe, quick and must not synchronously reenter the SDK.
/// There is no implicit console, file, database or network output. Sink errors are ignored without recursive logging.
public struct RemoteLogger: Sendable {
    public static let disabled = RemoteLogger()
    private let sink: (@Sendable (RemoteLogEvent) throws -> Void)?
    private let minimumLevel: RemoteLogLevel
    public init(minimumLevel: RemoteLogLevel = .info, sink: (@Sendable (RemoteLogEvent) throws -> Void)? = nil) {
        self.minimumLevel = minimumLevel; self.sink = sink
    }
    public func emit(_ event: RemoteLogEvent) {
        guard event.level.rank >= minimumLevel.rank, let sink else { return }
        try? sink(event)
    }
    public func record(_ error: any Error, component: RemoteLogComponent, operation: RemoteLogOperation, correlationID: UUID? = nil) {
        let code: RemoteLogCode
        var number: Int32?
        if error is CancellationError { code = .cancelled }
        else if let error = error as? RemoteSyncError {
            switch error {
            case .notConnected: code = .notConnected
            case .authenticationFailed: code = .authentication
            case .notFound: code = .notFound
            case .permissionDenied: code = .permission
            case .unsupported: code = .unsupported
            case .rateLimited: code = .rateLimited
            case .network: code = .network
            case .conflict: code = .conflict
            case .integrityMismatch: code = .integrity
            case .uploadSessionExpired: code = .conflict
            case .sourceSnapshotMissing: code = .integrity
            case .uploadCommitUnknown: code = .conflict
            case .secureStorageUnavailable: code = .permission
            case .cancelled: code = .cancelled
            case .underlying: code = .unknown
            }
        } else if let error = error as? any RemoteLogClassifiableError {
            code = error.remoteLogCode
            number = error.remoteLogNumericCode
        } else { code = .unknown }
        emit(.init(component: component, operation: operation, code: code, correlationID: correlationID, numericCode: number))
    }
}
