#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncContent
import BoneRemoteSyncKavita
import BoneRemoteSyncTransfer
import BoneRemoteSyncTestSupport

@Suite(.enabled(if: PythonFixture.isAvailable, "Requires Python 3"))
struct KavitaReaderTests {
    @Test func coverAndImagesUseNativeRoutesAndPDFExtraction() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let expected = try Data(contentsOf: server.file("cover.png"))
        for target: KavitaCover in [.library(1), .series(12), .volume(23), .chapter(34)] {
            #expect(try await source.cover(target) == expected)
        }
        let pdf = try await source.chapterReference(chapterID: 37)
        #expect(try await source.pageImage(pdf, page: 0) == expected)
        #expect(try await source.thumbnail(pdf, page: 2) == expected)
        let query = try #require(server.requests("Reader/image").last?["query"] as? [String: String])
        #expect(query == ["chapterId": "37", "page": "0", "extractPdf": "true"])
        let image = try await source.chapterReference(chapterID: 36)
        #expect(try await source.pageImage(image, page: 2) == expected)
        await #expect(throws: ContentServerError.invalidReference) { try await source.pageImage(pdf, page: 3) }
        await #expect(throws: ContentServerError.invalidReference) { try await source.thumbnail(pdf, page: -1) }
        let epub = try await source.chapterReference(chapterID: 34)
        await #expect(throws: RemoteSyncError.self) { try await source.pageImage(epub, page: 0) }
        #expect(try server.requests("Reader/image").count == 2)
        await source.disconnect()
    }

    @Test func progressRoundTripPreservesAncestryAndEPUBXPath() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let reference = try await source.chapterReference(chapterID: 34)
        let initial = try await source.progress(reference)
        #expect(!initial.hasRecordedProgress && initial.pageNum == 0 && initial.lastModifiedUtc == nil)
        #expect(initial.chapter.libraryID == 1 && initial.chapter.volumeID == 23)
        try await source.updateProgress(reference, pageNum: 0, bookScrollID: "//body/p[1]")
        #expect(try await !source.progress(reference).hasRecordedProgress)
        try await source.updateProgress(reference, pageNum: 1, bookScrollID: "//body/div[1]/p[3]")
        let saved = try await source.progress(reference)
        #expect(saved.hasRecordedProgress && saved.pageNum == 1 && saved.bookScrollID == "//body/div[1]/p[3]")
        #expect(saved.lastModifiedUtc == "2026-01-01T00:00:00Z" && !saved.isCompleted)
        let write = try #require(server.requests("Reader/progress").last?["body"] as? [String: Any])
        #expect(write["libraryId"] as? Int == 1 && write["seriesId"] as? Int == 12)
        #expect(write["volumeId"] as? Int == 23 && write["chapterId"] as? Int == 34)
        try await source.updateProgress(reference, pageNum: 3)
        #expect(try await source.progress(reference).isCompleted)
        try await source.updateProgress(reference, pageNum: 0)
        #expect(try await source.progress(reference).pageNum == 0)
        let writes = try server.requests("Reader/progress").count
        await #expect(throws: ContentServerError.invalidReference) { try await source.updateProgress(reference, pageNum: -1) }
        await #expect(throws: ContentServerError.invalidReference) { try await source.updateProgress(reference, pageNum: 4) }
        await #expect(throws: ContentServerError.invalidReference) { try await source.updateProgress(reference, pageNum: Int.max) }
        await #expect(throws: ContentServerError.invalidReference) {
            try await source.updateProgress(reference, pageNum: 1, bookScrollID: "epubcfi(/6/2)")
        }
        let pdf = try await source.chapterReference(chapterID: 37)
        await #expect(throws: ContentServerError.invalidReference) {
            try await source.updateProgress(pdf, pageNum: 1, bookScrollID: "//body/p[1]")
        }
        #expect(try server.requests("Reader/progress").count == writes)
        try server.configure(["badProgress": true])
        await #expect(throws: ContentServerError.invalidResponse) { try await source.progress(reference) }
        try server.configure(["overflowProgress": true])
        await #expect(throws: ContentServerError.invalidResponse) { try await source.progress(reference) }
        await source.disconnect()
    }

    @Test(arguments: ["chapter", "volume", "series", "membership"])
    func changedRelationshipsCannotWriteOrDownload(_ relation: String) async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let reference = try await source.chapterReference(chapterID: 34)
        try server.configure(["relation": relation])
        await #expect(throws: ContentServerError.self) { try await source.updateProgress(reference, pageNum: 1) }
        await #expect(throws: ContentServerError.self) { try await source.prepareDownload(reference) }
        #expect(try server.requests("Reader/progress").isEmpty)
        #expect(try server.requests("Download/chapter").isEmpty)
        await source.disconnect()
    }

    @Test(arguments: [34, 35, 36, 37])
    func originalAndZIPDownloadsReuseTransfer(_ chapterID: Int) async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let reference = try await source.chapterReference(chapterID: chapterID)
        let chapter = try await source.chapter(chapterID: chapterID)
        let file = try await source.prepareDownload(reference)
        let entry = try await kavitaEntry(source, file)
        let expectedName = [34: "raw.epub", 35: "archive.zip", 36: "image.zip", 37: "raw.pdf"][chapterID]!
        let expected = try Data(contentsOf: server.file(expectedName))
        if chapterID == 35 || chapterID == 36 {
            #expect(chapter.downloadKind == .archiveOfFiles && entry.size == nil && entry.name.hasSuffix(".zip"))
            #expect(expected.count != chapter.files.compactMap(\.bytes).reduce(0, +))
        } else {
            #expect(chapter.downloadKind == .originalFile && entry.size == Int64(expected.count))
        }
        #expect(entry.etag == nil && entry.modifiedAt == nil)
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: try await source.sourceBinding(), cacheDirectory: server.file("cache"))
        let coordinator = RemoteTransferCoordinator(materializer: materializer)
        let id = await coordinator.submit(.init(reference: file))
        let lease = try await coordinator.wait(for: id)
        #expect(try Data(contentsOf: lease.url) == expected)
        #expect(lease.version == nil)
        await lease.release(); await coordinator.shutdown(); await materializer.shutdown()
        #expect(try server.requests("Download/chapter").count == 1)
        #expect(try server.requests("Reader/progress").isEmpty)
        await source.disconnect()
    }

    @Test func forgedAndStaleDownloadDescriptorsAndRegistryLimit() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(references: 1); try await source.connect(.apiToken("fixture-key"))
        let reference = try await source.chapterReference(chapterID: 34)
        let file = try await source.prepareDownload(reference)
        let entry = try await kavitaEntry(source, file)
        let forged = RemoteEntry(id: entry.id, path: entry.path, name: "forged.epub", type: .file, size: entry.size)
        await #expect(throws: ContentServerError.invalidReference) {
            try await source.download(forged, to: server.file("forged"))
        }
        await #expect(throws: ContentServerError.resourceLimit) { try await source.prepareDownload(reference) }
        await #expect(throws: RemoteSyncError.self) {
            try await source.download(entry, to: server.file("conditional"), options: .init(expectedETag: "fake"))
        }
        try await source.connect(.apiToken("fixture-key"))
        await #expect(throws: ContentServerError.invalidReference) { try await source.download(entry, to: server.file("stale")) }
        await #expect(throws: ContentServerError.invalidReference) { try await source.progress(reference) }
        await #expect(throws: ContentServerError.invalidReference) { try await kavitaEntry(source, file) }
        #expect(try server.requests("Download/chapter").isEmpty)
        await source.disconnect()
    }

    @Test(arguments: [400, 401, 403, 404, 500])
    func progressErrorsAreNotReplayedOrLeaked(_ status: Int) async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let reference = try await source.chapterReference(chapterID: 34)
        try server.configure(["statusPath": "Reader/progress", "status": status])
        do {
            try await source.updateProgress(reference, pageNum: 1)
            Issue.record("Expected HTTP failure")
        } catch {
            #expect(!String(describing: error).contains("fictional-sensitive-error"))
            switch status {
            case 400: #expect(error as? ContentServerError == .invalidResponse)
            case 401: if case .authenticationFailed = error as? RemoteSyncError {} else { Issue.record("Expected authenticationFailed") }
            case 403: if case .permissionDenied = error as? RemoteSyncError {} else { Issue.record("Expected permissionDenied") }
            case 404: if case .notFound = error as? RemoteSyncError {} else { Issue.record("Expected notFound") }
            default: if case .network = error as? RemoteSyncError {} else { Issue.record("Expected network error") }
            }
        }
        #expect(try server.requests("Reader/progress").count == 1)
        #expect(try server.requests("Account/refresh-token").isEmpty)
        await source.disconnect()
    }

    @Test func missingDownloadRoleSurfaces403() async throws {
        let server = try KavitaFixture(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.apiToken("fixture-key"))
        let reference = try await source.chapterReference(chapterID: 34)
        let file = try await source.prepareDownload(reference)
        let entry = try await kavitaEntry(source, file)
        try server.configure(["statusPath": "Download/chapter", "status": 403])
        await #expect(throws: RemoteSyncError.permissionDenied(path: "Content resource")) {
            try await source.download(entry, to: server.file("denied"))
        }
        #expect(!FileManager.default.fileExists(atPath: server.file("denied").path))
        await source.disconnect()
    }
}
#endif
