import Foundation
import BoneRemoteSyncCore

/// Display semantics, independent of filesystem operations.
public enum RemoteBrowseKind: String, Sendable, Codable, Hashable {
    case directory, file, navigation, library, series, volume, chapter, book, podcast, episode, track
}

/// Scoped identity for display/diffing. Values do not authorize operations or survive every reconnect.
public struct RemoteBrowseID: Sendable, Codable, Hashable {
    public let source: RemoteSourceBinding
    public let kind: RemoteBrowseKind
    public let value: String
    public init(source: RemoteSourceBinding, kind: RemoteBrowseKind, value: String) {
        self.source = source; self.kind = kind; self.value = value
    }
}

/// Hints for available entry points, never a substitute for server permission checks.
public struct RemoteBrowseCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let browse = Self(rawValue: 1 << 0)
    public static let search = Self(rawValue: 1 << 1)
    public static let download = Self(rawValue: 1 << 2)
    public static let artwork = Self(rawValue: 1 << 3)
    /// Use nativeReference(for:) and the original source for reading/writing native positions.
    public static let nativeProgress = Self(rawValue: 1 << 4)
    /// Use nativeReference(for:) and the original Audiobookshelf source for playback sessions.
    public static let nativePlayback = Self(rawValue: 1 << 5)
}

/// Markup is preserved as data. Hosts must sanitize before rendering HTML/XHTML.
public struct RemoteBrowseText: Sendable, Codable, Hashable {
    public enum Format: String, Sendable, Codable { case text, html, xhtml }
    public let value: String
    public let format: Format
    public init(_ value: String, format: Format = .text) { self.value = value; self.format = format }
}

/// Codable presentation data, with no executable resource reference or authentication headers.
public struct RemoteBrowseMetadata: Sendable, Codable, Hashable {
    public var title: String
    public var subtitle: String?
    public var summary: RemoteBrowseText?
    public var authors: [String] = []
    public var narrators: [String] = []
    public var tags: [String] = []
    public var language: String?
    public var contentType: String?
    public var size: Int64?
    public var duration: TimeInterval?
    public var pageCount: Int?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var createdAtRaw: String?
    public var modifiedAtRaw: String?
    /// May be a year or partial date; never silently converted to an exact timestamp.
    public var publicationDate: String?
    /// Display-only fraction. It is not a native reading/listening locator and must not be written back.
    public var progress: Double?
    public init(title: String) { self.title = title }
}

/// Persistable display snapshot only. Decoding a snapshot cannot recreate a live item handle.
public struct RemoteBrowseSnapshot: Sendable, Codable, Hashable, Identifiable {
    public let id: RemoteBrowseID
    public let metadata: RemoteBrowseMetadata
    public let capabilities: RemoteBrowseCapabilities
}

/// Immutable session handle. Native links remain private and are not Codable or printable.
public struct RemoteBrowseItem: Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let snapshot: RemoteBrowseSnapshot
    public var id: RemoteBrowseID { snapshot.id }
    public var kind: RemoteBrowseKind { id.kind }
    public var metadata: RemoteBrowseMetadata { snapshot.metadata }
    public var capabilities: RemoteBrowseCapabilities { snapshot.capabilities }
    let owner: UUID
    let record: BrowserRecord
    public var description: String { "RemoteBrowseItem(\(kind.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["kind": kind.rawValue]) }
}

/// Forward continuation of one browse/search request; preserve it intact and consume sequentially.
public struct RemoteBrowseCursor: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let owner: UUID
    let continuation: BrowserContinuation
    let pageSize: Int
    let pageCount: Int
    public var description: String { "RemoteBrowseCursor(***)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct RemoteBrowsePage: Sendable {
    public let items: [RemoteBrowseItem]
    public let nextCursor: RemoteBrowseCursor?
    public let total: Int?
    /// Per-response known omissions. Even complete pages are not a transactionally consistent snapshot.
    public let coverage: RemoteListingCoverage
    public let capabilities: RemoteBrowseCapabilities
    public var hasNextPage: Bool { nextCursor != nil }
}

public enum RemoteBrowseDownloadKind: String, Sendable, Codable { case originalFile, archive, audioFile }

/// An explicitly selected representation/file, not necessarily the whole book.
public struct RemoteBrowseDownload: Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: RemoteBrowseID
    public let title: String
    public let filename: String?
    public let contentType: String?
    public let size: Int64?
    public let kind: RemoteBrowseDownloadKind
    let owner: UUID
    let record: BrowserDownloadRecord
    public var description: String { "RemoteBrowseDownload(\(kind.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["kind": kind.rawValue]) }
}

public struct RemoteBrowserOptions: Sendable {
    /// Bounds arrays from services without native pagination and locally buffered page tails.
    public let maxBufferedItems: Int
    public let maxPageCount: Int
    public let maxConcurrentOperations: Int
    public init(maxBufferedItems: Int = 10_000, maxPageCount: Int = 10_000, maxConcurrentOperations: Int = 8) throws {
        guard (1...100_000).contains(maxBufferedItems), (1...100_000).contains(maxPageCount),
              (1...32).contains(maxConcurrentOperations) else {
            throw RemoteBrowserError(code: .invalidInput)
        }
        self.maxBufferedItems = maxBufferedItems; self.maxPageCount = maxPageCount
        self.maxConcurrentOperations = maxConcurrentOperations
    }
    public static let `default` = try! Self()
}
