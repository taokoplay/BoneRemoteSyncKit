import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

/// 每个用例均使用真实、独立的临时文件系统，不访问用户文件。
@Suite struct LocalFileSourceWriteTests {
    @Test func advertisedWritesCanBeCalledThroughThePublicProtocol() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        #expect(writer.capabilities.upload)
        #expect(writer.capabilities.makeDirectory)
        #expect(writer.capabilities.remove)
        #expect(writer.capabilities.move)
        // 当前上传接口没有续传偏移或会话信息，不能宣称支持上传续传。
        #expect(!writer.capabilities.resumableUpload)
        try await writer.makeDirectory(path: "/documents")
        let entry = try await writer.stat(path: "/documents")
        #expect(entry.isDirectory)
    }

    @Test func uploadCreatesParentsAndReturnsSourceRelativeEntry() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        let input = try fixture.input("你好，Swift")
        let entry = try await writer.upload(from: input, to: "/新建目录/file.txt", options: .init())
        #expect(try fixture.text("新建目录/file.txt") == "你好，Swift")
        #expect(entry.id == "新建目录/file.txt")
        #expect(entry.path == "/新建目录/file.txt")
        #expect(entry.name == "file.txt")
        #expect(entry.size == Int64(Data("你好，Swift".utf8).count))
        #expect(entry.etag != nil)
        #expect(try String(contentsOf: input, encoding: .utf8) == "你好，Swift")
        #expect(try fixture.names("新建目录") == ["file.txt"])
    }

    @Test func uploadReplacesExistingFileOnlyAfterCopyCompletes() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("old", at: "target.txt")
        let input = try fixture.input("replacement")
        _ = try await writer.upload(from: input, to: "/target.txt", options: .init())
        #expect(try fixture.text("target.txt") == "replacement")
        #expect(try fixture.names() == ["target.txt"])
    }

    @Test func uploadWithoutOverwritePreservesOriginal() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("old", at: "target.txt")
        let input = try fixture.input("new")
        await #expect(throws: RemoteSyncError.conflict(path: "/target.txt")) {
            try await writer.upload(from: input, to: "/target.txt", options: .init(overwrite: false))
        }
        #expect(try fixture.text("target.txt") == "old")
        #expect(try fixture.names() == ["target.txt"])
    }

    @Test func uploadDoesNotReplaceDirectory() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("keep", at: "folder/child.txt")
        let input = try fixture.input("new")
        await #expect(throws: RemoteSyncError.conflict(path: "/folder")) {
            try await writer.upload(from: input, to: "/folder", options: .init())
        }
        #expect(try fixture.text("folder/child.txt") == "keep")
    }

    @Test func missingUploadInputProducesNotFoundAndNoTarget() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        let missing = fixture.workspace.appendingPathComponent("missing.txt")
        await #expect(throws: RemoteSyncError.notFound(path: missing.path)) {
            try await writer.upload(from: missing, to: "/target.txt", options: .init())
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test func uploadRejectsDirectoryInput() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        await #expect(throws: RemoteSyncError.unsupported(operation: "上传非普通文件")) {
            try await writer.upload(from: fixture.root, to: "/target", options: .init())
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test func uploadReportsActualByteProgressIncludingEmptyFile() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        let progress = ByteRecorder()
        let input = fixture.workspace.appendingPathComponent("large.bin")
        try Data(repeating: 0x6b, count: 2_100_123).write(to: input)
        _ = try await writer.upload(from: input, to: "/large.bin", options: .init(progress: { progress.record($0) }))
        let values = progress.snapshot()
        #expect(values.last == 2_100_123)
        #expect(values == values.sorted())
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("large.bin")) == Data(contentsOf: input))
        let empty = try fixture.input("")
        let emptyProgress = ByteRecorder()
        _ = try await writer.upload(from: empty, to: "/empty.txt", options: .init(progress: { emptyProgress.record($0) }))
        #expect(emptyProgress.snapshot().last == 0)
        #expect(try fixture.text("empty.txt").isEmpty)
    }

    @Test func cancelledUploadPreservesOriginalAndCleansStaging() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("old", at: "target.txt")
        let input = fixture.workspace.appendingPathComponent("large.bin")
        try Data(repeating: 0x62, count: 3_000_000).write(to: input)
        let task = Task {
            try await writer.upload(from: input, to: "/target.txt", options: .init(progress: { bytes in
                if bytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }))
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try fixture.text("target.txt") == "old")
        #expect(try fixture.names() == ["target.txt"])
    }

    @Test func makeDirectoryIsRecursiveAndIdempotent() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try await writer.makeDirectory(path: "/a/b")
        try await writer.makeDirectory(path: "/a/b")
        try await writer.makeDirectory(path: "/")
        let entry = try await writer.stat(path: "/a/b")
        #expect(entry.isDirectory)
    }

    @Test func makeDirectoryDoesNotReplaceFile() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("keep", at: "file")
        await #expect(throws: RemoteSyncError.conflict(path: "/file")) {
            try await writer.makeDirectory(path: "/file")
        }
        #expect(try fixture.text("file") == "keep")
    }

    @Test func removeDeletesFileAndNonemptyDirectory() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("a", at: "file.txt")
        try fixture.write("b", at: "tree/sub/child.txt")
        try await writer.remove(path: "/file.txt")
        try await writer.remove(path: "/tree")
        #expect(try fixture.names().isEmpty)
    }

    @Test func removeMissingPathProducesNormalizedError() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        await #expect(throws: RemoteSyncError.notFound(path: "/missing")) {
            try await writer.remove(path: "/missing")
        }
    }

    @Test(arguments: ["/", "/a/../", "/../../"])
    func removeCannotDeleteSourceRoot(path: String) async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("keep", at: "file.txt")
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/")) {
            try await writer.remove(path: path)
        }
        #expect(try fixture.text("file.txt") == "keep")
    }

    @Test func moveRenamesFileAndDirectory() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("a", at: "a.txt")
        try fixture.write("b", at: "tree/child.txt")
        try await writer.move(from: "/a.txt", to: "/renamed.txt")
        try await writer.move(from: "/tree", to: "/renamed-tree")
        #expect(try fixture.text("renamed.txt") == "a")
        #expect(try fixture.text("renamed-tree/child.txt") == "b")
        #expect(try fixture.names() == ["renamed-tree", "renamed.txt"])
    }

    @Test func moveNeverClobbersExistingTarget() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("source", at: "a.txt")
        try fixture.write("target", at: "b.txt")
        await #expect(throws: RemoteSyncError.conflict(path: "/b.txt")) {
            try await writer.move(from: "/a.txt", to: "/b.txt")
        }
        #expect(try fixture.text("a.txt") == "source")
        #expect(try fixture.text("b.txt") == "target")
    }

    @Test func moveMissingSourceProducesNormalizedError() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        await #expect(throws: RemoteSyncError.notFound(path: "/missing")) {
            try await writer.move(from: "/missing", to: "/target")
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test func moveRejectsOwnDescendantAndSamePath() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        try fixture.write("keep", at: "tree/child.txt")
        await #expect(throws: RemoteSyncError.conflict(path: "/tree/sub")) {
            try await writer.move(from: "/tree", to: "/tree/sub")
        }
        await #expect(throws: RemoteSyncError.conflict(path: "/tree")) {
            try await writer.move(from: "/tree", to: "/tree")
        }
        #expect(try fixture.text("tree/child.txt") == "keep")
    }

    @Test func writeOperationsRequireConnection() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let writer: any RemoteWritableSource = fixture.source
        let input = try fixture.input("new")
        await writer.disconnect()
        await #expect(throws: RemoteSyncError.notConnected) {
            try await writer.upload(from: input, to: "/target.txt", options: .init())
        }
        await #expect(throws: RemoteSyncError.notConnected) { try await writer.makeDirectory(path: "/folder") }
        await #expect(throws: RemoteSyncError.notConnected) { try await writer.remove(path: "/file") }
        await #expect(throws: RemoteSyncError.notConnected) { try await writer.move(from: "/a", to: "/b") }
        #expect(try fixture.names().isEmpty)
    }
}

struct WriteFixture: Sendable {
    let workspace: URL
    let root: URL
    let source: LocalFileSource

    init() async throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneLocalWrites-\(UUID())")
        root = workspace.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = LocalFileSource(root: root)
        do { try await source.connect(.anonymous) }
        catch { try? FileManager.default.removeItem(at: workspace); throw error }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: workspace) }

    func input(_ value: String) throws -> URL {
        let url = workspace.appendingPathComponent("input-\(UUID()).txt")
        try Data(value.utf8).write(to: url)
        return url
    }

    func write(_ value: String, at path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func names(_ path: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(path).path).sorted()
    }
}

final class ByteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func record(_ value: Int64) { lock.withLock { values.append(value) } }
    func snapshot() -> [Int64] { lock.withLock { values } }
}
