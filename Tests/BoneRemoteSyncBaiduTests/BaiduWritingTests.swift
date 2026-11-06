#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncBaidu

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python3")) struct BaiduWritingTests {
    @Test(arguments: [19, 4 * 1024 * 1024 + 17])
    func uploadRoundTripAndFileManagement(_ size: Int) async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        try await source.makeDirectory(path: "/new/nested")
        try await source.makeDirectory(path: "/new/nested")
        let input = server.file("input"); let bytes = Data(repeating: 42, count: size)
        try bytes.write(to: input); let progress = BaiduProgress()
        let uploaded = try await source.upload(from: input, to: "/new/nested/中文 +?.txt", options: .init(overwrite: false, progress: progress.record))
        #expect(uploaded.size == Int64(size) && uploaded.path == "/new/nested/中文 +?.txt")
        #expect(progress.values.first == 0 && progress.values.last == Int64(size))
        _ = try await source.download(uploaded, to: server.file("output"), options: .init(overwrite: false))
        #expect(try Data(contentsOf: server.file("output")) == bytes)
        await #expect(throws: RemoteSyncError.self) { try await source.upload(from: input, to: uploaded.path!, options: .init(overwrite: false)) }
        try await source.copy(from: uploaded.path!, to: "/new/copy.txt")
        try await source.move(from: "/new/copy.txt", to: "/new/moved.txt")
        #expect(try await source.stat(path: "/new/moved.txt").size == Int64(size))
        try await source.remove(path: "/new")
        await #expect(throws: RemoteSyncError.self) { try await source.stat(path: "/new") }
        let requests = try server.requests()
        let chunks = requests.filter { $0["method"] as? String == "upload" }
        #expect(chunks.count == (size + 4 * 1024 * 1024 - 1) / (4 * 1024 * 1024))
        #expect(chunks.enumerated().allSatisfy { index, r in (r["query"] as? [String: [String]])?["partseq"] == [String(index)] })
        let manage = requests.filter { $0["method"] as? String == "filemanager" }
        #expect(manage.allSatisfy { ($0["form"] as? [String: [String]])?["async"] == ["0"] })
        await source.disconnect()
    }
    @Test func overwriteAndUnsupportedPreflight() async throws {
        let server = try BaiduTestServer("empty-blocks"); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let input = server.file("input"); try Data("replacement".utf8).write(to: input)
        let value = try await source.upload(from: input, to: "/a.txt", options: .init(overwrite: true))
        #expect(value.size == 11)
        let requests = try server.requests().count
        await #expect(throws: RemoteSyncError.self) { try await source.upload(from: input, to: "/new", options: .init(expectedETag: "v1")) }
        await #expect(throws: RemoteSyncError.self) { try await source.remove(path: "/") }
        await #expect(throws: RemoteSyncError.self) { try await source.move(from: "/folder", to: "/folder/child") }
        #expect(try server.requests().filter { $0["method"] as? String == "precreate" }.count == 1)
        #expect(try server.requests().count >= requests)
        await source.disconnect()
    }
    @Test(arguments: ["bad-blocks", "bad-md5", "evil-upload-host"])
    func invalidUploadResponsesCannotCommit(_ scenario: String) async throws {
        let server = try BaiduTestServer(scenario); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        try Data(repeating: 7, count: 32).write(to: server.file("input"))
        await #expect(throws: (any Error).self) { try await source.upload(from: server.file("input"), to: "/new.txt", options: .init()) }
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "create" })
        await source.disconnect()
    }
    @Test(arguments: ["async-result", "entry-error"])
    func asynchronousOrPerItemErrorsAreNotSuccess(_ scenario: String) async throws {
        let server = try BaiduTestServer(scenario); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        await #expect(throws: (any Error).self) { try await source.remove(path: "/a.txt") }
        #expect(try server.requests().filter { $0["method"] as? String == "filemanager" }.count == 1)
        await source.disconnect()
    }
    @Test func cancellationDoesNotCommitAndMutationSlotIsExclusive() async throws {
        let server = try BaiduTestServer("slow-upload"); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        try Data(repeating: 7, count: 128).write(to: server.file("input"))
        let task = Task { try await source.upload(from: server.file("input"), to: "/new.txt", options: .init()) }
        try await server.waitFor("upload")
        await #expect(throws: RemoteSyncError.self) { try await source.remove(path: "/a.txt") }
        await source.disconnect()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "create" })
    }
}
#endif
