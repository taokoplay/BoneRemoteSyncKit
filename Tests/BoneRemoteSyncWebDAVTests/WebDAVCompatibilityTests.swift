#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

// Each case launches a process; serialize this added matrix to avoid overwhelming unrelated
// short-deadline fixtures. Assertions and production timeout policies remain unchanged.
@Suite(.serialized) struct WebDAVCompatibilityTests {
    @Test func collectionSlashWorksForListStatWalkAndWritePreflight() async throws {
        let server = try WebDAVTestServer(fixture: "compat_server")
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.basic(username: "alice", password: "secret"))
        #expect(try await source.list(path: "/folder").entries.count == 2)
        #expect(try await source.list(path: "/folder/").entries.count == 2)
        #expect(try await source.stat(path: "/资料 空间").isDirectory)
        #expect(try await source.stat(path: "/permanent").isDirectory)
        let summary = try await source.walk(path: "/folder", options: .init()) { _ in }
        #expect(summary.directoryCount == 2)
        let input = server.file("input")
        try Data("hello".utf8).write(to: input)
        _ = try await source.upload(from: input, to: "/folder/upload.txt", options: .init(overwrite: false))
        await source.disconnect()
        let requests = try server.requests()
        #expect(requests.contains { $0["path"] as? String == "/dav/folder/" })
        #expect(requests.allSatisfy { $0["authorization"] as? String == "Basic YWxpY2U6c2VjcmV0" })
        #expect(requests.filter { $0["method"] as? String == "PUT" }.count == 1)
    }

    @Test(arguments: [403, 423, 404, 401, 503])
    func resourceStatusIsPreservedAcrossReadRecoveryAndWrite(status: Int) async throws {
        let server = try WebDAVTestServer(fixture: "compat_server")
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let path = "/status-\(status)"
        let expected: RemoteSyncError
        switch status {
        case 403: expected = .permissionDenied(path: path)
        case 423: expected = .conflict(path: path)
        case 404: expected = .notFound(path: path)
        case 401: expected = .authenticationFailed(reason: nil)
        default: expected = .network("WebDAV HTTP \(status)")
        }
        await #expect(throws: expected) { try await source.stat(path: path) }
        await #expect(throws: expected) { try await source.list(path: path) }
        await #expect(throws: expected) {
            try await source.downloadResumable(path: path, to: server.file(), options: .init(sourceNamespace: "test"))
        }
        await #expect(throws: expected) { try await source.remove(path: path) }
        #expect(!FileManager.default.fileExists(atPath: server.file().path))
        #expect(try server.requests().allSatisfy { $0["method"] as? String == "PROPFIND" })
        await source.disconnect()
    }

    @Test func resourceTransientErrorsUseRetryPolicyButPermissionErrorsDoNot() async throws {
        let server = try WebDAVTestServer(fixture: "compat_server")
        defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: .init(maxAttempts: 2, initialDelay: 0, maxDelay: 0, totalTimeout: 30))
        try await source.connect(.anonymous)
        #expect(try await source.stat(path: "/retry-stat").size == 5)
        #expect(try await source.list(path: "/retry-list").entries.isEmpty)
        try await source.remove(path: "/retry-write")
        _ = try await source.downloadResumable(path: "/retry-recovery", to: server.file(), options: .init(sourceNamespace: "retry"))
        #expect(try Data(contentsOf: server.file()) == Data("hello".utf8))
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/status-403")) {
            try await source.stat(path: "/status-403")
        }
        let requests = try server.requests()
        for name in ["retry-stat", "retry-list", "retry-write", "retry-recovery"] {
            #expect(requests.filter { $0["method"] as? String == "PROPFIND" && $0["path"] as? String == "/dav/" + name }.count == 2)
        }
        #expect(requests.filter { $0["path"] as? String == "/dav/status-403" }.count == 1)
        #expect(requests.filter { $0["method"] as? String == "DELETE" }.count == 1)
        await source.disconnect()
    }

    @Test(arguments: [false, true])
    func canonicalRequestSharesDeadlineAndCancellation(cancel: Bool) async throws {
        let server = try WebDAVTestServer(fixture: "compat_server")
        defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: .init(maxAttempts: 1, totalTimeout: 10))
        try await source.connect(.anonymous)
        let task = Task { try await source.stat(path: "/slow-canonical") }
        if cancel {
            for _ in 0..<500 {
                if try server.requests().contains(where: { $0["path"] as? String == "/dav/slow-canonical/" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            task.cancel()
            await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        } else {
            await #expect(throws: RemoteSyncError.network("WebDAV 操作总时限已到")) { try await task.value }
        }
        let paths = try server.requests().compactMap { $0["path"] as? String }
        #expect(paths == ["/dav/", "/dav/slow-canonical", "/dav/slow-canonical/"])
        await source.disconnect()
    }

    @Test func missingPropertiesAreNotReportedAsMissingResource() async throws {
        let server = try WebDAVTestServer(fixture: "compat_server")
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.underlying("WebDAV 目标资源缺少属性")) {
            try await source.stat(path: "/no-properties")
        }
        await source.disconnect()
    }

    @Test(arguments: ["foreign", "outside", "query", "fragment", "userinfo", "scheme-change", "encoded", "temporary", "network-path", "loop"])
    func arbitraryRedirectsRemainRejected(name: String) async throws {
        let server = try WebDAVTestServer(fixture: "compat_server")
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV 重定向；请使用最终地址")) {
            try await source.list(path: "/" + name)
        }
        let requests = try server.requests()
        #expect(requests.count == (name == "loop" ? 3 : 2))
        await source.disconnect()
    }
}
#endif
