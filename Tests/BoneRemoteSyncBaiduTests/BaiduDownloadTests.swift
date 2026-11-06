#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncBaidu

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python3")) struct BaiduDownloadTests {
    @Test(arguments: ["normal", "download-redirect"])
    func completeDownloadUsesTokenAndUserAgentWithoutLeakingIntoEntry(_ scenario: String) async throws {
        let server = try BaiduTestServer(scenario); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let entry = try await source.stat(path: "/a.txt")
        let progress = BaiduProgress()
        _ = try await source.download(entry, to: server.file("out"), options: .init(overwrite: false, progress: progress.record))
        #expect(try Data(contentsOf: server.file("out")) == BaiduTestServer.payload)
        #expect(progress.values.last == Int64(BaiduTestServer.payload.count))
        let serialized = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!serialized.contains("token") && !serialized.contains("download"))
        let requests = try server.requests()
        #expect(requests.allSatisfy { $0["agent"] as? String == "pan.baidu.com" && $0["cookie"] is NSNull && $0["authorization"] is NSNull })
        let download = try #require(requests.first { ($0["path"] as? String)?.hasPrefix("/download/") == true })
        #expect((download["rawQuery"] as? String)?.contains("signature=a%2Fb%2Bz") == true)
        #expect((download["query"] as? [String: [String]])?["access_token"] == ["fixture-token"])
        await source.disconnect()
    }
    @Test(arguments: ["short-download", "changed-download", "error-download", "evil-dlink", "evil-redirect", "outside-id"])
    func failedDownloadPreservesTarget(_ scenario: String) async throws {
        let server = try BaiduTestServer(scenario); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let entry = try await source.stat(path: "/a.txt"); let output = server.file("out")
        try Data("keep".utf8).write(to: output)
        await #expect(throws: (any Error).self) { try await source.download(entry, to: output, options: .init()) }
        #expect(try String(contentsOf: output, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-baidu-") })
        await source.disconnect()
    }
    @Test func cancellationAndUnsupportedRequirementsDoNotPublish() async throws {
        let server = try BaiduTestServer("slow-download"); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let entry = try await source.stat(path: "/a.txt")
        await #expect(throws: RemoteSyncError.self) { try await source.download(entry, to: server.file("out"), options: .init(resumeFrom: 1)) }
        await #expect(throws: RemoteSyncError.self) { try await source.download(entry, to: server.file("out"), options: .init(expectedETag: "v1")) }
        let task = Task { try await source.download(entry, to: server.file("out"), options: .init()) }
        try await server.waitFor("/download/")
        await source.disconnect()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: server.file("out").path))
    }
    @Test func transferMaterializesByIDAndReleasesLease() async throws {
        let server = try BaiduTestServer(); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let entry = try await source.stat(path: "/a.txt"), binding = try await source.connectedBinding()
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: server.file("cache"))
        let coordinator = RemoteTransferCoordinator(materializer: materializer)
        let task = await coordinator.submit(.init(reference: .init(source: binding, itemID: entry.id)))
        let lease = try await coordinator.wait(for: task)
        #expect(try Data(contentsOf: lease.url) == BaiduTestServer.payload)
        await lease.release(); #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        await coordinator.shutdown(); await materializer.shutdown(); await source.disconnect()
    }
}
#endif
