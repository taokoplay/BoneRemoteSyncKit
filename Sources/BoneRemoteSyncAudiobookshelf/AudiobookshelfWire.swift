import Foundation
import BoneRemoteSyncContent
import BoneRemoteSyncCore

internal enum ABSValidation {
    static func number(_ value: Double?, maximum: Double = 8_640_000_000_000_000) throws {
        if let value, !value.isFinite || value < 0 || value > maximum {
            throw ContentServerError.invalidResponse
        }
    }
    static func unique(_ ids: [String], limit: Int = 10_000) throws {
        guard ids.count <= limit else { throw ContentServerError.resourceLimit }
        guard Set(ids).count == ids.count else { throw ContentServerError.invalidResponse }
        for id in ids { _ = try ContentValidation.id(id) }
    }
    static func chapters(_ values: [AudiobookshelfChapter]?) throws {
        guard let values else { return }
        guard values.count <= 10_000 else { throw ContentServerError.resourceLimit }
        guard Set(values.map(\.id)).count == values.count else { throw ContentServerError.invalidResponse }
        for chapter in values {
            try number(chapter.start); try number(chapter.end)
            guard chapter.id >= 0, chapter.end >= chapter.start else { throw ContentServerError.invalidResponse }
        }
    }
}

/// ABS echoes query-string page/limit as strings, but may return numbers for defaults.
internal struct ABSInteger: Decodable {
    let value: Int
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let integer = try? c.decode(Int.self) { value = integer }
        else if let string = try? c.decode(String.self), let integer = Int(string) { value = integer }
        else { throw ContentServerError.invalidResponse }
    }
}

internal struct ABSFileDTO: Decodable {
    struct Metadata: Decodable { let filename: String; let size: Int64? }
    let ino: String
    let metadata: Metadata
    let mimeType: String?
    let duration: Double?
    let index: Int?
    enum CodingKeys: String, CodingKey { case ino, metadata, mimeType, duration, index }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? c.decode(String.self, forKey: .ino) { ino = string }
        else { ino = String(try c.decode(UInt64.self, forKey: .ino)) }
        metadata = try c.decode(Metadata.self, forKey: .metadata)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
    }
    func model() throws -> AudiobookshelfFile {
        _ = try ContentValidation.id(ino)
        try ABSValidation.number(duration)
        guard metadata.size.map({ $0 >= 0 }) ?? true, index.map({ $0 >= -1 }) ?? true else {
            throw ContentServerError.invalidResponse
        }
        return .init(id: ino, filename: ContentValidation.filename(metadata.filename), size: metadata.size,
                     mimeType: mimeType, duration: duration, index: index)
    }
}

internal struct ABSTrackDTO: Decodable {
    let index: Int
    let startOffset: Double
    let duration: Double
    let title: String
    let contentUrl: String
    let mimeType: String
    let codec: String?
    func model(itemID: String, client: ContentHTTPClient) throws -> AudiobookshelfAudioTrack {
        try ABSValidation.number(startOffset); try ABSValidation.number(duration)
        guard index >= 0, mimeType.lowercased().hasPrefix("audio/"),
              !mimeType.lowercased().contains("mpegurl") else {
            throw RemoteSyncError.unsupported(operation: "Audiobookshelf non-direct audio")
        }
        let url = try client.serviceURL(contentUrl)
        let fileID = try ContentValidation.id(url.lastPathComponent)
        let expected = try client.url(path: ["api", "items", itemID, "file", fileID])
        guard url == expected else { throw ContentServerError.invalidReference }
        return .init(index: index, fileID: fileID, startOffset: startOffset, duration: duration,
                     title: ContentValidation.filename(title, fallback: "audio"), mimeType: mimeType, codec: codec)
    }
}

