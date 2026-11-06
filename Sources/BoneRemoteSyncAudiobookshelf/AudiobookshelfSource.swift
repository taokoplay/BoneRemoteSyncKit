import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncContent

/// Bounded ABS v2.37.2 client. Browsing uses the typed service APIs, not a filesystem.
/// Files are read-only; progress and playback writes are explicit and never retried.
public actor AudiobookshelfSource: RemoteSource {
    public nonisolated let kind: RemoteSourceKind = .audiobookshelf
    public nonisolated let capabilities: RemoteCapabilities
    public nonisolated let configuration: AudiobookshelfConfiguration
    private var generation = UUID()
    private var client: ContentHTTPClient?
    private var user: AudiobookshelfUser?
    private var tokens: AudiobookshelfTokens?
    private var registry = ContentResourceRegistry()
    private var destinations: Set<String> = []
    private let deviceID = UUID().uuidString
    private var activeSessionID: String?
    private var sessionOperation: UUID?

    public init(configuration: AudiobookshelfConfiguration) {
        self.configuration = configuration
        capabilities = .init(list: false, stat: true, download: true,
                             maxConcurrentTransfers: configuration.maxConcurrentRequests)
    }

    /// `.basic` performs POST /login with JSON username/password, not HTTP Basic auth.
    /// `.apiToken` sends a static API token as Bearer. Other credentials are unsupported.
    public func connect(_ credential: RemoteCredential) async throws {
        try await connect(credential, expectedUserID: nil)
    }

    /// Verifies /api/me before publishing a connection. Reconnect invalidates all old
    /// file references and playback sessions, even when the account has not changed.
    public func connect(_ credential: RemoteCredential, expectedUserID: String?) async throws {
        reset()
        let attempt = generation
        do {
            if let expectedUserID { _ = try ContentValidation.id(expectedUserID) }
            let accessToken: String
            var loginUserID: String?
            var issuedTokens: AudiobookshelfTokens?
            switch credential {
            case .basic(let username, let password):
                guard !username.isEmpty, username.utf8.count <= 1024, password.utf8.count <= 32_768,
                      !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ContentServerError.invalidConfiguration
                }
                struct Login: Encodable { let username: String; let password: String }
                let loginClient = try ContentHTTPClient(configuration: configuration)
                client = loginClient
                let response = try await loginClient.send(path: ["login"], method: "POST",
                    body: ContentCoding.encode(Login(username: username, password: password)),
                    headers: ["X-Return-Tokens": "true"])
                try check(attempt, loginClient)
                let login = try ContentCoding.decode(ABSLoginDTO.self, from: response)
                loginUserID = try ContentValidation.id(login.user.id)
                issuedTokens = try .init(accessToken: login.user.accessToken, refreshToken: login.user.refreshToken)
                accessToken = login.user.accessToken
                loginClient.cancel()
            case .apiToken(let value): accessToken = try ContentValidation.token(value)
            default: throw RemoteSyncError.unsupported(operation: "Audiobookshelf credential")
            }
            let authenticated = try ContentHTTPClient(configuration: configuration, authorization: .bearer(accessToken))
            client = authenticated
            let response = try await authenticated.send(path: ["api", "me"])
            try check(attempt, authenticated)
            let identity = try ContentCoding.decode(AudiobookshelfUser.self, from: response)
            try validate(identity)
            guard expectedUserID.map({ $0 == identity.id }) ?? true,
                  loginUserID.map({ $0 == identity.id }) ?? true else { throw ContentServerError.identityChanged }
            user = identity
            tokens = issuedTokens
        } catch {
            if generation == attempt { reset() }
            throw error
        }
    }

    /// Uses an explicitly renewed access token; refresh-token rotation is owned by the host.
    /// No implicit refresh, cookie session, retry, or mutation replay occurs.
    public func connect(tokens: AudiobookshelfTokens, expectedUserID: String) async throws {
        try await connect(.apiToken(tokens.accessToken), expectedUserID: expectedUserID)
    }

    /// Secrets are returned only on this explicit call, never in user/content models.
    public func authenticationTokens() throws -> AudiobookshelfTokens? { _ = try context(); return tokens }
    public func connectedUserID() throws -> String { try context().user.id }
    public func sourceBinding() throws -> RemoteSourceBinding {
        let c = try context()
        return .init(kind: kind, identity: c.generation.uuidString)
    }

    /// Cancels requests and invalidates local state. Close playback explicitly beforehand
    /// if server-side session accounting is required; disconnect makes no hidden writes.
    public func disconnect() async { reset() }

    public func currentUser() async throws -> AudiobookshelfUser {
        let c = try context()
        let identity = try ContentCoding.decode(AudiobookshelfUser.self, from: await send(c, path: ["api", "me"]))
        try check(c)
        try validate(identity)
        guard identity.id == c.user.id else { reset(); throw ContentServerError.identityChanged }
        user = identity
        return identity
    }

    public func libraries() async throws -> [AudiobookshelfLibrary] {
        let c = try context()
        let result = try ContentCoding.decode(ABSLibrariesDTO.self, from: await send(c, path: ["api", "libraries"]))
        try check(c)
        try ABSValidation.unique(result.libraries.map(\.id))
        guard result.libraries.allSatisfy({ $0.displayOrder.map({ $0 >= 0 }) ?? true }) else {
            throw ContentServerError.invalidResponse
        }
        return result.libraries
    }

    /// Zero-based page, pageSize 1...500. No implicit fetch-all loop.
    public func items(libraryID: String, page: Int = 0, pageSize: Int = 50) async throws -> ContentPage<AudiobookshelfItem> {
        let c = try context()
        _ = try ContentValidation.id(libraryID)
        try ContentValidation.pagination(page: page, pageSize: pageSize)
        let response = try await send(c, path: ["api", "libraries", libraryID, "items"], query: [
            .init(name: "page", value: String(page)), .init(name: "limit", value: String(pageSize)),
            .init(name: "minified", value: "1")])
        try check(c)
        let result = try ContentCoding.decode(ABSItemsDTO.self, from: response)
        guard result.page.value == page, result.limit.value == pageSize, result.total >= 0,
              result.results.count == min(pageSize, max(0, result.total - page * pageSize)),
              result.results.allSatisfy({ $0.libraryId == libraryID }) else { throw ContentServerError.invalidResponse }
        try ABSValidation.unique(result.results.map(\.id), limit: pageSize)
        let values = try result.results.map { try $0.model(client: c.client) }
        return .init(items: values, page: page, pageSize: pageSize, total: result.total,
                     hasNextPage: page * pageSize + values.count < result.total)
    }

    /// Native library search; the server limits each match category, not a paginated union.
    public func search(libraryID: String, query: String, limit: Int = 25) async throws -> AudiobookshelfSearchResults {
        let c = try context()
        _ = try ContentValidation.id(libraryID)
        let query = try ContentValidation.search(query)
        try ContentValidation.pagination(page: 0, pageSize: limit)
        let response = try await send(c, path: ["api", "libraries", libraryID, "search"], query: [
            .init(name: "q", value: query), .init(name: "limit", value: String(limit))])
        try check(c)
        let result = try ContentCoding.decode(ABSSearchDTO.self, from: response)
        guard result.book != nil || result.podcast != nil else { throw ContentServerError.invalidResponse }
        let books = result.book?.map(\.libraryItem) ?? []
        let podcasts = result.podcast?.map(\.libraryItem) ?? []
        try ABSValidation.unique(books.map(\.id), limit: limit)
        try ABSValidation.unique(podcasts.map(\.id), limit: limit)
        guard books.allSatisfy({ $0.libraryId == libraryID && $0.mediaType == .book }),
              podcasts.allSatisfy({ $0.libraryId == libraryID && $0.mediaType == .podcast }) else {
            throw ContentServerError.invalidResponse
        }
        return .init(books: try books.map { try $0.model(client: c.client) },
                     podcasts: try podcasts.map { try $0.model(client: c.client) }, limit: limit)
    }

    public func item(id: String) async throws -> AudiobookshelfItem {
        let c = try context()
        let value = try await detail(id: id, context: c)
        try check(c)
        return value
    }

    /// Episode details come from the expanded podcast item, bounded by maxResponseBytes.
    public func episode(itemID: String, episodeID: String) async throws -> AudiobookshelfEpisode {
        let c = try context()
        _ = try ContentValidation.id(episodeID)
        let item = try await detail(id: itemID, context: c)
        try check(c)
        guard item.mediaType == .podcast, let episode = item.episodes?.first(where: { $0.id == episodeID }) else {
            throw RemoteSyncError.notFound(path: "Audiobookshelf episode")
        }
        return episode
    }

    public func cover(itemID: String, width: Int? = nil, height: Int? = nil) async throws -> Data {
        let c = try context()
        _ = try ContentValidation.id(itemID)
        var query: [URLQueryItem] = []
        for (name, value) in [("width", width), ("height", height)] {
            if let value {
                guard (1...4096).contains(value) else { throw ContentServerError.invalidConfiguration }
                query.append(.init(name: name, value: String(value)))
            }
        }
        let response = try await send(c, path: ["api", "items", itemID, "cover"], query: query, kind: .image)
        try check(c)
        return response.data
    }

    /// Re-fetches item details, selects exactly one file and registers a generation-bound reference.
    public func prepareDownload(itemID: String, fileID: String) async throws -> RemoteFileReference {
        let c = try context()
        _ = try ContentValidation.id(fileID)
        let item = try await detail(id: itemID, context: c)
        try check(c)
        let candidates = (item.files ?? []) + (item.audioFiles ?? []) + (item.episodes ?? []).compactMap(\.audioFile)
        guard let file = candidates.first(where: { $0.id == fileID }) else { throw ContentServerError.invalidReference }
        return try register(file: file, itemID: itemID, context: c)
    }

    public func prepareTrackDownload(itemID: String, trackIndex: Int, episodeID: String? = nil) async throws -> RemoteFileReference {
        let c = try context()
        guard (0...10_000).contains(trackIndex) else { throw ContentServerError.invalidReference }
        if let episodeID { _ = try ContentValidation.id(episodeID) }
        let item = try await detail(id: itemID, context: c)
        try check(c)
        let tracks: [AudiobookshelfAudioTrack]
        let files: [AudiobookshelfFile]
        if let episodeID, let episode = item.episodes?.first(where: { $0.id == episodeID }) {
            tracks = episode.audioTrack.map { [$0] } ?? []; files = episode.audioFile.map { [$0] } ?? []
        } else if episodeID == nil, item.mediaType == .book {
            tracks = item.tracks ?? []; files = item.audioFiles ?? []
        } else { throw ContentServerError.invalidReference }
        guard let track = tracks.first(where: { $0.index == trackIndex }),
              let file = files.first(where: { $0.id == track.fileID }) else { throw ContentServerError.invalidReference }
        return try register(file: file, itemID: itemID, context: c)
    }

    /// Nil means ABS returned 404 (no saved progress), not a fabricated zero progress record.
    public func mediaProgress(itemID: String, episodeID: String? = nil) async throws -> AudiobookshelfMediaProgress? {
        let c = try context()
        let path = try progressPath(itemID: itemID, episodeID: episodeID)
        do {
            let result = try ContentCoding.decode(AudiobookshelfMediaProgress.self, from: await send(c, path: path))
            try check(c)
            guard result.userId == c.user.id, result.libraryItemId == itemID, result.episodeId == episodeID else {
                throw ContentServerError.invalidResponse
            }
            _ = try ContentValidation.id(result.id)
            try ABSValidation.number(result.duration); try ABSValidation.number(result.currentTime)
            try ABSValidation.number(result.progress, maximum: 1); try ABSValidation.number(result.ebookProgress, maximum: 1)
            try ABSValidation.number(result.lastUpdate); try ABSValidation.number(result.startedAt); try ABSValidation.number(result.finishedAt)
            return result
        } catch RemoteSyncError.notFound { try check(c); return nil }
    }

    public func updateMediaProgress(itemID: String, episodeID: String? = nil, update: AudiobookshelfProgressUpdate) async throws {
        let c = try context()
        let path = try progressPath(itemID: itemID, episodeID: episodeID)
        try ABSValidation.number(update.currentTime); try ABSValidation.number(update.duration)
        try ABSValidation.number(update.progress, maximum: 1); try ABSValidation.number(update.ebookProgress, maximum: 1)
        guard update.ebookLocation.map({ $0.utf8.count <= 8192 }) ?? true else { throw ContentServerError.invalidConfiguration }
        let body = try ContentCoding.encode(update)
        guard body != Data("{}".utf8) else { throw ContentServerError.invalidConfiguration }
        try await acknowledge(c, path: path, method: "PATCH", body: body)
        try check(c)
    }

    /// Starts one direct session for this source's device, replacing its previous session.
    /// `supportedMimeTypes` describes the host player; no transcoding/HLS is implemented.
    public func createPlaybackSession(itemID: String, episodeID: String? = nil,
                                      supportedMimeTypes: [String] = ["audio/mpeg", "audio/mp4"]) async throws -> AudiobookshelfPlaybackSession {
        let c = try context()
        let operation = try reserveSessionOperation()
        defer { if sessionOperation == operation { sessionOperation = nil } }
        if let episodeID { _ = try ContentValidation.id(episodeID) }
        guard !supportedMimeTypes.isEmpty, supportedMimeTypes.count <= 32,
              supportedMimeTypes.allSatisfy({ $0.hasPrefix("audio/") && $0.utf8.count <= 128 && !$0.contains("mpegurl") }) else {
            throw ContentServerError.invalidConfiguration
        }
        let item = try await detail(id: itemID, context: c)
        try check(c)
        let expectedTracks: [AudiobookshelfAudioTrack]
        if let episodeID, let episode = item.episodes?.first(where: { $0.id == episodeID }) {
            expectedTracks = episode.audioTrack.map { [$0] } ?? []
        } else if episodeID == nil, item.mediaType == .book { expectedTracks = item.tracks ?? [] }
        else { throw ContentServerError.invalidReference }
        guard !expectedTracks.isEmpty, expectedTracks.allSatisfy({ supportedMimeTypes.contains($0.mimeType) }) else {
            throw RemoteSyncError.unsupported(operation: "Audiobookshelf host audio format")
        }
        struct Device: Encodable { let deviceId: String; let clientName = "BoneRemoteSyncKit" }
        struct Play: Encodable {
            let forceDirectPlay = true
            let forceTranscode = false
            let mediaPlayer = "BoneRemoteSyncKit host"
            let supportedMimeTypes: [String]
            let deviceInfo: Device
        }
        var path = ["api", "items", itemID, "play"]
        if let episodeID { path.append(episodeID) }
        let response = try await sessionMutation(c, path: path, body: ContentCoding.encode(
            Play(supportedMimeTypes: supportedMimeTypes, deviceInfo: Device(deviceId: deviceID))))
        let result = try ContentCoding.decode(ABSSessionDTO.self, from: response)
        _ = try ContentValidation.id(result.id)
        guard result.userId == c.user.id, result.libraryItemId == itemID, result.libraryId == item.libraryID,
              result.episodeId == episodeID else { throw ContentServerError.invalidResponse }
        guard result.playMethod == 0 else { throw RemoteSyncError.unsupported(operation: "Audiobookshelf non-direct session") }
        try check(c)
        try ABSValidation.number(result.duration); try ABSValidation.number(result.currentTime)
        try ABSValidation.chapters(result.chapters)
        let tracks = try result.audioTracks.map { try $0.model(itemID: itemID, client: c.client) }
        try ABSValidation.unique(tracks.map(\.fileID))
        guard tracks.map(\.fileID) == expectedTracks.map(\.fileID),
              tracks.map(\.index) == expectedTracks.map(\.index),
              tracks.allSatisfy({ supportedMimeTypes.contains($0.mimeType) }) else { throw ContentServerError.invalidResponse }
        let playback = try tracks.map { track in
            AudiobookshelfPlaybackTrack(track: track, request: try c.client.streamRequest(
                path: ["api", "items", itemID, "file", track.fileID]))
        }
        activeSessionID = result.id
        return .init(id: result.id, userID: result.userId, libraryItemID: itemID, episodeID: episodeID,
                     duration: result.duration, currentTime: result.currentTime, chapters: result.chapters,
                     tracks: playback, generation: c.generation)
    }

    public func syncPlaybackSession(_ session: AudiobookshelfPlaybackSession, update: AudiobookshelfPlaybackUpdate) async throws {
        let c = try sessionContext(session)
        try validate(update)
        let operation = try reserveSessionOperation()
        defer { if sessionOperation == operation { sessionOperation = nil } }
        try await acknowledge(c, path: ["api", "session", session.id, "sync"], body: ContentCoding.encode(update))
        try check(c)
    }

    public func closePlaybackSession(_ session: AudiobookshelfPlaybackSession, update: AudiobookshelfPlaybackUpdate? = nil) async throws {
        let c = try sessionContext(session)
        if let update { try validate(update) }
        let operation = try reserveSessionOperation()
        defer { if sessionOperation == operation { sessionOperation = nil } }
        try await acknowledge(c, path: ["api", "session", session.id, "close"],
            body: update.map(ContentCoding.encode) ?? Data("{}".utf8), invalidatesSession: true)
        try check(c)
    }

    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        throw RemoteSyncError.unsupported(operation: "Audiobookshelf filesystem listing")
    }
    public func stat(path: String) async throws -> RemoteEntry { _ = try context(); return try registry.stat(path: path) }

    public func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions = .init()) async throws -> RemoteEntry {
        let c = try context()
        guard options.resumeFrom == nil, options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "Audiobookshelf resume/conditional download")
        }
        let resource = try registry.resource(entry: entry)
        let file = try ContentDownloadFile(destination: destination)
        guard destinations.insert(file.lockKey).inserted else { file.cleanup(); throw RemoteSyncError.conflict(path: "download destination") }
        defer { file.cleanup(); destinations.remove(file.lockKey) }
        try file.validate(overwrite: options.overwrite)
        let bytes = try await c.client.download(resource, file: file, options: options)
        try check(c)
        try file.install(overwrite: options.overwrite, bytes: bytes)
        return resource.entry
    }

    private struct Context { let client: ContentHTTPClient; let generation: UUID; let user: AudiobookshelfUser }
    private func context() throws -> Context {
        guard let client, let user else { throw RemoteSyncError.notConnected }
        return .init(client: client, generation: generation, user: user)
    }
    private func check(_ generation: UUID, _ client: ContentHTTPClient) throws {
        guard self.generation == generation, self.client === client else { throw RemoteSyncError.cancelled }
        if Task.isCancelled { throw RemoteSyncError.cancelled }
    }
    private func check(_ context: Context) throws { try check(context.generation, context.client) }
    private func reset() {
        client?.cancel(); client = nil; user = nil; tokens = nil
        generation = UUID(); registry.removeAll(); activeSessionID = nil; sessionOperation = nil
        // Keep reservations until in-flight downloads have finished their deferred cleanup.
    }
    private func validate(_ user: AudiobookshelfUser) throws {
        _ = try ContentValidation.id(user.id)
        guard user.isActive else { throw RemoteSyncError.authenticationFailed(reason: nil) }
        try ABSValidation.unique(user.librariesAccessible)
    }
    private func send(_ c: Context, path: [String], query: [URLQueryItem] = [], method: String = "GET",
                      body: Data? = nil, kind: ContentResponseKind = .json,
                      attempt: ContentRequestAttempt? = nil) async throws -> ContentHTTPResponse {
        try check(c)
        do {
            let response = try await c.client.send(path: path, query: query, method: method, body: body, kind: kind, attempt: attempt)
            try check(c)
            return response
        } catch { try check(c); throw error }
    }
    private func sessionMutation(_ c: Context, path: [String], body: Data,
                                 kind: ContentResponseKind = .json) async throws -> ContentHTTPResponse {
        let attempt = ContentRequestAttempt()
        defer {
            // Local admission failures cannot mutate the server. Once submitted, forbid replay
            // even on an unknown outcome, without clearing a newer connection's session.
            if attempt.mayHaveBeenSent, generation == c.generation { activeSessionID = nil }
        }
        return try await send(c, path: path, method: "POST", body: body, kind: kind, attempt: attempt)
    }
    private func acknowledge(_ c: Context, path: [String], method: String = "POST", body: Data,
                             invalidatesSession: Bool = false) async throws {
        // Express sendStatus(200) is text/plain; this is a bounded status body, not a file download.
        let response: ContentHTTPResponse
        if invalidatesSession { response = try await sessionMutation(c, path: path, body: body, kind: .binary) }
        else { response = try await send(c, path: path, method: method, body: body, kind: .binary) }
        try check(c)
        guard response.response.statusCode == 200,
              response.data == Data("OK".utf8) || response.data.isEmpty else { throw ContentServerError.invalidResponse }
    }
    private func detail(id: String, context c: Context) async throws -> AudiobookshelfItem {
        _ = try ContentValidation.id(id)
        let result = try ContentCoding.decode(ABSItemDTO.self, from: await send(c, path: ["api", "items", id],
            query: [.init(name: "expanded", value: "1")]))
        try check(c)
        guard result.id == id else { throw ContentServerError.invalidResponse }
        return try result.model(client: c.client, expanded: true)
    }
    private func register(file: AudiobookshelfFile, itemID: String, context c: Context) throws -> RemoteFileReference {
        try check(c)
        guard c.user.permissions.download else { throw RemoteSyncError.permissionDenied(path: "Audiobookshelf download") }
        return try registry.register(url: c.client.url(path: ["api", "items", itemID, "file", file.id, "download"]),
            name: file.filename, mediaType: file.mimeType, size: file.size,
            binding: sourceBinding(), limit: configuration.maxDownloadReferences)
    }
    private func progressPath(itemID: String, episodeID: String?) throws -> [String] {
        var path = ["api", "me", "progress", try ContentValidation.id(itemID)]
        if let episodeID { path.append(try ContentValidation.id(episodeID)) }
        return path
    }
    private func reserveSessionOperation() throws -> UUID {
        guard sessionOperation == nil else { throw RemoteSyncError.rateLimited(retryAfter: nil) }
        let value = UUID(); sessionOperation = value; return value
    }
    private func sessionContext(_ session: AudiobookshelfPlaybackSession) throws -> Context {
        let c = try context()
        guard session.generation == c.generation, session.id == activeSessionID, session.userID == c.user.id else {
            throw ContentServerError.invalidReference
        }
        return c
    }
    private func validate(_ update: AudiobookshelfPlaybackUpdate) throws {
        try ABSValidation.number(update.currentTime); try ABSValidation.number(update.duration)
        try ABSValidation.number(update.timeListened, maximum: 86_400)
    }
}
