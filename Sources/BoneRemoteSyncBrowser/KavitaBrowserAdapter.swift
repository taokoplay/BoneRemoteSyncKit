import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncKavita

struct KavitaBrowserAdapter: BrowserAdapter {
    let provider: KavitaSource
    let binding: RemoteSourceBinding
    let account: KavitaAccount
    var source: any RemoteSource { provider }
    var rootCapabilities: RemoteBrowseCapabilities { [.browse] }
    private var canDownload: Bool { account.roles.contains("Download") || account.roles.contains("Admin") }

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
            return .init(records: values.map(record), total: values.count)
        case .kavitaLibrary(let library):
            let page = if let query = request.query {
                try await provider.searchSeries(query, libraryID: library.id, page: request.page, pageSize: request.pageSize)
            } else {
                try await provider.series(libraryID: library.id, page: request.page, pageSize: request.pageSize)
            }
            try await validateSession()
            return .init(records: page.items.map(record), total: page.total, capabilities: [.browse, .search],
                         next: page.hasNextPage ? .request(request.next()) : nil)
        case .kavitaSeries, .kavitaVolume:
            guard request.query == nil else { throw RemoteBrowserError(code: .unsupported) }
            let fresh = try await details(request.parent!)
            try await validateSession()
            switch fresh.node {
            case .kavitaSeries(let series):
                let values = try await provider.volumes(seriesID: series.id)
                try await validateSession()
                return .init(records: values.map { record($0, libraryID: series.libraryID) }, total: values.count)
            case .kavitaVolume(let volume, let libraryID):
                return .init(records: volume.chapters.map { record($0, libraryID: libraryID, seriesID: volume.seriesID) },
                             total: volume.chapters.count)
            default: throw RemoteBrowserError(code: .invalidReference)
            }
        case .kavitaChapter: throw RemoteBrowserError(code: .unsupported)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }

    func details(_ node: BrowserNode) async throws -> BrowserRecord {
        try await validateSession()
        switch node {
        case .kavitaLibrary(let old):
            let values = try await provider.libraries()
            try await validateSession()
            guard let value = values.first(where: { $0.id == old.id }) else { throw RemoteBrowserError(code: .invalidReference) }
            return record(value)
        case .kavitaSeries(let old):
            let value = try await provider.series(seriesID: old.id)
            try await validateSession()
            guard value.id == old.id, value.libraryID == old.libraryID else { throw RemoteBrowserError(code: .invalidReference) }
            return record(value)
        case .kavitaVolume(let old, let libraryID):
            let value = try await provider.volume(volumeID: old.id)
            try await validateSession()
            guard value.id == old.id, value.seriesID == old.seriesID else { throw RemoteBrowserError(code: .invalidReference) }
            let series = try await provider.series(seriesID: old.seriesID)
            try await validateSession()
            guard series.libraryID == libraryID else { throw RemoteBrowserError(code: .invalidReference) }
            return record(value, libraryID: libraryID)
        case .kavitaChapter(let old, let libraryID, let seriesID):
            _ = try await chapterReference(old, libraryID: libraryID, seriesID: seriesID)
            try await validateSession()
            let value = try await provider.chapter(chapterID: old.id)
            try await validateSession()
            guard value.id == old.id, value.volumeID == old.volumeID else { throw RemoteBrowserError(code: .invalidReference) }
            return record(value, libraryID: libraryID, seriesID: seriesID)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }

    func artwork(_ node: BrowserNode) async throws -> Data? {
        let fresh = try await details(node)
        try await validateSession()
        let target: KavitaCover
        switch fresh.node {
        case .kavitaLibrary(let value): target = .library(value.id)
        case .kavitaSeries(let value): target = .series(value.id)
        case .kavitaVolume(let value, _): target = .volume(value.id)
        case .kavitaChapter(let value, _, _): target = .chapter(value.id)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
        let data = try await provider.cover(target)
        try await validateSession()
        return data
    }

    func downloads(_ node: BrowserNode) async throws -> [BrowserDownloadRecord] {
        let fresh = try await details(node)
        try await validateSession()
        guard canDownload, case .kavitaChapter(let value, let libraryID, let seriesID) = fresh.node,
              !value.files.isEmpty else { return [] }
        let reference = try await chapterReference(value, libraryID: libraryID, seriesID: seriesID)
        try await validateSession()
        let original = value.downloadKind == .originalFile
        let file = value.files[0]
        let name = original ? file.name ?? "chapter-\(value.id)" : "chapter-\(value.id).zip"
        return [.init(key: BrowserMapping.key("kavita", "download", String(value.id)), title: fresh.metadata.title,
                      filename: name, contentType: original ? contentType(file) : "application/zip",
                      size: original ? file.bytes : nil, kind: original ? .originalFile : .archive, locator: .kavita(reference))]
    }

    func prepare(_ download: BrowserDownloadRecord) async throws -> RemoteFileReference {
        try await validateSession()
        guard case .kavita(let chapter) = download.locator else { throw RemoteBrowserError(code: .invalidReference) }
        // The native prepare revalidates the saved ancestry; never replace it with freshly resolved parents.
        let reference = try await provider.prepareDownload(chapter)
        try await validateSession()
        return reference
    }

    func nativeReference(_ node: BrowserNode) async throws -> RemoteBrowseNativeReference {
        let fresh = try await details(node)
        try await validateSession()
        switch fresh.node {
        case .kavitaLibrary(let value): return .kavitaLibrary(value.id)
        case .kavitaSeries(let value): return .kavitaSeries(value.id)
        case .kavitaVolume(let value, _): return .kavitaVolume(value.id)
        case .kavitaChapter(let value, let libraryID, let seriesID):
            let reference = try await chapterReference(value, libraryID: libraryID, seriesID: seriesID)
            try await validateSession()
            return .kavitaChapter(reference)
        default: throw RemoteBrowserError(code: .invalidReference)
        }
    }

    private func chapterReference(_ chapter: KavitaChapter, libraryID: Int, seriesID: Int) async throws -> KavitaChapterReference {
        try await validateSession()
        let reference = try await provider.chapterReference(chapterID: chapter.id)
        try await validateSession()
        guard reference.chapterID == chapter.id, reference.volumeID == chapter.volumeID,
              reference.seriesID == seriesID, reference.libraryID == libraryID else { throw RemoteBrowserError(code: .invalidReference) }
        return reference
    }

    private func record(_ value: KavitaLibrary) -> BrowserRecord {
        .init(key: BrowserMapping.key("kavita", "library", String(value.id)), kind: .library,
              metadata: .init(title: BrowserMapping.title(value.name, fallback: "Library \(value.id)")),
              capabilities: [.browse, .search, .artwork], node: .kavitaLibrary(value))
    }

    private func record(_ value: KavitaSeries) -> BrowserRecord {
        var metadata = RemoteBrowseMetadata(title: BrowserMapping.title(value.name, fallback: "Series \(value.id)"))
        metadata.subtitle = value.libraryName
        metadata.pageCount = value.format == .epub ? nil : value.pages
        metadata.createdAtRaw = value.created; metadata.createdAt = BrowserMapping.date(value.created)
        metadata.modifiedAtRaw = value.lastChapterAddedUtc; metadata.modifiedAt = BrowserMapping.date(value.lastChapterAddedUtc)
        return .init(key: BrowserMapping.key("kavita", "series", String(value.id)), kind: .series,
                     metadata: metadata, capabilities: [.browse, .artwork], node: .kavitaSeries(value))
    }

    private func record(_ value: KavitaVolume, libraryID: Int) -> BrowserRecord {
        var metadata = RemoteBrowseMetadata(title: BrowserMapping.title(value.name, fallback: "Volume \(value.id)"))
        if !value.chapters.contains(where: isEPUB) { metadata.pageCount = value.pages }
        metadata.createdAtRaw = value.createdUtc; metadata.createdAt = BrowserMapping.date(value.createdUtc)
        metadata.modifiedAtRaw = value.lastModifiedUtc; metadata.modifiedAt = BrowserMapping.date(value.lastModifiedUtc)
        var capabilities: RemoteBrowseCapabilities = [.artwork]
        if !value.chapters.isEmpty { capabilities.insert(.browse) }
        return .init(key: BrowserMapping.key("kavita", "volume", String(value.id)), kind: .volume,
                     metadata: metadata, capabilities: capabilities, node: .kavitaVolume(value, libraryID: libraryID))
    }

    private func record(_ value: KavitaChapter, libraryID: Int, seriesID: Int) -> BrowserRecord {
        var metadata = RemoteBrowseMetadata(title: BrowserMapping.title(value.titleName ?? value.title, fallback: "Chapter \(value.id)"))
        metadata.subtitle = value.range
        metadata.summary = value.summary.map { .init($0, format: $0.contains("<") && $0.contains(">") ? .html : .text) }
        metadata.authors = value.writers?.compactMap { $0.name ?? $0.title } ?? []
        metadata.tags = ((value.tags ?? []) + (value.genres ?? [])).compactMap { $0.title ?? $0.name }
        metadata.language = value.language; metadata.publicationDate = value.releaseDate
        if !isEPUB(value) {
            metadata.pageCount = value.pages
            metadata.progress = BrowserMapping.fraction(value.pagesRead, total: value.pages)
        }
        if value.files.count == 1 { metadata.size = value.files[0].bytes; metadata.contentType = contentType(value.files[0]) }
        metadata.createdAtRaw = value.createdUtc; metadata.createdAt = BrowserMapping.date(value.createdUtc)
        metadata.modifiedAtRaw = value.lastModifiedUtc; metadata.modifiedAt = BrowserMapping.date(value.lastModifiedUtc)
        var capabilities: RemoteBrowseCapabilities = [.artwork, .nativeProgress]
        if canDownload && !value.files.isEmpty { capabilities.insert(.download) }
        return .init(key: BrowserMapping.key("kavita", "chapter", String(value.id)), kind: .chapter, metadata: metadata,
                     capabilities: capabilities, node: .kavitaChapter(value, libraryID: libraryID, seriesID: seriesID))
    }

    private func isEPUB(_ chapter: KavitaChapter) -> Bool {
        chapter.format == .epub || chapter.files.contains { $0.format == .epub }
    }

    private func contentType(_ file: KavitaFile) -> String? {
        switch file.format {
        case .epub: return "application/epub+zip"
        case .pdf: return "application/pdf"
        case .archive:
            switch (file.name as NSString?)?.pathExtension.lowercased() {
            case "cbz": return "application/x-cbz"
            case "cbr": return "application/x-cbr"
            default: return nil
            }
        default: return nil
        }
    }
}
