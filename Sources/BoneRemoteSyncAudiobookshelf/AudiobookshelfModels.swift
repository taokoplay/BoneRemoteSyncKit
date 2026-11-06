import Foundation
import BoneRemoteSyncContent

public typealias AudiobookshelfConfiguration = ContentServerConfiguration

/// Explicitly exported login secrets. Not Codable; keep in protected storage, never logs.
/// Access tokens expire. Reconnect explicitly after renewal; mutations are never replayed.
public struct AudiobookshelfTokens: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public init(accessToken: String, refreshToken: String? = nil) throws {
        self.accessToken = try ContentValidation.token(accessToken)
        self.refreshToken = try refreshToken.map(ContentValidation.token)
    }
    public var description: String { "AudiobookshelfTokens(<redacted>)" }
    public var debugDescription: String { description }
}

public struct AudiobookshelfUser: Sendable, Decodable, Equatable {
    public let id: String
    public let username: String
    public let type: String
    public let isActive: Bool
    public let permissions: AudiobookshelfPermissions
    public let librariesAccessible: [String]
}

public struct AudiobookshelfPermissions: Sendable, Decodable, Equatable {
    public let download: Bool
    public let update: Bool
    public let upload: Bool
    public let delete: Bool
    public let accessAllLibraries: Bool
    public let accessExplicitContent: Bool?
}

public enum AudiobookshelfMediaType: String, Sendable, Decodable { case book, podcast }

/// Library folders and server filesystem locations are deliberately omitted.
public struct AudiobookshelfLibrary: Sendable, Decodable {
    public let id: String
    public let name: String
    public let mediaType: AudiobookshelfMediaType
    public let displayOrder: Int?
}

public struct AudiobookshelfAuthor: Sendable, Decodable {
    public let id: String
    public let name: String
}

public struct AudiobookshelfSeries: Sendable, Decodable {
    public let id: String
    public let name: String
    public let sequence: String?
}

/// Optional fields remain absent when the server sends minified metadata.
public struct AudiobookshelfMetadata: Sendable, Decodable {
    public let title: String
    public let subtitle: String?
    public let authors: [AudiobookshelfAuthor]?
    public let authorName: String?
    public let author: String?
    public let narrators: [String]?
    public let narratorName: String?
    public let series: [AudiobookshelfSeries]?
    public let genres: [String]?
    public let publishedYear: String?
    public let publisher: String?
    public let description: String?
    public let language: String?
    public let isbn: String?
    public let asin: String?
    public let explicit: Bool?
}

public struct AudiobookshelfChapter: Sendable, Decodable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String
}

/// A concrete server file. `id` is the ABS inode identifier, not a local path.
public struct AudiobookshelfFile: Sendable {
    public let id: String
    public let filename: String
    public let size: Int64?
    public let mimeType: String?
    public let duration: Double?
    /// Server audio order; -1 means excluded from playback, nil means not supplied.
    public let index: Int?
}

public struct AudiobookshelfAudioTrack: Sendable {
    public let index: Int
    public let fileID: String
    public let startOffset: Double
    public let duration: Double
    public let title: String
    public let mimeType: String
    public let codec: String?
}

public struct AudiobookshelfEpisode: Sendable {
    public let id: String
    public let libraryItemID: String
    public let podcastID: String
    public let title: String
    public let subtitle: String?
    public let description: String?
    public let season: String?
    public let episode: String?
    public let publishedAt: Double?
    public let duration: Double?
    public let audioFile: AudiobookshelfFile?
    public let audioTrack: AudiobookshelfAudioTrack?
    public let chapters: [AudiobookshelfChapter]?
}

/// Detail responses include files/tracks/episodes; listing responses may omit them.
public struct AudiobookshelfItem: Sendable {
    public let id: String
    public let libraryID: String
    public let mediaType: AudiobookshelfMediaType
    public let metadata: AudiobookshelfMetadata
    public let duration: Double?
    public let size: Int64?
    public let tags: [String]?
    public let files: [AudiobookshelfFile]?
    public let audioFiles: [AudiobookshelfFile]?
    public let tracks: [AudiobookshelfAudioTrack]?
    public let chapters: [AudiobookshelfChapter]?
    public let episodes: [AudiobookshelfEpisode]?
}

/// ABS search is bounded by `limit` per category and has no public pagination cursor.
/// Only book/podcast item matches are exposed; author/tag/series facets are not flattened.
public struct AudiobookshelfSearchResults: Sendable {
    public let books: [AudiobookshelfItem]
    public let podcasts: [AudiobookshelfItem]
    public let limit: Int
}

public struct AudiobookshelfMediaProgress: Sendable, Decodable {
    public let id: String
    public let userId: String
    public let libraryItemId: String
    public let episodeId: String?
    public let duration: Double
    public let progress: Double
    public let currentTime: Double
    public let isFinished: Bool
    public let hideFromContinueListening: Bool?
    public let ebookLocation: String?
    public let ebookProgress: Double?
    /// ABS timestamps are milliseconds since the Unix epoch.
    public let lastUpdate: Double?
    public let startedAt: Double?
    public let finishedAt: Double?
}

/// A sparse, explicit PATCH. Nil fields are omitted; no writes occur during downloads.
public struct AudiobookshelfProgressUpdate: Sendable, Encodable {
    public var currentTime: Double?
    public var duration: Double?
    public var progress: Double?
    public var isFinished: Bool?
    public var hideFromContinueListening: Bool?
    public var ebookLocation: String?
    public var ebookProgress: Double?
    public init(currentTime: Double? = nil, duration: Double? = nil, progress: Double? = nil,
                isFinished: Bool? = nil, hideFromContinueListening: Bool? = nil,
                ebookLocation: String? = nil, ebookProgress: Double? = nil) {
        self.currentTime = currentTime; self.duration = duration; self.progress = progress
        self.isFinished = isFinished; self.hideFromContinueListening = hideFromContinueListening
        self.ebookLocation = ebookLocation; self.ebookProgress = ebookProgress
    }
}

/// `timeListened` is the incremental elapsed listening time since the previous sync,
/// not the cumulative playhead. A failed write must not be automatically replayed.
public struct AudiobookshelfPlaybackUpdate: Sendable, Encodable {
    public let currentTime: Double
    public let timeListened: Double
    public let duration: Double?
    public init(currentTime: Double, timeListened: Double, duration: Double? = nil) {
        self.currentTime = currentTime; self.timeListened = timeListened; self.duration = duration
    }
}

/// Only a direct file request is returned. The host implements decoding, range requests,
/// seeking and track transitions, and must not forward these credentials to another origin.
public struct AudiobookshelfPlaybackTrack: Sendable {
    public let track: AudiobookshelfAudioTrack
    public let request: ContentStreamRequest
}

/// Opaque connection-bound session; cannot be reconstructed or used after reconnect/close.
public struct AudiobookshelfPlaybackSession: Sendable {
    public let id: String
    public let userID: String
    public let libraryItemID: String
    public let episodeID: String?
    public let duration: Double
    public let currentTime: Double
    public let chapters: [AudiobookshelfChapter]
    public let tracks: [AudiobookshelfPlaybackTrack]
    internal let generation: UUID
}
