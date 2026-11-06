#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncKavita
import BoneRemoteSyncTestSupport

final class KavitaFixture: @unchecked Sendable {
    let workspace: URL
    let baseURL: URL
    private let process = Process()
    private let terminated = DispatchSemaphore(value: 0)

    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneKavitaTests-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        process.executableURL = try PythonFixture.executableURL()
        process.arguments = ["-u", try #require(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures")).path, workspace.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [terminated] _ in terminated.signal() }
        do { try process.run() }
        catch { try? FileManager.default.removeItem(at: workspace); throw error }
        let deadline = Date().addingTimeInterval(10)
        var port: Int?
        while Date() < deadline, process.isRunning {
            if let text = try? String(contentsOf: workspace.appendingPathComponent("port"), encoding: .utf8),
               let value = Int(text) { port = value; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let port else {
            if process.isRunning { process.terminate() }
            _ = terminated.wait(timeout: .now() + 5)
            try? FileManager.default.removeItem(at: workspace)
            throw URLError(.cannotConnectToHost)
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)/kavita/")!
    }
    func source(references: Int = 256) throws -> KavitaSource {
        KavitaSource(configuration: try .init(baseURL: baseURL, allowsInsecureHTTP: true, maxDownloadReferences: references))
    }
    func file(_ name: String) -> URL { workspace.appendingPathComponent(name) }
    func configure(_ options: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: options).write(to: file("mode.json"), options: .atomic)
    }
    func release() throws { try Data().write(to: file("release")) }
    func requests(_ path: String? = nil) throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: file("requests.jsonl"), encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            .filter { path == nil || ($0["path"] as? String) == "/kavita/api/" + path! }
    }
    func waitForRequest(_ path: String, count: Int = 1) async throws {
        for _ in 0..<500 {
            if try requests(path).count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.timedOut)
    }
    func cleanUp() {
        if process.isRunning { process.terminate() }
        #expect(terminated.wait(timeout: .now() + 5) == .success)
        try? FileManager.default.removeItem(at: workspace)
    }
}

func kavitaEntry(_ source: KavitaSource, _ reference: RemoteFileReference) async throws -> RemoteEntry {
    guard case .path(let path) = reference.locator else { throw URLError(.badURL) }
    return try await source.stat(path: path)
}
#endif
