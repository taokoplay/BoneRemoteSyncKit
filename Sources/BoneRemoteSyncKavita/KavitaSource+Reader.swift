import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncContent

extension KavitaSource {
    /// Bounded image data; coverImage DTO fields are never treated as public URLs.
    public func cover(_ target: KavitaCover) async throws -> Data {
        let context = try context()
        let entity: String, id: Int
        switch target {
        case .library(let value): entity = "library"; id = value
        case .series(let value): entity = "series"; id = value
        case .volume(let value): entity = "volume"; id = value
        case .chapter(let value): entity = "chapter"; id = value
        }
        try KavitaValidation.id(id)
        let response = try await request(context, path: ["api", "Image", entity + "-cover"],
            query: [.init(name: entity + "Id", value: String(id))], kind: .image)
        try check(context)
        return response.data
    }

    /// Zero-based image index, strictly below pages. PDF extraction is explicitly enabled.
    /// EPUB uses reading-order XHTML and is not exposed as an image reader by this method.
    public func pageImage(_ reference: KavitaChapterReference, page: Int) async throws -> Data {
        let context = try context()
        let result = try await image(reference, page: page, thumbnail: false)
        try check(context)
        return result
    }
    public func thumbnail(_ reference: KavitaChapterReference, page: Int) async throws -> Data {
        let context = try context()
        let result = try await image(reference, page: page, thumbnail: true)
        try check(context)
        return result
    }
    private func image(_ reference: KavitaChapterReference, page: Int, thumbnail: Bool) async throws -> Data {
        let context = try context()
        try KavitaValidation.page(page)
        let chapter = try await validatedChapter(reference, context: context)
        try check(context)
        guard page < chapter.pages else { throw ContentServerError.invalidReference }
        let format = chapter.format ?? chapter.files.first?.format
        if format == .epub, !thumbnail { throw RemoteSyncError.unsupported(operation: "Kavita EPUB page image") }
        var query = [URLQueryItem(name: "chapterId", value: String(reference.chapterID)),
                     .init(name: thumbnail ? "pageNum" : "page", value: String(page))]
        if !thumbnail { query.append(.init(name: "extractPdf", value: format == .pdf ? "true" : "false")) }
        let response = try await request(context, path: ["api", "Reader", thumbnail ? "thumbnail" : "image"],
                                         query: query, kind: .image)
        try check(context)
        return response.data
    }

    /// Registers the chapter endpoint: one non-image file is returned unchanged; all other chapters
    /// produce a ZIP containing the original files. ZIP size is unknown, never the source-size sum.
    public func prepareDownload(_ reference: KavitaChapterReference) async throws -> RemoteFileReference {
        let context = try context()
        let chapter = try await validatedChapter(reference, context: context)
        try check(context)
        guard !chapter.files.isEmpty else { throw ContentServerError.invalidResponse }
        let name: String, size: Int64?, mediaType: String?
        if chapter.downloadKind == .originalFile {
            let file = chapter.files[0]
            let suffix = file.format == .epub ? ".epub" : file.format == .pdf ? ".pdf" : ""
            name = file.name ?? "chapter-\(chapter.id)\(suffix)"
            size = file.bytes
            switch file.format {
            case .epub: mediaType = "application/epub+zip"
            case .pdf: mediaType = "application/pdf"
            case .archive:
                let ext = (name as NSString).pathExtension.lowercased()
                mediaType = ext == "cbz" ? "application/x-cbz" : ext == "cbr" ? "application/x-cbr" : nil
            default: mediaType = nil
            }
        } else {
            name = "chapter-\(chapter.id).zip"; size = nil; mediaType = "application/zip"
        }
        return try registry.register(url: context.client.url(path: ["api", "Download", "chapter"],
            query: [.init(name: "chapterId", value: String(chapter.id))]), name: name, mediaType: mediaType, size: size,
            binding: sourceBinding(), limit: configuration.maxDownloadReferences)
    }

