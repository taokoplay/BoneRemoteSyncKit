import Foundation
import BoneRemoteSyncContent

extension KavitaSource {
    public func libraries() async throws -> [KavitaLibrary] {
        let context = try context()
        let result = try await json([KavitaLibrary].self, context: context, path: ["api", "Library", "libraries"])
        try check(context)
        try KavitaValidation.unique(result.map(\.id))
        return result
    }

    /// Public pages are zero-based. Missing or inconsistent Pagination headers are invalid responses.
    public func series(libraryID: Int, page: Int = 0, pageSize: Int = 50) async throws -> ContentPage<KavitaSeries> {
        let context = try context()
        let result = try await seriesPage(libraryID: libraryID, search: nil, page: page, pageSize: pageSize)
        try check(context)
        return result
    }

    /// Searches series names through Series/v2, preserving pagination and the library filter.
    public func searchSeries(_ query: String, libraryID: Int, page: Int = 0,
                             pageSize: Int = 50) async throws -> ContentPage<KavitaSeries> {
        let context = try context()
        let result = try await seriesPage(libraryID: libraryID, search: ContentValidation.search(query), page: page, pageSize: pageSize)
        try check(context)
        return result
    }

    private func seriesPage(libraryID: Int, search: String?, page: Int, pageSize: Int) async throws -> ContentPage<KavitaSeries> {
        let context = try context()
        try KavitaValidation.id(libraryID)
        try ContentValidation.pagination(page: page, pageSize: pageSize)
        var statements = [KavitaFilter.Statement(field: 19, comparison: 0, value: String(libraryID)),
                          .init(field: 34, comparison: 0, value: "false")]
        if let search { statements.append(.init(field: 1, comparison: 7, value: search)) }
        let response = try await request(context, path: ["api", "Series", "v2"],
            query: [.init(name: "PageNumber", value: String(page + 1)), .init(name: "PageSize", value: String(pageSize))],
            method: "POST", body: ContentCoding.encode(KavitaFilter(statements: statements)))
        try check(context)
        let result = try ContentCoding.decode([KavitaSeries].self, from: response)
        try KavitaValidation.unique(result.map(\.id))
        for series in result {
            try KavitaValidation.series(series)
            guard series.libraryID == libraryID else { throw ContentServerError.invalidResponse }
        }
        let pagination = try KavitaValidation.pagination(response.response.value(forHTTPHeaderField: "Pagination"),
                                                        page: page, size: pageSize, count: result.count)
        return .init(items: result, page: page, pageSize: pageSize, total: pagination.totalItems,
                     hasNextPage: page + 1 < pagination.totalPages)
    }

    public func series(seriesID: Int) async throws -> KavitaSeries {
        let context = try context()
        let result = try await fetchSeries(seriesID, context: context)
        try check(context)
        return result
    }
    public func volumes(seriesID: Int) async throws -> [KavitaVolume] {
        let context = try context()
        try KavitaValidation.id(seriesID)
        let result = try await json([KavitaVolume].self, context: context, path: ["api", "Series", "volumes"],
                                    query: [.init(name: "seriesId", value: String(seriesID))])
        try check(context)
        try KavitaValidation.unique(result.map(\.id))
        try KavitaValidation.unique(result.flatMap(\.chapters).map(\.id))
        for volume in result {
            try KavitaValidation.volume(volume)
            guard volume.seriesID == seriesID else { throw ContentServerError.invalidResponse }
        }
        return result
    }
    public func volume(volumeID: Int) async throws -> KavitaVolume {
        let context = try context()
        let result = try await fetchVolume(volumeID, context: context)
        try check(context)
        return result
    }
    public func chapter(chapterID: Int) async throws -> KavitaChapter {
        let context = try context()
        let result = try await fetchChapter(chapterID, context: context)
        try check(context)
        return result
    }

    /// Resolves chapter → volume → series → library and confirms chapter membership in the volume.
    public func chapterReference(chapterID: Int) async throws -> KavitaChapterReference {
        let context = try context()
        let chapter = try await fetchChapter(chapterID, context: context)
        try check(context)
        let volume = try await fetchVolume(chapter.volumeID, context: context)
        try check(context)
        guard volume.chapters.contains(where: { $0.id == chapter.id }) else { throw ContentServerError.invalidResponse }
        let series = try await fetchSeries(volume.seriesID, context: context)
        try check(context)
        return .init(libraryID: series.libraryID, seriesID: series.id, volumeID: volume.id,
                     chapterID: chapter.id, generation: context.generation)
    }

    func fetchSeries(_ id: Int, context: Context) async throws -> KavitaSeries {
        try KavitaValidation.id(id)
        let result = try await json(KavitaSeries.self, context: context, path: ["api", "Series", String(id)])
        try check(context)
        try KavitaValidation.series(result)
        guard result.id == id else { throw ContentServerError.invalidResponse }
        return result
    }
    func fetchVolume(_ id: Int, context: Context) async throws -> KavitaVolume {
        try KavitaValidation.id(id)
        let result = try await json(KavitaVolume.self, context: context, path: ["api", "Series", "volume"],
                                    query: [.init(name: "volumeId", value: String(id))])
        try check(context)
        try KavitaValidation.volume(result)
        guard result.id == id else { throw ContentServerError.invalidResponse }
        return result
    }
    func fetchChapter(_ id: Int, context: Context) async throws -> KavitaChapter {
        try KavitaValidation.id(id)
        let result = try await json(KavitaChapter.self, context: context, path: ["api", "Series", "chapter"],
                                    query: [.init(name: "chapterId", value: String(id))])
        try check(context)
        try KavitaValidation.chapter(result)
        guard result.id == id else { throw ContentServerError.invalidResponse }
        return result
    }
    func validate(_ reference: KavitaChapterReference, context: Context) throws {
        guard reference.generation == context.generation else { throw ContentServerError.invalidReference }
        try KavitaValidation.id(reference.chapterID); try KavitaValidation.id(reference.volumeID)
        try KavitaValidation.id(reference.seriesID); try KavitaValidation.id(reference.libraryID)
    }
    func validatedChapter(_ reference: KavitaChapterReference, context: Context) async throws -> KavitaChapter {
        try validate(reference, context: context)
        let chapter = try await fetchChapter(reference.chapterID, context: context)
        try check(context)
        guard chapter.volumeID == reference.volumeID else { throw ContentServerError.invalidReference }
        let volume = try await fetchVolume(reference.volumeID, context: context)
        try check(context)
        guard volume.seriesID == reference.seriesID, volume.chapters.contains(where: { $0.id == chapter.id }) else {
            throw ContentServerError.invalidReference
        }
        let series = try await fetchSeries(reference.seriesID, context: context)
        try check(context)
        guard series.libraryID == reference.libraryID else { throw ContentServerError.invalidReference }
        return chapter
    }
}

private struct KavitaFilter: Encodable {
    struct Statement: Encodable { let field: Int; let comparison: Int; let value: String }
    struct Sort: Encodable { let sortField = 1; let isAscending = true }
    let statements: [Statement]
    let combination = 1
    let sortOptions = Sort()
    let limitTo = 0
}
