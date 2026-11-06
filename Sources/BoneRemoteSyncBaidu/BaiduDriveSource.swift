import Foundation
import BoneRemoteSyncCore

/// 百度个人网盘的应用目录来源；宿主负责应用审核、目录授权、OAuth UI 和安全令牌存储。
public actor BaiduDriveSource: RemoteSource {
    public nonisolated let kind: RemoteSourceKind = .baidu
    public nonisolated let capabilities: RemoteCapabilities
    public nonisolated let configuration: BaiduDriveConfiguration
    let endpoints: BDEndpoints
    private let refreshToken: BaiduDriveTokenRefresher?
    private let now: @Sendable () -> Date
    private var generation = UUID()
    private var client: BDHTTPClient?
    private var token: BaiduDriveToken?
    private var userID: String?
    private var ready = false
    private var refreshing: (id: UUID, task: Task<BaiduDriveToken, any Error>)?
    var activeMutation = false
    var destinations = Set<String>()
    var cursors: [String: BDCursor] = [:]
    var cursorOrder: [String] = []
    let cursorCapacity: Int

    public init(configuration: BaiduDriveConfiguration, refreshToken: BaiduDriveTokenRefresher? = nil) {
        self.configuration = configuration; self.endpoints = .production; self.refreshToken = refreshToken
        self.now = Date.init; self.cursorCapacity = 1024
        capabilities = .init(idAddressing: true, upload: true, makeDirectory: true, remove: true, move: true, copy: true,
                             maxConcurrentTransfers: configuration.maxConcurrentTransfers)
    }
    init(configuration: BaiduDriveConfiguration, endpoints: BDEndpoints, refreshToken: BaiduDriveTokenRefresher? = nil,
         now: @escaping @Sendable () -> Date = Date.init, cursorCapacity: Int = 1024) {
        self.configuration = configuration; self.endpoints = endpoints; self.refreshToken = refreshToken
        self.now = now; self.cursorCapacity = max(1, cursorCapacity)
        capabilities = .init(idAddressing: true, upload: true, makeDirectory: true, remove: true, move: true, copy: true,
                             maxConcurrentTransfers: configuration.maxConcurrentTransfers)
    }
    deinit { client?.cancel(); refreshing?.task.cancel() }

    public func connect(_ credential: RemoteCredential) async throws { try await open(credential, expectedUserID: nil) }
    /// 核对已保存账号后才请求目录；账号不符时不会访问文件。
    public func connect(_ credential: RemoteCredential, expectedUserID: String) async throws {
        try await open(credential, expectedUserID: expectedUserID)
    }
    private func open(_ credential: RemoteCredential, expectedUserID: String?) async throws {
        invalidate()
        do {
            switch credential {
            case .oauth(let access, let refresh, let expiry):
                token = try .init(accessToken: access, refreshToken: refresh, expiresAt: expiry ?? .distantFuture)
            case .apiToken(let access): token = try .init(accessToken: access, expiresAt: .distantFuture)
            default: throw RemoteSyncError.authenticationFailed(reason: "百度网盘需要 OAuth token")
            }
        } catch { throw RemoteSyncError.authenticationFailed(reason: "百度网盘凭据无效") }
        let gen = generation, http = BDHTTPClient(configuration: configuration, endpoints: endpoints)
        client = http
        do {
            let current = try await validToken(generation: gen, client: http)
            let info = try await Self.perform(endpoints.api.appendingPathComponent("nas"), parameters: ["method": "uinfo"],
                                              body: nil, contentType: nil, access: current.accessToken, client: http)
            try checkGeneration(gen)
            guard let uk = info["uk"]?.uintString else { throw BaiduDriveError.invalidResponse }
            guard expectedUserID == nil || expectedUserID == uk else { throw BaiduDriveError.invalidReference }
            userID = uk
            let ctx = BDContext(generation: gen, client: http, userID: uk, binding: BDLocation.binding(userID: uk, configuration: configuration))
            let root = try await item(path: "/", context: ctx)
            guard root.entry.isDirectory else { throw RemoteSyncError.unsupported(operation: "百度根路径必须为已存在的授权目录") }
            try check(ctx); ready = true
        } catch {
            if generation == gen { invalidate() }
            throw BDHTTPClient.mapped(error)
        }
    }
    public func disconnect() async { invalidate() }
    public func connectedUserID() throws -> String { try context().userID }
    public func connectedBinding() throws -> RemoteSourceBinding { .init(kind: .baidu, identity: try context().binding) }
    private func invalidate() {
        generation = UUID(); ready = false; client?.cancel(); refreshing?.task.cancel()
        client = nil; token = nil; userID = nil; refreshing = nil; cursors.removeAll(); cursorOrder.removeAll()
        // Mutation/target reservations are released only by the old operation's cleanup.
    }
    func context() throws -> BDContext {
        try Task.checkCancellation()
        guard ready, let client, let userID else { throw RemoteSyncError.notConnected }
        return .init(generation: generation, client: client, userID: userID, binding: BDLocation.binding(userID: userID, configuration: configuration))
    }
    func check(_ context: BDContext) throws { try checkGeneration(context.generation) }
    private func checkGeneration(_ gen: UUID) throws {
        guard !Task.isCancelled, generation == gen, client != nil else { throw RemoteSyncError.cancelled }
    }

    private func validToken(generation gen: UUID, client http: BDHTTPClient) async throws -> BaiduDriveToken {
        try checkGeneration(gen)
        guard let token else { throw RemoteSyncError.notConnected }
        if token.expiresAt.timeIntervalSince(now()) > 30 { return token }
        guard token.refreshToken != nil, let refreshToken else { throw RemoteSyncError.authenticationFailed(reason: "百度网盘令牌过期，需重新授权") }
        let work: (id: UUID, task: Task<BaiduDriveToken, any Error>)
        if let refreshing { work = refreshing }
        else {
            let expectedUser = userID, endpoint = endpoints.api.appendingPathComponent("nas"), clock = now
            work = (UUID(), Task {
                let next = try await refreshToken(token)
                try Task.checkCancellation()
                guard next.expiresAt.timeIntervalSince(clock()) > 30, next.refreshToken != nil else { throw BaiduDriveError.invalidResponse }
                let info = try await Self.perform(endpoint, parameters: ["method": "uinfo"], body: nil, contentType: nil,
                                                 access: next.accessToken, client: http)
                guard let uk = info["uk"]?.uintString, expectedUser == nil || expectedUser == uk else { throw BaiduDriveError.invalidReference }
                return next
            })
            refreshing = work
        }
        let next: BaiduDriveToken
        do { next = try await work.task.value }
        catch {
            if generation == gen { invalidate() }
            if error is CancellationError || Task.isCancelled { throw RemoteSyncError.cancelled }
            throw RemoteSyncError.authenticationFailed(reason: "百度网盘令牌刷新失败，请重新授权")
        }
        guard generation == gen, client != nil else { throw RemoteSyncError.cancelled }
        // A cancelled waiter must not discard a successfully rotated, already-persisted token.
        if refreshing?.id == work.id { self.token = next; refreshing = nil }
        try checkGeneration(gen)
        return next
    }

    func api(_ endpoint: String, method: String, parameters: [String: String] = [:], form: [String: String]? = nil,
             context: BDContext) async throws -> BDJSON {
        var query = parameters; query["method"] = method
        return try await sendJSON(endpoints.api.appendingPathComponent(endpoint), parameters: query,
                                  body: form.map { Data(BDLocation.form($0).utf8) },
                                  contentType: form == nil ? nil : "application/x-www-form-urlencoded", context: context)
    }
    func sendJSON(_ url: URL, parameters: [String: String], body: Data? = nil, contentType: String? = nil,
                  context: BDContext, requireCode: Bool = true) async throws -> BDJSON {
        try check(context)
        let safeURL = try BDLocation.serviceURL(url, endpoints: endpoints)
        let current = try await validToken(generation: context.generation, client: context.client)
        try check(context)
        let result = try await Self.perform(safeURL, parameters: parameters, body: body, contentType: contentType,
                                            access: current.accessToken, client: context.client, requireCode: requireCode)
        try check(context)
        return result
    }
    private static func perform(_ url: URL, parameters: [String: String], body: Data?, contentType: String?, access: String,
                                client: BDHTTPClient, requireCode: Bool = true) async throws -> BDJSON {
        var parameters = parameters; parameters["access_token"] = access
        var request = URLRequest(url: try BDLocation.url(url, parameters: parameters))
        request.httpMethod = body == nil ? "GET" : "POST"
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let result = try await client.send(request, body: body)
        let value: BDJSON
        do { value = try JSONDecoder().decode(BDJSON.self, from: result.data) }
        catch { throw BaiduDriveError.invalidResponse }
        return try BDAPI.checked(value, requireCode: requireCode)
    }
    func downloadToken(context: BDContext) async throws -> String {
        try await validToken(generation: context.generation, client: context.client).accessToken
    }
}

struct BDContext: Sendable {
    let generation: UUID
    let client: BDHTTPClient
    let userID: String
    let binding: String
}
struct BDItem: Sendable {
    let entry: RemoteEntry
    let remotePath: String
    let fsid: String
    let dlink: String?
    let cloudHash: String?
}
struct BDCursor {
    let path: String
    let parentID: String?
    let requestLimit: Int?
    let includeHidden: Bool
    let offset: Int
    let seenIDs: Set<String>
    let seenPaths: Set<String>
}
