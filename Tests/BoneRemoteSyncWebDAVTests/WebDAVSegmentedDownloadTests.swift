#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
import BoneRemoteSyncWebDAV

@Suite struct WebDAVSegmentedDownloadTests {
    private let config = RemoteSegmentedDownloadOptions(segmentSize: 8, maxConcurrentSegments: 3, minimumFileSize: 1)

    @Test func exactClosedRangesUseOneVersionAndReturnWholeFile() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "dav-ranges")
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: server.file("cache"))
        let lease = try await m.materialize(.init(source: binding, path: "/hello.txt"), options: .init(downloadStrategy: .segmentedRequired(config)))
        #expect(try String(contentsOf: lease.url, encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == 4)
        #expect(Set(gets.compactMap { $0["range"] as? String }) == Set(["bytes=0-7", "bytes=8-15", "bytes=16-23", "bytes=24-25"]))
        #expect(gets.allSatisfy { $0["ifMatch"] as? String == "\"v1\"" })
        await lease.release(); await m.shutdown(); await source.disconnect()
    }

    @Test(arguments: [false, true]) func ignoresRangeFallbackIsExplicit(required: Bool) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "dav-ranges")
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: server.file("cache"))
        let options = RemoteMaterializationOptions(downloadStrategy: required ? .segmentedRequired(config) : .segmentedIfSupported(config))
        if required {
            await #expect(throws: RemoteByteRangeError.unavailable) {
                try await m.materialize(.init(source: binding, path: "/ignore-range.txt"), options: options)
            }
        } else {
            let lease = try await m.materialize(.init(source: binding, path: "/ignore-range.txt"), options: options)
            #expect(try String(contentsOf: lease.url, encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
            await lease.release()
        }
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == (required ? 1 : 2))
        #expect(gets.first?["range"] as? String == "bytes=0-7")
        await m.shutdown(); await source.disconnect()
    }

    @Test(arguments: ["bad-range.txt", "wrong-etag.txt", "changed.txt", "range-short.txt", "range-extra.txt", "range-total.txt", "range-no-etag.txt", "range-late-change.txt", "encoded.txt", "force416.txt"])
    func badResponsesNeverFallbackOrPublish(name: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "dav-ranges")
        let cache = server.file("cache")
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: cache)
        await #expect(throws: (any Error).self) {
            try await m.materialize(.init(source: binding, path: "/" + name), options: .init(verifySize: false, downloadStrategy: .segmentedIfSupported(config)))
        }
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(!gets.isEmpty)
        #expect(gets.allSatisfy { $0["range"] is String })
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        await m.shutdown(); await source.disconnect()
    }

    @Test(arguments: ["weak.txt", "no-etag.txt", "unknown.txt", "empty.txt"])
    func ineligibleMetadataSkipsProbeAndRequiredFails(name: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "dav-ranges")
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: server.file("cache"))
        await #expect(throws: RemoteByteRangeError.unavailable) {
            try await m.materialize(.init(source: binding, path: "/" + name), options: .init(downloadStrategy: .segmentedRequired(config)))
        }
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        let lease = try await m.materialize(.init(source: binding, path: "/" + name), options: .init(downloadStrategy: .segmentedIfSupported(config)))
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == 1)
        #expect(gets.first?["range"] is NSNull)
        await lease.release(); await m.shutdown(); await source.disconnect()
    }

    @Test(arguments: ["range-200-header.txt", "range-200-length.txt", "range-200-encoding.txt"])
    func malformed200NeverAuthorizesFallback(name: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "dav-ranges")
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: server.file("cache"))
        await #expect(throws: (any Error).self) {
            try await m.materialize(.init(source: binding, path: "/" + name), options: .init(downloadStrategy: .segmentedIfSupported(config)))
        }
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == 1)
        #expect(gets.first?["range"] as? String == "bytes=0-7")
        await m.shutdown(); await source.disconnect()
    }

    @Test func configuredRetriesKeepTheSameRangeAndVersion() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, timeout: 10, retryPolicy: .standard)
        try await source.connect(.anonymous)
        let entry = try await source.stat(path: "/range-retry.txt")
        let bytes = try await source.readBytes(entry, range: .init(offset: 8, length: 8), requiringVersion: "\"v1\"")
        #expect(bytes == Data("ijklmnop".utf8))
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == 2)
        #expect(gets.allSatisfy { $0["range"] as? String == "bytes=8-15" && $0["ifMatch"] as? String == "\"v1\"" })
        await source.disconnect()
    }

    @Test(arguments: ["range-chunk-short.txt", "range-chunk-extra.txt", "range-chunk-hold.txt"])
    func actualChunkedBodyLengthIsAlwaysValidated(name: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, timeout: 10, retryPolicy: .standard)
        try await source.connect(.anonymous)
        let entry = try await source.stat(path: "/" + name)
        let started = ContinuousClock.now
        await #expect(throws: RemoteSyncError.integrityMismatch(path: "/" + name)) {
            try await source.readBytes(entry, range: .init(offset: 0, length: 8), requiringVersion: "\"v1\"")
        }
        // The hold fixture keeps the chunked response open for 5s after overflow.
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 1)
        await source.disconnect()
    }

    @Test func disconnectDuringParallelReadDoesNotPublish() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let binding = RemoteSourceBinding(kind: .webdav, identity: "dav-ranges")
        let cache = server.file("cache")
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: cache)
        let task = Task { try await m.materialize(.init(source: binding, path: "/slow.bin"), options: .init(downloadStrategy: .segmentedRequired(.init(segmentSize: 256 * 1024, minimumFileSize: 1)))) }
        for _ in 0..<1000 {
            if try server.requests().filter({ $0["method"] as? String == "GET" }).count >= 3 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count >= 3)
        await source.disconnect()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        await m.shutdown()
    }
}
#endif
