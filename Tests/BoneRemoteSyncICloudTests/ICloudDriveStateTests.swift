import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncICloud

@Suite struct ICloudDriveStateTests {
    @Test func hydrationRequestsDownloadOnceAndWaitsForCurrentVersion() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .downloaded)
        let source = f.source(cloud)
        try await source.connect(.anonymous)
        let task = Task { try await source.download(path: "/file", to: f.output) }
        try await cloud.waitForStart()
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
        cloud.set(.current)
        _ = try await task.value
        #expect(cloud.requests == 1)
        #expect(try Data(contentsOf: f.output) == Data("source".utf8))
    }

    @Test func hydrationTimeoutDoesNotInstallDestination() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .notDownloaded)
        let source = f.source(cloud, timeout: 0.03)
        try await source.connect(.anonymous)
        await #expect(throws: ICloudDriveError.downloadTimedOut(path: "/file").remoteSyncError) {
            try await source.download(path: "/file", to: f.output)
        }
        #expect(cloud.requests == 1)
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }

    @Test func disconnectCancelsHydrationWithoutInstallingOldSession() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .notDownloaded)
        let source = f.source(cloud)
        try await source.connect(.anonymous)
        let task = Task { try await source.download(path: "/file", to: f.output) }
        try await cloud.waitForStart()
        await source.disconnect()
        try await source.connect(.anonymous)
        cloud.set(.current)
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }

    @Test func cancelledHydrationReturnsSharedCancellationError() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .notDownloaded)
        let source = f.source(cloud)
        try await source.connect(.anonymous)
        let task = Task { try await source.download(path: "/file", to: f.output) }
        try await cloud.waitForStart()
        task.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
    }

    @Test func unresolvedConflictsBlockReadAndMutationAndMakeListingPartial() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .current, conflict: true)
        let source = f.source(cloud)
        try await source.connect(.anonymous)
        let page = try await source.list(path: "/")
        #expect(page.coverage == .partial)
        #expect(page.entries.isEmpty)
        await #expect(throws: RemoteSyncError.conflict(path: "/file")) { try await source.stat(path: "/file") }
        await #expect(throws: RemoteSyncError.conflict(path: "/file")) { try await source.remove(path: "/file") }
        await #expect(throws: RemoteSyncError.conflict(path: "/file")) { try await source.upload(from: f.input, to: "/file") }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("file")) == Data("source".utf8))
    }

    @Test func resumeValidatesPartLengthOffsetAndETag() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source()
        try await source.connect(.anonymous)
        let part = f.output.appendingPathExtension("part")
        let entry = try await source.stat(path: "/file")
        try Data("sou".utf8).write(to: part)
        _ = try await source.download(entry, to: f.output, options: .init(resumeFrom: 3, expectedETag: entry.etag))
        #expect(try Data(contentsOf: f.output) == Data("source".utf8))
        try Data("so".utf8).write(to: part)
        await #expect(throws: RemoteSyncError.conflict(path: part.path)) {
            try await source.download(entry, to: f.output, options: .init(resumeFrom: 3))
        }
        await #expect(throws: RemoteSyncError.self) {
            try await source.download(entry, to: f.output, options: .init(resumeFrom: -1))
        }
        await #expect(throws: RemoteSyncError.conflict(path: "/file")) {
            try await source.download(entry, to: f.output, options: .init(expectedETag: "wrong"))
        }
    }

    @Test func nonOverwriteRejectsExistingFileAndLeavesContents() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source()
        try await source.connect(.anonymous)
        try Data("keep".utf8).write(to: f.output)
        await #expect(throws: RemoteSyncError.self) {
            try await source.download(path: "/file", to: f.output, options: .init(overwrite: false))
        }
        await #expect(throws: RemoteSyncError.conflict(path: "/file")) {
            try await source.upload(from: f.input, to: "/file", options: .init(overwrite: false))
        }
        #expect(try Data(contentsOf: f.output) == Data("keep".utf8))
    }

    @Test func hardlinkedPartIsRejectedWithoutChangingSource() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source()
        try await source.connect(.anonymous)
        let part = f.output.appendingPathExtension("part")
        try FileManager.default.linkItem(at: f.root.appendingPathComponent("file"), to: part)
        await #expect(throws: RemoteSyncError.conflict(path: part.path)) {
            try await source.download(path: "/file", to: f.output)
        }
        #expect(try Data(contentsOf: part) == Data("source".utf8))
    }

    @Test func legacyPlaceholderMakesDefaultListingPartial() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        try Data().write(to: f.root.appendingPathComponent(".missing.txt.icloud"))
        let source = f.source()
        try await source.connect(.anonymous)
        let page = try await source.list(path: "/")
        #expect(page.coverage == .partial)
        #expect(page.entries.map(\.name) == ["file"])
    }

    @Test func statusReportsInjectedDownloadStateWithoutFakeAccountIdentity() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source(SimulatedUbiquitousItem(state: .downloading))
        let status = await source.status(path: "/file")
        #expect(status.downloadState == .downloading)
        #expect(status.isUbiquitous)
        #expect(!status.accountIdentifierAvailable)
        #expect(status.percentDownloaded == nil)
    }

    @Test func missingRootAndDisconnectedOperationsFailWithoutCreation() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/file") }
        let missing = ICloudDriveSource(configuration: try .init(directoryPath: "/missing"), rootURL: f.root)
        await #expect(throws: RemoteSyncError.notFound(path: "/missing")) { try await missing.connect(.anonymous) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("missing").path))
    }

    @Test func conditionalUploadIsRejectedWithoutLocalCommit() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source(); try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.self) {
            try await source.upload(from: f.input, to: "/file", options: .init(expectedETag: "v1"))
        }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("file")) == Data("source".utf8))
    }

    @Test func configurationRoundTripsAndErrorsMapToCoreVocabulary() throws {
        let config = try ICloudDriveConfiguration(containerIdentifier: "iCloud.example.app", directoryPath: "/Documents")
        #expect(try JSONDecoder().decode(ICloudDriveConfiguration.self, from: JSONEncoder().encode(config)) == config)
        #expect(ICloudDriveError.unresolvedConflict(path: "/f").remoteSyncError == .conflict(path: "/f"))
        #expect(ICloudDriveError.coordinationFailed(path: "/f").remoteSyncError == .conflict(path: "/f"))
        #expect(ICloudDriveError.unavailable.remoteSyncError == .network("iCloud Drive 当前不可用"))
        #expect(!ICloudDriveStatus(availability: .unavailable).isAvailable)
    }
}

