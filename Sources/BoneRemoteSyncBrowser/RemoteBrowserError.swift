import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncContent
import BoneRemoteSyncOPDS

/// One stable classification for browser clients, with an explicit native error escape hatch.
public struct RemoteBrowserError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Code: String, Sendable, Codable {
        case notConnected, sessionExpired, authentication, permissionDenied, notFound, unsupported
        case invalidInput, invalidReference, invalidResponse, rateLimited, resourceLimit
        case cancelled, network, conflict, integrityMismatch, provider
    }
    public let code: Code
    public let retryAfter: TimeInterval?
    /// May contain provider/path details. Do not serialize or log its raw description.
    public let underlyingError: (any Error)?
    public init(code: Code, retryAfter: TimeInterval? = nil, underlyingError: (any Error)? = nil) {
        self.code = code
        self.retryAfter = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.underlyingError = underlyingError
    }
    public var description: String { "RemoteBrowserError(\(code.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["code": code.rawValue]) }

    static func mapped(_ error: any Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .init(code: .cancelled, underlyingError: error)
        }
        var code: Code = .provider
        var retry: TimeInterval?
        if let native = error as? RemoteSyncError {
            switch native {
            case .notConnected: code = .notConnected
            case .authenticationFailed: code = .authentication
            case .permissionDenied: code = .permissionDenied
            case .notFound: code = .notFound
            case .unsupported: code = .unsupported
            case .rateLimited(let value): code = .rateLimited; retry = value
            case .network: code = .network
            case .conflict: code = .conflict
            case .integrityMismatch: code = .integrityMismatch
            case .cancelled: code = .cancelled
            default: break
            }
        } else if let native = error as? ContentServerError {
            switch native {
            case .invalidConfiguration: code = .invalidInput
            case .invalidReference, .invalidCursor: code = .invalidReference
            case .identityChanged: code = .sessionExpired
            case .resourceLimit: code = .resourceLimit
            case .invalidResponse, .redirectRejected: code = .invalidResponse
            }
        } else if let native = error as? OPDSError {
            switch native {
            case .invalidConfiguration: code = .invalidInput
            case .invalidReference, .invalidCursor: code = .invalidReference
            case .resourceLimit: code = .resourceLimit
            case .unsupportedAcquisition, .unsupportedSearch: code = .unsupported
            default: code = .invalidResponse
            }
        } else if error is URLError { code = .network }
        return .init(code: code, retryAfter: retry, underlyingError: error)
    }
}
