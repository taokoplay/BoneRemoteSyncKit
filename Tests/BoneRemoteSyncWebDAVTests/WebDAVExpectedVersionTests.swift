#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVExpectedVersionTests {
    @Test func staleCallerVersionCannotOverwritePreflightVersion() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let original = try await source.stat(path: "/hello.txt")
        let versionA = try #require(original.etag)
        try Data("newer remote version".utf8).write(to: server.file("input"))
        let versionB = try await source.upload(from: server.file("input"), to: "/hello.txt")
        #expect(versionB.etag != versionA)
        try Data("stale edit".utf8).write(to: server.file("input"))
        await #expect(throws: RemoteSyncError.conflict(path: "/hello.txt")) {
            try await source.upload(from: server.file("input"), to: "/hello.txt", options: .init(expectedETag: versionA))
        }
        #expect(try await source.stat(path: "/hello.txt").etag == versionB.etag)
        await source.disconnect()
    }

    @Test func matchingVersionIsSentUnchangedToConditionalPUT() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let version = try #require(try await source.stat(path: "/hello.txt").etag)
        try Data("edited".utf8).write(to: server.file("input"))
        let result = try await source.upload(from: server.file("input"), to: "/hello.txt", options: .init(expectedETag: version))
        #expect(result.size == 6)
        #expect(try server.requests().last?["ifMatch"] as? String == version)
        await source.disconnect()
    }

    @Test func invalidConditionsNeverSendPUT() async throws {
        let server = try WebDAVTestServer(fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        try Data("x".utf8).write(to: server.file("input"))
        for value in ["", "*", "W/\"weak\"", "\"v\"\r\nX: injected", "unquoted"] {
            await #expect(throws: RemoteSyncError.self) {
                try await source.upload(from: server.file("input"), to: "/hello.txt", options: .init(expectedETag: value))
            }
        }
        await #expect(throws: RemoteSyncError.self) {
            try await source.upload(from: server.file("input"), to: "/new", options: .init(overwrite: false, expectedETag: "\"v\""))
        }
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "PUT" })
        await source.disconnect()
    }

    @Test func matchingPreflightDoesNotBypassServerSideRaceOrCreateMissingTarget() async throws {
        let server = try WebDAVTestServer(root: "put-race", fixture: "write_server"); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let version = try #require(try await source.stat(path: "/hello.txt").etag)
        try Data("x".utf8).write(to: server.file("input"))
        await #expect(throws: RemoteSyncError.conflict(path: "/hello.txt")) {
            try await source.upload(from: server.file("input"), to: "/hello.txt", options: .init(expectedETag: version))
        }
        #expect(try server.requests().filter { $0["method"] as? String == "PUT" }.count == 1)
        await source.disconnect()
        let missing = try WebDAVTestServer(fixture: "write_server"); defer { missing.cleanUp() }
        let other = try missing.source(); try await other.connect(.anonymous)
        try Data("x".utf8).write(to: missing.file("input"))
        await #expect(throws: RemoteSyncError.conflict(path: "/missing")) {
            try await other.upload(from: missing.file("input"), to: "/missing", options: .init(expectedETag: version))
        }
        await #expect(throws: RemoteSyncError.notFound(path: "/missing")) { try await other.stat(path: "/missing") }
        await other.disconnect()
    }
}
#endif
