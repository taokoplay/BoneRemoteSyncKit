#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

/// Separate fixture with a mutable in-memory tree so write tests never disturb the read-only fixture.
final class OneDriveWriteServer: @unchecked Sendable {
    let workspace: URL
    let endpoints: ODEndpoints
    let configuration = try! OneDriveConfiguration(
        clientID: "fixture-client",
        redirectURI: URL(string: "bonetest://oauth/onedrive")!,
        timeout: 30
    )
    private let process = Process()
    private let logURL: URL

    init(_ scenario: String = "normal") throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneODWriteTests-\(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        logURL = workspace.appendingPathComponent("requests.jsonl")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-u",
            Bundle.module.url(forResource: "server-write", withExtension: "py", subdirectory: "Fixtures")!.path,
            logURL.path,
            scenario
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 {
            data.append(byte)
        }
        guard let port = String(data: data, encoding: .utf8), Int(port) != nil else {
            process.terminate()
            throw URLError(.cannotConnectToHost)
        }
        endpoints = ODEndpoints(
            graph: URL(string: "http://127.0.0.1:\(port)/v1.0/")!,
            authority: URL(string: "http://127.0.0.1:\(port)/oauth/")!,
            allowsLoopback: true
        )
    }

    func cleanUp() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: workspace)
    }

    func source() -> OneDriveSource {
        OneDriveSource(configuration: configuration, endpoints: endpoints)
    }

    var credential: RemoteCredential {
        .oauth(accessToken: "NEW", refreshToken: "REFRESH", expiresAt: Date().addingTimeInterval(3600))
    }

    /// Local file used as upload source; created inside the test workspace.
    func localFile(_ name: String = "upload.bin", bytes: Data) throws -> URL {
        let url = workspace.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func requests() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        return try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
}

@Suite struct OneDriveWritingTests {
    @Test func uploadCreatesThenReplacesOnlyWhenAllowed() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let source = server.source()
        try await source.connect(server.credential)

        let first = try server.localFile(bytes: Data("first".utf8))
        let entry = try await source.upload(from: first, to: "/new.txt", options: .init(overwrite: false))
        #expect(entry.name == "new.txt")
        #expect(entry.size == 5)
        #expect(try await source.stat(path: "/new.txt").size == 5)

        await #expect(throws: RemoteSyncError.self) {
            try await source.upload(from: first, to: "/new.txt", options: .init(overwrite: false))
        }

        let second = try server.localFile("second.bin", bytes: Data("replaced-longer".utf8))
        let replaced = try await source.upload(from: second, to: "/new.txt", options: .init(overwrite: true))
        #expect(replaced.size == 15)
        #expect(try await source.stat(path: "/new.txt").size == 15)

        let uploads = try server.requests().filter { ($0["method"] as? String) == "PUT" }
        #expect(uploads.count == 3)
        await source.disconnect()
    }

    @Test func uploadRejectsDirectoriesAndDisconnectedSource() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let source = server.source()
        await #expect(throws: RemoteSyncError.self) {
            try await source.upload(from: server.workspace, to: "/x.txt", options: .init())
        }
        try await source.connect(server.credential)
        await #expect(throws: RemoteSyncError.self) {
            try await source.upload(from: server.workspace, to: "/x.txt", options: .init())
        }
        await source.disconnect()
        await #expect(throws: RemoteSyncError.self) {
            try await source.upload(from: try server.localFile(bytes: Data("x".utf8)), to: "/x.txt", options: .init())
        }
    }

    @Test func makeDirectoryIsRecursiveAndIdempotent() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let source = server.source()
        try await source.connect(server.credential)

        try await source.makeDirectory(path: "/a/b/c")
        for path in ["/a", "/a/b", "/a/b/c"] {
            #expect(try await source.stat(path: path).isDirectory)
        }
        let before = try server.requests().filter { ($0["method"] as? String) == "POST" }.count
        try await source.makeDirectory(path: "/a/b/c")
        let after = try server.requests().filter { ($0["method"] as? String) == "POST" }.count
        #expect(before == after)
        #expect(before == 3)

        await #expect(throws: RemoteSyncError.self) { try await source.makeDirectory(path: "/keep.txt/sub") }
        await source.disconnect()
    }

    @Test func removeDeletesFileAndSubtreeButNeverRoot() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let source = server.source()
        try await source.connect(server.credential)

        try await source.makeDirectory(path: "/tree/child")
        try await source.upload(from: try server.localFile(bytes: Data("leaf".utf8)), to: "/tree/child/leaf.txt", options: .init())
        try await source.remove(path: "/tree")
        await #expect(throws: RemoteSyncError.self) { try await source.stat(path: "/tree") }

        try await source.remove(path: "/keep.txt")
        await #expect(throws: RemoteSyncError.self) { try await source.stat(path: "/keep.txt") }

        await #expect(throws: RemoteSyncError.self) { try await source.remove(path: "/") }
        #expect(try await source.stat(path: "/").isDirectory)
        await source.disconnect()
    }

    @Test func moveRenamesAndRejectsOccupiedDestination() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let source = server.source()
        try await source.connect(server.credential)
        try await source.makeDirectory(path: "/target")

        try await source.move(from: "/keep.txt", to: "/target/renamed.txt")
        #expect(try await source.stat(path: "/target/renamed.txt").name == "renamed.txt")
        await #expect(throws: RemoteSyncError.self) { try await source.stat(path: "/keep.txt") }

        try await source.upload(from: try server.localFile(bytes: Data("x".utf8)), to: "/target/other.txt", options: .init())
        await #expect(throws: RemoteSyncError.self) {
            try await source.move(from: "/target/other.txt", to: "/target/renamed.txt")
        }
        #expect(try await source.stat(path: "/target/other.txt").name == "other.txt")

        await #expect(throws: RemoteSyncError.self) { try await source.move(from: "/target/renamed.txt", to: "/missing/x.txt") }
        await #expect(throws: RemoteSyncError.self) { try await source.move(from: "/", to: "/x") }
        await source.disconnect()
    }

    @Test func writeFailuresMapWithoutInventingSuccess() async throws {
        let forbidden = try OneDriveWriteServer("upload-forbidden"); defer { forbidden.cleanUp() }
        let uploader = forbidden.source()
        try await uploader.connect(forbidden.credential)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/x.txt")) {
            try await uploader.upload(from: try forbidden.localFile(bytes: Data("x".utf8)), to: "/x.txt", options: .init())
        }
        await #expect(throws: RemoteSyncError.self) { try await uploader.stat(path: "/x.txt") }
        await uploader.disconnect()

        let forbiddenDelete = try OneDriveWriteServer("delete-forbidden"); defer { forbiddenDelete.cleanUp() }
        let remover = forbiddenDelete.source()
        try await remover.connect(forbiddenDelete.credential)
        await #expect(throws: RemoteSyncError.permissionDenied(path: "/keep.txt")) { try await remover.remove(path: "/keep.txt") }
        #expect(try await remover.stat(path: "/keep.txt").name == "keep.txt")
        await remover.disconnect()
    }

    @Test func capabilitiesAdvertiseWritesWithoutResumableUpload() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let source = server.source()
        let capabilities = source.capabilities
        #expect(capabilities.upload)
        #expect(capabilities.makeDirectory)
        #expect(capabilities.remove)
        #expect(capabilities.move)
        #expect(!capabilities.resumableUpload)
        #expect(!capabilities.rangedDownload)
        #expect(!capabilities.copy)
        await source.disconnect()
    }
}
#endif
