import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncWebDAV
import BoneRemoteSyncOneDrive

public enum RemoteCatalogError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidPath
    case unsupportedSchema
    case database(Int32)
    case closed
    case notFound
    case staleRevision
    case invalidPageToken
    case busy
    case needsAuthorization
    case incompleteListing
    case identityChanged
    case budgetExceeded
    case interrupted
}

/// Explicit provider identity; cloudAPI alone cannot distinguish different cloud adapters.
public enum RemoteCatalogProvider: String, Sendable, Codable { case local, webDAV, oneDrive }

/// Non-sensitive settings only. Passwords, tokens, bookmark data and runtime objects do not belong here.
public enum RemoteSourceConfiguration: Sendable, Codable, Equatable {
    case local(accessReference: String)
    case webDAV(baseURL: URL, timeout: TimeInterval = 60, retry: RemoteCatalogRetryPolicy = .none)
    case oneDrive(clientID: String, redirectURI: URL, driveID: String, timeout: TimeInterval = 60)

    public var provider: RemoteCatalogProvider {
        switch self { case .local: .local; case .webDAV: .webDAV; case .oneDrive: .oneDrive }
    }
    public func validate() throws {
        do {
            switch self {
            case .local(let reference):
                guard CatalogValidation.text(reference, max: 4096) else { throw RemoteCatalogError.invalidConfiguration }
            case .webDAV(let url, let timeout, let retry):
                guard timeout.isFinite, timeout > 0, timeout <= 86400,
                      CatalogValidation.text(url.absoluteString, max: 16384),
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      !url.path.utf8.contains(0) else { throw RemoteCatalogError.invalidConfiguration }
                _ = try WebDAVSource(baseURL: url, timeout: timeout, retryPolicy: retry.adapterPolicy)
            case .oneDrive(let client, let redirect, let drive, let timeout):
                guard CatalogValidation.text(client, max: 4096), CatalogValidation.text(drive, max: 4096),
                      CatalogValidation.text(redirect.absoluteString, max: 16384),
                      !redirect.path.utf8.contains(0) else { throw RemoteCatalogError.invalidConfiguration }
                _ = try OneDriveConfiguration(clientID: client, redirectURI: redirect, timeout: timeout)
            }
        } catch { throw RemoteCatalogError.invalidConfiguration }
    }

    /// Identity-affecting settings, excluding timeouts/retry behavior.
    func sameBinding(as other: Self) -> Bool {
        switch (self, other) {
        case (.local(let a), .local(let b)): return a == b
        case (.webDAV(let a, _, _), .webDAV(let b, _, _)): return a == b
        case (.oneDrive(let a, let b, let c, _), .oneDrive(let x, let y, let z, _)): return a == x && b == y && c == z
        default: return false
        }
    }
}

public struct RemoteCatalogRetryPolicy: Sendable, Codable, Equatable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let totalTimeout: TimeInterval?
    public init(maxAttempts: Int = 1, initialDelay: TimeInterval = 0.5,
                maxDelay: TimeInterval = 8, totalTimeout: TimeInterval? = nil) {
        self.maxAttempts = maxAttempts; self.initialDelay = initialDelay
        self.maxDelay = maxDelay; self.totalTimeout = totalTimeout
    }
    public static let none = Self()
    var adapterPolicy: WebDAVRetryPolicy {
        .init(maxAttempts: maxAttempts, initialDelay: initialDelay, maxDelay: maxDelay, totalTimeout: totalTimeout)
    }
}

public struct RemoteSourceProfile: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let bindingID: UUID
    public let configurationRevision: Int64
    public let displayName: String
    public let configuration: RemoteSourceConfiguration
    public let credentialReference: UUID?

    public init(id: UUID = UUID(), bindingID: UUID = UUID(), configurationRevision: Int64 = 1,
                displayName: String, configuration: RemoteSourceConfiguration, credentialReference: UUID? = nil) throws {
        self.id = id; self.bindingID = bindingID; self.configurationRevision = configurationRevision
        self.displayName = displayName; self.configuration = configuration; self.credentialReference = credentialReference
        try validate()
    }
    public func validate() throws {
        try configuration.validate()
        guard configurationRevision > 0, configurationRevision < Int64.max,
              CatalogValidation.text(displayName, max: 1024) else { throw RemoteCatalogError.invalidConfiguration }
        switch configuration {
        case .local: guard credentialReference == nil else { throw RemoteCatalogError.invalidConfiguration }
        case .oneDrive: guard credentialReference != nil else { throw RemoteCatalogError.invalidConfiguration }
        case .webDAV: break
        }
    }
    /// Stable across launches; switching account or endpoint requires a new binding.
    public var sourceNamespace: String { bindingID.uuidString }
}
