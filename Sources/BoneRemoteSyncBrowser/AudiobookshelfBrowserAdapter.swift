import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncAudiobookshelf

struct AudiobookshelfBrowserAdapter: BrowserAdapter {
    let provider: AudiobookshelfSource
    let binding: RemoteSourceBinding
    let user: AudiobookshelfUser
    var source: any RemoteSource { provider }
    var rootCapabilities: RemoteBrowseCapabilities { [.browse] }

    func validateSession() async throws {
        guard try await provider.sourceBinding() == binding else { throw RemoteBrowserError(code: .sessionExpired) }
    }

    func page(_ request: BrowserRequest) async throws -> BrowserResult {
        try await validateSession()
        switch request.parent {
        case nil:
            guard request.query == nil else { throw RemoteBrowserError(code: .unsupported) }
            let values = try await provider.libraries()
            try await validateSession()
            return .init(records: values.map { record(.audiobookshelfLibrary($0)) }, total: values.count)
        case .audiobookshelfLibrary(let library):
            if let query = request.query {
                let results = try await provider.search(libraryID: library.id, query: query, limit: request.pageSize)
                try await validateSession()
                // ABS limits each category independently and supplies neither a total nor a continuation.
                return .init(records: (results.books + results.podcasts).map { record(.audiobookshelfItem($0)) },
                             total: nil, coverage: .unknown, capabilities: [.browse, .search])
            }
            let page = try await provider.items(libraryID: library.id, page: request.page, pageSize: request.pageSize)
            try await validateSession()
            return .init(records: page.items.map { record(.audiobookshelfItem($0)) }, total: page.total,
                         capabilities: [.browse, .search], next: page.hasNextPage ? .request(request.next()) : nil)
        case .audiobookshelfItem, .audiobookshelfEpisode:
            guard request.query == nil else { throw RemoteBrowserError(code: .unsupported) }
            let fresh = try await refresh(request.parent!)
            try await validateSession()
            let nodes: [BrowserNode]
            switch fresh {
            case .audiobookshelfItem(let value):
                if value.mediaType == .podcast {
                    nodes = (value.episodes ?? []).map { .audiobookshelfEpisode($0) }
                } else {
                    let tracks = value.tracks ?? []
                    let trackFiles = Set(tracks.map(\.fileID))
                    nodes = tracks.map { .audiobookshelfTrack($0, itemID: value.id, episodeID: nil) }
                        + files(value).filter { !trackFiles.contains($0.id) }.map { .audiobookshelfFile($0, itemID: value.id) }
                }
            case .audiobookshelfEpisode(let value):
                nodes = value.audioTrack.map { [.audiobookshelfTrack($0, itemID: value.libraryItemID, episodeID: value.id)] } ?? []
            default: throw RemoteBrowserError(code: .invalidReference)
            }
            return .init(records: nodes.map(record), total: nodes.count)
        case .audiobookshelfTrack, .audiobookshelfFile: throw RemoteBrowserError(code: .unsupported)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }

    func details(_ node: BrowserNode) async throws -> BrowserRecord {
        let fresh = try await refresh(node)
        try await validateSession()
        var value = record(fresh)
        let itemID: String, episodeID: String?
        switch fresh {
        case .audiobookshelfItem(let item) where item.mediaType == .book: itemID = item.id; episodeID = nil
        case .audiobookshelfEpisode(let episode): itemID = episode.libraryItemID; episodeID = episode.id
        default: return value
        }
        let progress = try await provider.mediaProgress(itemID: itemID, episodeID: episodeID)
        try await validateSession()
        if let progress {
            var metadata = value.metadata
            metadata.progress = progress.ebookProgress ?? progress.progress
            value = .init(key: value.key, kind: value.kind, metadata: metadata, capabilities: value.capabilities, node: fresh)
        }
        return value
    }

    func artwork(_ node: BrowserNode) async throws -> Data? {
        let fresh = try await refresh(node)
        try await validateSession()
        let id: String
        switch fresh {
        case .audiobookshelfItem(let value): id = value.id
        case .audiobookshelfEpisode(let value): id = value.libraryItemID
        case .audiobookshelfLibrary, .audiobookshelfTrack, .audiobookshelfFile: return nil
        default: throw RemoteBrowserError(code: .invalidReference)
        }
        let data = try await provider.cover(itemID: id)
        try await validateSession()
        return data
    }

    func downloads(_ node: BrowserNode) async throws -> [BrowserDownloadRecord] {
        let fresh = try await refresh(node)
        try await validateSession()
        guard user.permissions.download else { return [] }
        let values: [AudiobookshelfFile], itemID: String
        switch fresh {
        case .audiobookshelfLibrary: return []
        case .audiobookshelfItem(let item): values = files(item); itemID = item.id
        case .audiobookshelfEpisode(let episode): values = episode.audioFile.map { [$0] } ?? []; itemID = episode.libraryItemID
        case .audiobookshelfFile(let file, let id): values = [file]; itemID = id
        case .audiobookshelfTrack(let track, let id, let episodeID):
            itemID = id
            let item = try await provider.item(id: id)
            try await validateSession()
            if let episodeID {
                guard let episode = item.episodes?.first(where: { $0.id == episodeID }),
                      episode.audioTrack?.fileID == track.fileID, episode.audioTrack?.index == track.index,
                      let file = episode.audioFile, file.id == track.fileID else { throw RemoteBrowserError(code: .invalidReference) }
                values = [file]
            } else {
                guard item.tracks?.contains(where: { $0.index == track.index && $0.fileID == track.fileID }) == true,
                      let file = files(item).first(where: { $0.id == track.fileID }) else { throw RemoteBrowserError(code: .invalidReference) }
                values = [file]
            }
        default: throw RemoteBrowserError(code: .invalidReference)
        }
        return values.map { file in
            .init(key: BrowserMapping.key("abs", "download", itemID, file.id), title: file.filename,
                  filename: file.filename, contentType: file.mimeType, size: file.size,
                  kind: file.mimeType?.hasPrefix("audio/") == true || file.duration != nil ? .audioFile : .originalFile,
                  locator: .audiobookshelf(itemID: itemID, fileID: file.id))
        }
    }

    func prepare(_ download: BrowserDownloadRecord) async throws -> RemoteFileReference {
        try await validateSession()
        guard case .audiobookshelf(let itemID, let fileID) = download.locator else { throw RemoteBrowserError(code: .invalidReference) }
        let reference = try await provider.prepareDownload(itemID: itemID, fileID: fileID)
        try await validateSession()
        return reference
    }

    func nativeReference(_ node: BrowserNode) async throws -> RemoteBrowseNativeReference {
        let fresh = try await refresh(node)
        try await validateSession()
        switch fresh {
        case .audiobookshelfLibrary(let value): return .audiobookshelfLibrary(value.id)
        case .audiobookshelfItem(let value): return .audiobookshelfItem(value.id)
        case .audiobookshelfEpisode(let value): return .audiobookshelfEpisode(itemID: value.libraryItemID, episodeID: value.id)
        case .audiobookshelfTrack(let value, let itemID, let episodeID):
            return .audiobookshelfTrack(itemID: itemID, episodeID: episodeID, trackIndex: value.index, fileID: value.fileID)
        case .audiobookshelfFile(let value, let itemID): return .audiobookshelfFile(itemID: itemID, fileID: value.id)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }

    private func refresh(_ node: BrowserNode) async throws -> BrowserNode {
        try await validateSession()
        switch node {
        case .audiobookshelfLibrary(let old):
            let values = try await provider.libraries()
            try await validateSession()
            guard let value = values.first(where: { $0.id == old.id }), value.mediaType == old.mediaType else {
                throw RemoteBrowserError(code: .invalidReference)
            }
            return .audiobookshelfLibrary(value)
        case .audiobookshelfItem(let old):
            let value = try await provider.item(id: old.id)
            try await validateSession()
            guard value.id == old.id, value.libraryID == old.libraryID, value.mediaType == old.mediaType else {
                throw RemoteBrowserError(code: .invalidReference)
            }
            return .audiobookshelfItem(value)
        case .audiobookshelfEpisode(let old):
            let value = try await provider.episode(itemID: old.libraryItemID, episodeID: old.id)
            try await validateSession()
            guard value.id == old.id, value.libraryItemID == old.libraryItemID, value.podcastID == old.podcastID else {
                throw RemoteBrowserError(code: .invalidReference)
            }
            return .audiobookshelfEpisode(value)
        case .audiobookshelfTrack(let old, let itemID, let episodeID):
            let item = try await provider.item(id: itemID)
            try await validateSession()
            let tracks: [AudiobookshelfAudioTrack]
            if let episodeID, item.mediaType == .podcast {
                tracks = item.episodes?.first(where: { $0.id == episodeID })?.audioTrack.map { [$0] } ?? []
            } else if episodeID == nil, item.mediaType == .book { tracks = item.tracks ?? [] }
            else { throw RemoteBrowserError(code: .invalidReference) }
            guard let value = tracks.first(where: { $0.index == old.index && $0.fileID == old.fileID }) else {
                throw RemoteBrowserError(code: .invalidReference)
            }
            return .audiobookshelfTrack(value, itemID: itemID, episodeID: episodeID)
        case .audiobookshelfFile(let old, let itemID):
            let item = try await provider.item(id: itemID)
            try await validateSession()
            guard let value = files(item).first(where: { $0.id == old.id }) else { throw RemoteBrowserError(code: .invalidReference) }
            return .audiobookshelfFile(value, itemID: itemID)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }

    private func files(_ item: AudiobookshelfItem) -> [AudiobookshelfFile] {
        var seen = Set<String>()
        return ((item.audioFiles ?? []) + (item.episodes ?? []).compactMap(\.audioFile) + (item.files ?? []))
            .filter { seen.insert($0.id).inserted }
    }

    private func record(_ node: BrowserNode) -> BrowserRecord {
        let key: String, kind: RemoteBrowseKind
        var metadata: RemoteBrowseMetadata
        var capabilities: RemoteBrowseCapabilities = []
        switch node {
        case .audiobookshelfLibrary(let value):
            key = BrowserMapping.key("abs", "library", value.id); kind = .library
            metadata = .init(title: value.name); capabilities = [.browse, .search]
        case .audiobookshelfItem(let value):
            kind = value.mediaType == .book ? .book : .podcast
            key = BrowserMapping.key("abs", kind.rawValue, value.id)
            metadata = .init(title: value.metadata.title)
            metadata.subtitle = value.metadata.subtitle
            metadata.summary = value.metadata.description.map { .init($0, format: .html) }
            metadata.authors = value.metadata.authors?.map(\.name)
                ?? (value.metadata.authorName ?? value.metadata.author).map { [$0] } ?? []
            metadata.narrators = value.metadata.narrators ?? value.metadata.narratorName.map { [$0] } ?? []
            metadata.tags = (value.tags ?? []) + (value.metadata.genres ?? [])
            metadata.language = value.metadata.language; metadata.publicationDate = value.metadata.publishedYear
            metadata.size = value.size; metadata.duration = value.duration
            capabilities = [.artwork]
            if value.mediaType == .book {
                capabilities.insert(.nativeProgress)
                if value.tracks == nil && value.audioFiles == nil || !(value.tracks ?? []).isEmpty {
                    capabilities.insert(.nativePlayback)
                }
                if value.files == nil && value.audioFiles == nil && value.tracks == nil || !files(value).isEmpty || !(value.tracks ?? []).isEmpty {
                    capabilities.insert(.browse)
                }
            } else if value.episodes == nil || !(value.episodes ?? []).isEmpty { capabilities.insert(.browse) }
            if user.permissions.download && (!files(value).isEmpty || value.files == nil && value.audioFiles == nil && value.episodes == nil) {
                capabilities.insert(.download)
            }
        case .audiobookshelfEpisode(let value):
            key = BrowserMapping.key("abs", "episode", value.libraryItemID, value.id); kind = .episode
            metadata = .init(title: value.title); metadata.subtitle = value.subtitle
            metadata.summary = value.description.map { .init($0, format: .html) }
            metadata.duration = value.duration; metadata.size = value.audioFile?.size
            metadata.contentType = value.audioFile?.mimeType
            // publishedAt is a release timestamp, not the item's creation time.
            if let date = BrowserMapping.milliseconds(value.publishedAt) { metadata.publicationDate = ISO8601DateFormatter().string(from: date) }
            capabilities = [.artwork, .nativeProgress]
            if value.audioTrack != nil { capabilities.formUnion([.browse, .nativePlayback]) }
            if user.permissions.download && value.audioFile != nil { capabilities.insert(.download) }
        case .audiobookshelfTrack(let value, let itemID, let episodeID):
            key = BrowserMapping.key("abs", "track", itemID, episodeID ?? "", String(value.index), value.fileID); kind = .track
            metadata = .init(title: value.title); metadata.duration = value.duration; metadata.contentType = value.mimeType
            capabilities = [.nativePlayback, .nativeProgress]
            if user.permissions.download { capabilities.insert(.download) }
        case .audiobookshelfFile(let value, let itemID):
            key = BrowserMapping.key("abs", "file", itemID, value.id); kind = .file
            metadata = .init(title: value.filename); metadata.duration = value.duration
            metadata.size = value.size; metadata.contentType = value.mimeType
            if user.permissions.download { capabilities.insert(.download) }
        default:
            preconditionFailure("Audiobookshelf mapping requires a native node")
        }
        return .init(key: key, kind: kind, metadata: metadata, capabilities: capabilities, node: node)
    }
}
