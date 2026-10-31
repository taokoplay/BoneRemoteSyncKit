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
        let iCloud = ICloudDriveSource()
        let sources: [any RemoteSource] = [local, webDAV, oneDrive, iCloud]
        #expect(sources.map(\.kind) == [.local, .webdav, .cloudAPI, .iCloud])
        let copyingSources: [any RemoteCopyingSource] = [local, webDAV, iCloud]
        #expect(copyingSources.allSatisfy { $0.capabilities.copy })
        let writable: any RemoteWritableSource = oneDrive
        #expect(!writable.capabilities.conditionalUpload)
        #expect(writable.capabilities.upload)
        #expect(RemotePath.normalize("folder/../file") == "/file")
        #expect(RemoteUploadOptions(overwrite: false).overwrite == false)
        #expect(RemoteUploadOptions(expectedETag: "\"v1\"").expectedETag == "\"v1\"")
        let checksum = try RemoteContentChecksum(algorithm: .sha256, digest: Data(repeating: 0, count: 32))
        #expect(checksum.digest.count == 32)
        let idSource: any RemoteIDAddressableSource = oneDrive
        #expect(idSource.capabilities.idAddressing)
        #expect(RemoteDownloadOptions().verifySize)
        let phase: RemoteDownloadPhase = .preparing
        let preparation: RemoteDownloadPreparationState = .inProgress
        let progress = RemoteDownloadProgress(phase: phase, preparationState: preparation)
        #expect(progress.fractionCompleted == nil)
        let status = ICloudDriveStatus(availability: .unavailable, unavailableReason: .driveUnavailable)
        #expect(status.unavailableReason == .driveUnavailable)
        let batch = ICloudDriveStatusResult(path: "/backup.zip", result: .success(status))
        #expect(batch.path == "/backup.zip")
        #expect(try batch.result.get() == status)
        #expect(ICloudDriveError.downloadTimedOut(path: "/f").remoteSyncError == .network("iCloud 文件下载超时：/f"))
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

    @Test func exposesSourceTypesAndBundledIcons() throws {
        let types = BoneRemoteSyncIcons.sourceTypes()
        #expect(types.map(\.kind) == RemoteSourceKind.allCases)
        #expect(types.first(where: { $0.kind == .webdav })?.icon == .webdav)
        #expect(types.first(where: { $0.kind == .cloudAPI })?.icon == .onedrive)
        #expect(types.first(where: { $0.kind == .iCloud })?.icon == .icloud)
        #expect(types.first(where: { $0.kind == .local })?.icon == nil)

        let drives = BoneRemoteSyncIcons.driveTypes()
        #expect(drives.count == 6)
        #expect(drives.map(\.id) == ["google-drive", "aliyun", "baidu", "onedrive", "icloud", "webdav"])
        for drive in drives {
            #expect(drive.icon.url?.pathExtension == "png")
            #expect(try drive.icon.data().count > 0)
        }
    }

    @Test func materializationAndSchedulingWorkThroughUnifiedImport() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneKitTransfer-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("kit-only".utf8).write(to: root.appendingPathComponent("file"))
        let source = LocalFileSource(root: root)
        try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .local, identity: "kit-test-session")
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding,
                                                  cacheDirectory: workspace.appendingPathComponent("cache"))
        let coordinator = RemoteTransferCoordinator(materializer: materializer)
        let id = await coordinator.submit(RemoteTransferRequest(reference: .init(source: binding, path: "/file")))
        let lease: MaterializedFileLease = try await coordinator.wait(for: id)
        let bytes = try await lease.withAccess { try Data(contentsOf: $0) }
        #expect(bytes == Data("kit-only".utf8))
        #expect(await coordinator.snapshot(id)?.phase == .completed)
        await coordinator.shutdown()
        await materializer.shutdown()
        await source.disconnect()
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
    @Test func uploadRecoveryValidatesBindingAndCapabilitiesThroughKit() async throws {
        let local = LocalFileSource(root: FileManager.default.temporaryDirectory)
        let binding = RemoteSourceBinding(kind: .local, identity: "upload-boundary")
        let target = RemoteFileReference(source: binding, path: "/file")
        let recovery = RemoteUploadRecovery(source: local, binding: binding)
        let handle = try RemoteUploadHandle(source: binding, target: target, sourceSize: 1, sourceFingerprint: "fixture")
        let options = RemoteResumableUploadOptions(snapshotDirectory: URL(fileURLWithPath: "/must-not-be-created"))
        #expect(!options.overwrite)
        await #expect(throws: RemoteSyncError.unsupported(operation: "来源未启用受管理恢复上传")) {
            try await recovery.prepare(from: URL(fileURLWithPath: "/must-not-be-read"), to: target, options: options)
        }
        await #expect(throws: RemoteSyncError.unsupported(operation: "来源未启用受管理恢复上传")) {
            try await recovery.resume(handle)
        }
        let other = RemoteUploadRecovery(source: local, binding: .init(kind: .local, identity: "different"))
        await #expect(throws: RemoteSyncError.conflict(path: "upload-binding")) { try await other.checkpoint(handle) }
        await #expect(throws: RemoteSyncError.conflict(path: "upload-binding")) { try await other.abort(handle) }
        let configuration = try OneDriveConfiguration(clientID: "fixture", redirectURI: URL(string: "fixture://oauth/callback")!)
        #expect(!OneDriveSource(configuration: configuration).capabilities.resumableUpload)
        let provider: any RemoteResumableUploadSource = try OneDriveSource(configuration: configuration,
            resumableUploadService: "BoneRemoteSyncKit.Fixture.OnlyConstructed")
        #expect(provider.capabilities.resumableUpload)
    }

}
