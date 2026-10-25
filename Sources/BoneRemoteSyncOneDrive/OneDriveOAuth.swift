import Foundation
import CryptoKit
import Security
import BoneRemoteSyncCore

/// A short-lived PKCE transaction. Keep it in memory and discard after handling one callback.
public struct OneDriveAuthorization: Sendable, CustomStringConvertible {
    public let url: URL
    public let state: String
    public let codeVerifier: String
    public var description: String { "OneDriveAuthorization(***)" }
}

public struct OneDriveOAuth: Sendable {
    let configuration: OneDriveConfiguration
    let endpoints: ODEndpoints
    public init(configuration: OneDriveConfiguration) { self.configuration = configuration; endpoints = .production }
    init(configuration: OneDriveConfiguration, endpoints: ODEndpoints) { self.configuration = configuration; self.endpoints = endpoints }
    public func authorize() throws -> OneDriveAuthorization {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw RemoteSyncError.underlying("OneDrive 随机数不可用")
            }
            return Self.base64URL(Data(bytes))
        }
        return try authorize(state: random(), verifier: random())
    }
    func authorize(state: String, verifier: String) throws -> OneDriveAuthorization {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard (43...128).contains(verifier.utf8.count), verifier.unicodeScalars.allSatisfy(allowed.contains),
              !state.isEmpty, state.utf8.count <= 1024 else { throw RemoteSyncError.unsupported(operation: "OneDrive PKCE 参数") }
        var url = URLComponents(url: endpoints.authority.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "Files.ReadWrite offline_access"), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))]
        return OneDriveAuthorization(url: url.url!, state: state, codeVerifier: verifier)
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public func authorizationCode(from callback: URL, transaction: OneDriveAuthorization) throws -> String {
        guard var parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.fragment == nil else {
            throw RemoteSyncError.authenticationFailed(reason: "OneDrive 授权回调无效")
        }
        let items = parts.queryItems ?? []; parts.query = nil
        guard parts.url == configuration.redirectURI,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == transaction.state,
              !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw RemoteSyncError.authenticationFailed(reason: "OneDrive 授权回调无效或被拒绝")
        }
        return code
    }
    public func exchange(code: String, transaction: OneDriveAuthorization) async throws -> OneDriveToken {
        guard !code.isEmpty else { throw RemoteSyncError.authenticationFailed(reason: "OneDrive 授权码为空") }
        return try await token([("grant_type", "authorization_code"), ("code", code),
            ("redirect_uri", configuration.redirectURI.absoluteString), ("code_verifier", transaction.codeVerifier)])
    }
    public func refresh(_ refreshToken: String) async throws -> OneDriveToken {
        let client = ODHTTPClient(timeout: configuration.timeout); defer { client.cancel() }
        return try await refresh(refreshToken, client: client)
    }
    func refresh(_ refreshToken: String, client: ODHTTPClient) async throws -> OneDriveToken {
        guard !refreshToken.isEmpty else { throw RemoteSyncError.authenticationFailed(reason: "OneDrive 刷新凭据为空") }
        return try await token([("grant_type", "refresh_token"), ("refresh_token", refreshToken)], client: client, previousRefresh: refreshToken)
    }
    private func token(_ fields: [(String, String)], client: ODHTTPClient? = nil, previousRefresh: String? = nil) async throws -> OneDriveToken {
        let owned = client == nil
        let client = client ?? ODHTTPClient(timeout: configuration.timeout)
        defer { if owned { client.cancel() } }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let fields = [("client_id", configuration.clientID), ("scope", "Files.ReadWrite offline_access")] + fields
        var request = URLRequest(url: endpoints.authority.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
        do {
            let result = try await client.send(request, limit: 1024 * 1024)
            if result.response.statusCode == 400 { throw RemoteSyncError.authenticationFailed(reason: "OneDrive 授权已失效或令牌兑换被拒绝") }
            try ODHTTPClient.validate(result.response, path: "/")
            let value = try JSONDecoder().decode(TokenResponse.self, from: result.data)
            guard value.token_type.lowercased() == "bearer", !value.access_token.isEmpty,
                  !value.access_token.contains(where: { $0.isWhitespace }),
                  value.expires_in.isFinite, value.expires_in > 0, value.expires_in <= 31_536_000,
                  value.refresh_token.map({ !$0.isEmpty }) ?? true else {
                throw RemoteSyncError.authenticationFailed(reason: "OneDrive 令牌响应无效")
            }
            return OneDriveToken(accessToken: value.access_token, refreshToken: value.refresh_token ?? previousRefresh,
                                 expiresAt: Date().addingTimeInterval(value.expires_in))
        } catch { throw ODHTTPClient.mapped(error) }
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let token_type: String
    }
}
