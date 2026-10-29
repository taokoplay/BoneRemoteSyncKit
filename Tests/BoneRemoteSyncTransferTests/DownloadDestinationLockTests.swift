import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
import BoneRemoteSyncLocal
@testable import BoneRemoteSyncTransfer

@Suite struct DownloadDestinationLockTests {
    @Test func independentStoresRejectDestinationAndSidecarAliasesAndRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = LocalDownloadDestinationLocks(directory: root.appendingPathComponent("locks"))
        let b = LocalDownloadDestinationLocks(directory: root.appendingPathComponent("locks"))
        let destination = root.appendingPathComponent("out")
        let held = try await a.acquire(destination: destination)
        for path in ["out", "OUT", "out.part", "out.part.checkpoint.json"] {
            await #expect(throws: (any Error).self) { try await b.acquire(destination: root.appendingPathComponent(path)) }
        }
        let other = try await b.acquire(destination: root.appendingPathComponent("other"))
        await other.release()
        await held.release()
        await held.release()
        let next = try await b.acquire(destination: destination)
        await next.release()
    }

    @Test func unsupportedAndWrongBindingFailBeforeLockOrSourceIO() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = RemoteSourceBinding(kind: .local, identity: "test")
        let recovery = RemoteDownloadRecovery(source: LocalFileSource(root: root), binding: binding,
            destinationLocks: LocalDownloadDestinationLocks(directory: root.appendingPathComponent("locks")))
        await #expect(throws: RemoteSyncError.unsupported(operation: "来源不支持受管理恢复下载")) {
            try await recovery.download(.init(source: binding, path: "/file"), to: root.appendingPathComponent("out"))
        }
        await #expect(throws: RemoteSyncError.conflict(path: "download-binding")) {
            try await recovery.download(.init(source: .init(kind: .local, identity: "other"), path: "/file"), to: root.appendingPathComponent("out"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(arguments: [false, true])
    func foreignLinkedLockFileIsRejected(hardlink: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("locks")
        let store = LocalDownloadDestinationLocks(directory: directory)
        let destination = root.appendingPathComponent("out")
        let initial = try await store.acquire(destination: destination)
        await initial.release()
        let lockFile = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let foreign = root.appendingPathComponent("foreign")
        try Data("preserve".utf8).write(to: foreign)
        try FileManager.default.removeItem(at: lockFile)
        if hardlink { try FileManager.default.linkItem(at: foreign, to: lockFile) }
        else { try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: foreign) }
        await #expect(throws: (any Error).self) { try await store.acquire(destination: destination) }
        #expect(try Data(contentsOf: foreign) == Data("preserve".utf8))
    }

    @Test func symbolicAncestorAliasesUseTheSameLocks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("targets")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let store = LocalDownloadDestinationLocks(directory: root.appendingPathComponent("locks"))
        let held = try await store.acquire(destination: target.appendingPathComponent("file"))
        await #expect(throws: (any Error).self) {
            try await store.acquire(destination: alias.appendingPathComponent("file"))
        }
        await held.release()
    }

    #if os(macOS)
    @Test(.enabled(if: PythonFixture.isAvailable, "跨进程锁验证需要 Python 3"))
    func separateProcessCannotAcquireHeldLockFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("locks")
        let store = LocalDownloadDestinationLocks(directory: directory)
        let held = try await store.acquire(destination: root.appendingPathComponent("out"))
        let script = """
        import sys, os, fcntl
        files = os.listdir(sys.argv[1])
        assert len(files) == 3
        for name in files:
            with open(os.path.join(sys.argv[1], name), 'r+b') as f:
                try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    assert sys.argv[2] == 'held'
                else:
                    assert sys.argv[2] == 'released'
        """
        func probe(_ phase: String) throws {
            let process = Process()
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            process.executableURL = try PythonFixture.executableURL()
            process.arguments = ["-c", script, directory.path, phase]
            try process.run()
            #expect(finished.wait(timeout: .now() + 10) == .success)
            #expect(process.terminationStatus == 0)
        }
        try probe("held")
        await held.release()
        try probe("released")
    }
    #endif

    @Test func lockDirectoryCannotBeUsedAsADownloadDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDownloadDestinationLocks(directory: root)
        await #expect(throws: (any Error).self) { try await store.acquire(destination: root.appendingPathComponent("output")) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func rejectsSymlinkRootAndRemoteDestinationWithoutCreatingLocks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDownloadDestinationLocks(directory: root)
        await #expect(throws: (any Error).self) { try await store.acquire(destination: URL(string: "https://localhost/out")!) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let linked = LocalDownloadDestinationLocks(directory: link)
        await #expect(throws: (any Error).self) { try await linked.acquire(destination: root.appendingPathComponent("out")) }
    }
}
