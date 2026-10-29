#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVMaterializationTests {
    @Test func strongVersionUsesIfMatchAndReturnsLeasedFile() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "fixture-dav")
        let reference = RemoteFileReference(source: binding, path: "/hello.txt")
        let entry = try await source.stat(path: "/hello.txt")
        let value = try #require(source.conditionalDownloadVersion(for: entry))
        let version = RemoteVersion(source: binding, locator: reference.locator, value: value, strength: .strongConditional)
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: server.file("cache"))
        let lease = try await m.materialize(reference, options: .init(consistency: .requireVersion(version)))
        #expect(try String(contentsOf: lease.url, encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
        #expect(lease.version == version)
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == 1)
        #expect(gets.first?["ifMatch"] as? String == value)
        await lease.release(); await m.shutdown(); await source.disconnect()
    }

    @Test func mismatchedVersionAndWrongLocatorCannotDownload() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "fixture-dav")
        let reference = RemoteFileReference(source: binding, path: "/hello.txt")
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: server.file("cache"))
        for version in [
            RemoteVersion(source: binding, locator: reference.locator, value: "\"old\"", strength: .strongConditional),
            RemoteVersion(source: binding, locator: .path("/other"), value: "\"v1\"", strength: .strongConditional)
        ] {
            await #expect(throws: RemoteSyncError.conflict(path: "/hello.txt")) {
                try await m.materialize(reference, options: .init(consistency: .requireVersion(version)))
            }
        }
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        #expect(!FileManager.default.fileExists(atPath: server.file("cache").path))
        await m.shutdown(); await source.disconnect()
    }
}
#endif
