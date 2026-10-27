#if os(macOS)
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

@Suite struct OneDriveConnectionIdentityTests {
    @Test func connectionIdentityIsAvailableOnlyDuringSuccessfulConnection() async throws {
        let server = try OneDriveTestServer()
        defer { server.cleanUp() }
        let source = server.source()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.connectedDriveID() }
        try await source.connect(server.credential)
        #expect(try await source.connectedDriveID() == "D")
        #expect(try await source.list(path: "/").coverage == .complete)
        await source.disconnect()
        await #expect(throws: RemoteSyncError.notConnected) { try await source.connectedDriveID() }
        await #expect(throws: RemoteSyncError.self) { try await source.connect(.anonymous) }
        await #expect(throws: RemoteSyncError.notConnected) { try await source.connectedDriveID() }
    }
}
#endif
