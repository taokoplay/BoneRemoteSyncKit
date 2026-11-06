import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncContent

/// Native Komga 1.30 REST client. Browsing uses the dedicated library/series/book APIs.
/// File operations address only references registered by `prepareDownload(bookID:)`.
/// Downloads never update reading progress; range/resume and conditional reads are unsupported.
public actor KomgaSource: RemoteSource {
    public nonisolated let kind: RemoteSourceKind = .komga
    public nonisolated let capabilities: RemoteCapabilities
    public nonisolated let configuration: KomgaConfiguration

    private var generation = UUID()
    private var client: ContentHTTPClient?
    private var user: KomgaUser?
    private var registry = ContentResourceRegistry()
    // Reservations survive reconnect until their old transfer has completely unwound.
    private var destinations = Set<String>()
    private struct Context: Sendable {
        let generation: UUID
        let client: ContentHTTPClient
    }

    public init(configuration: KomgaConfiguration) {
        self.configuration = configuration
        capabilities = .init(list: false, stat: true, download: true,
                             maxConcurrentTransfers: configuration.maxConcurrentRequests)
    }

    /// Basic username is an email address. API tokens are sent as X-API-Key on every request.
    /// No cookies, stored sessions, OAuth flow or credential persistence are used.
    public func connect(_ credential: RemoteCredential) async throws {
        try await connect(credential, expectedUserID: nil)
    }

    /// Authenticate with GET api/v2/users/me and optionally enforce a previously selected account.
    /// Every connect invalidates all earlier registered references, including same-user reconnects.
    public func connect(_ credential: RemoteCredential, expectedUserID: String?) async throws {
        if let expectedUserID { _ = try ContentValidation.id(expectedUserID) }
        reset()
        let authorization: ContentAuthorization
        switch credential {
        case .basic(let email, let password): authorization = .basic(username: email, password: password)
        case .apiToken(let key): authorization = .apiKey(key)
        default: throw RemoteSyncError.unsupported(operation: "Komga requires Basic email/password or an API key")
        }
        let next = try ContentHTTPClient(configuration: configuration, authorization: authorization)
        client = next
        let context = Context(generation: generation, client: next)
        do {
            let response = try await request(context, path: ["api", "v2", "users", "me"])
            try check(context)
            let verified = try KomgaCoding.decode(KomgaUser.self, response)
            try KomgaValidation.user(verified)
            guard expectedUserID.map({ $0 == verified.id }) ?? true else { throw ContentServerError.identityChanged }
            user = verified
        } catch {
            // A late cancelled connect must never clear a newer connection.
            if generation == context.generation, client === context.client { reset() }
            throw error
        }
    }

    public func disconnect() async { reset() }

    /// Revalidates identity and returns current permissions. A changed identity disconnects the source.
    public func currentUser() async throws -> KomgaUser {
        let context = try connected()
        let response = try await request(context, path: ["api", "v2", "users", "me"])
        try check(context)
        let verified = try KomgaCoding.decode(KomgaUser.self, response)
        try KomgaValidation.user(verified)
        guard user?.id == verified.id else { reset(); throw ContentServerError.identityChanged }
        user = verified
        return verified
    }

    /// Performs a fresh identity check, rather than accepting an unverified host-provided user ID.
    public func connectedUserID() async throws -> String {
        let context = try connected()
        let verified = try await currentUser()
        try check(context)
        return verified.id
    }

    /// A connection-specific binding for Transfer; discard its materializer after reconnecting.
    public func sourceBinding() throws -> RemoteSourceBinding {
        _ = try connected()
        return .init(kind: kind, identity: generation.uuidString)
    }

    public func libraries() async throws -> [KomgaLibrary] {
        let context = try connected()
        let response = try await request(context, path: ["api", "v1", "libraries"])
        try check(context)
        let values = try KomgaCoding.decode([KomgaLibrary].self, response)
        try KomgaValidation.unique(values.map(\.id))
        return values
    }

    public func library(id: String) async throws -> KomgaLibrary {
        let context = try connected()
        let response = try await request(context, path: ["api", "v1", "libraries", try ContentValidation.id(id)])
        try check(context)
        let value = try KomgaCoding.decode(KomgaLibrary.self, response)
        guard value.id == id else { throw ContentServerError.invalidResponse }
        return value
    }

    /// Server-side POST search. Pages are zero-based, size 1...500; empty sort uses relevance
    /// for search and metadata.titleSort ascending for ordinary browsing.
    public func series(libraryID: String? = nil, search: String? = nil, page: Int = 0, pageSize: Int = 50,
                       sort: [KomgaSeriesSort] = []) async throws -> ContentPage<KomgaSeries> {
        let context = try connected()
        let body = try ContentCoding.encode(KomgaSearch(libraryID: libraryID, search: search))
        let ordering = sort.isEmpty && search == nil ? [KomgaSeriesSort(.title)] : sort
        let query = try pagination(page, pageSize, sorts: ordering.map { $0.field.rawValue + "," + $0.direction.rawValue })
        let response = try await request(context, path: ["api", "v1", "series", "list"], query: query, method: "POST", body: body)
        try check(context)
        let envelope = try KomgaCoding.decode(KomgaPageEnvelope<KomgaSeries>.self, response)
        let result = try envelope.page(requested: page, pageSize: pageSize)
        try KomgaValidation.unique(result.items.map(\.id))
        for value in result.items { try KomgaValidation.series(value, libraryID: libraryID) }
        return result
    }

    /// Native series detail, optionally constrained to its expected parent library.
    public func series(id: String, libraryID: String? = nil) async throws -> KomgaSeries {
        let context = try connected()
        if let libraryID { _ = try ContentValidation.id(libraryID) }
        let value = try await fetchSeries(id, context)
        try check(context)
        try KomgaValidation.series(value, id: id, libraryID: libraryID)
        return value
    }

    /// Server-side book filtering and full-text search. Supplying both parents encodes allOf.
    /// Empty sort uses relevance for search and metadata.numberSort ascending otherwise.
    public func books(libraryID: String? = nil, seriesID: String? = nil, search: String? = nil,
                      page: Int = 0, pageSize: Int = 50, sort: [KomgaBookSort] = []) async throws -> ContentPage<KomgaBook> {
        let context = try connected()
        let body = try ContentCoding.encode(KomgaSearch(libraryID: libraryID, seriesID: seriesID, search: search))
        let ordering = sort.isEmpty && search == nil ? [KomgaBookSort(.number)] : sort
        let query = try pagination(page, pageSize, sorts: ordering.map { $0.field.rawValue + "," + $0.direction.rawValue })
        let response = try await request(context, path: ["api", "v1", "books", "list"], query: query, method: "POST", body: body)
        try check(context)
        let envelope = try KomgaCoding.decode(KomgaPageEnvelope<KomgaBook>.self, response)
        let result = try envelope.page(requested: page, pageSize: pageSize)
        try KomgaValidation.unique(result.items.map(\.id))
        for value in result.items { try KomgaValidation.book(value, libraryID: libraryID, seriesID: seriesID) }
        return result
    }

    public func book(id: String, seriesID: String? = nil, libraryID: String? = nil) async throws -> KomgaBook {
        let context = try connected()
        if let seriesID { _ = try ContentValidation.id(seriesID) }
        if let libraryID { _ = try ContentValidation.id(libraryID) }
        let value = try await fetchBook(id, context)
        try check(context)
        try KomgaValidation.book(value, id: id, libraryID: libraryID, seriesID: seriesID)
        return value
    }

    /// Fetch a bounded JPEG cover. Missing artwork remains a server notFound error.
    public func seriesCover(seriesID: String) async throws -> Data {
        let context = try connected()
        _ = try await fetchSeries(seriesID, context)
        try check(context)
        let response = try await request(context, path: ["api", "v1", "series", seriesID, "thumbnail"], kind: .image,
                                         headers: ["Accept": "image/jpeg"])
        try check(context)
        return try image(response)
    }

    public func bookCover(bookID: String) async throws -> Data {
        let context = try connected()
        _ = try await fetchBook(bookID, context)
        try check(context)
        let response = try await request(context, path: ["api", "v1", "books", bookID, "thumbnail"], kind: .image,
                                         headers: ["Accept": "image/jpeg"])
        try check(context)
        return try image(response)
    }

    /// The native, non-paginated one-based page directory. Availability depends on media analysis.
    public func pages(bookID: String) async throws -> [KomgaPage] {
        let context = try connected()
        let book = try await fetchBook(bookID, context)
        try check(context)
        let response = try await request(context, path: ["api", "v1", "books", bookID, "pages"])
        try check(context)
        let values = try KomgaCoding.decode([KomgaPage].self, response)
        // Ordinary EPUB has computed reading positions but no Divina image-page directory.
        let expectedCount = book.media.isEPUB && book.media.epubDivinaCompatible != true ? 0 : book.media.pagesCount
        guard values.count == expectedCount else { throw ContentServerError.invalidResponse }
        for (offset, value) in values.enumerated() {
            guard value.number == offset + 1, value.width.map({ $0 > 0 }) ?? true,
                  value.height.map({ $0 > 0 }) ?? true, value.sizeBytes.map({ $0 >= 0 }) ?? true else {
                throw ContentServerError.invalidResponse
            }
        }
        return values
    }

    /// Requests an actual image, including for PDF: contentNegotiation=false&convert=jpeg.
    /// Requires PAGE_STREAMING. The page parameter is one-based.
    public func pageImage(bookID: String, page: Int) async throws -> Data {
        let context = try connected()
        guard page > 0, page <= Int32.max else { throw ContentServerError.invalidReference }
        let book = try await fetchBook(bookID, context)
        try check(context)
        guard !book.media.isEPUB || book.media.epubDivinaCompatible == true else {
            throw RemoteSyncError.unsupported(operation: "Komga EPUB page images; use the original EPUB file")
        }
        guard page <= book.media.pagesCount else { throw ContentServerError.invalidReference }
        let response = try await request(context, path: ["api", "v1", "books", bookID, "pages", String(page)],
                                         query: [.init(name: "contentNegotiation", value: "false"), .init(name: "convert", value: "jpeg")],
                                         kind: .image, headers: ["Accept": "image/jpeg"])
        try check(context)
        return try image(response)
    }

    /// Reads BookDto.readProgress. Komga does not expose GET /read-progress.
    public func readProgress(bookID: String) async throws -> KomgaReadProgress? {
        let context = try connected()
        let book = try await fetchBook(bookID, context)
        try check(context)
        return book.readProgress
    }

    /// Explicit page write, range 1...pagesCount. The last page also marks completion.
    /// Ordinary EPUB requires `updateProgression(bookID:progression:)` instead.
    public func updateReadProgress(bookID: String, page: Int) async throws {
        let context = try connected()
        guard page > 0, page <= Int32.max else { throw ContentServerError.invalidReference }
        let book = try await fetchBook(bookID, context)
        try check(context)
        guard !book.media.isEPUB || book.media.epubDivinaCompatible == true else {
            throw RemoteSyncError.unsupported(operation: "Komga EPUB page progress; use updateProgression(bookID:progression:)")
        }
        guard page <= book.media.pagesCount else { throw ContentServerError.invalidReference }
        let response = try await request(context, path: ["api", "v1", "books", bookID, "read-progress"], method: "PATCH",
                                         body: ContentCoding.encode(KomgaProgressPatch(page: page, completed: nil)))
        try check(context)
        try noContent(response)
    }

    /// Marks the book completed, including ordinary EPUB; no page number is sent.
    public func markRead(bookID: String) async throws {
        let context = try connected()
        _ = try await fetchBook(bookID, context)
        try check(context)
        let response = try await request(context, path: ["api", "v1", "books", bookID, "read-progress"], method: "PATCH",
                                         body: ContentCoding.encode(KomgaProgressPatch(page: nil, completed: true)))
        try check(context)
        try noContent(response)
    }

    /// DELETE resets unread and clears the shared Readium record. It is idempotent on the server.
    public func resetReadProgress(bookID: String) async throws {
        let context = try connected()
        _ = try await fetchBook(bookID, context)
        try check(context)
        let response = try await request(context, path: ["api", "v1", "books", bookID, "read-progress"], method: "DELETE")
        try check(context)
        try noContent(response)
    }

    /// Typed Readium progression; nil means HTTP 204 (no record).
    public func progression(bookID: String) async throws -> KomgaReadiumProgression? {
        let context = try connected()
        _ = try await fetchBook(bookID, context)
        try check(context)
        let response = try await request(context, path: ["api", "v1", "books", bookID, "progression"],
                                         headers: ["Accept": "application/vnd.readium.progression+json"])
        try check(context)
        if response.response.statusCode == 204 { try noContent(response); return nil }
        let value = try KomgaCoding.decode(KomgaReadiumProgression.self, response)
        try KomgaValidation.progression(value, writing: false)
        return value
    }

    /// Explicit Readium PUT. EPUB href must name an internal publication resource and progression
    /// must match the server's positions. Equal/older modified values throw conflict; no automatic replay.
    public func updateProgression(bookID: String, progression: KomgaReadiumProgression) async throws {
        let context = try connected()
        try KomgaValidation.progression(progression, writing: true)
        let book = try await fetchBook(bookID, context)
        try check(context)
        if book.media.isEPUB {
            guard progression.locator.locations?.progression != nil else { throw ContentServerError.invalidReference }
        } else {
            guard let position = progression.locator.locations?.position,
                  position > 0, position <= book.media.pagesCount else { throw ContentServerError.invalidReference }
        }
        let response = try await request(context, path: ["api", "v1", "books", bookID, "progression"], method: "PUT",
                                         body: KomgaCoding.encodeProgression(progression),
                                         headers: ["Content-Type": "application/vnd.readium.progression+json"])
        try check(context)
        try noContent(response)
    }

    /// Registers one complete native file for repeated downloads/Transfer within this connection.
    /// FILE_DOWNLOAD is required; the server remains authoritative if permissions change later.
    public func prepareDownload(bookID: String) async throws -> RemoteFileReference {
        let context = try connected()
        guard user?.canDownloadFiles == true else { throw RemoteSyncError.permissionDenied(path: "Komga file download") }
        let book = try await fetchBook(bookID, context)
        try check(context)
        return try registry.register(url: context.client.url(path: ["api", "v1", "books", book.id, "file"]),
                                     name: book.name, mediaType: book.media.mediaType, size: book.sizeBytes,
                                     binding: sourceBinding(), limit: configuration.maxDownloadReferences)
    }

    public func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        _ = try connected()
        throw RemoteSyncError.unsupported(operation: "Komga filesystem listing; use libraries, series and books")
    }

    /// Returns the exact registered descriptor, not a live filesystem stat.
    public func stat(path: String) async throws -> RemoteEntry {
        _ = try connected()
        return try registry.stat(path: path)
    }

    @discardableResult
    public func download(_ entry: RemoteEntry, to destination: URL,
                         options: RemoteDownloadOptions = .init()) async throws -> RemoteEntry {
        let context = try connected()
        guard options.resumeFrom == nil, options.expectedETag == nil else {
            throw RemoteSyncError.unsupported(operation: "Komga download resume/conditional request")
        }
        let resource = try registry.resource(entry: entry)
        let file = try ContentDownloadFile(destination: destination)
        guard destinations.insert(file.lockKey).inserted else {
            file.cleanup()
            throw RemoteSyncError.conflict(path: "Komga download destination")
        }
        defer { file.cleanup(); destinations.remove(file.lockKey) }
        try file.validate(overwrite: options.overwrite)
        let bytes: Int64
        do { bytes = try await context.client.download(resource, file: file, options: options) }
        catch { try check(context); throw error }
        try check(context)
        try file.install(overwrite: options.overwrite, bytes: bytes)
        return resource.entry
    }

    private func reset() {
        client?.cancel(); client = nil; user = nil
        generation = UUID(); registry.removeAll()
    }
    private func connected() throws -> Context {
        guard let client, user != nil else { throw RemoteSyncError.notConnected }
        let context = Context(generation: generation, client: client)
        try check(context)
        return context
    }
    private func check(_ context: Context) throws {
        guard !Task.isCancelled, generation == context.generation, client === context.client else {
            throw RemoteSyncError.cancelled
        }
    }
    private func request(_ context: Context, path: [String], query: [URLQueryItem] = [], method: String = "GET",
                         body: Data? = nil, kind: ContentResponseKind = .json,
                         headers: [String: String] = [:]) async throws -> ContentHTTPResponse {
        try check(context)
        do {
            let response = try await context.client.send(path: path, query: query, method: method, body: body,
                                                         headers: headers, kind: kind)
            try check(context)
            return response
        } catch { try check(context); throw error }
    }
    private func fetchBook(_ id: String, _ context: Context) async throws -> KomgaBook {
        let response = try await request(context, path: ["api", "v1", "books", try ContentValidation.id(id)])
        try check(context)
        let value = try KomgaCoding.decode(KomgaBook.self, response)
        try KomgaValidation.book(value, id: id)
        return value
    }
    private func fetchSeries(_ id: String, _ context: Context) async throws -> KomgaSeries {
        let response = try await request(context, path: ["api", "v1", "series", try ContentValidation.id(id)])
        try check(context)
        let value = try KomgaCoding.decode(KomgaSeries.self, response)
        try KomgaValidation.series(value, id: id)
        return value
    }
    private func pagination(_ page: Int, _ pageSize: Int, sorts: [String]) throws -> [URLQueryItem] {
        try ContentValidation.pagination(page: page, pageSize: pageSize)
        guard sorts.count <= 8, Set(sorts).count == sorts.count else { throw ContentServerError.invalidReference }
        return [.init(name: "page", value: String(page)), .init(name: "size", value: String(pageSize))]
            + sorts.map { .init(name: "sort", value: $0) }
    }
    private func noContent(_ response: ContentHTTPResponse) throws {
        guard response.response.statusCode == 204, response.data.isEmpty else { throw ContentServerError.invalidResponse }
    }
    private func image(_ response: ContentHTTPResponse) throws -> Data {
        guard response.response.statusCode == 200, !response.data.isEmpty else { throw ContentServerError.invalidResponse }
        return response.data
    }
}
