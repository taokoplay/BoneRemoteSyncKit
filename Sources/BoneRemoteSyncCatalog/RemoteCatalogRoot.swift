import Foundation
import BoneRemoteSyncCore

public enum RemoteCatalogRefreshScope: String, Sendable, Codable { case children, subtree }

public struct RemoteCatalogRoot: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public let bindingID: UUID
    public let selectionRevision: Int64
    public let path: String
    public let entryID: String
    public let includeHidden: Bool
    public let defaultScope: RemoteCatalogRefreshScope

    /// The host or Catalog selection operation must verify this is a directory in the bound source.
    public init(id: UUID = UUID(), sourceID: UUID, bindingID: UUID, selectionRevision: Int64 = 1,
                path: String, entryID: String, includeHidden: Bool = false,
                defaultScope: RemoteCatalogRefreshScope = .children) throws {
        self.id = id; self.sourceID = sourceID; self.bindingID = bindingID
        self.selectionRevision = selectionRevision; self.path = path; self.entryID = entryID
        self.includeHidden = includeHidden; self.defaultScope = defaultScope
        try validate()
    }
    public func validate() throws {
        try CatalogValidation.path(path)
        // Local/WebDAV use an empty relative ID for the source root.
        guard selectionRevision > 0, selectionRevision < Int64.max,
              CatalogValidation.text(entryID, max: 32768, allowEmpty: path == "/") else {
            throw RemoteCatalogError.invalidConfiguration
        }
    }
}

public enum RemoteCatalogCacheState: String, Sendable { case notInitialized, current, stale }

public struct RemoteCatalogQuery: Sendable {
    public let limit: Int
    public let pageToken: String?
    public init(limit: Int = 100, pageToken: String? = nil) { self.limit = limit; self.pageToken = pageToken }
}

public struct RemoteCatalogSnapshot: Sendable {
    public let entries: [RemoteEntry]
    public let state: RemoteCatalogCacheState
    public let version: Int64
    public let lastSuccessfulAt: Date?
    public let lastAttemptAt: Date?
    public let nextPageToken: String?
}
