import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncKomga

struct KomgaBrowserAdapter: BrowserAdapter {
    let provider: KomgaSource
    let binding: RemoteSourceBinding
    let user: KomgaUser
    var source: any RemoteSource { provider }
    var rootCapabilities: RemoteBrowseCapabilities { [.browse, .search] }

    func validateSession() async throws {
        guard try await provider.sourceBinding() == binding else { throw RemoteBrowserError(code: .sessionExpired) }
    }

    func page(_ request: BrowserRequest) async throws -> BrowserResult {
        try await validateSession()
        switch request.parent {
        case nil where request.query == nil:
            let values = try await provider.libraries()
            try await validateSession()
            return .init(records: values.map(record), total: values.count, capabilities: rootCapabilities)
        case nil, .komgaLibrary, .komgaSeries:
            var libraryID: String?, seriesID: String?
            if let parent = request.parent {
                let fresh = try await details(parent)
                try await validateSession()
                switch fresh.node {
                case .komgaLibrary(let library): libraryID = library.id
                case .komgaSeries(let series): libraryID = series.libraryId; seriesID = series.id
                default: throw RemoteBrowserError(code: .invalidReference)
                }
            }
            if libraryID != nil, seriesID == nil, request.query == nil {
                let page = try await provider.series(libraryID: libraryID, page: request.page, pageSize: request.pageSize)
                try await validateSession()
                return .init(records: page.items.map(record), total: page.total, capabilities: [.browse, .search],
                             next: page.hasNextPage ? .request(request.next()) : nil)
            }
            let page = try await provider.books(libraryID: libraryID, seriesID: seriesID, search: request.query,
                                                page: request.page, pageSize: request.pageSize)
            try await validateSession()
            return .init(records: page.items.map(record), total: page.total, capabilities: [.browse, .search],
                         next: page.hasNextPage ? .request(request.next()) : nil)
        case .komgaBook:
            throw RemoteBrowserError(code: .unsupported)
        default:
            throw RemoteBrowserError(code: .invalidReference)
        }
    }

    func details(_ node: BrowserNode) async throws -> BrowserRecord {
        try await validateSession()
        switch node {
        case .komgaLibrary(let old):
            let value = try await provider.library(id: old.id)
            try await validateSession()
            guard value.id == old.id else { throw RemoteBrowserError(code: .invalidReference) }
            return record(value)
        case .komgaSeries(let old):
            let value = try await provider.series(id: old.id)
            try await validateSession()
            guard value.id == old.id, value.libraryId == old.libraryId else { throw RemoteBrowserError(code: .invalidReference) }
            return record(value)
        case .komgaBook(let old):
            let value = try await provider.book(id: old.id)
            try await validateSession()
            guard value.id == old.id, value.libraryId == old.libraryId, value.seriesId == old.seriesId else {
                throw RemoteBrowserError(code: .invalidReference)
            }
            return record(value)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }

    func artwork(_ node: BrowserNode) async throws -> Data? {
        let fresh = try await details(node)
        try await validateSession()
        let data: Data
        switch fresh.node {
        case .komgaLibrary: return nil
        case .komgaSeries(let series): data = try await provider.seriesCover(seriesID: series.id)
        case .komgaBook(let book): data = try await provider.bookCover(bookID: book.id)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
        try await validateSession()
        return data
    }

    func downloads(_ node: BrowserNode) async throws -> [BrowserDownloadRecord] {
        let fresh = try await details(node)
        try await validateSession()
        guard user.canDownloadFiles, case .komgaBook(let book) = fresh.node else { return [] }
        return [.init(key: BrowserMapping.key("komga", "download", book.id), title: fresh.metadata.title,
                      filename: book.name, contentType: book.media.mediaType, size: book.sizeBytes,
                      kind: .originalFile, locator: .komga(bookID: book.id))]
    }

    func prepare(_ download: BrowserDownloadRecord) async throws -> RemoteFileReference {
        try await validateSession()
        guard case .komga(let id) = download.locator else { throw RemoteBrowserError(code: .invalidReference) }
        let reference = try await provider.prepareDownload(bookID: id)
        try await validateSession()
        return reference
    }

    func nativeReference(_ node: BrowserNode) async throws -> RemoteBrowseNativeReference {
        let fresh = try await details(node)
        try await validateSession()
        switch fresh.node {
        case .komgaLibrary(let value): return .komgaLibrary(value.id)
        case .komgaSeries(let value): return .komgaSeries(value.id)
        case .komgaBook(let value): return .komgaBook(value.id)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }

    private func record(_ value: KomgaLibrary) -> BrowserRecord {
        .init(key: BrowserMapping.key("komga", "library", value.id), kind: .library,
              metadata: .init(title: value.name), capabilities: [.browse, .search], node: .komgaLibrary(value))
    }

    private func record(_ value: KomgaSeries) -> BrowserRecord {
        var metadata = RemoteBrowseMetadata(title: BrowserMapping.title(value.metadata.title, fallback: value.name))
        metadata.summary = summary(value.metadata.summary ?? value.booksMetadata?.summary)
        metadata.authors = value.booksMetadata?.authors?.map(\.name) ?? []
        metadata.tags = (value.metadata.tags ?? []) + (value.metadata.genres ?? [])
        metadata.language = value.metadata.language
        metadata.publicationDate = value.booksMetadata?.releaseDate
        metadata.createdAt = value.created; metadata.modifiedAt = value.lastModified
        var capabilities: RemoteBrowseCapabilities = [.search, .artwork]
        if value.booksCount > 0 { capabilities.insert(.browse) }
        return .init(key: BrowserMapping.key("komga", "series", value.id), kind: .series, metadata: metadata,
                     capabilities: capabilities, node: .komgaSeries(value))
    }

    private func record(_ value: KomgaBook) -> BrowserRecord {
        var metadata = RemoteBrowseMetadata(title: BrowserMapping.title(value.metadata.title, fallback: value.name))
        metadata.subtitle = value.seriesTitle
        metadata.summary = summary(value.metadata.summary)
        metadata.authors = value.metadata.authors?.map(\.name) ?? []
        metadata.tags = value.metadata.tags ?? []
        metadata.contentType = value.media.mediaType; metadata.size = value.sizeBytes
        metadata.pageCount = value.media.isEPUB ? nil : value.media.pagesCount
        metadata.publicationDate = value.metadata.releaseDate
        metadata.createdAt = value.created; metadata.modifiedAt = value.lastModified
        if !value.media.isEPUB {
            metadata.progress = BrowserMapping.fraction(value.readProgress?.page, total: value.media.pagesCount)
        }
        var capabilities: RemoteBrowseCapabilities = [.artwork, .nativeProgress]
        if user.canDownloadFiles { capabilities.insert(.download) }
        return .init(key: BrowserMapping.key("komga", "book", value.id), kind: .book,
                     metadata: metadata, capabilities: capabilities, node: .komgaBook(value))
    }

    private func summary(_ value: String?) -> RemoteBrowseText? {
        value.map { .init($0, format: $0.contains("<") && $0.contains(">") ? .html : .text) }
    }
}
