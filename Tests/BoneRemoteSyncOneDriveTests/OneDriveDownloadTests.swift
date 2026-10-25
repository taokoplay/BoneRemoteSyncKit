#if os(macOS)
import Foundation
import CryptoKit
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOneDrive

final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Int64] = []
    func record(_ value: Int64) { lock.withLock { values.append(value) } }
    var bytes: Int64 { lock.withLock { values.last ?? 0 } }
    var monotonic: Bool { lock.withLock { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } } }
}
@Suite struct OneDriveDownloadTests {
    @Test(arguments: ["normal", "expired"])
    func downloadsByIDWithoutBearerAtCDN(scenario: String) async throws {
        let server = try OneDriveTestServer(scenario); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        let entry = try await source.stat(path: "/file"); let probe = ProgressProbe()
        try Data("old".utf8).write(to: server.file())
        let downloaded = try await source.download(entry, to: server.file(), options: RemoteDownloadOptions(progress: { probe.record($0) }))
        #expect(downloaded.id == entry.id); #expect(probe.bytes == 1048576); #expect(probe.monotonic)
        let expected = (0..<32768).reduce(into: Data()) { $0.append(contentsOf: SHA256.hash(data: Data(String($1).utf8))) }
        #expect(try Data(contentsOf: server.file()) == expected)
        let requests = try server.requests(); let cdn = requests.filter { ($0["path"] as? String)?.hasPrefix("/download/") == true }
        #expect(cdn.count == (scenario == "expired" ? 2 : 1))
        #expect(cdn.allSatisfy { $0["authorization"] is NSNull && $0["cookie"] is NSNull })
        #expect(requests.contains { ($0["path"] as? String)?.hasPrefix("/v1.0/drives/D/items/file") == true })
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-onedrive-") })
        await source.disconnect()
    }
    @Test func emptyFileAndNonOverwriteAndUnsupportedResume() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential)
        let empty = try await source.stat(path: "/empty")
        _ = try await source.download(empty, to: server.file(), options: .init())
        #expect(try Data(contentsOf: server.file()).isEmpty)
        await #expect(throws: RemoteSyncError.self) { try await source.download(empty, to: server.file(), options: .init(overwrite: false)) }
        await #expect(throws: RemoteSyncError.self) { try await source.download(empty, to: server.file("resume"), options: .init(resumeFrom: 0)) }
        await source.disconnect()
    }
    @Test(arguments: ["download-redirect", "unsafe-url", "short", "compressed", "cut", "changes-during-body", "unknown-short", "partial", "expired-always"])
    func failuresProtectTargetAndExistingPart(scenario: String) async throws {
        let server = try OneDriveTestServer(scenario); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); let entry = try await source.stat(path: "/file")
        try Data("old".utf8).write(to: server.file()); try Data("manual-part".utf8).write(to: server.file().appendingPathExtension("part"))
        await #expect(throws: RemoteSyncError.self) { try await source.download(entry, to: server.file(), options: .init()) }
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        #expect(try Data(contentsOf: server.file().appendingPathExtension("part")) == Data("manual-part".utf8))
        #expect(try !server.requests().contains { ($0["path"] as? String)?.hasPrefix("/stolen") == true })
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-onedrive-") })
        await source.disconnect()
    }
    @Test func disablingSizeVerificationInstallsActualUnknownLength() async throws {
        let server = try OneDriveTestServer("unknown-short"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); let entry = try await source.stat(path: "/file")
        _ = try await source.download(entry, to: server.file(), options: .init(verifySize: false))
        #expect(try Data(contentsOf: server.file()).count == 10)
        await source.disconnect()
    }
    @Test func versionMismatchAndForeignIdentityNeverDownload() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); let entry = try await source.stat(path: "/file")
        await #expect(throws: RemoteSyncError.conflict(path: "/file")) { try await source.download(entry, to: server.file(), options: .init(expectedETag: "wrong")) }
        let foreign = RemoteEntry(id: ODLocation.identity(drive: "other", item: "file"), path: "/file", name: "file", type: .file)
        await #expect(throws: RemoteSyncError.self) { try await source.download(foreign, to: server.file(), options: .init()) }
        #expect(try !server.requests().contains { ($0["path"] as? String)?.hasPrefix("/download/") == true })
        await source.disconnect()
    }
    @Test(arguments: [false,true])
    func cancellationAndDisconnectProtectOldTarget(disconnect: Bool) async throws {
        let server = try OneDriveTestServer("slow"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); let entry = try await source.stat(path: "/file"); let probe = ProgressProbe()
        try Data("old".utf8).write(to: server.file())
        let download = Task { try await source.download(entry, to: server.file(), options: .init(progress: { probe.record($0) })) }
        for _ in 0..<1000 { if probe.bytes > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(probe.bytes > 0)
        if disconnect { await source.disconnect() } else { download.cancel() }
        await #expect(throws: RemoteSyncError.cancelled) { try await download.value }
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-onedrive-") })
        await source.disconnect()
    }
}
@Suite struct OneDriveDownloadSafetyTests {
    @Test func rejectsSymlinkDirectoryAndHardlinkTargets() async throws {
        let server = try OneDriveTestServer(); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); let entry = try await source.stat(path: "/file")
        try Data("victim".utf8).write(to: server.file("victim"))
        try FileManager.default.createSymbolicLink(at: server.file("link"), withDestinationURL: server.file("victim"))
        try FileManager.default.linkItem(at: server.file("victim"), to: server.file("hard"))
        try FileManager.default.createDirectory(at: server.file("directory"), withIntermediateDirectories: false)
        for name in ["link","hard","directory"] {
            await #expect(throws: RemoteSyncError.self) { try await source.download(entry, to: server.file(name), options: .init()) }
        }
        #expect(try Data(contentsOf: server.file("victim")) == Data("victim".utf8))
        await source.disconnect()
    }
    @Test func foldsDestinationAliasesDuringConcurrentDownload() async throws {
        let server = try OneDriveTestServer("slow"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); let entry = try await source.stat(path: "/file"); let probe = ProgressProbe()
        let first = Task { try await source.download(entry, to: server.file("Case.bin"), options: .init(progress: { probe.record($0) })) }
        for _ in 0..<1000 { if probe.bytes > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(probe.bytes > 0)
        await #expect(throws: RemoteSyncError.self) { try await source.download(entry, to: server.file("case.bin"), options: .init()) }
        first.cancel(); _ = try? await first.value; await source.disconnect()
    }
    @Test func lateNonOverwriteConflictNeverReplacesNewFile() async throws {
        let server = try OneDriveTestServer("slow"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); let entry = try await source.stat(path: "/file"); let probe = ProgressProbe()
        let first = Task { try await source.download(entry, to: server.file(), options: .init(overwrite: false, progress: { probe.record($0) })) }
        for _ in 0..<1000 { if probe.bytes > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(probe.bytes > 0)
        try Data("late-target".utf8).write(to: server.file())
        await #expect(throws: RemoteSyncError.self) { try await first.value }
        #expect(try Data(contentsOf: server.file()) == Data("late-target".utf8))
        await source.disconnect()
    }
    @Test func stagingHardlinkIsNotInstalled() async throws {
        let server = try OneDriveTestServer("slow"); defer { server.cleanUp() }; let source = server.source()
        try await source.connect(server.credential); let entry = try await source.stat(path: "/file"); let probe = ProgressProbe()
        try Data("old".utf8).write(to: server.file())
        let first = Task { try await source.download(entry, to: server.file(), options: .init(progress: { probe.record($0) })) }
        for _ in 0..<1000 { if probe.bytes > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        let staging = try #require(FileManager.default.contentsOfDirectory(at: server.workspace, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".bone-onedrive-") })
        try FileManager.default.linkItem(at: staging, to: server.file("hard-staging"))
        await #expect(throws: RemoteSyncError.self) { try await first.value }
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        await source.disconnect()
    }
    @Test func productionRejectsLocalLiteralAndInsecureDownloadURLs() throws {
        for raw in ["http://files.example.com/f", "https://127.0.0.1/f", "https://10.1.1.1/f", "https://[::1]/f", "https://localhost/f", "https://server.local/f", "https://user:pass@files.example.com/f", "https://files.example.com/f#secret", "https://0x7f.0.0.1/f", "https://server.local./f", "https://0x7f.0x0.0x0.0x1/f", "https://127.0.0.0x1/f", "https://0xA.0x0.0x0.0x1/f"] {
            #expect(throws: RemoteSyncError.self) { try ODLocation.download(raw, endpoints: .production) }
        }
        #expect(try ODLocation.download("https://files.example.com/f?auth=opaque", endpoints: .production).scheme == "https")
    }
}
#endif
