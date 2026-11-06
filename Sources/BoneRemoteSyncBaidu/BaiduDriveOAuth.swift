import Foundation
import BoneRemoteSyncCore

public enum BaiduDriveAuthorizationFlow: Sendable { case implicit, authorizationCode }

/// 授权事务仅在创建它的 OAuth 实例内有效，10分钟过期。
public struct BaiduDriveAuthorization: Sendable, CustomStringConvertible {
    public let url: URL
    public let state: String
    let id: UUID
    public var description: String { "BaiduDriveAuthorization(***)" }
}

public enum BaiduDriveAuthorizationResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case code(String)
    case token(BaiduDriveToken)
    public var description: String { "BaiduDriveAuthorizationResult(***)" }
    public var debugDescription: String { description }
}

/// OAuth UI 由宿主管理；授权码交换与 refresh 必须由保管 SecretKey 的宿主服务端完成。
/// 官方接口未声明 PKCE；本类型不会伪称提供 PKCE 保证。
public actor BaiduDriveOAuth {
    private struct Pending { let state: String; let redirect: URL; let flow: BaiduDriveAuthorizationFlow; let expires: Date }
    private let appKey: String
    private var pending: [UUID: Pending] = [:]
    public init(configuration: BaiduDriveConfiguration) { appKey = configuration.appKey }

    public func authorize(redirectURI: URL, flow: BaiduDriveAuthorizationFlow = .implicit) throws -> BaiduDriveAuthorization {
        guard let c = URLComponents(url: redirectURI, resolvingAgainstBaseURL: true), let scheme = c.scheme,
              !scheme.isEmpty, !["http", "file", "javascript", "data"].contains(scheme.lowercased()),
              c.query == nil, c.fragment == nil, c.user == nil, c.password == nil,
              c.host?.isEmpty == false, redirectURI.absoluteString.utf8.count <= 4096 else { throw BaiduDriveError.invalidConfiguration }
        pending = pending.filter { $0.value.expires > Date() }
        guard pending.count < 8 else { throw BaiduDriveError.invalidConfiguration }
        let id = UUID(), state = UUID().uuidString + UUID().uuidString
        let url = try BDLocation.url(URL(string: "https://openapi.baidu.com/oauth/2.0/authorize")!, parameters: [
            "response_type": flow == .implicit ? "token" : "code", "client_id": appKey,
            "redirect_uri": redirectURI.absoluteString, "scope": "basic,netdisk", "display": "mobile", "state": state
        ])
        pending[id] = .init(state: state, redirect: redirectURI, flow: flow, expires: Date().addingTimeInterval(600))
        return .init(url: url, state: state, id: id)
    }

    public func complete(_ authorization: BaiduDriveAuthorization, callbackURL: URL) throws -> BaiduDriveAuthorizationResult {
        guard let p = pending.removeValue(forKey: authorization.id), p.state == authorization.state, p.expires > Date(),
              var callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
              let expected = URLComponents(url: p.redirect, resolvingAgainstBaseURL: true),
              callback.scheme == expected.scheme, callback.host == expected.host, callback.port == expected.port,
              callback.percentEncodedPath == expected.percentEncodedPath, callback.user == nil, callback.password == nil,
              callbackURL.absoluteString.utf8.count <= 32768 else { throw BaiduDriveError.invalidReference }
        let items: [URLQueryItem]
        switch p.flow {
        case .implicit:
            guard callback.query == nil, let fragment = callback.percentEncodedFragment else { throw BaiduDriveError.invalidReference }
            callback.percentEncodedQuery = fragment; items = callback.queryItems ?? []
        case .authorizationCode:
            guard callback.fragment == nil else { throw BaiduDriveError.invalidReference }
            items = callback.queryItems ?? []
        }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, values[item.name] == nil else { throw BaiduDriveError.invalidReference }
            values[item.name] = value
        }
        guard values["state"] == p.state else { throw BaiduDriveError.invalidReference }
        guard values["error"] == nil else { throw RemoteSyncError.authenticationFailed(reason: "百度网盘授权未完成") }
        switch p.flow {
        case .authorizationCode:
            guard let code = values["code"], BDLocation.validToken(code) else { throw BaiduDriveError.invalidReference }
            return .code(code)
        case .implicit:
            guard let access = values["access_token"], let secondsText = values["expires_in"],
                  let seconds = Int(secondsText), (1...31_536_000).contains(seconds),
                  let rawScopes = values["scope"] else { throw BaiduDriveError.invalidReference }
            let scopes = Set(rawScopes.replacingOccurrences(of: "+", with: " ").replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init))
            guard scopes.isSuperset(of: ["basic", "netdisk"]) else { throw RemoteSyncError.authenticationFailed(reason: "缺少百度网盘授权范围") }
            return .token(try BaiduDriveToken(accessToken: access, expiresAt: Date().addingTimeInterval(TimeInterval(seconds))))
        }
    }
    public func cancel(_ authorization: BaiduDriveAuthorization) { pending[authorization.id] = nil }
}
