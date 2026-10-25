import Foundation

/// 凭据。只承载字段本身，不负责持久化。
///
/// 持久化请使用 Keychain（`kSecClassInternetPassword`），不要写进 UserDefaults、
/// 日志或 RemoteEntry 一类会被序列化的结构里。
public enum RemoteCredential: Sendable, Equatable {
    case anonymous
    case basic(username: String, password: String)
    /// SMB 的域/工作组是可选项，家庭 NAS 通常留空。
    case smb(username: String, password: String, domain: String?)
    /// 静态令牌（各类网盘的 access token、API key）。
    case apiToken(String)
    /// OAuth。刷新逻辑由适配器内部完成，过期时间用于提前刷新。
    case oauth(accessToken: String, refreshToken: String?, expiresAt: Date?)
}

extension RemoteCredential: CustomStringConvertible {
    /// 刻意不输出任何密文，避免日志泄漏。
    public var description: String {
        switch self {
        case .anonymous:
            return "anonymous"
        case .basic(let username, _):
            return "basic(\(username), ***)"
        case .smb(let username, _, let domain):
            return "smb(\(domain ?? "-")/\(username), ***)"
        case .apiToken:
            return "apiToken(***)"
        case .oauth(_, let refreshToken, let expiresAt):
            let refresh = refreshToken == nil ? "no-refresh" : "refresh"
            let expiry = expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            return "oauth(\(refresh), expires=\(expiry))"
        }
    }
}
