#if os(macOS)
import Foundation
import Darwin
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVWritingSafetyTests {
    @Test func snapshotIsPrivateIndependentAndCleanedUp() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let original = Data("original".utf8)
        try original.write(to: server.file("input"))
        let pool = DAVHTTPSession(timeout: 5)
        let scope = DAVOperationScope(pool: pool, policy: .none)
        var snapshot: DAVUploadSnapshot? = try await DAVUploadSnapshot.create(from: server.file("input"), scope: scope)
        let url = try #require(snapshot?.url)
        try Data("replaced".utf8).write(to: server.file("input"), options: .atomic)
        #expect(try Data(contentsOf: url) == original)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        snapshot = nil
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func writesRequireConnectionAndUseExplicitBasicCredential() async throws {
        let server = try WebDAVTestServer(root: "auth", fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.makeDirectory(path: "/new") }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.upload(from: server.file("input"), to: "/new") }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.remove(path: "/hello.txt") }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.copy(from: "/hello.txt", to: "/new") }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.move(from: "/hello.txt", to: "/new") }
        #expect(try server.requests().isEmpty)
        try await source.connect(.basic(username: "alice", password: "secret"))
        try Data("test".utf8).write(to: server.file("input"))
        try await source.makeDirectory(path: "/new")
        _ = try await source.upload(from: server.file("input"), to: "/new/file")
        try await source.copy(from: "/new/file", to: "/new/copied")
        try await source.move(from: "/new/copied", to: "/new/moved")
        try await source.remove(path: "/new")
        #expect(try server.requests().allSatisfy { $0["authorization"] as? String == "Basic YWxpY2U6c2VjcmV0" })
        await source.disconnect()
    }

    @Test func emptyAndLargeUploadsRoundTripWithEscapedDestination() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try await source.makeDirectory(path: "/资料")
        for size in [0, 3 * 1024 * 1024] {
            let payload = Data(repeating: 0xA5, count: size)
            try payload.write(to: server.file("input"))
            let progress = DAVProgress()
            let entry = try await source.upload(from: server.file("input"), to: "/资料/a #?%.txt", options: .init(progress: progress.record))
            #expect(entry.size == Int64(size))
            _ = try await source.download(entry, to: server.file(), options: .init())
            #expect(try Data(contentsOf: server.file()) == payload)
            #expect(progress.snapshot().first == 0)
            #expect(progress.snapshot().last == Int64(size))
        }
        try await source.copy(from: "/资料/a #?%.txt", to: "/资料/b #?%.txt")
        let request = try #require(server.requests().last)
        #expect((request["destination"] as? String)?.hasSuffix("/%E8%B5%84%E6%96%99/b%20%23%3F%25.txt") == true)
        #expect(request["overwrite"] as? String == "F")
        #expect(request["depth"] as? String == "infinity")
        await source.disconnect()
    }

    @Test func directoriesCopyAndMoveRecursivelyAndNeverOverwrite() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try await source.copy(from: "/folder", to: "/copy")
        #expect((try await source.stat(path: "/copy/child.txt")).size == 5)
        try await source.move(from: "/copy", to: "/moved")
        await #expect(throws: RemoteSyncError.notFound(path: "/copy")) { try await source.stat(path: "/copy") }
        #expect((try await source.stat(path: "/moved/child.txt")).size == 5)
        for copying in [true, false] {
            await #expect(throws: RemoteSyncError.conflict(path: "/hello.txt")) {
                if copying { try await source.copy(from: "/folder", to: "/hello.txt") }
                else { try await source.move(from: "/folder", to: "/hello.txt") }
            }
            await #expect(throws: RemoteSyncError.conflict(path: "/folder/nested")) {
                if copying { try await source.copy(from: "/folder", to: "/folder/nested") }
                else { try await source.move(from: "/folder", to: "/folder/nested") }
            }
        }
        await #expect(throws: RemoteSyncError.conflict(path: "/hello.txt")) { try await source.makeDirectory(path: "/hello.txt/child") }
        await #expect(throws: RemoteSyncError.notFound(path: "/absent")) { try await source.move(from: "/folder", to: "/absent/folder") }
        try await source.makeDirectory(path: "/")
        try await source.remove(path: "/moved")
        await #expect(throws: RemoteSyncError.notFound(path: "/moved/child.txt")) { try await source.stat(path: "/moved/child.txt") }
        await source.disconnect()
    }

    @Test func rejectsInvalidLocalSourcesAndHeadersBeforeWrites() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try Data("x".utf8).write(to: server.file("input"))
        try FileManager.default.createSymbolicLink(at: server.file("link"), withDestinationURL: server.file("input"))
        #expect(mkfifo(server.file("fifo").path, mode_t(0o600)) == 0)
        for url in [server.workspace, server.file("link"), server.file("fifo")] {
            await #expect(throws: RemoteSyncError.unsupported(operation: "上传非普通文件")) {
                try await source.upload(from: url, to: "/out")
            }
        }
        await #expect(throws: RemoteSyncError.notFound(path: server.file("absent").path)) {
            try await source.upload(from: server.file("absent"), to: "/out")
        }
        await #expect(throws: RemoteSyncError.unsupported(operation: "上传非本地文件")) {
            try await source.upload(from: URL(string: "https://example.com/input")!, to: "/out")
        }
        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV Content-Type 无效")) {
            try await source.upload(from: server.file("input"), to: "/out", options: .init(contentType: "text/plain\r\nX: injected"))
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/a\0b")) { try await source.makeDirectory(path: "/a\0b") }
        #expect(try server.requests().allSatisfy { $0["method"] as? String == "PROPFIND" })
        await source.disconnect()
    }

    @Test(arguments: ["forbidden", "locked", "limited", "broken", "unsupported", "redirect", "partial"])
    func mutationErrorsAreNotRetried(name: String) async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: .init(maxAttempts: 3, initialDelay: 0, maxDelay: 0, totalTimeout: 10))
        try await source.connect(.anonymous)
        try Data("x".utf8).write(to: server.file("input"))
        let expected: RemoteSyncError
        switch name {
        case "forbidden": expected = .permissionDenied(path: "/forbidden")
        case "locked": expected = .conflict(path: "/locked")
        case "limited": expected = .rateLimited(retryAfter: 7)
        case "broken": expected = .network("WebDAV HTTP 503")
        case "unsupported": expected = .unsupported(operation: "WebDAV PUT")
        case "redirect": expected = .unsupported(operation: "WebDAV 重定向；请使用最终地址")
        default: expected = .underlying("WebDAV PUT 返回 207，可能部分完成；请重新查询远端状态")
        }
        await #expect(throws: expected) { try await source.upload(from: server.file("input"), to: "/" + name, options: .init(overwrite: false)) }
        #expect(try server.requests().filter { $0["method"] as? String == "PUT" }.count == 1)
        #expect(try server.requests().allSatisfy { !($0["path"] as? String ?? "").contains("stolen") })
        await source.disconnect()
    }

    @Test func conditionalUploadProtectsConcurrentCreationAndReplacement() async throws {
        let server = try WebDAVTestServer(root: "put-race", fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try Data("x".utf8).write(to: server.file("input"))
        for path in ["/new", "/hello.txt"] {
            await #expect(throws: RemoteSyncError.conflict(path: path)) { try await source.upload(from: server.file("input"), to: path) }
            #expect((try await source.stat(path: path)).size == 17)
        }
        await source.disconnect()
    }

    @Test func existingCollectionRaceIsBenignButMissingValidatorIsNotOverwritten() async throws {
        let server = try WebDAVTestServer(root: "mkcol-race", fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try await source.makeDirectory(path: "/race/nested")
        #expect((try await source.stat(path: "/race/nested")).isDirectory)
        await source.disconnect()
        let weak = try WebDAVTestServer(root: "no-etag", fixture: "write_server"); defer { weak.cleanUp() }
        let weakSource = try weak.source(); try await weakSource.connect(.anonymous)
        try Data("x".utf8).write(to: weak.file("input"))
        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV 覆盖已有文件需要强 ETag")) {
            try await weakSource.upload(from: weak.file("input"), to: "/hello.txt")
        }
        #expect(try weak.requests().allSatisfy { $0["method"] as? String != "PUT" })
        await weakSource.disconnect()
    }

    @Test func cancelledTaskDoesNotSendMutation() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await source.makeDirectory(path: "/cancelled")
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try server.requests().allSatisfy { $0["method"] as? String == "PROPFIND" })
        await source.disconnect()
    }

    @Test(arguments: [false, true])
    func cancelAndDisconnectStopInFlightWrites(reconnect: Bool) async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try Data(repeating: 7, count: 1024 * 1024).write(to: server.file("input"))
        let task = Task { try await source.upload(from: server.file("input"), to: "/slow") }
        defer { task.cancel() }
        for _ in 0..<200 {
            if try server.requests().contains(where: { $0["method"] as? String == "PUT" }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try server.requests().contains { $0["method"] as? String == "PUT" })
        if reconnect { await source.disconnect(); try await source.connect(.anonymous) }
        else { task.cancel() }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try server.requests().filter { $0["method"] as? String == "PUT" }.count == 1)
        await source.disconnect()
    }

    @Test func earlySuccessWithoutReadingUploadBodyIsNotAccepted() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try Data(repeating: 1, count: 16 * 1024 * 1024).write(to: server.file("input"))
        await #expect(throws: (any Error).self) {
            try await source.upload(from: server.file("input"), to: "/early", options: .init(overwrite: false))
        }
        await source.disconnect()
    }

    @Test func totalDeadlineIncludesMutationResponseWait() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: .init(maxAttempts: 1, totalTimeout: 10))
        try await source.connect(.anonymous)
        try Data("x".utf8).write(to: server.file("input"))
        await #expect(throws: RemoteSyncError.network("WebDAV 操作总时限已到")) {
            try await source.upload(from: server.file("input"), to: "/deadline")
        }
        #expect(try server.requests().filter { $0["method"] as? String == "PUT" }.count == 1)
        await source.disconnect()
    }
}
#endif
