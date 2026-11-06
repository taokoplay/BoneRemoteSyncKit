#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncBaidu

final class BaiduTestServer: @unchecked Sendable {
    let workspace: URL
    let endpoints: BDEndpoints
    let configuration = try! BaiduDriveConfiguration(appKey: "fixture-app", rootPath: "/apps/Fixture", timeout: 15)
    private let process = Process()
    private let terminated = DispatchSemaphore(value: 0)
    init(_ scenario: String = "normal") throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneBaiduTests-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        process.executableURL = try PythonFixture.executableURL()
        process.arguments = ["-u", try #require(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures")).path, workspace.path, scenario]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [terminated] _ in terminated.signal() }
        try process.run()
        var port: Int?; let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, process.isRunning {
            if let raw = try? String(contentsOf: workspace.appendingPathComponent("port"), encoding: .utf8), let value = Int(raw) { port = value; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let port else { process.terminate(); throw URLError(.cannotConnectToHost) }
        endpoints = .init(api: URL(string: "http://127.0.0.1:\(port)/rest/2.0/xpan/")!,
                          locateUpload: URL(string: "http://127.0.0.1:\(port)/rest/2.0/pcs/file")!, allowsLoopback: true)
    }
    func source(refresh: BaiduDriveTokenRefresher? = nil) -> BaiduDriveSource {
        BaiduDriveSource(configuration: configuration, endpoints: endpoints, refreshToken: refresh)
    }
    var credential: RemoteCredential { .oauth(accessToken: "fixture-token", refreshToken: "fixture-refresh", expiresAt: .distantFuture) }
    func file(_ name: String) -> URL { workspace.appendingPathComponent(name) }
    func requests() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: file("requests.jsonl"), encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    func waitFor(_ method: String) async throws {
        for _ in 0..<500 {
            if try requests().contains(where: { ($0["method"] as? String) == method || ($0["path"] as? String)?.hasPrefix(method) == true }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.timedOut)
    }
    func cleanUp() {
        if process.isRunning { process.terminate() }
        #expect(terminated.wait(timeout: .now() + 5) == .success)
        try? FileManager.default.removeItem(at: workspace)
    }
    static let payload = Data("hello 百度\n".utf8)
}
final class BaiduProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    func record(_ value: Int64) { lock.withLock { storage.append(value) } }
    var values: [Int64] { lock.withLock { storage } }
}
#endif
