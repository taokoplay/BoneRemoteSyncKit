#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
@testable import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVGenericRecoveryTests {
    @Test func genericRecoveryObservesCheckpointAndResumesWithNewSource() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let binding = RemoteSourceBinding(kind: .webdav, identity: "opaque-account")
        let reference = RemoteFileReference(source: binding, path: "/slow.bin")
        let locks = LocalDownloadDestinationLocks(directory: server.file("locks"))
        let source = try server.source(); try await source.connect(.anonymous)
        let service = RemoteDownloadRecovery(source: source, binding: binding, destinationLocks: locks)
        let task = Task {
            try await service.download(reference, to: server.file(), options: .init(checkpointIntervalBytes: 65536, progress: { bytes in
                if bytes >= 131072 { withUnsafeCurrentTask { $0?.cancel() } }
            }))
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        let checkpointURL = server.file().appendingPathExtension("part.checkpoint.json")
        let persisted = try Data(contentsOf: checkpointURL)
        let json = try #require(try JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        let storedBinding = try #require(json["binding"] as? [String: String])
        #expect(Set(storedBinding.keys) == ["sourceNamespaceHash", "rootHash", "remotePathHash", "destinationHash"])
        #expect(storedBinding.values.allSatisfy { $0.count == 64 })
        let serialized = String(decoding: persisted, as: UTF8.self)
        for raw in [binding.identity, server.baseURL.absoluteString, "/slow.bin", server.file().path] {
            #expect(!serialized.contains(raw))
        }
        let checkpoint = try #require(try await service.checkpoint(reference, destination: server.file()))
        #expect(try Data(contentsOf: checkpointURL) == persisted)
        #expect(checkpoint.phase == .downloading)
        #expect(checkpoint.confirmedBytes == 131072)
        #expect(checkpoint.expectedSize == 3_145_728)
        #expect(checkpoint.version.source == binding)
        #expect(checkpoint.version.locator == reference.locator)
        #expect(checkpoint.version.strength == .strongConditional)
        #expect(!FileManager.default.fileExists(atPath: server.file().path))
        let other = RemoteFileReference(source: .init(kind: .webdav, identity: "other-account"), path: "/slow.bin")
        let otherService = RemoteDownloadRecovery(source: source, binding: other.source, destinationLocks: locks)
        await #expect(throws: (any Error).self) { try await otherService.checkpoint(other, destination: server.file()) }
        await source.disconnect()
        let next = try server.source(); try await next.connect(.anonymous)
        let recovery = RemoteDownloadRecovery(source: next, binding: binding, destinationLocks: locks)
        let result = try await recovery.download(reference, to: server.file())
        #expect(result.state == .committed)
        #expect(try Data(contentsOf: server.file()).count == 3_145_728)
        #expect(try await recovery.checkpoint(reference, destination: server.file()) == nil)
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.last?["range"] as? String == "bytes=131072-")
        // A completed result is not an idempotency key. A second fresh download must not overwrite it.
        await #expect(throws: (any Error).self) { try await recovery.download(reference, to: server.file()) }
        await next.disconnect()
    }

    @Test(arguments: ["version", "inode", "digest", "locator"])
    func genericResumeRejectsChangedPairWithoutGET(kind: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let pair = try RecoveryPair(server: server, etag: kind == "version" ? "\"old\"" : "\"v1\"")
        if kind == "inode" { try Data("abcdeTAIL".utf8).write(to: pair.target.part, options: .atomic) }
        if kind == "digest" { try Data("changed!!".utf8).write(to: pair.target.part) }
        let before = try Data(contentsOf: pair.store.url)
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "account")
        let recovery = RemoteDownloadRecovery(source: source, binding: binding,
            destinationLocks: LocalDownloadDestinationLocks(directory: server.file("locks")))
        let ref = RemoteFileReference(source: binding, path: kind == "locator" ? "/other.txt" : "/hello.txt")
        await #expect(throws: (any Error).self) {
            try await recovery.download(ref, to: server.file(), options: .init(overwrite: true))
        }
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        #expect(try Data(contentsOf: pair.store.url) == before)
        await source.disconnect()
    }

    @Test func readyAndCommittedCheckpointStatesAreDistinguished() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let binding = RemoteSourceBinding(kind: .webdav, identity: "account")
        let ref = RemoteFileReference(source: binding, path: "/hello.txt")
        let source = try server.source(); try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.cancelled) {
            try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"),
                hooks: .init(onPhase: { if $0 == .beforeInstall { throw RemoteSyncError.cancelled } }))
        }
        let ready = try #require(try await source.downloadCheckpoint(ref, destination: server.file()))
        #expect(ready.phase == .readyToInstall)
        let result = try await source.downloadResumableResult(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"),
            hooks: .init(onPhase: { if $0 == .installedBeforeCleanup { throw RemoteSyncError.cancelled } }))
        #expect(result.state == .committedCleanupPending)
        let committed = try #require(try await source.downloadCheckpoint(ref, destination: server.file()))
        #expect(committed.phase == .committedCleanupPending)
        #expect(committed.confirmedBytes == 26)
        await source.disconnect()
    }
}
#endif
