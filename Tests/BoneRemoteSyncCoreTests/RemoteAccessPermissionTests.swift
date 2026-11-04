import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

@Suite struct RemoteAccessPermissionTests {
    @Test func multiSelectionSupportsInsertionAndRemoval() {
        var permission: RemoteAccessPermission = [.readOnly, .create]
        permission.insert(.edit)
        permission.remove(.create)
        #expect(permission == [.readOnly, .edit])
        #expect(RemoteAccessPermission.allCases == [.readOnly, .edit, .create, .delete])
        #expect(!RemoteAccessPermission.allCases.contains(.all))
    }

    @Test(arguments: Array(UInt(0)..<16))
    func everyCombinationRoundTrips(rawValue: UInt) throws {
        let permission = RemoteAccessPermission(rawValue: rawValue)
        let data = try JSONEncoder().encode(permission)
        #expect(try JSONDecoder().decode(RemoteAccessPermission.self, from: data) == permission)
        let names = try JSONDecoder().decode([String].self, from: data)
        #expect(names.count == rawValue.nonzeroBitCount)
    }

    @Test func encodingUsesStableNamesAndDeduplicatesOptions() throws {
        let permission: RemoteAccessPermission = [.readOnly, .edit, .delete]
        #expect(String(decoding: try JSONEncoder().encode(permission), as: UTF8.self) == #"["readOnly","edit","delete"]"#)
        #expect(try JSONDecoder().decode(RemoteAccessPermission.self, from: Data(#"["create","create"]"#.utf8)) == .create)
    }

    @Test(arguments: [#""readOnly""#, #""editor""#, #""edit""#, #""admin""#,
        #"["readOnly","admin"]"#, #"["editor"]"#, "15", "null", "{}"])
    func invalidPermissionsAreRejected(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteAccessPermission.self, from: Data(json.utf8))
        }
    }

    @Test func unknownBitsCannotBeSilentlySaved() {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(RemoteAccessPermission(rawValue: 1 << 8))
        }
    }
}

@Suite struct RemoteAccessControlledSourceTests {
    private let localURL = URL(fileURLWithPath: "/unused-upload")

    @Test(arguments: Array(UInt(0)..<16))
    func readIsRequiredAndWritePermissionsAreIndependent(rawValue: UInt) async throws {
        let permission = RemoteAccessPermission(rawValue: rawValue)
        let probe = AccessProbe()
        let source = RemoteAccessControlledSource(source: probe, permission: permission)
        #expect(source.permission == permission.union(.readOnly))
        let entry = RemoteEntry(id: "existing", path: "/existing", name: "existing", type: .file)
        _ = try await source.list(path: "/existing")
        _ = try await source.stat(path: "/existing")
        _ = try await source.download(entry, to: localURL, options: .init())
        try await expectAccess(permission.contains(.create), path: "/new") { try await source.makeDirectory(path: "/new") }
        try await expectAccess(permission.contains(.delete), path: "/existing") { try await source.remove(path: "/existing") }
        try await expectAccess(permission.contains(.edit), path: "/existing") { try await source.move(from: "/existing", to: "/moved") }
        try await expectAccess(permission.contains(.create), path: "/copy") {
            try await source.copy(from: "/existing", to: "/copy")
        }
        var expected = ["list", "stat", "download"]
        if permission.contains(.create) { expected.append("makeDirectory") }
        if permission.contains(.delete) { expected.append("remove") }
        if permission.contains(.edit) { expected.append("move") }
        if permission.contains(.create) { expected.append("copy") }
        #expect(await probe.operations == expected)
    }

    @Test(arguments: Array(UInt(0)..<16))
    func capabilitiesMatchGrantedPermissions(rawValue: UInt) {
        let permission = RemoteAccessPermission(rawValue: rawValue)
        let value = RemoteAccessControlledSource(source: AccessProbe(), permission: permission).capabilities
        #expect(value.list && value.stat && value.download)
        #expect(value.rangedDownload && value.idAddressing && value.changeFeed && value.contentHash)
        #expect(value.upload == !permission.intersection([.edit, .create]).isEmpty)
        #expect(value.resumableUpload == value.upload)
        #expect(value.conditionalUpload == permission.contains(.edit))
        #expect(value.makeDirectory == permission.contains(.create))
        #expect(value.remove == permission.contains(.delete))
        #expect(value.move == permission.contains(.edit))
        #expect(value.copy == permission.contains(.create))
        #expect(value.maxConcurrentTransfers == 7)
        let limited = RemoteCapabilities(list: false, stat: false, download: false)
        #expect(RemoteAccessControlledSource(source: AccessProbe(capabilities: limited), permission: permission).capabilities == limited)
    }

