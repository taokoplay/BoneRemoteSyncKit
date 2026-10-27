import Foundation
import BoneRemoteSyncCore

/// Personal main drive only. Host owns account selection, authorization UI and secure token storage.
public actor OneDriveSource: RemoteSource {
    public nonisolated let kind: RemoteSourceKind = .cloudAPI
    public nonisolated let capabilities = RemoteCapabilities(
        rangedDownload: false,
        upload: true,
        resumableUpload: false,
        makeDirectory: true,
        remove: true,
        move: true
    )
    let configuration: OneDriveConfiguration
    let endpoints: ODEndpoints
    let onTokenRefresh: (@Sendable (OneDriveToken) throws -> Void)?
    public init(configuration: OneDriveConfiguration, onTokenRefresh: (@Sendable (OneDriveToken) throws -> Void)? = nil) {
        self.configuration = configuration; self.endpoints = .production; self.onTokenRefresh = onTokenRefresh
    }
    init(configuration: OneDriveConfiguration, endpoints: ODEndpoints, onTokenRefresh: (@Sendable (OneDriveToken) throws -> Void)? = nil) {
        self.configuration = configuration; self.endpoints = endpoints; self.onTokenRefresh = onTokenRefresh
    }
    var generation = UUID()
    var client: ODHTTPClient?
    var token: OneDriveToken?
    var driveID: String?
    var refreshing: (id: UUID, task: Task<OneDriveToken, Error>)?
    var cursors: [String: ODCursor] = [:]
    var cursorOrder: [String] = []
    var destinations: Set<String> = []
    deinit { client?.cancel(); refreshing?.task.cancel() }

    public func connect(_ credential: RemoteCredential) async throws {
        invalidate()
        guard case let .oauth(access, refresh, expiry) = credential,
              !access.isEmpty, !access.contains(where: { $0.isWhitespace }),
              expiry?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw RemoteSyncError.authenticationFailed(reason: "OneDrive 需要 OAuth 凭据")
        }
        let gen = generation
        let http = ODHTTPClient(timeout: configuration.timeout)
        client = http
        token = OneDriveToken(accessToken: access, refreshToken: refresh, expiresAt: expiry ?? .distantFuture)
        do {
            let result = try await graph(endpoints.graph.appendingPathComponent("me/drive"), generation: gen, client: http)
            let drive = try decode(ODDrive.self, result.data)
            try check(gen)
            guard drive.driveType == "personal", !drive.id.isEmpty else { throw RemoteSyncError.unsupported(operation: "仅支持 OneDrive Personal 主盘") }
            driveID = drive.id
        } catch {
            if generation == gen { invalidate() }
            throw ODHTTPClient.mapped(error)
        }
    }
    /// 当前连接的 Personal 主盘身份，用于持久化绑定核对；断开后不可读取。
    public func connectedDriveID() throws -> String {
        try context().drive
    }

    public func disconnect() async { invalidate() }
    func invalidate() {
        generation = UUID(); client?.cancel(); refreshing?.task.cancel()
        client = nil; token = nil; driveID = nil; refreshing = nil; cursors.removeAll(); cursorOrder.removeAll()
        // Active old-generation downloads retain their reservations until their cleanup returns.
    }
    func context() throws -> ODContext {
        try Task.checkCancellation()
        guard let client, let driveID else { throw RemoteSyncError.notConnected }
        return ODContext(generation: generation, client: client, drive: driveID)
    }
    func check(_ gen: UUID) throws {
        try Task.checkCancellation()
        guard gen == generation, client != nil else { throw RemoteSyncError.cancelled }
    }
}

struct ODContext: Sendable {
    let generation: UUID
    let client: ODHTTPClient
    let drive: String
}
struct ODCursor {
    let path: String
    let limit: Int?
    let includeHidden: Bool
    let url: URL
    let resource: URL
    let visited: Set<Data>
}
