#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncWebDAV

/// 仅测试工具拥有 Process；生产模块不依赖 Python，不接触用户文件。
final class WebDAVTestServer: @unchecked Sendable {
    let workspace: URL
    let baseURL: URL
    private let process: Process
    private let logURL: URL

    init(root: String = "dav", fixture: String = "server") throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneDAVTests-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        logURL = workspace.appendingPathComponent("requests.jsonl")
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = Bundle.module.url(forResource: fixture, withExtension: "py", subdirectory: "Fixtures")!
        process.arguments = ["-u", script.path, logURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var portData = Data()
        while let data = try pipe.fileHandleForReading.read(upToCount: 1), !data.isEmpty, data[0] != 10 { portData.append(data) }
        guard let text = String(data: portData, encoding: .utf8), let port = Int(text) else {
            process.terminate()
            throw NSError(domain: "Fixture", code: 1)
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)/\(root)/")!
    }

    func cleanUp() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: workspace)
    }

    func source() throws -> WebDAVSource { try WebDAVSource(baseURL: baseURL, timeout: 10) }
    func file(_ name: String = "out.bin") -> URL { workspace.appendingPathComponent(name) }
    func requests() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        return try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
}

final class DAVProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func record(_ value: Int64) { lock.withLock { values.append(value) } }
    func snapshot() -> [Int64] { lock.withLock { values } }
}
#endif
