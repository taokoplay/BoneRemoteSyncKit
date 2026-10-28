import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncICloud

@Suite struct ICloudDriveBatchStatusTests {
    @Test func returnsOrderedNormalizedResultsWithoutConnectingOrDownloading() async throws {
        let f = try BatchStatusFixture(); defer { f.cleanUp() }
        let probe = BatchStatusProbe()
        var environment = probe.environment(root: f.root)
        environment.itemState = { url in
            probe.recordRead(url.lastPathComponent)
            return ICloudItemState(isUbiquitous: true, downloadState: url.lastPathComponent == "a" ? .notDownloaded : .current)
        }
        let source = ICloudDriveSource(configuration: .standard, environment: environment)
        let results = try await source.statuses(paths: ["a", "/folder/../b", "/a"])
        #expect(results.map(\.path) == ["/a", "/b", "/a"])
        #expect(try results.map { try $0.result.get().downloadState } == [.notDownloaded, .current, .notDownloaded])
        #expect(try results.allSatisfy { try $0.result.get().accountIdentifierAvailable })
        #expect(probe.reads == ["a", "b", "a"])
        #expect(probe.containerLookups == 1)
        #expect(probe.downloads == 0)
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/a") }
    }

    @Test func isolatesMissingInvalidConflictAndMetadataErrors() async throws {
        let f = try BatchStatusFixture(); defer { f.cleanUp() }
        let probe = BatchStatusProbe()
        var environment = probe.environment(root: f.root)
        environment.itemState = { url in
            probe.recordRead(url.lastPathComponent)
            if url.lastPathComponent == "b" { throw RemoteSyncError.permissionDenied(path: "/b") }
            return ICloudItemState(isUbiquitous: true, downloadState: .current,
                                   hasUnresolvedConflicts: url.lastPathComponent == "conflict")
        }
        try Data().write(to: f.root.appendingPathComponent("conflict"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("escape"), withDestinationURL: f.workspace)
        let source = ICloudDriveSource(configuration: .standard, environment: environment)
        let results = try await source.statuses(paths: ["/missing", "/b", "/bad\0name", "/escape/outside", "/conflict", "/a"])
        #expect(results.count == 6)
        guard results.count == 6 else { return }
        #expect(throws: RemoteSyncError.notFound(path: "/missing")) { try results[0].result.get() }
        #expect(throws: RemoteSyncError.permissionDenied(path: "/b")) { try results[1].result.get() }
        #expect(throws: RemoteSyncError.self) { try results[2].result.get() }
        #expect(throws: RemoteSyncError.permissionDenied(path: "/escape/outside")) { try results[3].result.get() }
        #expect(throws: ICloudDriveError.unresolvedConflict(path: "/conflict")) { try results[4].result.get() }
        #expect(try results[5].result.get().downloadState == .current)
        #expect(probe.reads == ["b", "conflict", "a"])
        #expect(probe.downloads == 0)
    }

    @Test func hardlinksAreReadableAndInternalSymlinksStayWithinRoot() async throws {
        let f = try BatchStatusFixture(); defer { f.cleanUp() }
        let probe = BatchStatusProbe()
        var environment = probe.environment(root: f.root)
        environment.itemState = { url in
            probe.recordRead(url.lastPathComponent)
            return ICloudItemState(isUbiquitous: false)
        }
        try FileManager.default.linkItem(at: f.root.appendingPathComponent("a"), to: f.root.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("inside"), withDestinationURL: f.root.appendingPathComponent("a"))
        let source = ICloudDriveSource(configuration: .standard, environment: environment)
        let results = try await source.statuses(paths: ["/hardlink", "/inside"])
        #expect(results.count == 2)
        #expect(try results.allSatisfy { try $0.result.get().isAvailable })
        #expect(probe.reads.count == 2)
        #expect(probe.downloads == 0)
    }

    @Test func unavailableRootsReturnReasonsWithoutCreatingOrReadingItems() async throws {
        let f = try BatchStatusFixture(); defer { f.cleanUp() }
        let probe = BatchStatusProbe()
        var environment = probe.environment(root: f.root)
        environment.identityToken = { nil }
        let signedOut = ICloudDriveSource(configuration: .standard, environment: environment)
        let out = try await signedOut.statuses(paths: ["/a", "/b"])
        #expect(out.count == 2)
        #expect(try out.allSatisfy { try $0.result.get().unavailableReason == .notSignedIn })
        #expect(probe.containerLookups == 0)

        environment = probe.environment(root: f.root)
        environment.containerURL = { id in id == nil ? f.root : nil }
        let named = ICloudDriveSource(configuration: try .init(containerIdentifier: "iCloud.missing"), environment: environment)
        #expect(try await named.statuses(paths: ["/a"]).first?.result.get().unavailableReason == .containerNotFound)
        environment.containerURL = { _ in nil }
        let unavailable = ICloudDriveSource(configuration: .standard, environment: environment)
        #expect(try await unavailable.statuses(paths: ["/a"]).first?.result.get().unavailableReason == .driveUnavailable)

        let missing = ICloudDriveSource(configuration: try .init(directoryPath: "/Documents/Backup"), rootURL: f.root, environment: environment)
        #expect(try await missing.statuses(paths: ["/a"]).first?.result.get().unavailableReason == .directoryNotFound)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Documents").path))
        #expect(probe.reads.isEmpty)
        #expect(probe.downloads == 0)
    }

    @Test func emptyInputDoesNotQueryEnvironment() async throws {
        let f = try BatchStatusFixture(); defer { f.cleanUp() }
        let probe = BatchStatusProbe()
        let source = ICloudDriveSource(configuration: .standard, environment: probe.environment(root: f.root))
        #expect(try await source.statuses(paths: []).isEmpty)
        #expect(probe.containerLookups == 0 && probe.reads.isEmpty)
    }

    @Test(arguments: [false, true])
    func accountChangeDuringReadDiscardsTheWholeBatch(signOut: Bool) async throws {
        let f = try BatchStatusFixture(); defer { f.cleanUp() }
        let probe = BatchStatusProbe()
        var environment = probe.environment(root: f.root)
        environment.itemState = { url in
            probe.recordRead(url.lastPathComponent)
            if url.lastPathComponent == "b" { probe.setIdentity(signOut ? nil : "new-account") }
            return ICloudItemState(isUbiquitous: true, downloadState: .current)
        }
        let source = ICloudDriveSource(configuration: .standard, environment: environment)
        await #expect(throws: ICloudDriveError.accountChanged) {
            try await source.statuses(paths: ["/a", "/b", "/a"])
        }
        #expect(probe.reads == ["a", "b"])
    }