private struct ICloudStateFixture {
    let workspace: URL
    let root: URL
    let input: URL
    let output: URL
    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudState-\(UUID())")
        root = workspace.appendingPathComponent("container")
        input = workspace.appendingPathComponent("input")
        output = workspace.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: root.appendingPathComponent("file"))
        try Data("input".utf8).write(to: input)
    }
    func source(_ cloud: SimulatedUbiquitousItem? = nil, timeout: Double = 2) -> ICloudDriveSource {
        ICloudDriveSource(configuration: try! .init(downloadTimeout: timeout, pollInterval: 0.005), rootURL: root,
                          environment: cloud?.environment ?? .system)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: workspace) }
}

private final class SimulatedUbiquitousItem: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ICloudDriveDownloadState
    private let conflict: Bool
    private var count = 0
    init(state: ICloudDriveDownloadState, conflict: Bool = false) { self.state = state; self.conflict = conflict }
    func set(_ state: ICloudDriveDownloadState) { lock.withLock { self.state = state } }
    var requests: Int { lock.withLock { count } }
    var environment: ICloudDriveEnvironment {
        .init(itemState: { _ in self.lock.withLock {
            ICloudItemState(isUbiquitous: true, downloadState: self.state, hasUnresolvedConflicts: self.conflict)
        } }, startDownloading: { _ in self.lock.withLock { self.count += 1 } })
    }
    func waitForStart() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while requests == 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RemoteSyncError.network("test download did not start") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
