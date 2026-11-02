import Foundation
import BoneRemoteSyncCore

/// OneDrive Personal 公共客户端配置；客户端应用中不得嵌入 client secret。
public struct OneDriveConfiguration: Sendable {
    public let clientID: String
    public let redirectURI: URL
    public let timeout: TimeInterval
    /// 创建并校验 OneDrive OAuth 应用参数和请求超时。
    public init(clientID: String, redirectURI: URL, timeout: TimeInterval = 60) throws {
        guard !clientID.isEmpty, !clientID.contains(where: { $0.isWhitespace }),
              let scheme = redirectURI.scheme, !scheme.isEmpty,
              redirectURI.query == nil, redirectURI.fragment == nil,
              redirectURI.user == nil, redirectURI.password == nil,
              timeout.isFinite, timeout > 0, timeout <= 86400 else {
            throw RemoteSyncError.unsupported(operation: "OneDrive 应用配置")
        }
        self.clientID = clientID; self.redirectURI = redirectURI; self.timeout = timeout
    }
}

struct ODEndpoints: Sendable {
    let graph: URL
    let authority: URL
    let allowsLoopback: Bool
    static let production = ODEndpoints(graph: URL(string: "https://graph.microsoft.com/v1.0/")!,
        authority: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/")!, allowsLoopback: false)
}

/// OneDrive OAuth 令牌的安全内存表示；宿主应保存到账号作用域 Keychain。
public struct OneDriveToken: Sendable, CustomStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public var credential: RemoteCredential { .oauth(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt) }
    public var description: String { "OneDriveToken(***)" }
}
