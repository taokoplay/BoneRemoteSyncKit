#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
import BoneRemoteSyncWebDAV

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVRetryTests {
    private var fast: WebDAVRetryPolicy { .init(maxAttempts: 3, initialDelay: 0, maxDelay: 0, totalTimeout: 5) }

    @Test func optedInConnectStatAndGETRetryOnceEach() async throws {
        let server = try WebDAVTestServer(root: "retry-once")
        defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: fast)
        try await source.connect(.anonymous)
        _ = try await source.download(path: "/hello.txt", to: server.file())
        #expect(try String(contentsOf: server.file(), encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 2)
        #expect(try server.requests().filter { $0["method"] as? String == "PROPFIND" }.count == 4)
        await source.disconnect()
    }

    @Test func defaultsAreSingleAttemptAndRepeatedFailureHasHardLimit() async throws {
        for count in [1, 3] {
            let server = try WebDAVTestServer(root: "retry-always")
            defer { server.cleanUp() }
            let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: count == 1 ? .none : fast)
            await #expect(throws: (any Error).self) { try await source.connect(.anonymous) }
            #expect(try server.requests().count == count)
        }
    }

    @Test func unimplementedAndInvalidXMLDoNotRetry() async throws {
        for root in ["retry-501", "badxml"] {
            let server = try WebDAVTestServer(root: root)
            defer { server.cleanUp() }
            let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: fast)
            await #expect(throws: (any Error).self) { try await source.connect(.anonymous) }
            #expect(try server.requests().count == 1)
        }
    }

    @Test func retryAfterWaitsAndTooLongRetryAfterStops() async throws {
        for long in [true, false] {
            let server = try WebDAVTestServer(root: long ? "retry-after-long" : "retry-after")
            defer { server.cleanUp() }
            let source = try WebDAVSource(baseURL: server.baseURL,
                retryPolicy: .init(initialDelay: 0, maxDelay: 0, totalTimeout: 5))
            let start = DispatchTime.now().uptimeNanoseconds
            if long {
                await #expect(throws: RemoteSyncError.rateLimited(retryAfter: 60)) { try await source.connect(.anonymous) }
                #expect(try server.requests().count == 1)
            } else {
                try await source.connect(.anonymous)
                #expect(DispatchTime.now().uptimeNanoseconds - start >= 1_000_000_000)
                #expect(try server.requests().count == 2)
            }
            await source.disconnect()
        }
    }

    @Test func ordinaryBodyFailureDoesNotRestartMutatedPart() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: fast)
        try await source.connect(.anonymous)
        try Data("old".utf8).write(to: server.file())
        await #expect(throws: (any Error).self) { try await source.download(path: "/truncated.txt", to: server.file()) }
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 1)
        #expect(try String(contentsOf: server.file(), encoding: .utf8) == "old")
        await source.disconnect()
    }
}
#endif
