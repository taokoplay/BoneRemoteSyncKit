import Foundation
import Testing
import CryptoKit
import BoneRemoteSyncCore
@testable import BoneRemoteSyncTransfer

actor ControlledTransferSource: RemoteSource {
    nonisolated let kind: RemoteSourceKind = .local
    nonisolated let capabilities = RemoteCapabilities(maxConcurrentTransfers: 1)
    var downloads = 0
    var stats = 0
    var statBlocked = false
    var statCancelled = 0
    var active = 0
    var peak = 0
    var cancelled = 0
    var blocked = true
    var payload = Data("payload".utf8)
    var hasVersion = true
    var wrongSize = false
    var failure: RemoteSyncError?
    var savedProgress: (@Sendable (RemoteDownloadProgress) -> Void)?

    func connect(_ credential: RemoteCredential) async throws {}
    func disconnect() async {}
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        throw RemoteSyncError.unsupported(operation: "test")
    }
    func stat(path: String) async throws -> RemoteEntry {
        stats += 1
        do {
            while statBlocked { try await Task.sleep(nanoseconds: 1_000_000) }
        } catch {
            if Task.isCancelled { statCancelled += 1 }
            throw error
        }
        return RemoteEntry(id: path, path: path, name: "file", type: .file,
                           size: Int64(payload.count), etag: hasVersion ? "version-1" : nil)
    }
    func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        downloads += 1
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        savedProgress = options.phaseProgress
        do {
            while blocked { try await Task.sleep(nanoseconds: 1_000_000) }
            try Task.checkCancellation()
            if let failure { throw failure }
            let bytes = wrongSize ? Data("bad".utf8) : payload
            try bytes.write(to: destination)
            options.phaseProgress?(.init(phase: .transferring, completedBytes: Int64(bytes.count)))
            return entry
        } catch {
            if Task.isCancelled { cancelled += 1 }
            throw error
        }
    }
    func unblock() { blocked = false }
    func setStatBlocked(_ value: Bool) { statBlocked = value }
    func configure(version: Bool = true, wrongSize: Bool = false, failure: RemoteSyncError? = nil) {
        hasVersion = version; self.wrongSize = wrongSize; self.failure = failure
    }
    func lateProgress() { savedProgress?(.init(phase: .preparing)) }
}

struct TransferFixture {
    let root: URL
    let source = ControlledTransferSource()
    let binding = RemoteSourceBinding(kind: .local, identity: "fixture-session")
    var reference: RemoteFileReference { .init(source: binding, path: "/file") }
    var cache: URL { root.appendingPathComponent("cache") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TransferLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func materializer() -> RemoteFileMaterializer {
        .init(source: source, sourceBinding: binding, cacheDirectory: cache)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Condition did not become true within the test deadline")
}

@Suite struct TransferLifecycleTests {
    @Test func concurrentLeasesDoNotDeleteEachOthersFiles() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let m = f.materializer()
        let first = Task { try await m.materialize(f.reference) }
        try await eventually { await f.source.downloads == 1 }
        let second = Task { try await m.materialize(f.reference) }
        try await eventually { await f.source.stats == 2 }
        // Allow the second request to register after stat's actor hop.
        try await Task.sleep(nanoseconds: 20_000_000)
        await f.source.unblock()
        let a = try await first.value
        let b = try await second.value
        #expect(await f.source.downloads == 1)
        #expect(a.url == b.url)
        await a.release()
        #expect(FileManager.default.fileExists(atPath: b.url.path))
        await b.release()
        #expect(!FileManager.default.fileExists(atPath: b.url.path))
    }

    @Test func lastCancelledWaiterStopsUnderlyingDownload() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let m = f.materializer()
        let task = Task { try await m.materialize(f.reference) }
        try await eventually { await f.source.downloads == 1 }
        task.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await f.source.cancelled == 1)
        await f.source.unblock() // also lets the pre-fix implementation settle
        do { let lease = try await task.value; await lease.release(); Issue.record("cancelled waiter succeeded") }
        catch { #expect(error is CancellationError || (error as? RemoteSyncError) == .cancelled) }
        await m.clearPersistentCache()
    }

