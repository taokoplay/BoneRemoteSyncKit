#if os(macOS)
import Foundation
import Darwin
import BoneRemoteSyncTestSupport

final class NativeBrowserFixture: @unchecked Sendable {
    struct Request: Decodable {
        let method: String
        let path: String
        let query: [String: String]
        let body: String
        func json() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
        }
    }
    enum FixtureError: Error { case startup, timeout, missingResource }
    let directory: URL
    private let process = Process()
    private let stopped = DispatchSemaphore(value: 0)
    private var port = 0

    private init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoneBrowserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    static func start() async throws -> NativeBrowserFixture {
        let fixture = try NativeBrowserFixture()
        do {
            guard let script = Bundle.module.url(forResource: "native", withExtension: "py", subdirectory: "Fixtures") else {
                throw FixtureError.missingResource
            }
            fixture.process.executableURL = try PythonFixture.executableURL()
            fixture.process.arguments = [script.path, fixture.directory.path]
            fixture.process.standardOutput = FileHandle.nullDevice
            fixture.process.standardError = FileHandle.nullDevice
            let stopped = fixture.stopped
            fixture.process.terminationHandler = { _ in stopped.signal() }
            try fixture.process.run()
            for _ in 0..<250 {
                if let text = try? String(contentsOf: fixture.directory.appendingPathComponent("port"), encoding: .utf8),
                   let port = Int(text), port > 0 {
                    fixture.port = port
                    return fixture
                }
                if !fixture.process.isRunning { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw FixtureError.startup
        } catch { fixture.stop(); throw error }
    }
    func url(_ service: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(service)/")! }
    func state(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
    func data(_ filename: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(filename)) }
    func requests() throws -> [Request] {
        try data("requests.jsonl").split(separator: 10).map { try JSONDecoder().decode(Request.self, from: Data($0)) }
    }
    func waitFor(_ marker: String) async throws {
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw FixtureError.timeout
    }
    func release() throws { try Data().write(to: directory.appendingPathComponent("release")) }
    func stop() {
        if process.isRunning {
            process.terminate()
            if stopped.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = stopped.wait(timeout: .now() + 2)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { stop() }
}
#endif
