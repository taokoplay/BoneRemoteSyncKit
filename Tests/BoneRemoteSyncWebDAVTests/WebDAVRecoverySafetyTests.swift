#if os(macOS)
import Foundation
import CryptoKit
import Darwin
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

struct RecoveryPair {
    let target: WebDAVDownloadTarget
    let store: DAVCheckpointStore
    var record: DAVCheckpointRecord
    init(server: WebDAVTestServer, path: String = "/hello.txt", committed: Int64 = 5,
         phase: DAVCheckpointPhase = .downloading, namespace: String = "account", size: Int64 = 26,
         etag: String = "\"v1\"", content: Data = Data("abcdeTAIL".utf8)) throws {
        target = try WebDAVDownloadTarget(destination: server.file())
        try Data("old".utf8).write(to: target.destination)
        try content.write(to: target.part)
        let binding = DAVCheckpointBinding(sourceNamespace: namespace, root: server.baseURL.absoluteString,
                                           remotePath: path, destination: target.lockKey)
        store = DAVCheckpointStore(target: target, binding: binding)
        let info = try #require(try WebDAVDownloadTarget.information(target.part))
        record = DAVCheckpointRecord(phase: phase, binding: binding, etag: etag, expectedSize: size,
            committedBytes: committed, prefixSHA256: DAVPartHasher.hex(SHA256.hash(data: content.prefix(Int(committed)))),
            partDevice: UInt64(info.st_dev), partInode: UInt64(info.st_ino))
        try store.save(record)
    }
}

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVRecoverySafetyTests {
    var fast: WebDAVRetryPolicy { .init(maxAttempts: 3, initialDelay: 0, maxDelay: 0, totalTimeout: 15) }

    @Test func transientBodyFailureResumesFromCommittedPrefix() async throws {
        let server = try WebDAVTestServer(root: "gated"); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: fast)
        try await source.connect(.anonymous)
        let marker = server.file("requests.jsonl.cut-ready")
        _ = try await source.downloadResumable(path: "/cut-once.bin", to: server.file(), options: .init(sourceNamespace: "account", checkpointIntervalBytes: 65536, progress: { bytes in
            if bytes == 262144 { try? Data("committed".utf8).write(to: marker, options: .atomic) }
        }))
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == 2)
        #expect(gets.last?["range"] as? String == "bytes=262144-")
        #expect(gets.allSatisfy { $0["ifMatch"] as? String == "\"v1\"" })
        var expected = Data()
        for index in 0..<98304 { expected.append(contentsOf: SHA256.hash(data: Data(String(index).utf8))) }
        #expect(SHA256.hash(data: try Data(contentsOf: server.file())) == SHA256.hash(data: expected))
        await source.disconnect()
    }

    @Test func allBytesWithoutConfirmedEOFMustRestartRatherThanRangePastEnd() async throws {
        let server = try WebDAVTestServer(root: "gated"); defer { server.cleanUp() }
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: fast)
        try await source.connect(.anonymous)
        let marker = server.file("requests.jsonl.cut-ready")
        _ = try await source.downloadResumable(path: "/complete-cut.bin", to: server.file(), options: .init(sourceNamespace: "account", checkpointIntervalBytes: 65536, progress: { bytes in
            if bytes == 3_145_728 { try? Data("committed".utf8).write(to: marker, options: .atomic) }
        }))
        let gets = try server.requests().filter { $0["method"] as? String == "GET" }
        #expect(gets.count == 2)
        #expect(gets.allSatisfy { $0["range"] as? String == nil })
        #expect(try Data(contentsOf: server.file()).count == 3_145_728)
        await source.disconnect()
    }

    @Test func repeatedBodyFailureHasExactlyThreeGETsAndPreservesTarget() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        try Data("old".utf8).write(to: server.file())
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: fast)
        try await source.connect(.anonymous)
        await #expect(throws: (any Error).self) {
            try await source.downloadResumable(path: "/cut-always.bin", to: server.file(), options: .init(sourceNamespace: "account", checkpointIntervalBytes: 65536))
        }
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 3)
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        await source.disconnect()
    }

    @Test(arguments: ["namespace", "path", "root", "destination", "etag", "size", "short", "digest", "schema", "json", "oversized", "missing-part", "hardlink", "symlink"])
    func mismatchedPairNeverGETsOrChangesFiles(kind: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let pair = try RecoveryPair(server: server, namespace: kind == "namespace" ? "other" : "account",
                                    size: kind == "size" ? 27 : 26, etag: kind == "etag" ? "\"old\"" : "\"v1\"")
        if ["path", "root", "destination", "schema"].contains(kind) {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: pair.store.url)) as? [String: Any])
            if kind == "schema" { json["schemaVersion"] = 2 }
            else {
                var binding = try #require(json["binding"] as? [String: Any])
                binding[kind == "path" ? "remotePathHash" : kind + "Hash"] = String(repeating: "0", count: 64)
                json["binding"] = binding
            }
            try JSONSerialization.data(withJSONObject: json).write(to: pair.store.url)
        }
        if kind == "short" { try Data("ab".utf8).write(to: pair.target.part) }
        if kind == "digest" { try Data("axcdeTAIL".utf8).write(to: pair.target.part) }
        if kind == "json" { try Data("{}".utf8).write(to: pair.store.url) }
        if kind == "oversized" { try Data(repeating: 120, count: 65537).write(to: pair.store.url) }
        if kind == "missing-part" { try FileManager.default.removeItem(at: pair.target.part) }
        if kind == "hardlink" { try FileManager.default.linkItem(at: pair.target.part, to: server.file("alias")) }
        if kind == "symlink" {
            try FileManager.default.moveItem(at: pair.target.part, to: server.file("alias"))
            try FileManager.default.createSymbolicLink(at: pair.target.part, withDestinationURL: server.file("alias"))
        }
        let checkpointBefore = try Data(contentsOf: pair.store.url)
        let partBefore = try? Data(contentsOf: pair.target.part)
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: fast)
        try await source.connect(.anonymous)
        await #expect(throws: (any Error).self) {
            try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"))
        }
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        #expect(try Data(contentsOf: pair.store.url) == checkpointBefore)
        #expect((try? Data(contentsOf: pair.target.part)) == partBefore)
        await source.disconnect()
    }

    @Test(arguments: ["ignore-range.txt", "bad-range.txt", "force416.txt", "wrong-etag.txt", "encoded.txt"])
    func invalidGETDoesNotTruncateUncommittedTail(name: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let pair = try RecoveryPair(server: server, path: "/\(name)")
        let before = try Data(contentsOf: pair.store.url)
        let source = try WebDAVSource(baseURL: server.baseURL, retryPolicy: fast)
        try await source.connect(.anonymous)
        await #expect(throws: (any Error).self) {
            try await source.downloadResumable(path: "/\(name)", to: server.file(), options: .init(sourceNamespace: "account"))
        }
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 1)
        #expect(try Data(contentsOf: pair.target.part) == Data("abcdeTAIL".utf8))
        #expect(try Data(contentsOf: pair.store.url) == before)
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        await source.disconnect()
    }

    @Test func verifiedTailIsRolledBackAndFullUnreadyPartRestartsAtZero() async throws {
        for committed: Int64 in [5, 26] {
            let server = try WebDAVTestServer(); defer { server.cleanUp() }
            let pair = try RecoveryPair(server: server, committed: committed,
                                        content: committed == 5 ? Data("abcdeTAIL".utf8) : Data("abcdefghijklmnopqrstuvwxyzTAIL".utf8))
            let source = try server.source(); try await source.connect(.anonymous)
            _ = try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"))
            #expect(try Data(contentsOf: pair.target.destination) == Data("abcdefghijklmnopqrstuvwxyz".utf8))
            let get = try #require(server.requests().last)
            #expect(get["range"] as? String == (committed == 5 ? "bytes=5-" : nil))
            await source.disconnect()
        }
    }

    @Test(arguments: [false, true])
    func readyBeforeAndAfterRenameAreIdempotent(installed: Bool) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let pair = try RecoveryPair(server: server, committed: 26, phase: .readyToInstall, content: Data("abcdefghijklmnopqrstuvwxyz".utf8))
        if installed { try FileManager.default.removeItem(at: server.file()); try FileManager.default.moveItem(at: pair.target.part, to: server.file()) }
        let source = try server.source(); try await source.connect(.anonymous)
        _ = try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account", overwrite: installed ? false : true))
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        #expect(try Data(contentsOf: server.file()) == Data("abcdefghijklmnopqrstuvwxyz".utf8))
        #expect(!FileManager.default.fileExists(atPath: pair.store.url.path))
        await source.disconnect()
    }

    @Test func readyWithoutMatchingTargetIsNotSuccess() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let pair = try RecoveryPair(server: server, committed: 26, phase: .readyToInstall, content: Data("abcdefghijklmnopqrstuvwxyz".utf8))
        try FileManager.default.removeItem(at: pair.target.part)
        let source = try server.source(); try await source.connect(.anonymous)
        await #expect(throws: (any Error).self) {
            try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"))
        }
        #expect(try Data(contentsOf: server.file()) == Data("old".utf8))
        #expect(FileManager.default.fileExists(atPath: pair.store.url.path))
        await source.disconnect()
    }

    @Test(arguments: ["ready", "before-install", "after-install"])
    func injectedWindowRetainsRecoverablePair(window: String) async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        try Data("old".utf8).write(to: server.file())
        let source = try server.source(); try await source.connect(.anonymous)
        let hooks = DAVRecoveryTestHooks(onPhase: { phase in
            if (window == "ready" && phase == .readyCommitted) ||
               (window == "before-install" && phase == .beforeInstall) ||
               (window == "after-install" && phase == .installedBeforeCleanup) { throw ProbeError.injected }
        })
        let transfer = Task { try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"), hooks: hooks) }
        if window == "after-install" { _ = try await transfer.value }
        else { await #expect(throws: (any Error).self) { try await transfer.value } }
        #expect(try Data(contentsOf: server.file()) == Data((window == "after-install" ? "abcdefghijklmnopqrstuvwxyz" : "old").utf8))
        _ = try await source.downloadResumable(path: "/hello.txt", to: server.file(), options: .init(sourceNamespace: "account"))
        #expect(try server.requests().filter { $0["method"] as? String == "GET" }.count == 1)
        await source.disconnect()
    }

    @Test func checkpointRenameFailureRetainsPreviousRecordAndRemovesTemporary() throws {
        let f = try CheckpointFileFixture(); defer { f.cleanUp() }
        try f.store.save(f.record)
        let before = try Data(contentsOf: f.store.url)
        var next = f.record; next.committedBytes = 4; next.prefixSHA256 = DAVPartHasher.hex(SHA256.hash(data: Data("abcd".utf8)))
        #expect(throws: ProbeError.self) {
            try f.store.save(next, hooks: .init(onPhase: { if $0 == .beforeCheckpointRename { throw ProbeError.injected } }))
        }
        #expect(try Data(contentsOf: f.store.url) == before)
        #expect(try f.store.load() == f.record)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }
}

enum ProbeError: Error { case injected }
#endif
