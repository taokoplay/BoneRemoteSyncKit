import Foundation
import BoneRemoteSyncContent

public typealias KavitaConfiguration = ContentServerConfiguration

/// A JWT pair returned only by an explicit login/refresh. Store in the host's secure credential store.
/// Neither description nor reflection includes credentials. This type is intentionally not Codable.
public struct KavitaTokens: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let refreshToken: String?
    public init(accessToken: String, refreshToken: String? = nil) throws {
        self.accessToken = try ContentValidation.token(accessToken)
        self.refreshToken = try refreshToken.map(ContentValidation.token)
    }
    public var description: String { "KavitaTokens(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }
}

/// Verified using GET Account, never the incomplete Plugin/authenticate identity.
public struct KavitaAccount: Sendable, Decodable, Equatable {
    public let id: Int
    public let username: String?
    public let roles: [String]
    public let kavitaVersion: String?
}

/// Raw values preserve formats introduced by newer servers.
public struct KavitaFormat: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(Int.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
    public static let image = Self(rawValue: 0)
    public static let archive = Self(rawValue: 1)
    public static let unknown = Self(rawValue: 2)
    public static let epub = Self(rawValue: 3)
    public static let pdf = Self(rawValue: 4)
}

public struct KavitaLibrary: Sendable, Decodable, Equatable {
    public let id: Int
    public let name: String?
    /// Native LibraryType raw value; unknown values are preserved.
    public let type: Int
    public let includeInSearch: Bool?
}

public struct KavitaSeries: Sendable, Decodable, Equatable {
    public let id: Int
    public let libraryID: Int
    public let name: String?
    public let originalName: String?
    public let localizedName: String?
    public let sortName: String?
    public let libraryName: String?
    public let format: KavitaFormat
    public let pages: Int
    public let pagesRead: Int?
    public let totalReads: Int?
    public let userRating: Double?
    public let hasUserRated: Bool?
    public let wordCount: Int64?
    public let created: String?
    public let lastChapterAddedUtc: String?
    private enum CodingKeys: String, CodingKey {
        case id, name, originalName, localizedName, sortName, libraryName, format, pages, pagesRead
        case totalReads, userRating, hasUserRated, wordCount, created, lastChapterAddedUtc
        case libraryID = "libraryId"
    }
}

public struct KavitaVolume: Sendable, Decodable, Equatable {
    public let id: Int
    public let seriesID: Int
    public let name: String?
    public let minNumber: Double?
    public let maxNumber: Double?
    public let pages: Int
    public let pagesRead: Int?
    public let chapters: [KavitaChapter]
    public let createdUtc: String?
    public let lastModifiedUtc: String?
    private enum CodingKeys: String, CodingKey {
        case id, name, minNumber, maxNumber, pages, pagesRead, chapters, createdUtc, lastModifiedUtc
        case seriesID = "seriesId"
    }
}

/// One logical reading unit, potentially backed by several files. Server filesystem paths are omitted.
public struct KavitaChapter: Sendable, Decodable, Equatable {
    public let id: Int
    public let volumeID: Int
    public let title: String?
    public let titleName: String?
    public let range: String?
    public let minNumber: Double?
    public let maxNumber: Double?
    public let sortOrder: Double?
    public let pages: Int
    public let pagesRead: Int?
    public let totalReads: Int?
    public let isSpecial: Bool?
    public let format: KavitaFormat?
    public let files: [KavitaFile]
    public let summary: String?
    public let language: String?
    public let isbn: String?
    public let ageRating: Int?
    public let wordCount: Int64?
    public let writers: [KavitaNamedMetadata]?
    public let genres: [KavitaNamedMetadata]?
    public let tags: [KavitaNamedMetadata]?
    public let releaseDate: String?
    public let createdUtc: String?
    public let lastModifiedUtc: String?
    public let lastReadingProgressUtc: String?
    public var downloadKind: KavitaChapterDownloadKind {
        files.count == 1 && files[0].format != .image ? .originalFile : .archiveOfFiles
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, titleName, range, minNumber, maxNumber, sortOrder, pages, pagesRead, totalReads
        case isSpecial, format, files, summary, language, isbn, ageRating, wordCount, writers, genres, tags
        case releaseDate, createdUtc, lastModifiedUtc, lastReadingProgressUtc
        case volumeID = "volumeId"
    }
}

public enum KavitaChapterDownloadKind: String, Sendable { case originalFile, archiveOfFiles }

public struct KavitaNamedMetadata: Sendable, Decodable, Equatable {
    public let id: Int
    public let title: String?
    public let name: String?
    public let roles: [Int]?
}

/// Descriptive file metadata only. Kavita exposes downloads at chapter scope, not at mangaFileID scope.
public struct KavitaFile: Sendable, Decodable, Equatable {
    public let id: Int
    public let name: String?
    public let pages: Int?
    public let bytes: Int64?
    public let format: KavitaFormat
    public let fileExtension: String?
    private enum CodingKeys: String, CodingKey { case id, filePath, pages, bytes, format; case fileExtension = "extension" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        pages = try c.decodeIfPresent(Int.self, forKey: .pages)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes)
        format = try c.decode(KavitaFormat.self, forKey: .format)
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension)
        let path = try c.decodeIfPresent(String.self, forKey: .filePath)
        name = path.flatMap { $0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last }
            .map { ContentValidation.filename(String($0)) }
    }
}

/// An adapter-issued, connection-bound ancestry. Reconnect or refresh invalidates this reference.
/// Obtain a new reference with chapterReference(chapterID:); do not persist it across sessions.
public struct KavitaChapterReference: Sendable, Hashable {
    public let libraryID: Int
    public let seriesID: Int
    public let volumeID: Int
    public let chapterID: Int
    let generation: UUID
}

/// Native progress: pageNum is 0...pages; pages denotes completion.
/// For EPUB it is a reading-order index and bookScrollID is Kavita's DOM XPath, never EPUB CFI.
public struct KavitaProgress: Sendable, Equatable {
    public let chapter: KavitaChapterReference
    public let pageNum: Int
    public let totalPages: Int
    public let bookScrollID: String?
    public let lastModifiedUtc: String?
    /// A no-history response carries zero ancestors; those never replace the validated reference.
    public let hasRecordedProgress: Bool
    public var isCompleted: Bool { totalPages > 0 && pageNum == totalPages }
}

public enum KavitaCover: Sendable {
    case library(Int), series(Int), volume(Int), chapter(Int)
}

public struct KavitaBookInfo: Sendable, Decodable, Equatable {
    public let bookTitle: String?
    public let seriesName: String?
    public let seriesFormat: KavitaFormat
    public let libraryID: Int
    public let seriesID: Int
    public let volumeID: Int
    public let pages: Int
    public let chapterNumber: String?
    public let volumeNumber: String?
    private enum CodingKeys: String, CodingKey {
        case bookTitle, seriesName, seriesFormat, pages, chapterNumber, volumeNumber
        case libraryID = "libraryId", seriesID = "seriesId", volumeID = "volumeId"
    }
}

/// Native EPUB table of contents. `part` is an opaque internal href, not an authenticated network URL.
public struct KavitaBookChapter: Sendable, Decodable, Equatable {
    public let title: String?
    public let part: String?
    public let page: Int
    public let children: [KavitaBookChapter]?
}
