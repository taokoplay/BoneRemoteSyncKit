import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncContent

/// Kavita v0.9.1.4 native content API. File listing is unsupported; only explicitly prepared
/// chapter downloads participate in RemoteSource stat/download and the Transfer materializer.
/// Progress writes and token refresh are explicit; no operation is automatically replayed.
public actor KavitaSource: RemoteSource {
    public nonisolated let kind: RemoteSourceKind = .kavita
    public nonisolated let capabilities: RemoteCapabilities
    let configuration: KavitaConfiguration
    var generation = UUID()
    var client: ContentHTTPClient?
    var pendingClient: ContentHTTPClient?
    var accountValue: KavitaAccount?
    var tokens: KavitaTokens?
    var refreshing = false
    var registry = ContentResourceRegistry()
    var destinations = Set<String>()

    struct Context {
        let generation: UUID
        let client: ContentHTTPClient
    }

    public init(configuration: KavitaConfiguration) {
        self.configuration = configuration
        capabilities = .init(list: false, stat: true, download: true,
                             maxConcurrentTransfers: configuration.maxConcurrentRequests)
    }

    /// `.basic` posts username/password to Account/login; `.apiToken` sends X-API-Key directly.
    /// `.oauth` supplies an existing JWT. Kavita JWT refresh is explicit, irrespective of expiresAt.
    public func connect(_ credential: RemoteCredential) async throws {
        try await connect(credential, expectedUserID: nil)
    }

    public func connect(_ credential: RemoteCredential, expectedUserID: Int?) async throws {
        reset()
        let attempt = generation
        do {
            if let expectedUserID { try KavitaValidation.id(expectedUserID) }
            let authorization: ContentAuthorization
            switch credential {
            case .apiToken(let key): authorization = .apiKey(try ContentValidation.token(key))
            case .oauth(let access, let refresh, _):
                tokens = try .init(accessToken: access, refreshToken: refresh)
                authorization = .bearer(access)
            case .basic(let username, let password):
                try KavitaValidation.password(username: username, password: password)
                let loginClient = try ContentHTTPClient(configuration: configuration)
                client = loginClient
                let response = try await loginClient.send(path: ["api", "Account", "login"], method: "POST",
                    body: ContentCoding.encode(KavitaLogin(username: username, password: password)))
                try checkAttempt(attempt, client: loginClient)
                let pair = try ContentCoding.decode(KavitaTokenWire.self, from: response).validated()
                tokens = pair
                authorization = .bearer(pair.accessToken)
                loginClient.cancel()
            default:
                throw RemoteSyncError.unsupported(operation: "Kavita credential")
            }
            let connected = try ContentHTTPClient(configuration: configuration, authorization: authorization)
            client = connected
            let response = try await connected.send(path: ["api", "Account"])
            try checkAttempt(attempt, client: connected)
            let identity = try ContentCoding.decode(KavitaAccount.self, from: response)
            try KavitaValidation.responseID(identity.id)
            if let expectedUserID, identity.id != expectedUserID { throw ContentServerError.identityChanged }
            accountValue = identity
        } catch {
            if generation == attempt { reset() }
            throw error
        }
    }

    /// Explicit JWT entry point. API keys must use connect(.apiToken(...)).
    public func connectJWT(_ tokens: KavitaTokens, expectedUserID: Int? = nil) async throws {
        try await connect(.oauth(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: nil),
                          expectedUserID: expectedUserID)
    }

    public func disconnect() async { reset() }

    public func connectedUserID() throws -> Int { _ = try context(); return accountValue!.id }
    public func account() throws -> KavitaAccount { _ = try context(); return accountValue! }
    /// Returns credentials only for hosts that explicitly persist JWTs; direct API key sessions return nil.
    public func currentTokens() throws -> KavitaTokens? { _ = try context(); return tokens }
    public func sourceBinding() throws -> RemoteSourceBinding {
        let context = try context()
        return .init(kind: kind, identity: context.generation.uuidString)
    }

    /// Serial, explicit refresh. On success rotates the connection and invalidates existing references.
    /// A failed refresh is never retried; the host may need to sign in again if the server rotated tokens.
    public func refreshTokens() async throws -> KavitaTokens {
        let context = try context()
        guard !refreshing else { throw RemoteSyncError.rateLimited(retryAfter: nil) }
        guard let old = tokens, let refresh = old.refreshToken else {
            throw RemoteSyncError.unsupported(operation: "Kavita session has no refresh token")
        }
        refreshing = true
        defer {
            if generation == context.generation { refreshing = false; pendingClient = nil }
        }
        let response = try await request(context, path: ["api", "Account", "refresh-token"], method: "POST",
            body: ContentCoding.encode(KavitaRefresh(token: old.accessToken, refreshToken: refresh)))
        try check(context)
        let fresh = try ContentCoding.decode(KavitaTokenWire.self, from: response).validated(requireRefresh: true)
        let candidate = try ContentHTTPClient(configuration: configuration, authorization: .bearer(fresh.accessToken))
        pendingClient = candidate
        do {
            let verified = try await candidate.send(path: ["api", "Account"])
            try check(context)
            let identity = try ContentCoding.decode(KavitaAccount.self, from: verified)
            guard identity.id == accountValue?.id else { throw ContentServerError.identityChanged }
            context.client.cancel()
            generation = UUID(); registry.removeAll()
            client = candidate; pendingClient = nil; tokens = fresh; accountValue = identity; refreshing = false
            return fresh
        } catch {
            candidate.cancel()
            throw error
        }
    }

    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        throw RemoteSyncError.unsupported(operation: "Kavita filesystem listing; use libraries/series/volumes")
    }
    public func stat(path: String) async throws -> RemoteEntry {
        _ = try context()
        return try registry.stat(path: path)
    }

    public func download(_ entry: RemoteEntry, to destination: URL,
                         options: RemoteDownloadOptions = .init()) async throws -> RemoteEntry {
        let context = try context()
        guard options.resumeFrom == nil, options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "Kavita resume/conditional download")
        }
        let resource = try registry.resource(entry: entry)
        let file = try ContentDownloadFile(destination: destination)
        guard destinations.insert(file.lockKey).inserted else {
            file.cleanup()
            throw RemoteSyncError.conflict(path: "Content download destination")
        }
        defer { file.cleanup(); destinations.remove(file.lockKey) }
        try file.validate(overwrite: options.overwrite)
        let bytes = try await context.client.download(resource, file: file, options: options)
        try check(context)
        try file.install(overwrite: options.overwrite, bytes: bytes)
        return entry
    }

    func reset() {
        client?.cancel(); pendingClient?.cancel()
        client = nil; pendingClient = nil; accountValue = nil; tokens = nil; refreshing = false
        generation = UUID(); registry.removeAll()
        // Destination reservations outlive reset until each old operation has cleaned up its staging file.
    }
    func context() throws -> Context {
        guard let client, accountValue != nil else { throw RemoteSyncError.notConnected }
        try Task.checkCancellation()
        return .init(generation: generation, client: client)
    }
    func checkAttempt(_ attempt: UUID, client candidate: ContentHTTPClient) throws {
        try Task.checkCancellation()
        guard generation == attempt, client === candidate else { throw RemoteSyncError.cancelled }
    }
    func check(_ context: Context) throws {
        try checkAttempt(context.generation, client: context.client)
        guard accountValue != nil else { throw RemoteSyncError.notConnected }
    }
    func request(_ context: Context, path: [String], query: [URLQueryItem] = [], method: String = "GET",
                 body: Data? = nil, kind: ContentResponseKind = .json) async throws -> ContentHTTPResponse {
        try check(context)
        let response = try await context.client.send(path: path, query: query, method: method, body: body, kind: kind)
        try check(context)
        return response
    }
    func json<T: Decodable>(_ type: T.Type, context: Context, path: [String],
                            query: [URLQueryItem] = []) async throws -> T {
        let response = try await request(context, path: path, query: query)
        try check(context)
        return try ContentCoding.decode(type, from: response)
    }
}

struct KavitaLogin: Encodable { let username: String; let password: String }
struct KavitaRefresh: Encodable { let token: String; let refreshToken: String }
struct KavitaTokenWire: Decodable {
    let token: String
    let refreshToken: String?
    func validated(requireRefresh: Bool = false) throws -> KavitaTokens {
        guard !requireRefresh || refreshToken != nil else { throw ContentServerError.invalidResponse }
        do { return try .init(accessToken: token, refreshToken: refreshToken) }
        catch { throw ContentServerError.invalidResponse }
    }
}
