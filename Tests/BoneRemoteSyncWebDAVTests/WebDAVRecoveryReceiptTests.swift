#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite struct WebDAVRecoveryReceiptTests {
    @Test func cancellationAfterRenameStillReturnsCommittedReceipt() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let task = Task {
            try await source.downloadResumableResult(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"),
                hooks: .init(onPhase: { if $0 == .installedBeforeCleanup { withUnsafeCurrentTask { $0?.cancel() } } }))
        }
        let result = try await task.value
        #expect(result.state == .committed)
        #expect(try Data(contentsOf: server.file()).count == 26)
        #expect(!FileManager.default.fileExists(atPath: server.file().appendingPathExtension("part.checkpoint.json").path))
        await source.disconnect()
    }

    @Test func committedCleanupFailureIsReportedWithoutRedownloading() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let result = try await source.downloadResumableResult(path: "/hello.txt", to: server.file(),
            options: .init(sourceNamespace: "account", overwrite: false),
            hooks: .init(onPhase: { if $0 == .installedBeforeCleanup { throw RemoteSyncError.cancelled } }))
        #expect(result.state == .committedCleanupPending)
        #expect(result.entry.size == 26)
        #expect(try Data(contentsOf: server.file()).count == 26)
        let next = try await source.downloadResumableResult(path: "/hello.txt", to: server.file(),
            options: .init(sourceNamespace: "account", overwrite: false))
        #expect(next.state == .committed)
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 1)
        await source.disconnect()
    }
}
#endif
