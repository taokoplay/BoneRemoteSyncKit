import Foundation
import BoneRemoteSyncContent

/// Komga service root configuration, including a reverse proxy mount when present.
public typealias KomgaConfiguration = ContentServerConfiguration

/// Verified current user. Role strings remain open to future server additions.
public struct KomgaUser: Sendable, Codable, Equatable {
    public let id: String
    public let email: String
    public let roles: [String]
    public let sharedAllLibraries: Bool
    public let sharedLibrariesIds: [String]
    public let labelsAllow: [String]?
    public let labelsExclude: [String]?
    public let ageRestriction: KomgaAgeRestriction?
    public var canDownloadFiles: Bool { roles.contains("FILE_DOWNLOAD") }
    public var canStreamPages: Bool { roles.contains("PAGE_STREAMING") }
}

public struct KomgaAgeRestriction: Sendable, Codable, Equatable {
    public let age: Int
    public let restriction: String
}

/// Safe library metadata; the server's local `root` is deliberately excluded.
public struct KomgaLibrary: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let unavailable: Bool
}

public struct KomgaAuthor: Sendable, Codable, Equatable {
    public let name: String
    public let role: String
}

public struct KomgaNotableEntity: Sendable, Codable, Equatable {
    public let name: String
    public let kind: String
}

public struct KomgaBookMetadata: Sendable, Codable, Equatable {
    public let title: String
    public let summary: String?
    /// Human-readable issue number; distinct from the book's integer order.
    public let number: String?
    public let numberSort: Double?
    /// Calendar date in yyyy-MM-dd form, not a timestamp or local time zone.
    public let releaseDate: String?
    public let authors: [KomgaAuthor]?
    public let notableEntities: [KomgaNotableEntity]?
    public let tags: [String]?
    public let isbn: String?
}

public struct KomgaSeriesMetadata: Sendable, Codable, Equatable {
    public let title: String
    public let titleSort: String?
    public let status: String?
    public let summary: String?
    public let readingDirection: String?
    public let publisher: String?
    public let language: String?
    public let ageRating: Int?
    public let totalBookCount: Int?
    public let genres: [String]?
    public let tags: [String]?
    public let sharingLabels: [String]?
}

public struct KomgaBooksMetadata: Sendable, Codable, Equatable {
    public let authors: [KomgaAuthor]?
    public let notableEntities: [KomgaNotableEntity]?
    public let tags: [String]?
    public let releaseDate: String?
    public let summary: String?
    public let summaryNumber: String?
}

/// Native series metadata, without the server-local `url` field.
public struct KomgaSeries: Sendable, Codable, Equatable {
    public let id: String
    public let libraryId: String
    public let name: String
    public let booksCount: Int
    public let booksReadCount: Int?
    public let booksUnreadCount: Int?
    public let booksInProgressCount: Int?
    public let metadata: KomgaSeriesMetadata
    public let booksMetadata: KomgaBooksMetadata?
    public let created: Date?
    public let lastModified: Date?
    public let deleted: Bool?
    public let oneshot: Bool?
}

public struct KomgaMedia: Sendable, Codable, Equatable {
    public let status: String
    public let mediaType: String
    public let pagesCount: Int
    public let epubDivinaCompatible: Bool?
    public let epubIsKepub: Bool?
    public let mediaProfile: String?
    public var isEPUB: Bool {
        mediaProfile?.uppercased() == "EPUB" || mediaType.lowercased() == "application/epub+zip"
    }
}

/// Current user's page progress. An EPUB Readium position can yield page zero.
public struct KomgaReadProgress: Sendable, Codable, Equatable {
    public let page: Int
    public let completed: Bool
    public let readDate: Date
    public let created: Date
    public let lastModified: Date
    public let deviceId: String
    public let deviceName: String
}

/// Native book metadata; local `url`, file hash and local file timestamps are not download guarantees.
public struct KomgaBook: Sendable, Codable, Equatable {
    public let id: String
    public let seriesId: String
    public let seriesTitle: String?
    public let libraryId: String
    public let name: String
    public let number: Int
    public let sizeBytes: Int64?
    public let media: KomgaMedia
    public let metadata: KomgaBookMetadata
    public let readProgress: KomgaReadProgress?
    public let created: Date?
    public let lastModified: Date?
    public let deleted: Bool?
    public let oneshot: Bool?
}

