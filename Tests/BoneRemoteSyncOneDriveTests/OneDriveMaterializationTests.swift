#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
@testable import BoneRemoteSyncOneDrive

@Suite struct OneDriveMaterializationTests {
    @Test func itemIDMaterializationUsesProviderWithoutExposingDownloadURL() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }
        let source = server.source()
        try await source.connect(server.credential)
        let binding = RemoteSourceBinding(kind: source.kind, identity: "onedrive-fixture")
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: binding,
                                                  cacheDirectory: server.workspace.appendingPathComponent("cache"))
        let coordinator = RemoteTransferCoordinator(materializer: materializer)
        let entry = try await source.stat(path: "/file")
        let reference = RemoteFileReference(source: binding, itemID: entry.id)
        let id = await coordinator.submit(.init(reference: reference))
        let lease = try await coordinator.wait(for: id)
        #expect(try Data(contentsOf: lease.url).count == 1048576)
        #expect(lease.reference == reference)
        #expect(lease.url.isFileURL)
        let cdn = try server.requests().filter { ($0["path"] as? String)?.hasPrefix("/download/") == true }
        #expect(cdn.count == 1)
        #expect(cdn.allSatisfy { $0["authorization"] is NSNull && $0["cookie"] is NSNull })
        await lease.release()
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        await coordinator.shutdown(); await materializer.shutdown(); await source.disconnect()
    }
}
#endif
