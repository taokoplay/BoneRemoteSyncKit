#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

@Suite struct OneDriveExpectedVersionTests {
    @Test func unsupportedConditionalUploadDoesNotSendRequests() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let source = server.source(); try await source.connect(server.credential)
        let count = try server.requests().count
        let input = try server.localFile(bytes: Data("x".utf8))
        await #expect(throws: RemoteSyncError.self) {
            try await source.upload(from: input, to: "/new", options: .init(expectedETag: "\"v1\""))
        }
        #expect(try server.requests().count == count)
        await source.disconnect()
    }
}
#endif
