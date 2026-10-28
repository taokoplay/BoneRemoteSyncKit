import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer

/// Deterministic provider seam for the generic wrapper's lifetime, not a network fixture.
private struct RecoveryLifetimeSource: RemoteResumableDownloadSource {
    enum Outcome: String, CaseIterable, Sendable {
        case failed, cancelled, committed, committedCleanupPending
    }
    let outcome: Outcome
    let kind = RemoteSourceKind.webdav
    let capabilities = RemoteCapabilities()
    func connect(_ credential: RemoteCredential) async throws {}
    func disconnect() async {}
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        throw RemoteSyncError.unsupported(operation: "unused fixture method")
    }
    func stat(path: String) async throws -> RemoteEntry {
        throw RemoteSyncError.unsupported(operation: "unused fixture method")
    }
    func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        throw RemoteSyncError.unsupported(operation: "unused fixture method")
    }
    func validateResumableDownload(_ reference: RemoteFileReference, options: RemoteResumableDownloadOptions) throws {}
    private func failIfNeeded() throws {
        switch outcome {
        case .failed: throw RemoteSyncError.integrityMismatch(path: "fixture")
        case .cancelled:
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        case .committed, .committedCleanupPending: break
        }
    }
    func downloadResuming(_ reference: RemoteFileReference, to destination: URL,
                          options: RemoteResumableDownloadOptions) async throws -> RemoteResumableDownloadResult {
        try failIfNeeded()
        try Data("committed".utf8).write(to: destination)
        // The provider has crossed its commit point when cancellation arrives.
        withUnsafeCurrentTask { $0?.cancel() }
        let entry = RemoteEntry(id: "file", path: "/file", name: "file", type: .file, size: 9)
        return .init(entry: entry, state: outcome == .committed ? .committed : .committedCleanupPending)
    }
    func downloadCheckpoint(_ reference: RemoteFileReference, destination: URL) async throws -> RemoteDownloadCheckpoint? {
        try failIfNeeded()
        return nil
    }
}

@Suite struct DownloadRecoveryLifecycleTests {
    @Test(arguments: RecoveryLifetimeSource.Outcome.allCases)
    fileprivate func downloadReleasesLockAndPreservesCommitOutcome(outcome: RecoveryLifetimeSource.Outcome) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locks = LocalDownloadDestinationLocks(directory: root.appendingPathComponent("locks"))
        let binding = RemoteSourceBinding(kind: .webdav, identity: "fixture")
        let reference = RemoteFileReference(source: binding, path: "/file")
        let destination = root.appendingPathComponent("output")
        let service = RemoteDownloadRecovery(source: RecoveryLifetimeSource(outcome: outcome),
            binding: binding, destinationLocks: locks)
        let task = Task { try await service.download(reference, to: destination) }
        switch outcome {
        case .failed:
            await #expect(throws: RemoteSyncError.integrityMismatch(path: "fixture")) { try await task.value }
        case .cancelled:
            await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        case .committed, .committedCleanupPending:
            let result = try await task.value
            #expect(result.state == (outcome == .committed ? .committed : .committedCleanupPending))
            #expect(try Data(contentsOf: destination) == Data("committed".utf8))
        }
        // A distinct owner must acquire immediately after either success or failure.
        let next = try await LocalDownloadDestinationLocks(directory: locks.directory).acquire(destination: destination)
        await next.release()
    }

    @Test(arguments: [RecoveryLifetimeSource.Outcome.failed, .cancelled])
    fileprivate func checkpointFailureReleasesLock(outcome: RecoveryLifetimeSource.Outcome) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locks = LocalDownloadDestinationLocks(directory: root.appendingPathComponent("locks"))
        let binding = RemoteSourceBinding(kind: .webdav, identity: "fixture")
        let reference = RemoteFileReference(source: binding, path: "/file")
        let destination = root.appendingPathComponent("output")
        let service = RemoteDownloadRecovery(source: RecoveryLifetimeSource(outcome: outcome),
            binding: binding, destinationLocks: locks)
        let task = Task { try await service.checkpoint(reference, destination: destination) }
        let expected: RemoteSyncError = outcome == .failed ? .integrityMismatch(path: "fixture") : .cancelled
        await #expect(throws: expected) { try await task.value }
        let next = try await LocalDownloadDestinationLocks(directory: locks.directory).acquire(destination: destination)
        await next.release()
    }
}