    @Test func entriesWithoutVersionAreNeverReused() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        await f.source.configure(version: false)
        await f.source.unblock()
        let m = f.materializer()
        let a = try await m.materialize(f.reference, options: .init(retention: .persistent))
        let b = try await m.materialize(f.reference, options: .init(retention: .persistent))
        #expect(a.url != b.url)
        #expect(await f.source.downloads == 2)
        await a.release(); await b.release(); await m.clearPersistentCache()
    }

    @Test func cancellingOneSharedWaiterLeavesTheOtherAlive() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let m = f.materializer()
        let a = Task { try await m.materialize(f.reference) }
        try await eventually { await f.source.downloads == 1 }
        let b = Task { try await m.materialize(f.reference) }
        try await eventually { await f.source.stats == 2 }
        try await Task.sleep(nanoseconds: 20_000_000)
        a.cancel()
        do { _ = try await a.value; Issue.record("cancelled waiter succeeded") } catch {}
        #expect(await f.source.cancelled == 0)
        await f.source.unblock()
        let lease = try await b.value
        #expect(try Data(contentsOf: lease.url) == Data("payload".utf8))
        await lease.release()
        await m.shutdown()
    }

    @Test func refreshDoesNotInvalidateAnExistingLease() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        await f.source.unblock()
        let m = f.materializer()
        let a = try await m.materialize(f.reference)
        let b = try await m.materialize(f.reference, options: .init(reuse: .refresh))
        #expect(a.url != b.url)
        await a.release()
        #expect(FileManager.default.fileExists(atPath: b.url.path))
        await b.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path).isEmpty)
    }

    @Test func verifySizeFailureCleansOnlyNewStaging() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        await f.source.unblock()
        let m = f.materializer()
        let a = try await m.materialize(f.reference)
        await f.source.configure(wrongSize: true)
        await #expect(throws: RemoteSyncError.integrityMismatch(path: "materialization-staging")) {
            try await m.materialize(f.reference, options: .init(reuse: .refresh))
        }
        #expect(try Data(contentsOf: a.url) == Data("payload".utf8))
        // Explicitly disabling size validation must not accidentally reuse a verified record.
        let b = try await m.materialize(f.reference, options: .init(reuse: .refresh, verifySize: false))
        #expect(try Data(contentsOf: b.url) == Data("bad".utf8))
        await a.release(); await b.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path).isEmpty)
    }

    @Test func materializerShutdownCancelsAndDrainsInitialStat() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        await f.source.setStatBlocked(true)
        let m = f.materializer()
        let pending = Task { try await m.materialize(f.reference) }
        try await eventually { await f.source.stats == 1 }
        await m.shutdown()
        #expect(await f.source.statCancelled == 1)
        #expect(await f.source.downloads == 0)
        await f.source.setStatBlocked(false) // Allows the pre-fix implementation to settle.
        do { let lease = try await pending.value; await lease.release(); Issue.record("shutdown published a lease") }
        catch { #expect(error is CancellationError || (error as? RemoteSyncError) == .cancelled) }
        #expect(!FileManager.default.fileExists(atPath: f.cache.path))
    }

    @Test func shutdownDrainsActiveAndQueuedTasksAndBlocksAdmission() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let m = f.materializer()
        let c = RemoteTransferCoordinator(materializer: m, maxConcurrentTransfers: 4)
        let a = await c.submit(.init(reference: f.reference))
        let b = await c.submit(.init(reference: .init(source: f.binding, path: "/queued")))
        try await eventually { await f.source.downloads == 1 }
        await c.shutdown()
        #expect(await f.source.active == 0)
        #expect(await f.source.downloads == 1)
        #expect(await c.snapshot(a)?.phase == .cancelled)
        #expect(await c.snapshot(b)?.phase == .cancelled)
        let next = await c.submit(.init(reference: f.reference))
        await #expect(throws: RemoteSyncError.cancelled) { try await c.wait(for: next) }
        await m.shutdown()
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path).isEmpty)
    }

    @Test func lateProgressCannotRewriteTerminalStateAndResultIsSingleTake() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        await f.source.unblock()
        let c = RemoteTransferCoordinator(materializer: f.materializer())
        let id = await c.submit(.init(reference: f.reference))
        let lease = try await c.wait(for: id)
        let before = await c.snapshot(id)
        #expect(before?.progress?.phase == .completed)
        await f.source.lateProgress()
        try await Task.sleep(nanoseconds: 5_000_000)
        #expect(await c.snapshot(id) == before)
        await #expect(throws: RemoteSyncError.conflict(path: id.uuidString)) { try await c.wait(for: id) }
        await lease.release()
        try await c.forget(id)
        #expect(await c.snapshot(id) == nil)
        await c.shutdown()
    }

    @Test func checksumMismatchCannotPublishAndUnsupportedAlgorithmFailsBeforeIO() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let m = f.materializer()
        await f.source.unblock()
        let unsupported = try RemoteContentChecksum(algorithm: .md5, digest: Data(repeating: 0, count: 16))
        await #expect(throws: RemoteSyncError.self) {
            try await m.materialize(f.reference, options: .init(expectedChecksum: unsupported))
        }
        #expect(await f.source.stats == 0)
        await f.source.unblock()
        let bad = try RemoteContentChecksum(algorithm: .sha256, digest: Data(repeating: 0, count: 32))
        await #expect(throws: RemoteSyncError.self) {
            try await m.materialize(f.reference, options: .init(expectedChecksum: bad))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.cache.path).isEmpty)
        let good = try RemoteContentChecksum(algorithm: .sha256, digest: Data(SHA256.hash(data: Data("payload".utf8))))
        let lease = try await m.materialize(f.reference, options: .init(expectedChecksum: good))
        await lease.release(); await m.shutdown()
    }

    @Test func globalLimitAppliesAcrossDifferentBindings() async throws {
        let a = try TransferFixture(); defer { a.cleanup() }
        let b = try TransferFixture(); defer { b.cleanup() }
        let bindingB = RemoteSourceBinding(kind: .local, identity: "second-session")
        let second = RemoteFileMaterializer(source: b.source, sourceBinding: bindingB, cacheDirectory: b.cache)
        let c = try RemoteTransferCoordinator(materializers: [a.materializer(), second], maxConcurrentTransfers: 1)
        let one = await c.submit(.init(reference: a.reference))
        let two = await c.submit(.init(reference: .init(source: bindingB, path: "/file")))
        try await eventually { await a.source.downloads == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await b.source.downloads == 0)
        await a.source.unblock()
        let leaseA = try await c.wait(for: one)
        try await eventually { await b.source.downloads == 1 }
        await b.source.unblock()
        let leaseB = try await c.wait(for: two)
        await leaseA.release(); await leaseB.release(); await c.shutdown()
    }

    @Test func cancelledResultObserverDoesNotCancelTheSubmittedJob() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let c = RemoteTransferCoordinator(materializer: f.materializer())
        let id = await c.submit(.init(reference: f.reference))
        let waiting = Task { try await c.wait(for: id) }
        try await eventually { await f.source.downloads == 1 }
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("cancelled observer succeeded") } catch {}
        #expect(await f.source.cancelled == 0)
        await f.source.unblock()
        let lease = try await c.wait(for: id)
        await lease.release(); await c.shutdown()
    }

    @Test func schedulerHonorsSourceLimitAndRedactsSnapshots() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        await f.source.configure(failure: .underlying("https://secret.invalid/?token=secret-value"))
        let c = RemoteTransferCoordinator(materializer: f.materializer(), maxConcurrentTransfers: 4)
        var ids: [UUID] = []
        for n in 0..<4 {
            ids.append(await c.submit(.init(reference: .init(source: f.binding, path: "/file-\(n)"))))
        }
        try await eventually { await f.source.downloads > 0 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await f.source.peak == 1)
        await f.source.unblock()
        for id in ids {
            do { let lease = try await c.wait(for: id); await lease.release(); Issue.record("failure succeeded") }
            catch {}
            let snapshot = await c.snapshot(id)
            #expect(snapshot?.errorDescription?.contains("secret-value") == false)
        }
    }
}
