import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
@testable import BoneRemoteSyncICloud

/// Local seam only: this does not exercise Apple account, hydration or cloud propagation.
@Suite struct ICloudMaterializationTests {
    @Test func localContainerSeamMaterializesThroughCoordinator() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudTransfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("icloud-seam".utf8).write(to: root.appendingPathComponent("file"))
        let source = ICloudDriveSource(configuration: try .init(directoryPath: "/"), rootURL: root)
        try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .iCloud, identity: "local-container-seam")
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding,
                                                  cacheDirectory: workspace.appendingPathComponent("cache"))
        let coordinator = RemoteTransferCoordinator(materializer: materializer, maxConcurrentTransfers: 4)
        let id = await coordinator.submit(.init(reference: .init(source: binding, path: "/file")))
        let lease = try await coordinator.wait(for: id)
        #expect(try Data(contentsOf: lease.url) == Data("icloud-seam".utf8))
        #expect(await coordinator.snapshot(id)?.phase == .completed)
        #expect(materializer.maxConcurrentTransfers == 1)
        await lease.release()
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        await coordinator.shutdown(); await materializer.shutdown(); await source.disconnect()
    }
}
