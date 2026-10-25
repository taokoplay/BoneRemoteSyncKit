import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

@Suite struct LocalFileSourceSafetyTests {
    @Test(arguments: ["/", "/child/.."])
    func uploadAndMoveCannotReplaceSourceRoot(path: String) async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let input = try fixture.input("new")
        try fixture.write("keep", at: "keep.txt")
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/")) {
            try await fixture.source.upload(from: input, to: path)
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/")) {
            try await fixture.source.move(from: "/keep.txt", to: path)
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/")) {
            try await fixture.source.move(from: path, to: "/moved")
        }
        #expect(try fixture.text("keep.txt") == "keep")
    }

    @Test func externalSymlinkCannotBeUsedAsWriteParent() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let outside = fixture.workspace.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("escape"), withDestinationURL: outside)
        let input = try fixture.input("new")
        try fixture.write("source", at: "source.txt")
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/escape/new.txt")) {
            try await fixture.source.upload(from: input, to: "/escape/new.txt")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/escape/folder")) {
            try await fixture.source.makeDirectory(path: "/escape/folder")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/escape/keep.txt")) {
            try await fixture.source.remove(path: "/escape/keep.txt")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/escape/new.txt")) {
            try await fixture.source.move(from: "/source.txt", to: "/escape/new.txt")
        }
        #expect(try fixture.text("source.txt") == "source")
        #expect(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8) == "outside")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
    }

    @Test func rootSymlinkAliasCannotBeRemovedOrReplaced() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("root-alias"), withDestinationURL: fixture.root)
        try fixture.write("keep", at: "file.txt")
        let input = try fixture.input("new")
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/root-alias")) {
            try await fixture.source.remove(path: "/root-alias")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/root-alias")) {
            try await fixture.source.upload(from: input, to: "/root-alias")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/root-alias")) {
            try await fixture.source.move(from: "/root-alias", to: "/moved")
        }
        #expect(try fixture.text("file.txt") == "keep")
    }

    @Test func uploadToSymlinkNeverOverwritesTheLinkTarget() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        try fixture.write("keep", at: "target.txt")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("link.txt").path, withDestinationPath: "target.txt")
        let input = try fixture.input("new")
        await #expect(throws: RemoteSyncError.conflict(path: "/link.txt")) {
            try await fixture.source.upload(from: input, to: "/link.txt")
        }
        #expect(try fixture.text("target.txt") == "keep")
    }

    @Test func uploadRejectsSymbolicLinkInputWithoutChangingTarget() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        try fixture.write("keep", at: "target.txt")
        let input = try fixture.input("new")
        let inputLink = fixture.workspace.appendingPathComponent("input-link.txt")
        try FileManager.default.createSymbolicLink(at: inputLink, withDestinationURL: input)
        await #expect(throws: RemoteSyncError.unsupported(operation: "上传非普通文件")) {
            try await fixture.source.upload(from: inputLink, to: "/target.txt")
        }
        #expect(try fixture.text("target.txt") == "keep")
        #expect(try fixture.names() == ["target.txt"])
    }

    @Test func cancelledBeforeStartMakesNoDirectoryOrFile() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let input = try fixture.input("new")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.source.upload(from: input, to: "/new/target.txt")
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try fixture.names().isEmpty)
    }

    @Test func changedInputDuringUploadPreservesOriginalAndCleansStaging() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        try fixture.write("keep", at: "target.txt")
        let input = try fixture.input("initial")
        await #expect(throws: RemoteSyncError.conflict(path: input.path)) {
            try await fixture.source.upload(from: input, to: "/target.txt", options: .init(progress: { bytes in
                if bytes > 0 { try? Data("changed-and-longer".utf8).write(to: input) }
            }))
        }
        #expect(try fixture.text("target.txt") == "keep")
        #expect(try fixture.names() == ["target.txt"])
    }

    @Test func targetCreatedDuringNonOverwritingUploadIsPreserved() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let input = try fixture.input("new")
        let destination = fixture.root.appendingPathComponent("target.txt")
        await #expect(throws: RemoteSyncError.conflict(path: "/target.txt")) {
            try await fixture.source.upload(from: input, to: "/target.txt", options: .init(overwrite: false, progress: { bytes in
                if bytes == 0 { try? Data("other writer".utf8).write(to: destination) }
            }))
        }
        #expect(try fixture.text("target.txt") == "other writer")
        #expect(try fixture.names() == ["target.txt"])
    }

    @Test func nullPathCannotBeTreatedAsAnExistingDirectory() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/\0")) {
            try await fixture.source.makeDirectory(path: "/\0")
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test(arguments: ["dangling", "loop"])
    func unresolvedSymlinksAreRejectedForWrites(link: String) async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let url = fixture.root.appendingPathComponent(link)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: link == "loop" ? "loop" : "missing")
        let input = try fixture.input("new")
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/\(link)/file.txt")) {
            try await fixture.source.upload(from: input, to: "/\(link)/file.txt")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/\(link)/folder")) {
            try await fixture.source.makeDirectory(path: "/\(link)/folder")
        }
        #expect(try fixture.names() == [link])
    }

    @Test func moveRejectsDescendantReachedThroughDirectoryAlias() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        try fixture.write("keep", at: "tree/file.txt")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias").path, withDestinationPath: "tree")
        await #expect(throws: RemoteSyncError.conflict(path: "/alias/sub")) {
            try await fixture.source.move(from: "/tree", to: "/alias/sub")
        }
        #expect(try fixture.text("tree/file.txt") == "keep")
    }
}
