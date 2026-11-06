import Foundation
import CryptoKit
import BoneRemoteSyncCore
import BoneRemoteSyncOPDS
import BoneRemoteSyncKomga
import BoneRemoteSyncKavita
import BoneRemoteSyncAudiobookshelf

/// Explicit escape hatch for native reading positions, playback and provider-specific screens.
/// The host must use the same connected source and discard references when it reconnects.
public enum RemoteBrowseNativeReference: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case file(RemoteFileReference)
    case opds(OPDSItem)
    case komgaLibrary(String), komgaSeries(String), komgaBook(String)
    case kavitaLibrary(Int), kavitaSeries(Int), kavitaVolume(Int), kavitaChapter(KavitaChapterReference)
    case audiobookshelfLibrary(String), audiobookshelfItem(String)
    case audiobookshelfEpisode(itemID: String, episodeID: String)
    case audiobookshelfTrack(itemID: String, episodeID: String?, trackIndex: Int, fileID: String)
    case audiobookshelfFile(itemID: String, fileID: String)
    public var description: String { "RemoteBrowseNativeReference(***)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

enum BrowserNode: Sendable {
    case file(RemoteEntry)
    case opdsNavigation(OPDSNavigationItem, OPDSLink?)
    case opdsPublication(OPDSPublication)
    case komgaLibrary(KomgaLibrary), komgaSeries(KomgaSeries), komgaBook(KomgaBook)
    case kavitaLibrary(KavitaLibrary), kavitaSeries(KavitaSeries)
    case kavitaVolume(KavitaVolume, libraryID: Int)
    case kavitaChapter(KavitaChapter, libraryID: Int, seriesID: Int)
    case audiobookshelfLibrary(AudiobookshelfLibrary), audiobookshelfItem(AudiobookshelfItem)
    case audiobookshelfEpisode(AudiobookshelfEpisode)
    case audiobookshelfTrack(AudiobookshelfAudioTrack, itemID: String, episodeID: String?)
    case audiobookshelfFile(AudiobookshelfFile, itemID: String)
}

struct BrowserRecord: Sendable {
    let key: String
    let kind: RemoteBrowseKind
    let metadata: RemoteBrowseMetadata
    let capabilities: RemoteBrowseCapabilities
    let node: BrowserNode
}

struct BrowserRequest: Sendable {
    var parent: BrowserNode?
    var query: String?
    var page: Int = 0
    var pageSize: Int
    var includeHidden: Bool = false
    var fileCursor: String?
    var opdsCursor: OPDSPageCursor?
    func next() -> Self { var value = self; value.page += 1; return value }
}

indirect enum BrowserContinuation: Sendable {
    case request(BrowserRequest)
    case buffered(BrowserResult, offset: Int)
}

struct BrowserResult: Sendable {
    var records: [BrowserRecord]
    var total: Int?
    var coverage: RemoteListingCoverage = .complete
    var capabilities: RemoteBrowseCapabilities = [.browse]
    var next: BrowserContinuation?
}

enum BrowserDownloadLocator: Sendable {
    case file(RemoteFileReference)
    case opds(OPDSPublication, OPDSAcquisition)
    case komga(bookID: String)
    case kavita(KavitaChapterReference)
    case audiobookshelf(itemID: String, fileID: String)
}

struct BrowserDownloadRecord: Sendable {
    let key: String
    let title: String
    let filename: String?
    let contentType: String?
    let size: Int64?
    let kind: RemoteBrowseDownloadKind
    let locator: BrowserDownloadLocator
}

protocol BrowserAdapter: Sendable {
    var source: any RemoteSource { get }
    var binding: RemoteSourceBinding { get }
    var rootCapabilities: RemoteBrowseCapabilities { get }
    func validateSession() async throws
    func page(_ request: BrowserRequest) async throws -> BrowserResult
    func details(_ node: BrowserNode) async throws -> BrowserRecord
    func artwork(_ node: BrowserNode) async throws -> Data?
    func downloads(_ node: BrowserNode) async throws -> [BrowserDownloadRecord]
    func prepare(_ download: BrowserDownloadRecord) async throws -> RemoteFileReference
    func nativeReference(_ node: BrowserNode) async throws -> RemoteBrowseNativeReference
}

enum BrowserMapping {
    static func key(_ parts: String...) -> String {
        // Length-prefix prevents collisions even when native IDs contain separators or URLs.
        let text = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func title(_ value: String?, fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return value
    }
    static func fraction(_ current: Int?, total: Int) -> Double? {
        guard let current, current >= 0, total > 0 else { return nil }
        return min(1, Double(current) / Double(total))
    }
    /// Only absolute timestamps are normalized. Ambiguous/partial values remain in raw fields.
    static func date(_ value: String?) -> Date? {
        guard let value, value.contains("T"), value.utf8.count <= 128 else { return nil }
        let tail = String(value.suffix(6))
        guard value.hasSuffix("Z") || ((tail.hasPrefix("+") || tail.hasPrefix("-")) && tail.contains(":")) else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
    static func milliseconds(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value >= 0, value <= 8_640_000_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
