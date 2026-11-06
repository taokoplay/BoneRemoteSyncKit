#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncContent

private final class ContentTestServer: @unchecked Sendable {
    let workspace: URL
    let baseURL: URL
    private let process = Process()
    private let terminated = DispatchSemaphore(value: 0)
    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneContentTests-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        process.executableURL = try PythonFixture.executableURL()
        process.arguments = ["-u", try #require(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures")).path, workspace.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [terminated] _ in terminated.signal() }
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        var port: Int?
        while Date() < deadline, process.isRunning {
            if let raw = try? String(contentsOf: workspace.appendingPathComponent("port"), encoding: .utf8), let value = Int(raw) { port = value; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let port else { process.terminate(); throw URLError(.cannotConnectToHost) }
        baseURL = URL(string: "http://127.0.0.1:\(port)/mount/")!
    }
    func client(timeout: Double = 5, concurrent: Int = 3, interval: Double = 0, limit: Int = 8192,
                auth: ContentAuthorization = .bearer("fixture-secret")) throws -> ContentHTTPClient {
        try .init(configuration: .init(baseURL: baseURL, allowsInsecureHTTP: true, timeout: timeout,
                                        maxConcurrentRequests: concurrent, requestInterval: interval, maxResponseBytes: limit), authorization: auth)
    }
    func file(_ name: String) -> URL { workspace.appendingPathComponent(name) }
    func resource(_ endpoint: String, size: Int64? = nil) throws -> ContentResource {
        .init(entry: .init(id: "fixture", path: "/resources/fixture", name: "book.epub", type: .file, size: size),
              url: baseURL.appendingPathComponent("api/\(endpoint)"))
    }
    func requests() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: file("requests.jsonl"), encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    func waitForRequest(_ endpoint: String) async throws {
        for _ in 0..<500 {
            if try requests().contains(where: { ($0["path"] as? String) == "/mount/api/" + endpoint }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.timedOut)
    }
    func cleanUp() {
        if process.isRunning { process.terminate() }
        #expect(terminated.wait(timeout: .now() + 5) == .success)
        try? FileManager.default.removeItem(at: workspace)
    }
    static var payload: Data { Data(String(repeating: "PK\u{03}\u{04}content-fixture", count: 8192).utf8) }
}
@Suite(.serialized, .enabled(if: PythonFixture.isAvailable, "需要 Python 3 启动 HTTP fixture")) struct ContentTransportTests {
    @Test func authorizationUsesHeadersAndCookiesStayDisabled() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        for auth: ContentAuthorization in [.basic(username: "reader", password: "fixture"), .apiKey("fixture-key"), .bearer("fixture-token")] {
            let client = try server.client(auth: auth)
            _ = try await client.send(path: ["api", "json"])
            _ = try await client.send(path: ["api", "json"])
        }
        let requests = try server.requests()
        #expect(requests.count == 6)
        #expect(requests[0]["authorization"] as? String == "Basic " + Data("reader:fixture".utf8).base64EncodedString())
        #expect(requests[2]["key"] as? String == "fixture-key")
        #expect(requests[4]["authorization"] as? String == "Bearer fixture-token")
        #expect(requests.allSatisfy { $0["cookie"] is NSNull })
    }

    @Test func redirectsAndErrorBodiesAreContained() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client()
        await #expect(throws: ContentServerError.redirectRejected) { try await client.send(path: ["api", "redirect"]) }
        await #expect(throws: RemoteSyncError.rateLimited(retryAfter: 7)) { try await client.send(path: ["api", "rate"]) }
        await #expect(throws: RemoteSyncError.authenticationFailed(reason: "Content service authentication failed")) { try await client.send(path: ["api", "auth"]) }
        #expect(try server.requests().count == 3)
        await #expect(throws: ContentServerError.invalidReference) { try await client.send(path: ["api", "json"], headers: ["Authorization": "other-secret"]) }
        #expect(try server.requests().count == 3)
    }

    @Test func buffersHaveLengthAndStreamingLimits() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client(limit: 1024)
        for endpoint in ["large", "chunked-large"] {
            await #expect(throws: ContentServerError.resourceLimit) { try await client.send(path: ["api", endpoint]) }
        }
        await #expect(throws: ContentServerError.invalidResponse) { try await client.send(path: ["api", "html"]) }
        await #expect(throws: ContentServerError.invalidResponse) { try await client.send(path: ["api", "json"], kind: .image) }
        #expect(try await client.send(path: ["api", "image"], kind: .image).data.starts(with: [137, 80, 78, 71]))
        #expect(try await client.send(path: ["api", "empty"]).data.isEmpty)
    }

