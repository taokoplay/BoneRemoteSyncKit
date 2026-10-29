#if os(macOS)
import Foundation
import CryptoKit
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVRecoveryTests {
    @Test func newManagedDownloadAndEmptyFileRemoveCheckpoint() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        for name in ["hello.txt", "empty.txt"] {
            let target = server.file(name)
            let result = try await source.downloadResumable(path: "/\(name)", to: target, options: .init(sourceNamespace: "account"))
            #expect(result.size == (name == "hello.txt" ? 26 : 0))
            #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("part").path))
            #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("part.checkpoint.json").path))
        }
        await source.disconnect()
    }

    @Test func cancellationNewSourceResumesSamePair() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let target = server.file()
        try Data("old".utf8).write(to: target)
        let source = try server.source(); try await source.connect(.anonymous)
        let options = WebDAVResumableDownloadOptions(sourceNamespace: "account", checkpointIntervalBytes: 65536, progress: { count in
            if count >= 131072 { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let transfer = Task { try await source.downloadResumable(path: "/slow.bin", to: target, options: options) }
        await #expect(throws: RemoteSyncError.cancelled) { try await transfer.value }
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        await source.disconnect()
        let next = try server.source(); try await next.connect(.anonymous)
        _ = try await next.downloadResumable(path: "/slow.bin", to: target, options: .init(sourceNamespace: "account", checkpointIntervalBytes: 65536))
        let payload = try Data(contentsOf: target)
        #expect(payload.count == 3_145_728)
        #expect(DAVPartHasher.hex(SHA256.hash(data: payload)) == DAVPartHasher.hex(SHA256.hash(data: Data((0...255).map(UInt8.init)) * 12288)))
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == 2)
        #expect(gets.last?["range"] as? String == "bytes=131072-")
        #expect(gets.last?["ifMatch"] as? String == "\"v1\"")
        await next.disconnect()
    }

    @Test(arguments: ["no-etag.txt", "weak.txt", "unknown.txt"])
    func unsupportedRepresentationDoesNotCreatePart(name: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        await #expect(throws: (any Error).self) {
            try await source.downloadResumable(path: "/\(name)", to: server.file(), options: .init(sourceNamespace: "id"))
        }
        #expect(!FileManager.default.fileExists(atPath: server.file().appendingPathExtension("part").path))
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        await source.disconnect()
    }

    @Test func orphanPartIsNotAdoptedOrTruncated() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let part = server.file().appendingPathExtension("part")
        try Data("unrelated".utf8).write(to: part)
        let source = try server.source(); try await source.connect(.anonymous)
        await #expect(throws: (any Error).self) {
            try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "id"))
        }
        #expect(try Data(contentsOf: part) == Data("unrelated".utf8))
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        await source.disconnect()
    }
}

private func * (lhs: Data, rhs: Int) -> Data {
    var result = Data(); for _ in 0..<rhs { result.append(lhs) }; return result
}
#endif
