#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

final class OneDriveTestServer: @unchecked Sendable {
    let workspace: URL
    let endpoints: ODEndpoints
    // Many tests launch Python fixtures concurrently with the WebDAV suite. Allow
    // scheduler/process-startup contention; this is not an HTTP timeout assertion.
    // Keep the production default (60s) unchanged.
    let configuration = try! OneDriveConfiguration(clientID: "fixture-client", redirectURI: URL(string: "bonetest://oauth/onedrive")!, timeout: 30)
    private let process = Process()
    private let terminated = DispatchSemaphore(value: 0)
    init(_ scenario: String = "normal") throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneODTests-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        process.terminationHandler = { [terminated] _ in terminated.signal() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures")!.path,
                             workspace.appendingPathComponent("requests.jsonl").path, scenario]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); var data = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { data.append(byte) }
        guard let port = String(data: data, encoding: .utf8), Int(port) != nil else { process.terminate(); throw URLError(.cannotConnectToHost) }
        endpoints = ODEndpoints(graph: URL(string: "http://127.0.0.1:\(port)/v1.0/")!,
            authority: URL(string: "http://127.0.0.1:\(port)/oauth/")!, allowsLoopback: true)
    }
    func cleanUp() {
        if process.isRunning { process.terminate() }
        // waitUntilExit can remain in a cooperative thread's run loop after the child exits.
        // Register before launch, then bound cleanup rather than silently hanging the test run.
        #expect(terminated.wait(timeout: .now() + 10) == .success, "OneDrive fixture did not terminate")
        try? FileManager.default.removeItem(at: workspace)
    }
    func file(_ name: String = "output.bin") -> URL { workspace.appendingPathComponent(name) }
    func requests() throws -> [[String: Any]] {
        let url = file("requests.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    var oauth: OneDriveOAuth { OneDriveOAuth(configuration: configuration, endpoints: endpoints) }
}
#endif
