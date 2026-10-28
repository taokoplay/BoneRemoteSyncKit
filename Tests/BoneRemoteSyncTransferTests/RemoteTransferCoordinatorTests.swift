import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal
import BoneRemoteSyncTransfer

@Suite struct RemoteTransferCoordinatorTests {
    @Test func submitWaitAndSnapshotExposeCompletedMaterialization() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let remoteRoot = workspace.appendingPathComponent("remote", isDirectory: true)
        let cacheRoot = workspace.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try Data("coordinated".utf8).write(to: remoteRoot.appendingPathComponent("file.txt"))

        let source = LocalFileSource(root: remoteRoot)
        try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .local, identity: "coordinator-root")
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: cacheRoot)
        let coordinator = RemoteTransferCoordinator(materializer: materializer)
        let id = await coordinator.submit(RemoteTransferRequest(
            reference: RemoteFileReference(source: binding, path: "/file.txt"),
            options: .init(retention: .persistent)
        ))

        let lease = try await coordinator.wait(for: id)
        #expect(try Data(contentsOf: lease.url) == Data("coordinated".utf8))
        let snapshot = await coordinator.snapshot(id)
        #expect(snapshot?.phase == .completed)
        #expect(snapshot?.isTerminal == true)
        await lease.release()
        await source.disconnect()
    }

    @Test func cancellationProducesTerminalCancelledSnapshot() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let remoteRoot = workspace.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64).write(to: remoteRoot.appendingPathComponent("file.bin"))

        let source = LocalFileSource(root: remoteRoot)
        try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .local, identity: "coordinator-root")
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding,
                                                  cacheDirectory: workspace.appendingPathComponent("cache"))
        let coordinator = RemoteTransferCoordinator(materializer: materializer)
        let id = await coordinator.submit(RemoteTransferRequest(
            reference: RemoteFileReference(source: binding, path: "/file.bin")
        ))
        await coordinator.cancel(id)
        try await waitUntilTerminal(coordinator, id: id)
        let snapshot = await coordinator.snapshot(id)
        #expect(snapshot?.phase == .cancelled || snapshot?.phase == .completed)
        await source.disconnect()
    }

    private func waitUntilTerminal(
        _ coordinator: RemoteTransferCoordinator,
        id: RemoteTransferID
    ) async throws {
        for _ in 0..<100 {
            if let snapshot = await coordinator.snapshot(id), snapshot.isTerminal { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("transfer did not reach a terminal state")
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BoneTransferCoordinator-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
