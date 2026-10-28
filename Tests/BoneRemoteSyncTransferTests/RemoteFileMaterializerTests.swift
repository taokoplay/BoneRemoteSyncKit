import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal
import BoneRemoteSyncTransfer

@Suite struct RemoteFileMaterializerTests {
    @Test func materializesAndReleasesLeaseOwnedFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let remoteRoot = workspace.appendingPathComponent("remote", isDirectory: true)
        let cacheRoot = workspace.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: remoteRoot.appendingPathComponent("file.txt"))

        let source = LocalFileSource(root: remoteRoot)
        try await source.connect(.anonymous)
        let materializer = RemoteFileMaterializer(
            source: source,
            sourceBinding: RemoteSourceBinding(kind: .local, identity: "test-root"),
            cacheDirectory: cacheRoot
        )
        let reference = RemoteFileReference(
            source: RemoteSourceBinding(kind: .local, identity: "test-root"),
            path: "/file.txt"
        )

        let lease = try await materializer.materialize(reference)
        #expect(try Data(contentsOf: lease.url) == Data("payload".utf8))
        let materializedURL = lease.url
        await lease.release()
        #expect(!FileManager.default.fileExists(atPath: materializedURL.path))
        await source.disconnect()
    }

    @Test func matchingPersistentMaterializationsShareTheCompletedFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let remoteRoot = workspace.appendingPathComponent("remote", isDirectory: true)
        let cacheRoot = workspace.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try Data("stable".utf8).write(to: remoteRoot.appendingPathComponent("file.txt"))

        let source = LocalFileSource(root: remoteRoot)
        try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .local, identity: "test-root")
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: cacheRoot)
        let reference = RemoteFileReference(source: binding, path: "/file.txt")
        let options = RemoteMaterializationOptions(retention: .persistent)

        let first = try await materializer.materialize(reference, options: options)
        let second = try await materializer.materialize(reference, options: options)
        #expect(first.url == second.url)
        #expect(try Data(contentsOf: second.url) == Data("stable".utf8))
        await first.release()
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        await second.release()
        await materializer.clearPersistentCache()
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
        await source.disconnect()
    }

    @Test func requiredVersionRejectsUnsupportedWeakGuarantee() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let remoteRoot = workspace.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try Data("versioned".utf8).write(to: remoteRoot.appendingPathComponent("file.txt"))

        let source = LocalFileSource(root: remoteRoot)
        try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .local, identity: "versioned-root")
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding,
                                                  cacheDirectory: workspace.appendingPathComponent("cache"))
        let reference = RemoteFileReference(source: binding, path: "/file.txt")
        let entry = try await source.stat(path: "/file.txt")
        let required = RemoteVersion(source: binding, locator: .path("/file.txt"), value: entry.etag! + "-changed", strength: .metadataFingerprint)

        await #expect(throws: RemoteSyncError.unsupported(operation: "所请求的版本无法保证条件读取")) {
            try await materializer.materialize(reference, options: .init(consistency: .requireVersion(required)))
        }
        await source.disconnect()
    }

    @Test func sourceBindingMismatchIsRejectedBeforeReadingSource() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let remoteRoot = workspace.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        let source = LocalFileSource(root: remoteRoot)
        try await source.connect(.anonymous)
        let materializer = RemoteFileMaterializer(
            source: source,
            sourceBinding: RemoteSourceBinding(kind: .local, identity: "one"),
            cacheDirectory: workspace.appendingPathComponent("cache")
        )
        let reference = RemoteFileReference(
            source: RemoteSourceBinding(kind: .local, identity: "two"),
            path: "/missing.txt"
        )

        await #expect(throws: RemoteSyncError.conflict(path: "/missing.txt")) {
            try await materializer.materialize(reference)
        }
        await source.disconnect()
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BoneTransfer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
