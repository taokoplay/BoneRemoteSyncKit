#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveContentTypeTests {
    @Test(arguments: ["normal", "upload-refresh"])
    func explicitAndDefaultMIMEAreSentIncludingAuthReplay(scenario: String) async throws {
        let server = try OneDriveWriteServer(scenario)
        defer { server.cleanUp() }
        let source = server.source()
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data("hello".utf8))
        _ = try await source.upload(from: file, to: "/text.txt", options: .init(contentType: "text/plain; charset=utf-8"))
        let uploads = try server.requests().filter { $0["method"] as? String == "PUT" }
        #expect(uploads.count == (scenario == "normal" ? 1 : 2))
        #expect(uploads.allSatisfy { $0["contentType"] as? String == "text/plain; charset=utf-8" })
        if scenario == "upload-refresh" {
            #expect(uploads.last?["authorization"] as? String == "Bearer REFRESHED")
        }
        _ = try await source.upload(from: file, to: "/binary", options: .init())
        #expect(try server.requests().last?["contentType"] as? String == "application/octet-stream")
        await source.disconnect()
    }

    @Test(arguments: ["", "text/plain\r\nX-Header: injected", "text/\0plain", "text/\u{7f}plain", String(repeating: "x", count: 1025)])
    func invalidMIMEIsRejectedBeforeAnyAdditionalRequest(value: String) async throws {
        let server = try OneDriveWriteServer()
        defer { server.cleanUp() }
        let source = server.source()
        try await source.connect(server.credential)
        let before = try server.requests().count
        let file = try server.localFile(bytes: Data("hello".utf8))
        await #expect(throws: RemoteSyncError.unsupported(operation: "OneDrive Content-Type 无效")) {
            try await source.upload(from: file, to: "/text.txt", options: .init(contentType: value))
        }
        #expect(try server.requests().count == before)
        await source.disconnect()
    }
}
#endif