internal struct ABSEpisodeDTO: Decodable {
    let id: String
    let libraryItemId: String
    let podcastId: String
    let title: String
    let subtitle: String?
    let description: String?
    let season: String?
    let episode: String?
    let publishedAt: Double?
    let duration: Double?
    let audioFile: ABSFileDTO?
    let audioTrack: ABSTrackDTO?
    let chapters: [AudiobookshelfChapter]?
    func model(itemID: String, client: ContentHTTPClient) throws -> AudiobookshelfEpisode {
        guard libraryItemId == itemID else { throw ContentServerError.invalidResponse }
        _ = try ContentValidation.id(id); _ = try ContentValidation.id(podcastId)
        try ABSValidation.number(duration); try ABSValidation.number(publishedAt)
        try ABSValidation.chapters(chapters)
        let file = try audioFile?.model()
        let track = try audioTrack?.model(itemID: itemID, client: client)
        if let track, track.fileID != file?.id { throw ContentServerError.invalidResponse }
        return .init(id: id, libraryItemID: libraryItemId, podcastID: podcastId, title: title,
                     subtitle: subtitle, description: description, season: season, episode: episode,
                     publishedAt: publishedAt, duration: duration, audioFile: file, audioTrack: track, chapters: chapters)
    }
}

internal struct ABSItemDTO: Decodable {
    struct Media: Decodable {
        let id: String?
        let metadata: AudiobookshelfMetadata
        let duration: Double?
        let size: Int64?
        let tags: [String]?
        let audioFiles: [ABSFileDTO]?
        let tracks: [ABSTrackDTO]?
        let chapters: [AudiobookshelfChapter]?
        let episodes: [ABSEpisodeDTO]?
    }
    let id: String
    let libraryId: String
    let mediaType: AudiobookshelfMediaType
    let media: Media
    let libraryFiles: [ABSFileDTO]?
    func model(client: ContentHTTPClient, expanded: Bool = false) throws -> AudiobookshelfItem {
        _ = try ContentValidation.id(id); _ = try ContentValidation.id(libraryId)
        try ABSValidation.number(media.duration)
        guard media.size.map({ $0 >= 0 }) ?? true else { throw ContentServerError.invalidResponse }
        if expanded {
            guard libraryFiles != nil else { throw ContentServerError.invalidResponse }
            switch mediaType {
            case .book:
                guard media.audioFiles != nil, media.tracks != nil, media.chapters != nil else {
                    throw ContentServerError.invalidResponse
                }
            case .podcast:
                guard media.episodes != nil else { throw ContentServerError.invalidResponse }
            }
        }
        let files = try libraryFiles?.map { try $0.model() }
        let audio = try media.audioFiles?.map { try $0.model() }
        let tracks = try media.tracks?.map { try $0.model(itemID: id, client: client) }
        let episodes = try media.episodes?.map { try $0.model(itemID: id, client: client) }
        try ABSValidation.unique(files?.map(\.id) ?? [])
        try ABSValidation.unique(audio?.map(\.id) ?? [])
        try ABSValidation.unique(tracks?.map(\.fileID) ?? [])
        try ABSValidation.unique(episodes?.map(\.id) ?? [])
        try ABSValidation.chapters(media.chapters)
        if let tracks, Set(tracks.map(\.index)).count != tracks.count {
            throw ContentServerError.invalidResponse
        }
        if let tracks, let audio {
            let audioIDs = Set(audio.map(\.id))
            guard tracks.allSatisfy({ audioIDs.contains($0.fileID) }) else {
                throw ContentServerError.invalidResponse
            }
        }
        if let episodes, let mediaID = media.id {
            guard episodes.allSatisfy({ $0.podcastID == mediaID }) else { throw ContentServerError.invalidResponse }
        }
        return .init(id: id, libraryID: libraryId, mediaType: mediaType, metadata: media.metadata,
                     duration: media.duration, size: media.size, tags: media.tags, files: files,
                     audioFiles: audio, tracks: tracks, chapters: media.chapters, episodes: episodes)
    }
}

internal struct ABSLibrariesDTO: Decodable { let libraries: [AudiobookshelfLibrary] }
internal struct ABSItemsDTO: Decodable {
    let results: [ABSItemDTO]
    let total: Int
    let page: ABSInteger
    let limit: ABSInteger
}
internal struct ABSSearchDTO: Decodable {
    struct Match: Decodable { let libraryItem: ABSItemDTO }
    let book: [Match]?
    let podcast: [Match]?
}
internal struct ABSLoginDTO: Decodable {
    struct User: Decodable { let id: String; let accessToken: String; let refreshToken: String? }
    let user: User
}
internal struct ABSSessionDTO: Decodable {
    let id: String
    let userId: String
    let libraryId: String
    let libraryItemId: String
    let episodeId: String?
    let playMethod: Int
    let duration: Double
    let currentTime: Double
    let chapters: [AudiobookshelfChapter]
    let audioTracks: [ABSTrackDTO]
}
