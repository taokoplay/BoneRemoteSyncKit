import Foundation
import Darwin
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

    @Test func hydrationReportsPreparationAndTransferPhases() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .notDownloaded)
        let source = f.source(cloud)
        let events = ICloudProgressProbe()
        try await source.connect(.anonymous)
        let task = Task {
            try await source.download(path: "/file", to: f.output, options: .init(phaseProgress: { event in
                events.append(event)
            }))
        }
        try await cloud.waitForStart()
        try await events.waitForPreparation(.notStarted)
        cloud.set(.downloading)
        try await events.waitForPreparation(.inProgress)
        cloud.set(.current)
        _ = try await task.value
        let snapshot = events.values
        #expect(snapshot.last?.phase == .transferring)
        #expect(snapshot.last?.fractionCompleted == 1)
        #expect(snapshot.contains { $0.phase == .preparing && $0.preparationState == .ready })
    }

    @Test func hydrationTimeoutDoesNotInstallDestination() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .notDownloaded)
        let source = f.source(cloud, timeout: 0.03)
        try await source.connect(.anonymous)
        await #expect(throws: ICloudDriveError.downloadTimedOut(path: "/file")) {
            try await source.download(path: "/file", to: f.output)
        }
        #expect(cloud.requests == 1)
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }

    @Test func hydrationTimeoutPreservesTypedICloudError() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .notDownloaded)
        let source = f.source(cloud, timeout: 0.03)
        try await source.connect(.anonymous)

        do {
            try await source.download(path: "/file", to: f.output)
            Issue.record("expected iCloud hydration to time out")
        } catch let error as ICloudDriveError {
            #expect(error == .downloadTimedOut(path: "/file"))
        } catch {
            Issue.record("expected ICloudDriveError, got: \(error)")
        }
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
        await #expect(throws: ICloudDriveError.unresolvedConflict(path: "/file")) { try await source.stat(path: "/file") }
        await #expect(throws: ICloudDriveError.unresolvedConflict(path: "/file")) { try await source.remove(path: "/file") }
        await #expect(throws: ICloudDriveError.unresolvedConflict(path: "/file")) { try await source.upload(from: f.input, to: "/file") }
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

    @Test func decodedStatusKeepsAvailabilityReasonInvariant() throws {
        let available = Data(#"{"availability":"available","unavailableReason":"driveUnavailable","accountIdentifierAvailable":false,"isUbiquitous":false}"#.utf8)
        let unavailable = Data(#"{"availability":"unavailable","accountIdentifierAvailable":false,"isUbiquitous":false}"#.utf8)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ICloudDriveStatus.self, from: available).unavailableReason == nil)
        #expect(try decoder.decode(ICloudDriveStatus.self, from: unavailable).unavailableReason == .unknown)
        let status = ICloudDriveStatus(availability: .unavailable, unavailableReason: .directoryNotFound)
        #expect(try decoder.decode(ICloudDriveStatus.self, from: JSONEncoder().encode(status)) == status)
    }

    @Test func missingRootAndDisconnectedOperationsFailWithoutCreation() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.stat(path: "/file") }
        let missing = ICloudDriveSource(configuration: try .init(directoryPath: "/missing"), rootURL: f.root)
        await #expect(throws: ICloudDriveError.directoryNotFound(path: "/missing")) { try await missing.connect(.anonymous) }
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

    @Test func accountAndServiceFailuresAreStructuredWithoutSideEffects() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        var environment = ICloudDriveEnvironment.system
        environment.identityToken = { nil }
        environment.containerURL = { _ in f.root }
        let signedOut = ICloudDriveSource(configuration: .standard, environment: environment)
        #expect(await signedOut.status().unavailableReason == .notSignedIn)
        await #expect(throws: ICloudDriveError.accountNotSignedIn) { try await signedOut.connect(.anonymous) }

        environment.identityToken = { NSString(string: "account") }
        environment.containerURL = { _ in nil }
        let unavailable = ICloudDriveSource(configuration: .standard, environment: environment)
        #expect(await unavailable.status().unavailableReason == .driveUnavailable)
        await #expect(throws: ICloudDriveError.driveUnavailable) { try await unavailable.connect(.anonymous) }
    }

    @Test func unavailableNamedContainerDoesNotHideAccessibleDefaultContainer() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        var environment = ICloudDriveEnvironment.system
        environment.identityToken = { NSString(string: "account") }
        environment.containerURL = { identifier in identifier == nil ? f.root : nil }
        let source = ICloudDriveSource(configuration: try .init(containerIdentifier: "iCloud.missing"), environment: environment)
        #expect(await source.status().unavailableReason == .containerNotFound)
        await #expect(throws: ICloudDriveError.containerNotFound(identifier: "iCloud.missing")) {
            try await source.connect(.anonymous)
        }
    }

    @Test func missingConfiguredDirectoryIsReportedByStatusAndConnection() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = ICloudDriveSource(configuration: try .init(directoryPath: "/Documents/Backup"), rootURL: f.root)
        #expect(await source.status().unavailableReason == .directoryNotFound)
        await #expect(throws: ICloudDriveError.directoryNotFound(path: "/Documents/Backup")) {
            try await source.connect(.anonymous)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Documents").path))
    }

    @Test func deletingConfiguredRootAfterConnectionKeepsDirectoryErrorTyped() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source()
        try await source.connect(.anonymous)
        try FileManager.default.removeItem(at: f.root)
        #expect(await source.status().unavailableReason == .directoryNotFound)
        await #expect(throws: ICloudDriveError.directoryNotFound(path: "/")) {
            try await source.list(path: "/")
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.path))
    }

    @Test(arguments: [false, true])
    func accountChangeDuringHydrationStopsOldSession(signOut: Bool) async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let identity = ICloudIdentityProbe()
        let cloud = SimulatedUbiquitousItem(state: .notDownloaded)
        var environment = cloud.environment
        environment.identityToken = { identity.token }
        environment.containerURL = { _ in f.root }
        let source = ICloudDriveSource(configuration: try .init(pollInterval: 0.005), environment: environment)
        try await source.connect(.anonymous)
        let progress = ICloudProgressProbe()
        let task = Task {
            try await source.download(path: "/file", to: f.output, options: .init(phaseProgress: { progress.append($0) }))
        }
        try await progress.waitForPreparation(.notStarted)
        identity.set(signOut ? nil : "other")
        cloud.set(.current)
        await #expect(throws: ICloudDriveError.accountChanged) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
        #expect(!progress.values.contains { $0.phase == .transferring })
        await source.disconnect()
        if !signOut {
            try await source.connect(.anonymous)
            _ = try await source.download(path: "/file", to: f.output)
            #expect(try Data(contentsOf: f.output) == Data("source".utf8))
        }
    }

    @Test(.enabled(if: geteuid() != 0, "Requires non-root permission enforcement"))
    func inaccessibleConfiguredRootIsNotMisreportedAsMissing() async throws {
        let f = try ICloudStateFixture()
        defer { _ = chmod(f.root.path, 0o700); f.cleanUp() }
        let backup = f.root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        let config = try ICloudDriveConfiguration(directoryPath: "/Backup")
        let connected = ICloudDriveSource(configuration: config, rootURL: f.root)
        try await connected.connect(.anonymous)
        #expect(chmod(f.root.path, 0) == 0)
        // The non-root test process cannot search the container, though Backup still exists.
        let fresh = ICloudDriveSource(configuration: config, rootURL: f.root)
        #expect(await fresh.status().unavailableReason == .unknown)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/Backup")) {
            try await fresh.connect(.anonymous)
        }
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/Backup")) {
            try await connected.list(path: "/")
        }
    }

    @Test(arguments: [false, true])
    func accountChangeInsideMetadataReadCannotReportReady(signOut: Bool) async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let identity = ICloudIdentityProbe()
        let progress = ICloudProgressProbe()
        var environment = ICloudDriveEnvironment.system
        environment.identityToken = { identity.token }
        environment.containerURL = { _ in f.root }
        environment.itemState = { _ in
            // Deterministically models an account change after the pre-read identity gate.
            identity.set(signOut ? nil : "other")
            return ICloudItemState(isUbiquitous: true, downloadState: .current, hasUnresolvedConflicts: false)
        }
        let source = ICloudDriveSource(configuration: .standard, environment: environment)
        try await source.connect(.anonymous)
        let entry = RemoteEntry(id: "file", path: "/file", name: "file", type: .file)
        await #expect(throws: ICloudDriveError.accountChanged) {
            try await source.download(entry, to: f.output, options: .init(phaseProgress: { progress.append($0) }))
        }
        #expect(progress.values.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
        #expect(!FileManager.default.fileExists(atPath: f.output.appendingPathExtension("part").path))
    }

    @Test func repeatedPreparationSnapshotsAreDeduplicatedUntilTimeout() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let source = f.source(SimulatedUbiquitousItem(state: .unknown), timeout: 0.04)
        let progress = ICloudProgressProbe()
        try await source.connect(.anonymous)
        await #expect(throws: ICloudDriveError.downloadTimedOut(path: "/file")) {
            try await source.download(path: "/file", to: f.output, options: .init(phaseProgress: { progress.append($0) }))
        }
        #expect(progress.values == [RemoteDownloadProgress(phase: .preparing, preparationState: .unknown)])
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }

    @Test(arguments: [false, true])
    func localOrCurrentFilesSkipHydrationAndReportEmptyTransfer(ubiquitous: Bool) async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        try Data().write(to: f.root.appendingPathComponent("file"))
        let cloud = SimulatedUbiquitousItem(state: .current)
        let source = f.source(ubiquitous ? cloud : nil)
        let progress = ICloudProgressProbe()
        try await source.connect(.anonymous)
        _ = try await source.download(path: "/file", to: f.output, options: .init(phaseProgress: { progress.append($0) }))
        #expect(cloud.requests == 0)
        #expect(progress.values.filter { $0.phase == .preparing }.map(\.preparationState) == (ubiquitous ? [.ready] : []))
        #expect(progress.values.last?.phase == .transferring)
        #expect(progress.values.last?.completedBytes == 0)
        #expect(progress.values.last?.totalBytes == 0)
        #expect(progress.values.last?.fractionCompleted == nil)
        #expect(try Data(contentsOf: f.output).isEmpty)
    }

    @Test func cancelPreparationCannotEmitTransferOrInstallTarget() async throws {
        let f = try ICloudStateFixture(); defer { f.cleanUp() }
        let cloud = SimulatedUbiquitousItem(state: .notDownloaded)
        let source = f.source(cloud)
        let progress = ICloudProgressProbe()
        try await source.connect(.anonymous)
        let task = Task {
            try await source.download(path: "/file", to: f.output, options: .init(phaseProgress: { progress.append($0) }))
        }
        try await progress.waitForPreparation(.notStarted)
        task.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        let terminalEvents = progress.values
        cloud.set(.current)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(progress.values == terminalEvents)
        #expect(!terminalEvents.contains { $0.phase == .transferring })
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
        #expect(!FileManager.default.fileExists(atPath: f.output.appendingPathExtension("part").path))
    }

    @Test func configurationRoundTripsAndErrorsMapToCoreVocabulary() throws {
        let config = try ICloudDriveConfiguration(containerIdentifier: "iCloud.example.app", directoryPath: "/Documents")
        #expect(try JSONDecoder().decode(ICloudDriveConfiguration.self, from: JSONEncoder().encode(config)) == config)
        #expect(ICloudDriveError.unresolvedConflict(path: "/f").remoteSyncError == .conflict(path: "/f"))
        #expect(ICloudDriveError.coordinationFailed(path: "/f").remoteSyncError == .conflict(path: "/f"))
        #expect(ICloudDriveError.accountNotSignedIn.remoteSyncError == .authenticationFailed(reason: ICloudDriveError.accountNotSignedIn.description))
        #expect(ICloudDriveError.directoryNotFound(path: "/Documents/Backup").remoteSyncError == .notFound(path: "/Documents/Backup"))
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

private final class ICloudProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RemoteDownloadProgress] = []
    func append(_ event: RemoteDownloadProgress) { lock.withLock { events.append(event) } }
    var values: [RemoteDownloadProgress] { lock.withLock { events } }

    func waitForPreparation(_ state: RemoteDownloadPreparationState) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !values.contains(where: { $0.preparationState == state }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw RemoteSyncError.network("test preparation state did not arrive: \(state)")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class ICloudIdentityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "account"
    func set(_ value: String?) { lock.withLock { self.value = value } }
    var token: NSObject? { lock.withLock { value.map { NSString(string: $0) } } }
}