/// One-based page directory entry. `fileName` identifies a resource inside the publication.
public struct KomgaPage: Sendable, Codable, Equatable {
    public let number: Int
    public let fileName: String
    public let mediaType: String
    public let width: Int?
    public let height: Int?
    public let sizeBytes: Int64?
}

public enum KomgaSortDirection: String, Sendable, Codable { case ascending = "asc", descending = "desc" }

public struct KomgaSeriesSort: Sendable, Equatable {
    public enum Field: String, Sendable {
        case title = "metadata.titleSort", created = "createdDate", modified = "lastModifiedDate"
        case name, booksCount
    }
    public let field: Field
    public let direction: KomgaSortDirection
    public init(_ field: Field, _ direction: KomgaSortDirection = .ascending) {
        self.field = field; self.direction = direction
    }
}

public struct KomgaBookSort: Sendable, Equatable {
    public enum Field: String, Sendable {
        case title = "metadata.title", number = "metadata.numberSort", releaseDate = "metadata.releaseDate"
        case created = "createdDate", modified = "lastModifiedDate", size = "size", name, series
    }
    public let field: Field
    public let direction: KomgaSortDirection
    public init(_ field: Field, _ direction: KomgaSortDirection = .ascending) {
        self.field = field; self.direction = direction
    }
}

/// Device attribution supplied explicitly by the host reader.
public struct KomgaReadiumDevice: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct KomgaReadiumLocations: Sendable, Codable, Equatable {
    public let fragments: [String]?
    /// Resource-relative fraction in 0...1; required when updating EPUB progression.
    public let progression: Double?
    /// One-based publication position; required for DIVINA/PDF.
    public let position: Int?
    /// Publication-relative fraction. Komga recalculates this for EPUB.
    public let totalProgression: Double?
    public init(fragments: [String]? = nil, progression: Double? = nil, position: Int? = nil,
                totalProgression: Double? = nil) {
        self.fragments = fragments; self.progression = progression
        self.position = position; self.totalProgression = totalProgression
    }
}

public struct KomgaReadiumText: Sendable, Codable, Equatable {
    public let after: String?
    public let before: String?
    public let highlight: String?
    public init(after: String? = nil, before: String? = nil, highlight: String? = nil) {
        self.after = after; self.before = before; self.highlight = highlight
    }
}

/// A publication locator, never an authenticated HTTP download URL.
/// A progress record created through page PATCH may return an empty locator.
public struct KomgaReadiumLocator: Sendable, Codable, Equatable {
    public let href: String
    public let type: String
    public let title: String?
    public let locations: KomgaReadiumLocations?
    public let text: KomgaReadiumText?
    public let koboSpan: String?
    public init(href: String, type: String, title: String? = nil, locations: KomgaReadiumLocations? = nil,
                text: KomgaReadiumText? = nil, koboSpan: String? = nil) {
        self.href = href; self.type = type; self.title = title; self.locations = locations
        self.text = text; self.koboSpan = koboSpan
    }
    private enum CodingKeys: String, CodingKey { case href, type, title, locations, text, koboSpan }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Komga's NON_EMPTY serialization omits href/type on the legacy empty locator.
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        locations = try c.decodeIfPresent(KomgaReadiumLocations.self, forKey: .locations)
        text = try c.decodeIfPresent(KomgaReadiumText.self, forKey: .text)
        koboSpan = try c.decodeIfPresent(String.self, forKey: .koboSpan)
    }
}

/// GET/PUT /progression payload. Equal or older `modified` values produce HTTP 409.
/// Source methods encode/decode `modified` as an ISO-8601 timestamp with a time zone.
public struct KomgaReadiumProgression: Sendable, Codable, Equatable {
    public let modified: Date
    public let device: KomgaReadiumDevice
    public let locator: KomgaReadiumLocator
    public init(modified: Date, device: KomgaReadiumDevice, locator: KomgaReadiumLocator) {
        self.modified = modified; self.device = device; self.locator = locator
    }
}
