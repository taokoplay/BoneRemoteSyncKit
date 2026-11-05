#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOPDS

final class OPDSTestServer: @unchecked Sendable {
    let workspace: URL
    let baseURL: URL
    private let process = Process()
    private let terminated = DispatchSemaphore(value: 0)
    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneOPDSTests-\(UUID())")
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
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }
    func url(_ path: String) -> URL { URL(string: path, relativeTo: baseURL)!.absoluteURL }
    func source(_ path: String = "/catalog/root", pages: Int = 1000, references: Int = 10000, concurrent: Int = 3) throws -> OPDSSource {
        OPDSSource(configuration: try .init(rootURL: url(path), allowsInsecureHTTP: true, maxPages: pages,
                                            maxDownloadReferences: references, maxConcurrentTransfers: concurrent))
    }
    func file(_ name: String) -> URL { workspace.appendingPathComponent(name) }
    func requests() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: file("requests.jsonl"), encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    func waitForRequest(_ path: String) async throws {
        for _ in 0..<500 {
            if try requests().contains(where: { ($0["path"] as? String) == path }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.timedOut)
    }
    func cleanUp() {
        if process.isRunning { process.terminate() }
        #expect(terminated.wait(timeout: .now() + 5) == .success)
        try? FileManager.default.removeItem(at: workspace)
    }
    static var payload: Data { Data(String(repeating: "PK\u{03}\u{04}opds-test-content", count: 10000).utf8) }
}

final class OPDSProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RemoteDownloadProgress] = []
    func append(_ value: RemoteDownloadProgress) { lock.withLock { items.append(value) } }
    var values: [RemoteDownloadProgress] { lock.withLock { items } }
}
#endif
