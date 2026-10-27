import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncICloud

@Suite struct ICloudDriveSafetyTests {
    @Test func sourceRejectsEscapingSymlink() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        let outside = f.workspace.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("escape"), withDestinationURL: outside)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/escape/file")) {
            try await f.source.stat(path: "/escape/file")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/escape/new")) {
            try await f.source.makeDirectory(path: "/escape/new")
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
    }

    @Test func rootAliasCannotBeRemovedOrMoved() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("alias"), withDestinationURL: f.root)
        await #expect(throws: RemoteSyncError.self) { try await f.source.remove(path: "/alias") }
        await #expect(throws: RemoteSyncError.self) { try await f.source.move(from: "/alias", to: "/moved") }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("file")) == Data("source".utf8))
    }

    @Test func movingOrCopyingSymlinkIsRejected() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("alias"), withDestinationURL: f.root.appendingPathComponent("file"))
        await #expect(throws: RemoteSyncError.self) { try await f.source.move(from: "/alias", to: "/moved") }
        try? FileManager.default.removeItem(at: f.root.appendingPathComponent("alias"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("alias"), withDestinationURL: f.root.appendingPathComponent("file"))
        await #expect(throws: RemoteSyncError.self) { try await f.source.copy(from: "/alias", to: "/copied") }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("copied").path))
    }

    @Test func uploadNeverReplacesDirectory() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let child = f.root.appendingPathComponent("folder/child")
        try Data("keep".utf8).write(to: child)
        await #expect(throws: RemoteSyncError.conflict(path: "/folder")) {
            try await f.source.upload(from: f.input, to: "/folder")
        }
        #expect(try Data(contentsOf: child) == Data("keep".utf8))
    }

    @Test func downloadNeverReplacesDirectory() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        let destination = URL(fileURLWithPath: f.workspace.path + "/folder", isDirectory: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let child = destination.appendingPathComponent("child")
        try Data("keep".utf8).write(to: child)
        await #expect(throws: RemoteSyncError.conflict(path: destination.path)) {
            try await f.source.download(path: "/file", to: destination)
        }
        #expect(try Data(contentsOf: child) == Data("keep".utf8))
    }

    @Test func downloadRejectsSymlinkPartBeforeTruncation() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        let destination = f.workspace.appendingPathComponent("output")
        let part = destination.appendingPathExtension("part")
        try FileManager.default.createSymbolicLink(at: part, withDestinationURL: f.input)
        await #expect(throws: RemoteSyncError.conflict(path: part.path)) {
            try await f.source.download(path: "/file", to: destination)
        }
        #expect(try Data(contentsOf: f.input) == Data("input".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func downloadRejectsSourceAsDestination() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        let original = f.root.appendingPathComponent("file")
        await #expect(throws: RemoteSyncError.conflict(path: original.path)) {
            try await f.source.download(path: "/file", to: original)
        }
        #expect(try Data(contentsOf: original) == Data("source".utf8))
    }

    @Test func cancelledUploadPreservesTargetAndCleansStaging() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        let slot = ICloudCancellationSlot()
        let task = Task {
            try await f.source.upload(from: f.input, to: "/file", options: .init(progress: { _ in slot.cancel() }))
        }
        slot.set(task)
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("file")) == Data("source".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == ["file"])
    }

    @Test func cancelledDownloadPreservesTarget() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        let destination = f.workspace.appendingPathComponent("output")
        try Data("keep".utf8).write(to: destination)
        let slot = ICloudCancellationSlot()
        let task = Task {
            try await f.source.download(path: "/file", to: destination, options: .init(progress: { _ in slot.cancel() }))
        }
        slot.set(task)
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try Data(contentsOf: destination) == Data("keep".utf8))
    }

    @Test func invalidDecodedConfigurationIsRejected() throws {
        let data = Data(#"{"directoryPath":"/../outside","downloadTimeout":0,"pollInterval":-1}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ICloudDriveConfiguration.self, from: data) }
    }

    @Test func injectedContainerUsesConfiguredSubdirectory() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let source = ICloudDriveSource(configuration: try .init(directoryPath: "/Documents"), rootURL: f.root)
        try await source.connect(.anonymous)
        let page = try await source.list(path: "/")
        #expect(page.entries.isEmpty)
        let status = await source.status()
        #expect(status.rootURL?.standardizedFileURL.path == f.root.appendingPathComponent("Documents").path)
    }

    @Test func listingRejectsUnrepresentableNameInsteadOfAliasingPath() async throws {
        let f = try await ICloudSafetyFixture(); defer { f.cleanUp() }
        try Data().write(to: f.root.appendingPathComponent("a\\b"))
        await #expect(throws: RemoteSyncError.self) { try await f.source.list(path: "/") }
    }
}

private struct ICloudSafetyFixture: Sendable {
    let workspace: URL
    let root: URL
    let input: URL
    let source: ICloudDriveSource
    init() async throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudSafety-\(UUID())")
        root = workspace.appendingPathComponent("container")
        input = workspace.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: root.appendingPathComponent("file"))
        try Data("input".utf8).write(to: input)
        source = ICloudDriveSource(configuration: try .init(directoryPath: "/"), rootURL: root)
        try await source.connect(.anonymous)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: workspace) }
}

private final class ICloudCancellationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<RemoteEntry, Error>?
    private var requested = false
    func set(_ task: Task<RemoteEntry, Error>) {
        lock.withLock { self.task = task; if requested { task.cancel() } }
    }
    func cancel() {
        lock.withLock { requested = true; task?.cancel() }
    }
}