    @Test func cancellationDuringLastMetadataReadDoesNotReturnResults() async throws {
        let f = try BatchStatusFixture(); defer { f.cleanUp() }
        let gate = BatchStatusGate(); defer { gate.release() }
        let probe = BatchStatusProbe()
        var environment = probe.environment(root: f.root)
        environment.itemState = { _ in gate.block(); return ICloudItemState() }
        let source = ICloudDriveSource(configuration: .standard, environment: environment)
        let task = Task { try await source.statuses(paths: ["/a"]) }
        try await gate.waitForEntry()
        task.cancel()
        gate.release()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
    }

    @Test func disconnectDiscardsInFlightBatchButDoesNotPreventFreshQueries() async throws {
        let f = try BatchStatusFixture(); defer { f.cleanUp() }
        let gate = BatchStatusGate(); defer { gate.release() }
        let probe = BatchStatusProbe()
        var environment = probe.environment(root: f.root)
        environment.itemState = { _ in gate.block(); return ICloudItemState() }
        let source = ICloudDriveSource(configuration: .standard, environment: environment)
        try await source.connect(.anonymous)
        let task = Task { try await source.statuses(paths: ["/a"]) }
        try await gate.waitForEntry()
        await source.disconnect()
        gate.release()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try await source.statuses(paths: ["/b"]).first?.result.get().isAvailable == true)
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/a") }
    }
}

private struct BatchStatusFixture: Sendable {
    let workspace: URL
    let root: URL
    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudBatch-\(UUID())")
        root = workspace.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        try Data("private".utf8).write(to: workspace.appendingPathComponent("outside"))
    }
    func cleanUp() { try? FileManager.default.removeItem(at: workspace) }
}

private final class BatchStatusProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: String? = "account"
    private var names: [String] = []
    private var lookups = 0
    private var requests = 0
    var reads: [String] { lock.withLock { names } }
    var containerLookups: Int { lock.withLock { lookups } }
    var downloads: Int { lock.withLock { requests } }
    func recordRead(_ name: String) { lock.withLock { names.append(name) } }
    func setIdentity(_ value: String?) { lock.withLock { identity = value } }
    func environment(root: URL) -> ICloudDriveEnvironment {
        .init(identityToken: { self.lock.withLock { self.identity.map { NSString(string: $0) } } },
              containerURL: { _ in self.lock.withLock { self.lookups += 1 }; return root },
              itemState: { url in self.recordRead(url.lastPathComponent); return ICloudItemState() },
              startDownloading: { _ in self.lock.withLock { self.requests += 1 } })
    }
}

private final class BatchStatusGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var released = false
    func block() {
        let shouldWait = lock.withLock { entered = true; return !released }
        if shouldWait { _ = semaphore.wait(timeout: .now() + 5) }
    }
    func release() {
        lock.withLock {
            if !released { released = true; semaphore.signal() }
        }
    }
    func waitForEntry() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !lock.withLock({ entered }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RemoteSyncError.network("metadata gate not reached") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