    @Test func successfulDownloadIsAtomicAndUnboundedByMetadataLimit() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client(limit: 1024)
        let target = server.file("result.epub"), old = Data("old".utf8)
        try old.write(to: target)
        let file = try ContentDownloadFile(destination: target); defer { file.cleanup() }
        let bytes = try await client.download(server.resource("file", size: Int64(ContentTestServer.payload.count)), file: file, options: .init(overwrite: true))
        #expect(try Data(contentsOf: target) == old)
        try file.install(overwrite: true, bytes: bytes)
        #expect(try Data(contentsOf: target) == ContentTestServer.payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-content-") })
    }

    @Test func badDownloadNeverReplacesExistingFile() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client(), old = Data("old".utf8), target = server.file("result.epub")
        try old.write(to: target)
        for endpoint in ["html", "fake-file", "short-file", "partial"] {
            let file = try ContentDownloadFile(destination: target)
            await #expect(throws: (any Error).self) { try await client.download(server.resource(endpoint), file: file, options: .init(overwrite: true)) }
            file.cleanup()
            #expect(try Data(contentsOf: target) == old)
        }
        let file = try ContentDownloadFile(destination: target); defer { file.cleanup() }
        await #expect(throws: RemoteSyncError.integrityMismatch(path: "Content resource")) {
            try await client.download(server.resource("file", size: 1), file: file, options: .init(overwrite: true))
        }
        #expect(try Data(contentsOf: target) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-content-") })
    }

    @Test func protectedTargetsAndUnsupportedResumeFailBeforeNetwork() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client(), target = server.file("target"), original = server.file("original")
        try Data("old".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
        let file = try ContentDownloadFile(destination: target)
        await #expect(throws: RemoteSyncError.conflict(path: target.path)) { try await client.download(server.resource("file"), file: file, options: .init(overwrite: true)) }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.linkItem(at: original, to: target)
        await #expect(throws: RemoteSyncError.conflict(path: target.path)) { try await client.download(server.resource("file"), file: file, options: .init(overwrite: true)) }
        let fresh = try ContentDownloadFile(destination: server.file("fresh"))
        await #expect(throws: (any Error).self) { try await client.download(server.resource("file"), file: fresh, options: .init(resumeFrom: 1)) }
        await #expect(throws: (any Error).self) { try await client.download(server.resource("file"), file: fresh, options: .init(expectedETag: "v1")) }
        #expect(try server.requests().isEmpty)
    }

    @Test func cancellationDrainsDownloadBeforeCleanup() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client(), target = server.file("cancelled"), old = Data("old".utf8)
        try old.write(to: target)
        let file = try ContentDownloadFile(destination: target)
        let task = Task { try await client.download(server.resource("slow-file"), file: file, options: .init(overwrite: true)) }
        try await server.waitForRequest("slow-file")
        task.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        file.cleanup()
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(try Data(contentsOf: target) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-content-") })
    }

    @Test func concurrencyIsBoundedAndClientCancellationReachesActiveRequest() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client(concurrent: 1)
        let task = Task { try await client.send(path: ["api", "slow"]) }
        try await server.waitForRequest("slow")
        await #expect(throws: RemoteSyncError.rateLimited(retryAfter: nil)) { try await client.send(path: ["api", "json"]) }
        client.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        await #expect(throws: RemoteSyncError.cancelled) { try await client.send(path: ["api", "json"]) }
        #expect(try server.requests().count == 1)
    }

    @Test func intervalSerializesAdmissionsWithoutBurst() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client(interval: 0.15)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = try await client.send(path: ["api", "json"]) } }
            try await group.waitForAll()
        }
        let times = try server.requests().compactMap { $0["time"] as? Double }.sorted()
        #expect(times.count == 3)
        for (first, second) in zip(times, times.dropFirst()) { #expect(second - first >= 0.12) }
    }

    @Test func timeoutIncludesRateWaitAndCancelledWaitNeverSends() async throws {
        let server = try ContentTestServer(); defer { server.cleanUp() }
        let client = try server.client(timeout: 0.3, interval: 2)
        _ = try await client.send(path: ["api", "json"])
        let start = ProcessInfo.processInfo.systemUptime
        await #expect(throws: RemoteSyncError.network("Content transport failed (-1001)")) { try await client.send(path: ["api", "json"]) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
        #expect(try server.requests().count == 1)
        let task = Task { try await client.send(path: ["api", "json"]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try server.requests().count == 1)
    }
}
#endif
