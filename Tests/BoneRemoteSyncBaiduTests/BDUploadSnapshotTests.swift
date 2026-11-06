import Foundation
import Darwin
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncBaidu

@Suite struct BDUploadSnapshotTests {
    @Test func snapshotSurvivesSourceReplacementAndRemoval() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data("abc".utf8).write(to: source)
        let snapshot = try BDUploadSnapshot(source: source, maximumBytes: 3)
        #expect(snapshot.size == 3)
        #expect(snapshot.blockMD5s == ["900150983cd24fb0d6963f7d28e17f72"])
        try Data("replacement".utf8).write(to: source, options: .atomic)
        #expect(try snapshot.chunk(part: 0) == Data("abc".utf8))
        try FileManager.default.removeItem(at: source)
        #expect(try snapshot.chunk(part: 0) == Data("abc".utf8))
        #expect(throws: BaiduDriveError.invalidResponse) { try snapshot.chunk(part: -1) }
        #expect(throws: BaiduDriveError.invalidResponse) { try snapshot.chunk(part: 1) }
    }

    @Test func readsBoundedBlocksInAnyOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let first = Data(repeating: 0x61, count: BDUploadSnapshot.blockSize)
        let last = Data("final block".utf8)
        #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
        let writer = try FileHandle(forWritingTo: source)
        try writer.write(contentsOf: first)
        try writer.write(contentsOf: last)
        try writer.close()
        let snapshot = try BDUploadSnapshot(source: source, maximumBytes: Int64(first.count + last.count))
        #expect(snapshot.blockMD5s.count == 2)
        #expect(try snapshot.chunk(part: 1) == last)
        #expect(try snapshot.chunk(part: 0) == first)
        #expect(try snapshot.chunk(part: 1) == last)
        #expect(snapshot.blockMD5s.allSatisfy { $0.count == 32 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } })
    }

    @Test func rejectsEmptyOversizedAndNonRegularSources() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data().write(to: source)
        #expect(throws: RemoteSyncError.self) { try BDUploadSnapshot(source: source, maximumBytes: 10) }
        try Data("abcd".utf8).write(to: source)
        #expect(throws: RemoteSyncError.self) { try BDUploadSnapshot(source: source, maximumBytes: 3) }
        #expect(throws: RemoteSyncError.self) { try BDUploadSnapshot(source: directory, maximumBytes: 10) }
        let symlink = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        #expect(throws: RemoteSyncError.sourceSnapshotMissing) { try BDUploadSnapshot(source: symlink, maximumBytes: 10) }
        let hardlink = directory.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: source, to: hardlink)
        #expect(throws: RemoteSyncError.sourceSnapshotMissing) { try BDUploadSnapshot(source: source, maximumBytes: 10) }
        let fifo = directory.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
        #expect(throws: RemoteSyncError.sourceSnapshotMissing) { try BDUploadSnapshot(source: fifo, maximumBytes: 10) }
    }

    @Test func cancelledCreationRejectsBeforeCopying() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data("abc".utf8).write(to: source)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BDUploadSnapshot.create(from: source, maximumBytes: 3)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled upload snapshot was created")
        } catch {
            #expect(error as? RemoteSyncError == .cancelled)
        }
        #expect(try Data(contentsOf: source) == Data("abc".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BDUploadSnapshotTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
