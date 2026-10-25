import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncOneDrive

/// Host integration sample. This does not open an authorization UI or store secrets.
/// Build into the host app; provide an exact account-scoped, atomic Keychain writer.
public actor OneDriveExample {
    private let oauth: OneDriveOAuth
    private let source: OneDriveSource
    private var transaction: OneDriveAuthorization?
    public init(clientID: String, redirectURI: URL,
                persistRefreshedToken: @escaping @Sendable (OneDriveToken) throws -> Void) throws {
        let configuration = try OneDriveConfiguration(clientID: clientID, redirectURI: redirectURI)
        oauth = OneDriveOAuth(configuration: configuration)
        source = OneDriveSource(configuration: configuration, onTokenRefresh: persistRefreshedToken)
    }
    /// Present this URL with ASWebAuthenticationSession in an appropriate iOS/macOS host.
    /// Keep one transaction per account flow; do not log the URL, verifier or callback.
    public func beginAuthorization() throws -> URL {
        let value = try oauth.authorize(); transaction = value; return value.url
    }
    /// Consume each transaction once, before awaiting network I/O. Persist this initial
    /// credential in Keychain before calling connect; cancel UI when switching accounts.
    public func completeAuthorization(callback: URL) async throws -> OneDriveToken {
        guard let transaction else { throw RemoteSyncError.authenticationFailed(reason: "缺少授权事务") }
        self.transaction = nil
        let code = try oauth.authorizationCode(from: callback, transaction: transaction)
        return try await oauth.exchange(code: code, transaction: transaction)
    }
    public func connect(savedCredential: RemoteCredential) async throws { try await source.connect(savedCredential) }
    public func page(path: String = "/", cursor: String? = nil) async throws -> RemoteListPage {
        try await source.list(path: path, request: .init(cursor: cursor, limit: 100))
    }
    public func download(_ entry: RemoteEntry, to destination: URL) async throws {
        _ = try await source.download(entry, to: destination, options: .init(overwrite: false))
    }
    public func disconnect() async { transaction = nil; await source.disconnect() }
}
