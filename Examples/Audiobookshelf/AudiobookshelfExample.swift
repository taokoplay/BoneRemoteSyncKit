import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncContent
import BoneRemoteSyncAudiobookshelf
import BoneRemoteSyncTransfer

/// Copy this file into a host target depending on Audiobookshelf and Transfer products.
/// All credentials and IDs come from the host; no embedded demo account is used.
public enum AudiobookshelfExample {
    /// Preserve a reverse proxy mount in baseURL, for example https://books.example.org/abs/.
    public static func connect(baseURL: URL, credential: RemoteCredential,
                               expectedUserID: String? = nil) async throws -> AudiobookshelfSource {
        let configuration = try AudiobookshelfConfiguration(baseURL: baseURL,
            maxConcurrentRequests: 3, maxResponseBytes: 8 * 1024 * 1024)
        let source = AudiobookshelfSource(configuration: configuration)
        try await source.connect(credential, expectedUserID: expectedUserID)
        return source
    }

    public static func browse(source: AudiobookshelfSource, libraryID: String,
                              page: Int = 0) async throws -> ContentPage<AudiobookshelfItem> {
        try await source.items(libraryID: libraryID, page: page, pageSize: 50)
    }

    /// The host selects a concrete file from item.files/audioFiles or an episode.audioFile.
    /// The closure keeps the lease alive until the host has finished using the local URL.
    public static func withDownloadedFile<Result: Sendable>(
        source: AudiobookshelfSource, itemID: String, fileID: String, cacheDirectory: URL,
        consume: @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        let reference = try await source.prepareDownload(itemID: itemID, fileID: fileID)
        let materializer = RemoteFileMaterializer(source: source,
            sourceBinding: try await source.sourceBinding(), cacheDirectory: cacheDirectory)
        do {
            let lease = try await materializer.materialize(reference)
            let value = try await lease.withAccess(consume)
            await materializer.shutdown()
            return value
        } catch {
            await materializer.shutdown()
            throw error
        }
    }

    /// Returns authenticated per-track requests; the host owns the player and loader.
    /// Never log these requests or forward their headers across origins/redirects.
    public static func beginPlayback(source: AudiobookshelfSource, itemID: String,
                                     episodeID: String? = nil,
                                     supportedMimeTypes: [String]) async throws -> AudiobookshelfPlaybackSession {
        try await source.createPlaybackSession(itemID: itemID, episodeID: episodeID,
                                                supportedMimeTypes: supportedMimeTypes)
    }

    /// Call only on an explicit host playback event. `listenedSinceLastSync` is elapsed
    /// listening time, not an accumulated total and not the distance the user seeked.
    public static func reportPlayback(source: AudiobookshelfSource, session: AudiobookshelfPlaybackSession,
                                      absoluteItemTime: Double, listenedSinceLastSync: Double) async throws {
        try await source.syncPlaybackSession(session, update: .init(
            currentTime: absoluteItemTime, timeListened: listenedSinceLastSync, duration: session.duration))
    }

    /// Explicit close may update progress; disconnect itself performs no server write.
    /// A thrown close is an unknown server outcome and must not be blindly replayed.
    public static func endPlayback(source: AudiobookshelfSource, session: AudiobookshelfPlaybackSession,
                                   absoluteItemTime: Double, listenedSinceLastSync: Double) async throws {
        try await source.closePlaybackSession(session, update: .init(
            currentTime: absoluteItemTime, timeListened: listenedSinceLastSync, duration: session.duration))
    }
}
