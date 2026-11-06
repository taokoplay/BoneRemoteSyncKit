import BoneRemoteSyncKit

/// Host supplies credentials from its credential store and an app-private cache directory.
/// Call this only after the user has chosen a book and asked to open/download it.
func openKomgaBook(
    configuration: KomgaConfiguration,
    credential: RemoteCredential,
    expectedUserID: String?,
    bookID: String,
    cacheDirectoryPath: String,
    consume: @Sendable (MaterializedFileLease) async throws -> Void
) async throws {
    let source = KomgaSource(configuration: configuration)
    try await source.connect(credential, expectedUserID: expectedUserID)
    do {
        let reference = try await source.prepareDownload(bookID: bookID)
        let materializer = RemoteFileMaterializer(
            source: source,
            sourceBinding: try await source.sourceBinding(),
            cacheDirectory: .init(fileURLWithPath: cacheDirectoryPath, isDirectory: true)
        )
        do {
            let lease = try await materializer.materialize(reference)
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

/// A single bounded page. Continue only when the returned page has hasNextPage=true.
func searchKomgaBooks(
    source: KomgaSource,
    libraryID: String,
    query: String,
    page: Int = 0
) async throws -> ContentPage<KomgaBook> {
    try await source.books(libraryID: libraryID, search: query, page: page, pageSize: 30)
}

/// An explicit reader action; opening or downloading a file never invokes this automatically.
func saveKomgaPage(source: KomgaSource, bookID: String, currentPage: Int) async throws {
    try await source.updateReadProgress(bookID: bookID, page: currentPage)
}

/// The host reader obtains href/progression from its actual EPUB locator and chooses modified/device.
/// A 409 conflict should be reconciled by the host before submitting another explicit update.
func saveKomgaEPUB(
    source: KomgaSource,
    bookID: String,
    progression: KomgaReadiumProgression
) async throws {
    try await source.updateProgression(bookID: bookID, progression: progression)
}
