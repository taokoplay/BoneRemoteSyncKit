import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncBaidu

@Suite struct BaiduOAuthTests {
    let config = try! BaiduDriveConfiguration(appKey: "fixture-app", rootPath: "/apps/Fixture")
    let redirect = URL(string: "fixture://oauth/baidu")!
    func callback(_ authorization: BaiduDriveAuthorization, extra: [URLQueryItem] = []) -> URL {
        var url = URLComponents(url: redirect, resolvingAgainstBaseURL: true)!
        var query = URLComponents(); query.queryItems = [.init(name: "state", value: authorization.state), .init(name: "access_token", value: "test-token"),
            .init(name: "expires_in", value: "3600"), .init(name: "scope", value: "basic netdisk")] + extra
        url.percentEncodedFragment = query.percentEncodedQuery
        return url.url!
    }
    @Test func implicitStateScopeAndSingleUse() async throws {
        let oauth = BaiduDriveOAuth(configuration: config)
        let auth = try await oauth.authorize(redirectURI: redirect)
        let query = URLComponents(url: auth.url, resolvingAgainstBaseURL: true)!.queryItems!
        #expect(auth.url.host == "openapi.baidu.com")
        #expect(query.contains(.init(name: "response_type", value: "token")))
        #expect(!auth.url.absoluteString.contains("client_secret"))
        let result = try await oauth.complete(auth, callbackURL: callback(auth))
        guard case .token(let token) = result else { Issue.record("expected token"); return }
        #expect(token.accessToken == "test-token" && token.refreshToken == nil)
        #expect(!String(describing: result).contains(token.accessToken))
        await #expect(throws: BaiduDriveError.invalidReference) { try await oauth.complete(auth, callbackURL: callback(auth)) }
    }
    @Test func codeFlowReturnsCodeForHostExchange() async throws {
        let oauth = BaiduDriveOAuth(configuration: config)
        let auth = try await oauth.authorize(redirectURI: redirect, flow: .authorizationCode)
        var url = URLComponents(url: redirect, resolvingAgainstBaseURL: true)!
        url.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: auth.state)]
        let result = try await oauth.complete(auth, callbackURL: url.url!)
        guard case .code(let code) = result else { Issue.record("expected code"); return }
        #expect(code == "fixture-code")
    }
    @Test(arguments: ["state", "redirect", "duplicate", "scope", "cancel", "other-instance"])
    func invalidOAuthTransactionsAreRejected(_ scenario: String) async throws {
        let oauth = BaiduDriveOAuth(configuration: config), other = BaiduDriveOAuth(configuration: config)
        let auth = try await oauth.authorize(redirectURI: redirect)
        var url = callback(auth)
        if scenario == "state" { url = URL(string: url.absoluteString.replacingOccurrences(of: auth.state, with: "wrong"))! }
        if scenario == "redirect" { url = URL(string: url.absoluteString.replacingOccurrences(of: "fixture://oauth", with: "fixture://evil"))! }
        if scenario == "duplicate" { url = callback(auth, extra: [.init(name: "state", value: auth.state)]) }
        if scenario == "scope" { url = URL(string: url.absoluteString.replacingOccurrences(of: "netdisk", with: "email"))! }
        if scenario == "cancel" { await oauth.cancel(auth) }
        let target = scenario == "other-instance" ? other : oauth
        await #expect(throws: (any Error).self) { try await target.complete(auth, callbackURL: url) }
    }
    @Test func configurationAndScopePathsCannotEscapeApplication() throws {
        for path in ["/", "/apps", "/apps/Fixture/../Other", "/apps/Fixture/", "/apps/Fixture\u{0}"] {
            #expect(throws: BaiduDriveError.invalidConfiguration) { try BaiduDriveConfiguration(appKey: "app", rootPath: path) }
        }
        #expect(try BDLocation.remote("../../secret", configuration: config) == "/apps/Fixture/secret")
        #expect(throws: BaiduDriveError.invalidResponse) { try BDLocation.local("/apps/Fixture2/secret", configuration: config) }
        let json = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(BaiduDriveConfiguration.self, from: json) == config)
        let bad = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "Fixture", with: "../Other")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BaiduDriveConfiguration.self, from: Data(bad.utf8)) }
    }
    @Test func identifiersStayExactAndHashesAreNotGuessed() throws {
        let value = try JSONDecoder().decode(BDJSON.self, from: Data(#"{"fs_id":18446744073709551615,"uk":"9007199254740993"}"#.utf8))
        #expect(value["fs_id"]?.uintString == "18446744073709551615")
        #expect(value["uk"]?.uintString == "9007199254740993")
        let binding = BDLocation.binding(userID: "111", configuration: config)
        let id = BDLocation.entryID("18446744073709551615", binding: binding)
        #expect(try BDLocation.fsid(id, binding: binding) == "18446744073709551615")
        #expect(throws: BaiduDriveError.invalidReference) { try BDLocation.fsid(id, binding: "other") }
    }
}
