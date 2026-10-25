import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

@Suite struct LocalFileSourceCopyTests {
    @Test func copyFileLeavesSourceIntactAndUsesPublicCopyProtocol() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let source: any RemoteSource = fixture.source
        let copier = try #require(source as? any RemoteCopyingSource)
        #expect(copier.capabilities.copy)
        try fixture.write("original", at: "a.txt")
        try await copier.copy(from: "/a.txt", to: "/b.txt")
        #expect(try fixture.text("a.txt") == "original")
        #expect(try fixture.text("b.txt") == "original")
        try fixture.write("changed", at: "b.txt")
        #expect(try fixture.text("a.txt") == "original")
    }

    @Test func copyDirectoryRecursivelyPreservesSource() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let source: any RemoteSource = fixture.source
        let copier = try #require(source as? any RemoteCopyingSource)
        try fixture.write("nested", at: "tree/sub/a.txt")
        try await copier.copy(from: "/tree", to: "/copy")
        #expect(try fixture.text("tree/sub/a.txt") == "nested")
        #expect(try fixture.text("copy/sub/a.txt") == "nested")
    }

    @Test func copyDirectoryPreservesNestedSymlinksWithoutReadingExternalTarget() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        try fixture.write("inside", at: "tree/file.txt")
        let outside = fixture.workspace.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("tree/external-link"),
            withDestinationURL: outside
        )
        try await fixture.source.copy(from: "/tree", to: "/copy")
        let copiedLink = fixture.root.appendingPathComponent("copy/external-link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copiedLink.path) == outside.path)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
        #expect(try fixture.text("copy/file.txt") == "inside")
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/copy/external-link")) {
            try await fixture.source.stat(path: "/copy/external-link")
        }
    }

    @Test func moveAndCopyRequireExistingDestinationParent() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        try fixture.write("keep", at: "file.txt")
        await #expect(throws: RemoteSyncError.notFound(path: "/missing/copy.txt")) {
            try await fixture.source.copy(from: "/file.txt", to: "/missing/copy.txt")
        }
        await #expect(throws: RemoteSyncError.notFound(path: "/missing/moved.txt")) {
            try await fixture.source.move(from: "/file.txt", to: "/missing/moved.txt")
        }
        #expect(try fixture.names() == ["file.txt"])
        #expect(try fixture.text("file.txt") == "keep")
    }

    @Test func copyNeverClobbersTargetOrCopiesIntoItself() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let source: any RemoteSource = fixture.source
        let copier = try #require(source as? any RemoteCopyingSource)
        try fixture.write("source", at: "tree/a.txt")
        try fixture.write("target", at: "target.txt")
        await #expect(throws: RemoteSyncError.conflict(path: "/target.txt")) {
            try await copier.copy(from: "/tree/a.txt", to: "/target.txt")
        }
        await #expect(throws: RemoteSyncError.conflict(path: "/tree/sub")) {
            try await copier.copy(from: "/tree", to: "/tree/sub")
        }
        await #expect(throws: RemoteSyncError.conflict(path: "/tree")) {
            try await copier.copy(from: "/tree", to: "/tree")
        }
        #expect(try fixture.text("target.txt") == "target")
        #expect(try fixture.text("tree/a.txt") == "source")
    }

    @Test func copyMissingSourceAndDisconnectedSourceProduceNormalizedErrors() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let source: any RemoteSource = fixture.source
        let copier = try #require(source as? any RemoteCopyingSource)
        await #expect(throws: RemoteSyncError.notFound(path: "/missing")) {
            try await copier.copy(from: "/missing", to: "/target")
        }
        await copier.disconnect()
        await #expect(throws: RemoteSyncError.notConnected) {
            try await copier.copy(from: "/missing", to: "/target")
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test func copyCannotUseSourceRootOrWriteThroughExternalSymlink() async throws {
        let fixture = try await WriteFixture()
        defer { fixture.cleanUp() }
        let source: any RemoteSource = fixture.source
        let copier = try #require(source as? any RemoteCopyingSource)
        try fixture.write("keep", at: "file.txt")
        let outside = fixture.workspace.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("escape"), withDestinationURL: outside)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/")) {
            try await copier.copy(from: "/", to: "/copy")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/")) {
            try await copier.copy(from: "/file.txt", to: "/")
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/escape/copy.txt")) {
            try await copier.copy(from: "/file.txt", to: "/escape/copy.txt")
        }
        #expect(try fixture.text("file.txt") == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
