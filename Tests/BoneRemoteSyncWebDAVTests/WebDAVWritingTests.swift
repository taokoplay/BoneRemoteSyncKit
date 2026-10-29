#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVWritingTests {
    @Test func supportsUploadDirectoryCreationMoveCopyAndRecursiveRemove() async throws {
        let server = try WebDAVTestServer(fixture: "write_server")
        defer { server.cleanUp() }
        let reader: any RemoteSource = try server.source()
        let source = try #require(reader as? any RemoteCopyingSource)
        try await source.connect(.anonymous)

        try await source.makeDirectory(path: "/uploads/nested")
        try await source.makeDirectory(path: "/uploads/nested")

        let local = server.file("input.txt")
        try Data("uploaded by WebDAV".utf8).write(to: local)
        let progress = DAVProgress()
        let uploaded = try await source.upload(
            from: local,
            to: "/uploads/nested/input.txt",
            options: .init(overwrite: false, contentType: "text/plain", progress: progress.record)
        )
        #expect(uploaded.path == "/uploads/nested/input.txt")
        #expect(uploaded.size == 18)
        #expect(progress.snapshot().first == 0)
        #expect(progress.snapshot().last == 18)

        try await source.copy(from: "/uploads/nested/input.txt", to: "/uploads/nested/copied.txt")
        try await source.move(from: "/uploads/nested/copied.txt", to: "/uploads/nested/moved.txt")
        #expect((try await source.stat(path: "/uploads/nested/moved.txt")).size == 18)

        try await source.remove(path: "/uploads")
        await #expect(throws: RemoteSyncError.notFound(path: "/uploads")) {
            try await source.stat(path: "/uploads")
        }

        let requests = try server.requests()
        #expect(requests.contains { $0["method"] as? String == "MKCOL" })
        #expect(requests.contains { $0["method"] as? String == "PUT" && $0["contentType"] as? String == "text/plain" })
        #expect(requests.contains { $0["method"] as? String == "COPY" })
        #expect(requests.contains { $0["method"] as? String == "MOVE" })
        #expect(requests.contains { $0["method"] as? String == "DELETE" })
        await source.disconnect()
    }

    @Test func uploadHonorsNonOverwriteAndAllowsExplicitOverwrite() async throws {
        let server = try WebDAVTestServer(fixture: "write_server")
        defer { server.cleanUp() }
        let reader: any RemoteSource = try server.source()
        let source = try #require(reader as? any RemoteCopyingSource)
        try await source.connect(.anonymous)
        let local = server.file("input.txt")
        try Data("new content".utf8).write(to: local)

        await #expect(throws: RemoteSyncError.conflict(path: "/hello.txt")) {
            try await source.upload(from: local, to: "/hello.txt", options: .init(overwrite: false))
        }
        let result = try await source.upload(from: local, to: "/hello.txt", options: .init(overwrite: true))
        #expect(result.size == 11)
        #expect((try await source.stat(path: "/hello.txt")).size == 11)

        let puts = try server.requests().filter { $0["method"] as? String == "PUT" }
        #expect(puts.first?["ifNoneMatch"] as? String == "*")
        #expect(puts.last?["ifNoneMatch"] as? String == nil)
        await source.disconnect()
    }

    @Test func writeOperationsRejectRootAndMissingParentsWithoutMutatingRemote() async throws {
        let server = try WebDAVTestServer(fixture: "write_server")
        defer { server.cleanUp() }
        let reader: any RemoteSource = try server.source()
        let source = try #require(reader as? any RemoteCopyingSource)
        try await source.connect(.anonymous)
        let local = server.file("input.txt")
        try Data("x".utf8).write(to: local)

        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV 不能用文件覆盖根目录")) {
            try await source.upload(from: local, to: "/", options: .init())
        }
        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV 不能删除根目录")) {
            try await source.remove(path: "/")
        }
        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV 不能移动根目录或覆盖根目录")) {
            try await source.move(from: "/hello.txt", to: "/")
        }
        await #expect(throws: RemoteSyncError.notFound(path: "/missing")) {
            try await source.upload(from: local, to: "/missing/file.txt", options: .init())
        }
        #expect(try server.requests().filter { ["PUT", "DELETE", "MOVE", "COPY", "MKCOL"].contains($0["method"] as? String ?? "") }.isEmpty)
        await source.disconnect()
    }
}
#endif
