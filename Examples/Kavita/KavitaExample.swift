import BoneRemoteSyncKit

/// The host supplies configuration, a securely stored key, an app-owned cache directory,
/// and a consumer that finishes using the lease before returning. No real credentials are embedded.
func kavitaNativeExample(
    configuration: KavitaConfiguration,
    apiKey: String,
    cacheDirectoryPath: String,
    consume: @Sendable (MaterializedFileLease) async throws -> Void
) async throws {
    let source = KavitaSource(configuration: configuration)
    try await source.connect(.apiToken(apiKey))
    do {
        guard let library = try await source.libraries().first else {
            await source.disconnect()
            return
        }
        let page = try await source.series(libraryID: library.id, page: 0, pageSize: 25)
        // A UI can request page.page + 1 when page.hasNextPage is true.
        guard let series = page.items.first,
              let volume = try await source.volumes(seriesID: series.id).first,
              let chapter = volume.chapters.first else {
            await source.disconnect()
            return
        }
        _ = try await source.searchSeries(series.name ?? "book", libraryID: library.id, pageSize: 25)
        _ = try await source.cover(.series(series.id))
        let reference = try await source.chapterReference(chapterID: chapter.id)
        _ = try await source.progress(reference)
        if chapter.format == .epub {
            _ = try await source.bookInfo(reference)
            _ = try await source.bookChapters(reference)
        } else if chapter.pages > 0 {
            _ = try await source.pageImage(reference, page: 0)
        }

        // This selects the complete chapter download. Multiple files or images yield a ZIP.
        let file = try await source.prepareDownload(reference)
        let materializer = RemoteFileMaterializer(
            source: source,
            sourceBinding: try await source.sourceBinding(),
            cacheDirectory: .init(fileURLWithPath: cacheDirectoryPath, isDirectory: true)
        )
        do {
            let lease = try await materializer.materialize(file)
            do {
                try await consume(lease)
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
            await materializer.shutdown()
        } catch {
            await materializer.shutdown()
            throw error
        }
        await source.disconnect()
    } catch {
        await source.disconnect()
        throw error
    }
}

/// Invoke only after the host explicitly chooses to save an EPUB position.
/// The XPath must refer to Kavita's DOM; a locator from another EPUB engine needs host-side conversion.
/// A first-ever readingOrderIndex == 0 write is ignored by Kavita, including its XPath.
func saveKavitaEPUBPosition(
    source: KavitaSource,
    chapter: KavitaChapterReference,
    readingOrderIndex: Int,
    kavitaXPath: String?
) async throws {
    try await source.updateProgress(chapter, pageNum: readingOrderIndex, bookScrollID: kavitaXPath)
}

/// Existing JWTs use an explicit JWT entry point. Persist the returned pair securely after refresh.
/// Refresh invalidates existing references; do not automatically replay a failed progress write.
func explicitlyRefreshKavitaJWT(
    source: KavitaSource,
    tokens: KavitaTokens,
    expectedUserID: Int
) async throws -> KavitaTokens {
    try await source.connectJWT(tokens, expectedUserID: expectedUserID)
    return try await source.refreshTokens()
}
