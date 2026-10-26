import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

@Suite struct LocalDownloadSafetyTests {
    @Test(arguments: ["direct", "parent-alias", "hardlink"])
    func sourceCannotBeAdoptedAsPart(alias: String) async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        let sourceURL = f.root.appendingPathComponent("archive.part")
        try Data("keep original".utf8).write(to: sourceURL)
        var destination = f.root.appendingPathComponent("archive")
        if alias == "parent-alias" {
            let link = f.root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
            destination = link.appendingPathComponent("archive")
        } else if alias == "hardlink" {
            destination = f.root.appendingPathComponent("other")
            try FileManager.default.linkItem(at: sourceURL, to: destination.appendingPathExtension("part"))
        }
        await #expect(throws: RemoteSyncError.self) {
            try await f.source.download(path: "/archive.part", to: destination, options: .init(overwrite: false))
        }
        #expect(try Data(contentsOf: sourceURL) == Data("keep original".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func destinationCreatedDuringNonOverwriteIsPreserved() async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        let data = Data(repeating: 65, count: 2 << 20)
        try data.write(to: f.root.appendingPathComponent("input"))
        let destination = f.root.appendingPathComponent("output")
        await #expect(throws: RemoteSyncError.conflict(path: destination.path)) {
            try await f.source.download(path: "/input", to: destination, options: .init(overwrite: false, progress: { bytes in
                if bytes == Int64(data.count) { try? Data("other writer".utf8).write(to: destination) }
            }))
        }
        #expect(try Data(contentsOf: destination) == Data("other writer".utf8))
    }

    @Test(arguments: [Int64(-1), Int64.min, 6])
    func invalidResumeDoesNotAlterFiles(offset: Int64) async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        try Data("hello".utf8).write(to: f.root.appendingPathComponent("input"))
        let destination = f.root.appendingPathComponent("output")
        let part = destination.appendingPathExtension("part")
        try Data("saved".utf8).write(to: part)
        await #expect(throws: RemoteSyncError.unsupported(operation: "本地下载续传偏移无效")) {
            try await f.source.download(path: "/input", to: destination, options: .init(resumeFrom: offset))
        }
        #expect(try Data(contentsOf: part) == Data("saved".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func mismatchedResumeKeepsExistingPart() async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        try Data("hello".utf8).write(to: f.root.appendingPathComponent("input"))
        let destination = f.root.appendingPathComponent("output")
        let part = destination.appendingPathExtension("part")
        try Data("he".utf8).write(to: part)
        await #expect(throws: RemoteSyncError.conflict(path: part.path)) {
            try await f.source.download(path: "/input", to: destination, options: .init(resumeFrom: 3))
        }
        #expect(try Data(contentsOf: part) == Data("he".utf8))
    }

    @Test func resumedPartSymlinkCannotModifyItsTarget() async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        try Data("hello".utf8).write(to: f.root.appendingPathComponent("input"))
        let destination = f.root.appendingPathComponent("output")
        let victim = f.root.appendingPathComponent("victim")
        try Data("he".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathExtension("part"), withDestinationURL: victim)
        await #expect(throws: RemoteSyncError.self) {
            try await f.source.download(path: "/input", to: destination, options: .init(resumeFrom: 2))
        }
        #expect(try Data(contentsOf: victim) == Data("he".utf8))
    }

    @Test func cancellationRetainsPartAndPreservesDestination() async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        try Data(repeating: 65, count: 2 << 20).write(to: f.root.appendingPathComponent("input"))
        let destination = f.root.appendingPathComponent("output")
        try Data("old".utf8).write(to: destination)
        let task = Task {
            try await f.source.download(path: "/input", to: destination, options: .init(progress: { bytes in
                if bytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }))
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(try Data(contentsOf: destination.appendingPathExtension("part")).count == 1 << 20)
    }

    @Test func emptyFileReportsZeroAndInstalls() async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        try Data().write(to: f.root.appendingPathComponent("input"))
        let destination = f.root.appendingPathComponent("output")
        _ = try await f.source.download(path: "/input", to: destination, options: .init(progress: { bytes in
            #expect(bytes == 0)
        }))
        #expect(try Data(contentsOf: destination).isEmpty)
    }

    @Test(arguments: [0o755, 0o640, 0o4755])
    func overwritePreservesOrdinaryPermissions(mode: Int) async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        try Data("new".utf8).write(to: f.root.appendingPathComponent("input"))
        let destination = f.root.appendingPathComponent("output")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        _ = try await f.source.download(path: "/input", to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode & 0o777)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test func changingSourceDuringCopyPreventsInstallation() async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        let input = f.root.appendingPathComponent("input")
        try Data("hello".utf8).write(to: input)
        let destination = f.root.appendingPathComponent("output")
        try Data("old".utf8).write(to: destination)
        await #expect(throws: RemoteSyncError.self) {
            try await f.source.download(path: "/input", to: destination, options: .init(progress: { bytes in
                if bytes == 5 { try? Data("other".utf8).write(to: input) }
            }))
        }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
    }

    @Test func sourceCannotBeItsOwnDestination() async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        let input = f.root.appendingPathComponent("input")
        try Data("hello".utf8).write(to: input)
        await #expect(throws: RemoteSyncError.conflict(path: input.path)) {
            try await f.source.download(path: "/input", to: input)
        }
        #expect(try Data(contentsOf: input) == Data("hello".utf8))
        #expect(!FileManager.default.fileExists(atPath: input.appendingPathExtension("part").path))
    }

    @Test func normalResumeAndOverwriteStillWork() async throws {
        let f = try await DownloadFixture()
        defer { f.cleanup() }
        try Data("hello".utf8).write(to: f.root.appendingPathComponent("input"))
        let destination = f.root.appendingPathComponent("output")
        try Data("old".utf8).write(to: destination)
        try Data("he".utf8).write(to: destination.appendingPathExtension("part"))
        _ = try await f.source.download(path: "/input", to: destination, options: .init(resumeFrom: 2))
        #expect(try Data(contentsOf: destination) == Data("hello".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
    }
}

private struct DownloadFixture {
    let root: URL
    let source: LocalFileSource
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BoneLocalDownload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = LocalFileSource(root: root)
        try await source.connect(.anonymous)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
