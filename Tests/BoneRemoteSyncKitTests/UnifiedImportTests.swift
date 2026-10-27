import Foundation
import Testing
import BoneRemoteSyncKit

/// Deliberately imports only the umbrella SDK, without @testable or individual source modules.
@Suite struct UnifiedImportTests {
    @Test func exposesAllImplementedSourcesAndCoreContracts() throws {
        let local = LocalFileSource(root: FileManager.default.temporaryDirectory)
        let webDAV = try WebDAVSource(
            baseURL: URL(string: "https://dav.example.com/files/")!,
            retryPolicy: .standard
        )
        let configuration = try OneDriveConfiguration(
            clientID: "test-client", redirectURI: URL(string: "example-app://oauth/onedrive")!
        )
        let oneDrive = OneDriveSource(configuration: configuration)
        let sources: [any RemoteSource] = [local, webDAV, oneDrive]
        #expect(sources.map(\.kind) == [.local, .webdav, .cloudAPI])
        let copyingSources: [any RemoteCopyingSource] = [local, webDAV]
        #expect(copyingSources.allSatisfy { $0.capabilities.copy })
        let writable: any RemoteWritableSource = oneDrive
        #expect(writable.capabilities.upload)
        #expect(RemotePath.normalize("folder/../file") == "/file")
        #expect(RemoteUploadOptions(overwrite: false).overwrite == false)
        #expect(RemoteDownloadOptions().verifySize)
        let metadata = RemoteEntry(id: "photo", path: "/photo", name: "photo.HEIC", type: .file,
                                   createdAt: Date(timeIntervalSince1970: 123))
        let category: RemoteFileCategory = metadata.fileCategory
        #expect(category == .image)
        #expect(metadata.createdAt == Date(timeIntervalSince1970: 123))
        #expect(WebDAVResumableDownloadOptions(sourceNamespace: "test-account").sourceNamespace == "test-account")
        let profile = try RemoteSourceProfile(displayName: "Local", configuration: .local(accessReference: "host-bookmark"))
        #expect(profile.sourceNamespace == profile.bindingID.uuidString)
        let options = RemoteCatalogRefreshOptions(scope: .subtree)
        try options.validate()
        #expect(options.concurrency == 4)
        let cachedState: RemoteCatalogCacheState = .notInitialized
        #expect(cachedState.rawValue == "notInitialized")
        #expect(RemoteListPage(coverage: .unknown, entries: []).coverage == .unknown)
        let logger = RemoteLogger.disabled
        logger.record(RemoteCatalogError.unsupportedSchema, component: .sqlite, operation: .databaseOpen)
        #expect(RemoteCatalogError.database(6922).remoteLogNumericCode == 6922)
        #expect(RemoteLogCode.cancelled.level == .info)
        let oauth = OneDriveOAuth(configuration: configuration)
        let authorization: OneDriveAuthorization = try oauth.authorize()
        #expect(authorization.url.host == "login.microsoftonline.com")
    }

    @Test func localReadWriteAndProtocolExtensionsWorkThroughUnifiedImport() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneKitImport-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = workspace.appendingPathComponent("input")
        let payload = Data("Unified import 中文".utf8)
        try payload.write(to: input)
        let source: any RemoteCopyingSource = LocalFileSource(root: root)
        do {
            let credential: RemoteCredential = .anonymous
            try await source.connect(credential)
            try await source.makeDirectory(path: "/folder")
            let uploaded: RemoteEntry = try await source.upload(
                from: input, to: "/folder/file", options: RemoteUploadOptions(overwrite: false)
            )
            #expect(uploaded.size == Int64(payload.count))
            try await source.copy(from: "/folder/file", to: "/folder/copy")
            try await source.move(from: "/folder/copy", to: "/folder/moved")
            let page: RemoteListPage = try await source.list(path: "/folder")
            #expect(Set(page.entries.map(\.name)) == ["file", "moved"])
            let output = workspace.appendingPathComponent("output")
            _ = try await source.download(path: "/folder/moved", to: output, options: .init(overwrite: false))
            #expect(try Data(contentsOf: output) == payload)
            var paths = Set<String>()
            for try await entry in source.walk(path: "/folder") {
                if let path = entry.path { paths.insert(path) }
            }
            #expect(paths == ["/folder/file", "/folder/moved"])
            try await source.remove(path: "/folder")
            await #expect(throws: RemoteSyncError.notFound(path: "/folder")) {
                try await source.stat(path: "/folder")
            }
            await source.disconnect()
        } catch {
            await source.disconnect()
            throw error
        }
    }
}