    @Test func defaultSessionIsReadOnlyAndRemovedReadIsRestored() async throws {
        let source = RemoteAccessControlledSource(source: AccessProbe())
        #expect(source.permission == .readOnly)
        #expect(source.capabilities.list && source.capabilities.stat && source.capabilities.download)
        #expect(!source.capabilities.upload && !source.capabilities.makeDirectory && !source.capabilities.remove)
        #expect(!source.capabilities.move && !source.capabilities.copy)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/new")) {
            try await source.upload(from: localURL, to: "/new", options: .init())
        }
        var selection: RemoteAccessPermission = [.readOnly, .delete]
        selection.remove(.readOnly)
        let restored = RemoteAccessControlledSource(source: AccessProbe(), permission: selection)
        #expect(restored.permission == [.readOnly, .delete])
        #expect(restored.capabilities.remove && !restored.capabilities.upload)
    }

    @Test(arguments: Array(UInt(0)..<16), [false, true])
    func uploadDistinguishesNewAndExistingFiles(rawValue: UInt, existing: Bool) async throws {
        let permission = RemoteAccessPermission(rawValue: rawValue)
        let probe = AccessProbe()
        let source = RemoteAccessControlledSource(source: probe, permission: permission)
        let path = existing ? "/existing" : "/new"
        let allowed = permission.contains(existing ? .edit : .create)
        try await expectAccess(allowed, path: path) {
            _ = try await source.upload(from: localURL, to: path, options: .init(contentType: "text/plain"))
        }
        let options = await probe.lastUpload
        #expect((options != nil) == allowed)
        if allowed {
            #expect(options?.contentType == "text/plain")
            if !existing && !permission.contains(.edit) { #expect(options?.overwrite == false) }
            if existing && !permission.contains(.create) { #expect(options?.expectedETag == "version-1") }
        }
    }

    @Test func conditionalUploadPreservesCallerVersionAndRequiresEdit() async throws {
        let probe = AccessProbe()
        let editor = RemoteAccessControlledSource(source: probe, permission: .edit)
        _ = try await editor.upload(from: localURL, to: "/existing", options: .init(expectedETag: "caller-version"))
        #expect(await probe.lastUpload?.expectedETag == "caller-version")
        #expect(await probe.operations == ["upload"])
        let creator = RemoteAccessControlledSource(source: probe, permission: .create)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/existing")) {
            try await creator.upload(from: localURL, to: "/existing", options: .init(expectedETag: "caller-version"))
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/new")) {
            try await editor.upload(from: localURL, to: "/new", options: .init(overwrite: false))
        }
        #expect(await probe.operations == ["upload"])
    }

    @Test(arguments: [RemoteSyncError.permissionDenied(path: "/new"), .network("offline"), .authenticationFailed(reason: nil)])
    func failedMetadataChecksNeverGrantCreation(error: RemoteSyncError) async throws {
        let probe = AccessProbe(statError: error)
        let source = RemoteAccessControlledSource(source: probe, permission: .create)
        await #expect(throws: error) { try await source.upload(from: localURL, to: "/new", options: .init()) }
        #expect(await probe.lastUpload == nil)
    }

    @Test func realLocalUploadsEnforceCreateAndEditSeparately() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccessTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input")
        let target = directory.appendingPathComponent("target")
        try Data("new".utf8).write(to: input)
        try Data("old".utf8).write(to: target)
        let adapter = LocalFileSource(root: directory)
        try await adapter.connect(.anonymous)
        let creator = RemoteAccessControlledSource(source: adapter, permission: .create)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/target")) {
            try await creator.upload(from: input, to: "/target", options: .init())
        }
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        _ = try await creator.upload(from: input, to: "/created", options: .init())
        #expect(try Data(contentsOf: directory.appendingPathComponent("created")) == Data("new".utf8))
        let editor = RemoteAccessControlledSource(source: adapter, permission: .edit)
        _ = try await editor.upload(from: input, to: "/target", options: .init())
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/missing")) {
            try await editor.upload(from: input, to: "/missing", options: .init())
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing").path))
        await adapter.disconnect()
    }

    private func expectAccess(_ allowed: Bool, path: String, operation: () async throws -> Void) async throws {
        if allowed { try await operation() }
        else { await #expect(throws: RemoteSyncError.permissionDenied(path: path)) { try await operation() } }
    }
}

private actor AccessProbe: RemoteCopyingSource {
    nonisolated let kind = RemoteSourceKind.local
    nonisolated let capabilities: RemoteCapabilities
    private let statError: RemoteSyncError?
    private(set) var operations: [String] = []
    private(set) var lastUpload: RemoteUploadOptions?

    init(capabilities: RemoteCapabilities = .init(idAddressing: true, rangedDownload: true, upload: true,
        conditionalUpload: true, resumableUpload: true, makeDirectory: true, remove: true, move: true,
        copy: true, changeFeed: true, contentHash: true, maxConcurrentTransfers: 7), statError: RemoteSyncError? = nil) {
        self.capabilities = capabilities
        self.statError = statError
    }

    func connect(_ credential: RemoteCredential) async throws {}
    func disconnect() async {}
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        operations.append("list")
        return RemoteListPage(coverage: .complete, entries: [])
    }
    func stat(path: String) async throws -> RemoteEntry {
        operations.append("stat")
        if let statError { throw statError }
        guard path == "/existing" else { throw RemoteSyncError.notFound(path: path) }
        return RemoteEntry(id: "existing", path: path, name: "existing", type: .file, etag: "version-1")
    }
    func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        operations.append("download")
        return entry
    }
    func upload(from localURL: URL, to path: String, options: RemoteUploadOptions) async throws -> RemoteEntry {
        operations.append("upload")
        lastUpload = options
        return RemoteEntry(id: path, path: path, name: RemotePath.name(of: path), type: .file)
    }
    func makeDirectory(path: String) async throws { operations.append("makeDirectory") }
    func remove(path: String) async throws { operations.append("remove") }
    func move(from sourcePath: String, to destinationPath: String) async throws { operations.append("move") }
    func copy(from sourcePath: String, to destinationPath: String) async throws { operations.append("copy") }
}