    public func progress(_ reference: KavitaChapterReference) async throws -> KavitaProgress {
        let context = try context()
        let chapter = try await validatedChapter(reference, context: context)
        try check(context)
        let wire = try await json(KavitaProgressWire.self, context: context, path: ["api", "Reader", "get-progress"],
                                  query: [.init(name: "chapterId", value: String(reference.chapterID))])
        try check(context)
        guard wire.chapterId == reference.chapterID, wire.pageNum >= 0, wire.pageNum <= chapter.pages else {
            throw ContentServerError.invalidResponse
        }
        let noHistory = wire.libraryId == 0 && wire.seriesId == 0 && wire.volumeId == 0 && wire.pageNum == 0
        guard noHistory || (wire.libraryId == reference.libraryID && wire.seriesId == reference.seriesID &&
                            wire.volumeId == reference.volumeID) else { throw ContentServerError.invalidResponse }
        do { try KavitaValidation.xpath(wire.bookScrollId.flatMap { $0.isEmpty ? nil : $0 }) }
        catch { throw ContentServerError.invalidResponse }
        return .init(chapter: reference, pageNum: wire.pageNum, totalPages: chapter.pages,
                     bookScrollID: noHistory ? nil : wire.bookScrollId,
                     lastModifiedUtc: noHistory ? nil : wire.lastModifiedUtc, hasRecordedProgress: !noHistory)
    }

    /// Explicit host action. pageNum accepts 0...pages, including the completion sentinel.
    /// EPUB bookScrollID is Kavita XPath. A first-ever pageNum=0 write is ignored by Kavita,
    /// even if it contains XPath. Success means accepted, not guaranteed persisted or conflict-free.
    public func updateProgress(_ reference: KavitaChapterReference, pageNum: Int,
                               bookScrollID: String? = nil) async throws {
        let context = try context()
        try KavitaValidation.page(pageNum); try KavitaValidation.xpath(bookScrollID)
        let chapter = try await validatedChapter(reference, context: context)
        try check(context)
        guard pageNum <= chapter.pages else { throw ContentServerError.invalidReference }
        if bookScrollID != nil, (chapter.format ?? chapter.files.first?.format) != .epub {
            throw ContentServerError.invalidReference
        }
        let body = KavitaProgressWrite(libraryId: reference.libraryID, seriesId: reference.seriesID,
            volumeId: reference.volumeID, chapterId: reference.chapterID, pageNum: pageNum, bookScrollId: bookScrollID)
        _ = try await request(context, path: ["api", "Reader", "progress"], method: "POST", body: ContentCoding.encode(body))
        try check(context)
        // The official success response is HTTP 200 with an empty body; do not decode it.
    }

    public func bookInfo(_ reference: KavitaChapterReference) async throws -> KavitaBookInfo {
        let context = try context()
        let chapter = try await validatedChapter(reference, context: context)
        try check(context)
        let info = try await json(KavitaBookInfo.self, context: context,
                                  path: ["api", "Book", String(reference.chapterID), "book-info"])
        try check(context)
        guard info.libraryID == reference.libraryID, info.seriesID == reference.seriesID,
              info.volumeID == reference.volumeID, info.pages == chapter.pages else { throw ContentServerError.invalidResponse }
        return info
    }

    /// EPUB table of contents only; HTML/CSS rewriting and an embedded web reader remain host concerns.
    public func bookChapters(_ reference: KavitaChapterReference) async throws -> [KavitaBookChapter] {
        let context = try context()
        let chapter = try await validatedChapter(reference, context: context)
        try check(context)
        guard (chapter.format ?? chapter.files.first?.format) == .epub else {
            throw RemoteSyncError.unsupported(operation: "Kavita EPUB table of contents")
        }
        let items = try await json([KavitaBookChapter].self, context: context,
                                   path: ["api", "Book", String(reference.chapterID), "chapters"])
        try check(context)
        try KavitaValidation.toc(items, pages: chapter.pages)
        return items
    }
}

private struct KavitaProgressWire: Decodable {
    let libraryId: Int; let seriesId: Int; let volumeId: Int; let chapterId: Int; let pageNum: Int
    let bookScrollId: String?; let lastModifiedUtc: String?
}
private struct KavitaProgressWrite: Encodable {
    let libraryId: Int; let seriesId: Int; let volumeId: Int; let chapterId: Int; let pageNum: Int
    let bookScrollId: String?
}
