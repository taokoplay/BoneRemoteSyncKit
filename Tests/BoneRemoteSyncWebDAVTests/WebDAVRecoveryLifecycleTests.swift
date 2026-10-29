#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVRecoveryLifecycleTests {
    @Test func managedAndOrdinaryDownloadsReserveSidecarAliases() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let progress = DAVProgress()
        let task = Task { try await source.downloadResumable(path: "/slow.bin", to: server.file(), options: .init(sourceNamespace: "id", checkpointIntervalBytes: 65536, progress: progress.record)) }
        defer { task.cancel() }
        for _ in 0..<200 {
            if progress.snapshot().last ?? 0 >= 65536 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(progress.snapshot().last ?? 0 >= 65536)
        for alias in [server.file().appendingPathExtension("part.checkpoint.json"), server.file("OUT.BIN.PART.CHECKPOINT.JSON")] {
            await #expect(throws: (any Error).self) { try await source.download(path: "/hello.txt", to: alias) }
            await #expect(throws: (any Error).self) { try await source.downloadResumable(path: "/hello.txt", to: alias, options: .init(sourceNamespace: "id")) }
        }
        task.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        await source.disconnect()
    }

    @Test func disconnectAndReconnectDoNotInstallOldManagedDownload() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try Data("old".utf8).write(to: server.file())
        let progress = DAVProgress()
        let task = Task { try await source.downloadResumable(path: "/slow.bin", to: server.file(), options: .init(sourceNamespace: "id", checkpointIntervalBytes: 65536, progress: progress.record)) }
        defer { task.cancel() }
        for _ in 0..<200 {
            if progress.snapshot().last ?? 0 >= 65536 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(progress.snapshot().last ?? 0 >= 65536)
        await source.disconnect()
        try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        await source.disconnect()
    }

    @Test func absoluteDeadlineStillAppliesAfterWorkerReturns() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: .init(maxAttempts: 1, totalTimeout: 60))
        try await source.connect(.anonymous)
        try Data("old".utf8).write(to: server.file())
        let clock = RecoveryTestClock()
        let runtime = DAVRetryRuntime(now: { clock.now }, wallNow: { Date() }, sleep: { try await Task.sleep(nanoseconds: $0) }, randomUnit: { 1 })
        await #expect(throws: RemoteSyncError.network("WebDAV 操作总时限已到")) {
            try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "id"),
                hooks: .init(onPhase: { if $0 == .beforeInstall { clock.expire() } }), runtime: runtime)
        }
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        #expect(FileManager.default.fileExists(atPath: server.file().appendingPathExtension("part").path))
        await source.disconnect()
    }

    @Test func statAndGETAttemptsShareBoundedTwoStageBudget() async throws {
        let server = try WebDAVTestServer(root: "retry-twice"); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: .init(maxAttempts: 3, initialDelay: 0, maxDelay: 0, totalTimeout: 60))
        try await source.connect(.anonymous)
        _ = try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "id"))
        let requests = try server.requests().filter { ($0["path"] as? String)?.hasSuffix("/hello.txt") == true }
        #expect(requests.count == 6)
        #expect(requests.filter { $0["method"] as? String == "PROPFIND" }.count == 3)
        #expect(requests.filter { $0["method"] as? String == "GET" }.count == 3)
        await source.disconnect()
    }

    @Test func injectedWallClockFlowsThroughBothPreflightAndGET() async throws {
        let server = try WebDAVTestServer(root: "retry-date"); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: .standard)
        try await source.connect(.anonymous)
        let delays = RecoveryRetryDelays()
        let runtime = DAVRetryRuntime(now: { 0 }, wallNow: { Date(timeIntervalSince1970: 784111770) }, sleep: { nanos in
            if nanos == 7_000_000_000 { delays.record(nanos) }
            else { try await Task.sleep(nanoseconds: nanos) }
        }, randomUnit: { 1 })
        _ = try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "id"), hooks: .none, runtime: runtime)
        #expect(delays.values == [7_000_000_000, 7_000_000_000])
        #expect(try server.requests().filter { ($0["path"] as? String)?.hasSuffix("/hello.txt") == true }.count == 4)
        await source.disconnect()
    }

    @Test func preInstallCancellationDoesNotInstallReadyPart() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try Data("old".utf8).write(to: server.file())
        let task = Task {
            try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "id"),
                hooks: .init(onPhase: { if $0 == .beforeInstall { withUnsafeCurrentTask { $0?.cancel() } } }))
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        _ = try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "id"))
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 1)
        await source.disconnect()
    }

    @Test func overwrittenSidecarDuringProgressIsNotReplacedOrInstalled() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try Data("old".utf8).write(to: server.file())
        let checkpoint = server.file().appendingPathExtension("part.checkpoint.json")
        await #expect(throws: (any Error).self) {
            try await source.downloadResumable(path: "/slow.bin", to: server.file(), options: .init(sourceNamespace: "id", checkpointIntervalBytes: 65536, progress: { bytes in
                if bytes == 65536 { try? Data("foreign".utf8).write(to: checkpoint, options: .atomic) }
            }))
        }
        #expect(try Data(contentsOf: checkpoint) == Data("foreign".utf8))
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        await source.disconnect()
    }
}
private final class RecoveryRetryDelays: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UInt64] = []
    var values: [UInt64] { lock.withLock { recorded } }
    func record(_ value: UInt64) { lock.withLock { recorded.append(value) } }
}

private final class RecoveryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var now: UInt64 { lock.withLock { value } }
    func expire() { lock.withLock { value = 61_000_000_000 } }
}
#endif
