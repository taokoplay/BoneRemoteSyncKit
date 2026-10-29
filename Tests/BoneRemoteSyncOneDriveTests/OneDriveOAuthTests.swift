import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveOAuthTests {
    let configuration = try! OneDriveConfiguration(clientID: "test-client", redirectURI: URL(string: "bonetest://oauth/onedrive")!)
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    @Test func pkceUsesRFC7636S256AndReadWriteScopes() throws {
        let auth = try OneDriveOAuth(configuration: configuration).authorize(state: "test-state", verifier: verifier)
        let items = URLComponents(url: auth.url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        #expect(auth.url.host == "login.microsoftonline.com")
        #expect(auth.url.path == "/consumers/oauth2/v2.0/authorize")
        #expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(query["code_challenge_method"] == "S256")
        // 写能力（upload/makeDirectory/remove/move）必须有写权限，只读 scope 会在真实账号上 403。
        #expect(query["scope"] == "Files.ReadWrite offline_access")
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "bonetest://oauth/onedrive")
        #expect(!auth.description.contains(verifier))
    }
    @Test func callbackRequiresExactRedirectStateAndUniqueCode() throws {
        let oauth = OneDriveOAuth(configuration: configuration)
        let auth = try oauth.authorize(state: "known-state", verifier: verifier)
        #expect(try oauth.authorizationCode(from: URL(string: "bonetest://oauth/onedrive?code=a%2Bb&state=known-state")!, transaction: auth) == "a+b")
        for callback in ["bonetest://other/onedrive?code=a&state=known-state", "bonetest://oauth/other?code=a&state=known-state",
                         "bonetest://oauth/onedrive?code=a&state=bad", "bonetest://oauth/onedrive?code=a&state=known-state&code=b",
                         "bonetest://oauth/onedrive?code=a&state=known-state#code=x", "bonetest://oauth/onedrive?error=access_denied&state=known-state"] {
            #expect(throws: RemoteSyncError.self) { try oauth.authorizationCode(from: URL(string: callback)!, transaction: auth) }
        }
    }
    @Test func generatedTransactionsAreUnpredictableAndVerifierIsValid() throws {
        let oauth = OneDriveOAuth(configuration: configuration)
        let first = try oauth.authorize(); let second = try oauth.authorize()
        #expect(first.state != second.state); #expect(first.codeVerifier != second.codeVerifier)
        #expect(first.state.count >= 43); #expect(first.codeVerifier.count >= 43)
        #expect(throws: RemoteSyncError.self) { try oauth.authorize(state: "x", verifier: "short") }
    }
}

#if os(macOS)
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveTokenTests {
    @Test func exchangesAndRefreshesWithoutClientSecret() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }
        let auth = try server.oauth.authorize()
        let token = try await server.oauth.exchange(code: "a+b &c", transaction: auth)
        #expect(token.accessToken == "NEW"); #expect(token.refreshToken == "ROTATED")
        #expect(token.expiresAt.timeIntervalSinceNow > 3500)
        let refreshed = try await server.oauth.refresh("rotate+&")
        #expect(refreshed.accessToken == "NEW")
        let requests = try server.requests()
        #expect(requests.count == 2)
        let body = requests[0]["body"] as! String
        #expect(body.contains("code=a%2Bb%20%26c")); #expect(body.contains("code_verifier="))
        // 兑换和刷新必须与授权阶段申请同一套写权限，否则拿到的令牌只能读。
        #expect(body.contains("scope=Files.ReadWrite%20offline_access"))
        #expect(!body.contains("client_secret")); #expect(!refreshed.description.contains("NEW"))
        #expect((requests[1]["body"] as! String).contains("refresh_token=rotate%2B%26"))
        #expect((requests[1]["body"] as! String).contains("scope=Files.ReadWrite%20offline_access"))
    }
    @Test(arguments: ["token-error", "token-large", "token-redirect", "bad-token"])
    func rejectsUntrustedTokenResponsesWithoutSecrets(scenario: String) async throws {
        let server = try OneDriveTestServer(scenario); defer { server.cleanUp() }
        do { _ = try await server.oauth.refresh("private-refresh"); Issue.record("token must fail") }
        catch { #expect(!String(describing: error).contains("SECRET")); #expect(!String(describing: error).contains("private-refresh")) }
        #expect(try server.requests().count == 1)
    }
}
#endif
