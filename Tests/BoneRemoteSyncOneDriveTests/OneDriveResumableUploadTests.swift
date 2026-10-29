#if os(macOS)
import Foundation
import CryptoKit
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
@testable import BoneRemoteSyncOneDrive

private final class MemoryUploadSessionStore: ODUploadSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: ODUploadSessionRecord] = [:]
    private var shouldFailRead = false
    func setFailRead(_ value: Bool) { lock.withLock { shouldFailRead = value } }
    private var shouldFailReplace = false
    private var failPhase: RemoteUploadPhase?
    func setFailPhase(_ phase: RemoteUploadPhase?) { lock.withLock { failPhase = phase } }

    func setFailReplace(_ value: Bool) { lock.withLock { shouldFailReplace = value } }
    func read(_ id: UUID) throws -> ODUploadSessionRecord? {
        try lock.withLock {
            if shouldFailRead { throw RemoteSyncError.secureStorageUnavailable }
            return values[id]
        }
    }
    func insert(_ record: ODUploadSessionRecord) throws {
        try lock.withLock {
            guard values[record.handle.id] == nil else { throw RemoteSyncError.conflict(path: "upload-session") }
            values[record.handle.id] = record
        }
    }
    func replace(_ record: ODUploadSessionRecord) throws {
        try lock.withLock {
            guard !shouldFailReplace, record.phase != failPhase, values[record.handle.id] != nil else {
                throw RemoteSyncError.secureStorageUnavailable
            }
            values[record.handle.id] = record
        }
    }
    func remove(_ id: UUID) throws { _ = lock.withLock { values.removeValue(forKey: id) } }
}

private func uploadTarget(_ source: OneDriveSource, path: String) async throws -> RemoteFileReference {
    RemoteFileReference(source: try await source.connectedBinding(), path: path)
}

@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct OneDriveResumableUploadTests {
    @Test func oneDriveAdvertisesAndImplementsManagedResumableUpload() throws {
        let configuration = try OneDriveConfiguration(
            clientID: "fixture-client",
            redirectURI: URL(string: "bonetest://oauth/onedrive")!
        )
        let source = try OneDriveSource(configuration: configuration, resumableUploadService: "BoneRemoteSyncKit.Tests.\(UUID().uuidString)")
        #expect(source.capabilities.resumableUpload)
    }

    @Test func uploadsOrderedChunksWithoutBearerOnPreauthenticatedSession() async throws {
        let server = try OneDriveWriteServer()
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x5a, count: 700_000))
        let snapshotDirectory = server.workspace.appendingPathComponent("snapshots")
        let target = try await uploadTarget(source, path: "/resumable.bin")
        let options = RemoteResumableUploadOptions(snapshotDirectory: snapshotDirectory, chunkSize: 320 * 1024)

        let handle = try await source.prepareResumableUpload(from: sourceFile, to: target, options: options)
        let result = try await source.uploadResuming(handle, options: options)

        #expect(result.state == .committed)
        #expect(result.entry?.size == 700_000)
        #expect(try await source.stat(path: "/resumable.bin").size == 700_000)
        #expect(try store.read(handle.id)?.phase == .committed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path).allSatisfy {
            !$0.hasSuffix(".snapshot")
        })

        let requests = try server.requests()
        let sessionRequests = requests.filter { ($0["path"] as? String)?.hasPrefix("/upload-session/") == true }
        #expect(sessionRequests.contains { ($0["method"] as? String) == "GET" })
        #expect(sessionRequests.filter { ($0["method"] as? String) == "PUT" }.count == 3)
        #expect(sessionRequests.allSatisfy { $0["authorization"] is NSNull && $0["cookie"] is NSNull })
        #expect(requests.contains { ($0["method"] as? String) == "POST" &&
            ($0["path"] as? String)?.contains("createUploadSession") == true &&
            ($0["authorization"] as? String) == "Bearer NEW" })
        await source.disconnect()
    }

    @Test func retriesRateLimitWithoutCreatingAnotherSession() async throws {
        let server = try OneDriveWriteServer("upload-429")
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x31, count: 400_000))
        let target = try await uploadTarget(source, path: "/limited.bin")
        let options = RemoteResumableUploadOptions(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"),
                                                   chunkSize: 320 * 1024)
        let handle = try await source.prepareResumableUpload(from: sourceFile, to: target, options: options)
        let result = try await source.uploadResuming(handle, options: options)
        #expect(result.entry?.size == 400_000)
        let requests = try server.requests()
        #expect(requests.filter { ($0["path"] as? String)?.contains("createUploadSession") == true }.count == 1)
        #expect(requests.filter { ($0["method"] as? String) == "PUT" }.count == 3)
        await source.disconnect()
    }

    @Test func abortDeletesOnlyThePreauthenticatedSessionAndLocalSnapshot() async throws {
        let server = try OneDriveWriteServer()
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x42, count: 400_000))
        let snapshotDirectory = server.workspace.appendingPathComponent("snapshots")
        let target = try await uploadTarget(source, path: "/aborted.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: snapshotDirectory, chunkSize: 320 * 1024)
        )
        try await source.abortResumableUpload(handle)
        #expect(try store.read(handle.id)?.phase == .aborted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path).allSatisfy {
            !$0.hasSuffix(".snapshot")
        })
        let requests = try server.requests()
        let deletes = requests.filter { ($0["method"] as? String) == "DELETE" &&
            ($0["path"] as? String)?.hasPrefix("/upload-session/") == true }
        #expect(deletes.isEmpty)
        await source.disconnect()
    }

    @Test func lostFinalResponseReturnsUnknownAndDoesNotStartReplacementSession() async throws {
        let server = try OneDriveWriteServer("upload-commit-unknown")
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x13, count: 400_000))
        let target = try await uploadTarget(source, path: "/unknown.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
        )
        await #expect(throws: RemoteSyncError.uploadCommitUnknown) {
            try await source.uploadResuming(handle)
        }
        let checkpoint = try await source.uploadCheckpoint(handle)
        #expect(checkpoint?.phase == .reconciling)
        let requests = try server.requests()
        #expect(requests.filter { ($0["path"] as? String)?.contains("createUploadSession") == true }.count == 1)
        #expect(requests.filter { ($0["method"] as? String) == "DELETE" }.isEmpty)
        await source.disconnect()
    }

    @Test func requestedRangeConflictDoesNotAdvanceCheckpoint() async throws {
        let server = try OneDriveWriteServer("upload-416")
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x2a, count: 400_000))
        let target = try await uploadTarget(source, path: "/range-conflict.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
        )
        let result = try await source.uploadResuming(handle)
        #expect(result.entry?.size == 400_000)
        let puts = try server.requests().filter { ($0["method"] as? String) == "PUT" }
        #expect(puts.count == 3)
        #expect(puts.first?["contentRange"] as? String == "bytes 0-327679/400000")
        await source.disconnect()
    }

    @Test func malformedRangesAreRejectedBeforeAnotherPut() async throws {
        let server = try OneDriveWriteServer("upload-malformed-ranges")
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x2b, count: 400_000))
        let target = try await uploadTarget(source, path: "/bad-range.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
        )
        await #expect(throws: RemoteSyncError.conflict(path: "upload-session-range")) {
            try await source.uploadResuming(handle)
        }
        #expect(try server.requests().filter { ($0["method"] as? String) == "PUT" }.isEmpty)
        await source.disconnect()
    }

    @Test func nonAlignedRangesAreRejectedBeforeSendingInvalidFragments() async throws {
        let server = try OneDriveWriteServer("upload-noncontiguous-ranges")
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x2b, count: 400_000))
        let target = try await uploadTarget(source, path: "/noncontiguous.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
        )
        await #expect(throws: RemoteSyncError.conflict(path: "upload-session-range")) {
            try await source.uploadResuming(handle)
        }
        #expect(try server.requests().filter { ($0["method"] as? String) == "PUT" }.isEmpty)
        await source.disconnect()
    }

    @Test func sessionStatusAuthenticationAndConflictsAreMappedWithoutRecreation() async throws {
        for scenario in ["upload-session-401", "upload-session-409", "upload-session-412", "upload-session-500"] {
            let server = try OneDriveWriteServer(scenario)
            defer { server.cleanUp() }
            let store = MemoryUploadSessionStore()
            let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                            resumableUploadService: "fixture", sessionStore: store)
            try await source.connect(server.credential)
            let sourceFile = try server.localFile(bytes: Data(repeating: 0x2c, count: 400_000))
            let target = try await uploadTarget(source, path: "/status-\(scenario).bin")
            let handle = try await source.prepareResumableUpload(
                from: sourceFile, to: target,
                options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
            )
            let expected: RemoteSyncError = switch scenario {
            case "upload-session-401": .uploadSessionExpired
            case "upload-session-409", "upload-session-412": .conflict(path: "upload-session")
            default: .network("OneDrive 上传会话请求失败")
            }
            await #expect(throws: expected) { try await source.uploadResuming(handle) }
            #expect(try server.requests().filter { ($0["path"] as? String)?.contains("createUploadSession") == true }.count == 1)
            await source.disconnect()
        }
    }

    @Test func putConflictsAndServerErrorsDoNotCreateReplacementSessions() async throws {
        for scenario in ["upload-put-409", "upload-put-412", "upload-put-500"] {
            let server = try OneDriveWriteServer(scenario)
            defer { server.cleanUp() }
            let store = MemoryUploadSessionStore()
            let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                            resumableUploadService: "fixture", sessionStore: store)
            try await source.connect(server.credential)
            let sourceFile = try server.localFile(bytes: Data(repeating: 0x2d, count: 400_000))
            let target = try await uploadTarget(source, path: "/put-\(scenario).bin")
            let handle = try await source.prepareResumableUpload(
                from: sourceFile, to: target,
                options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
            )
            let expected: RemoteSyncError = scenario == "upload-put-409" || scenario == "upload-put-412"
                ? .conflict(path: "upload-session")
                : .network("OneDrive 上传会话请求失败")
            await #expect(throws: expected) { try await source.uploadResuming(handle) }
            #expect((try await source.uploadCheckpoint(handle))?.confirmedBytes == 0)
            #expect(try server.requests().filter { ($0["path"] as? String)?.contains("createUploadSession") == true }.count == 1)
            await source.disconnect()
        }
    }

    @Test func persistenceFailureStopsBeforeSendingAChunk() async throws {
        let server = try OneDriveWriteServer()
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x2e, count: 400_000))
        let target = try await uploadTarget(source, path: "/storage-failure.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
        )
        store.setFailReplace(true)
        await #expect(throws: RemoteSyncError.secureStorageUnavailable) {
            try await source.uploadResuming(handle)
        }
        #expect(try server.requests().filter { ($0["method"] as? String) == "PUT" }.isEmpty)
        await source.disconnect()
    }

    @Test func changedSnapshotIsRejectedBeforeSendingAChunk() async throws {
        let server = try OneDriveWriteServer()
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x2f, count: 400_000))
        let target = try await uploadTarget(source, path: "/changed-snapshot.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
        )
        let record = try #require(try store.read(handle.id))
        try Data(repeating: 0x00, count: 1).write(to: record.snapshotURL)
        await #expect(throws: RemoteSyncError.sourceSnapshotMissing) {
            try await source.uploadResuming(handle)
        }
        #expect(try server.requests().filter { ($0["method"] as? String) == "PUT" }.isEmpty)
        await source.disconnect()
    }

    @Test func explicitAbortAfterUnknownFinalCommitDoesNotClaimRemoteRollback() async throws {
        let server = try OneDriveWriteServer("upload-commit-unknown")
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x30, count: 400_000))
        let target = try await uploadTarget(source, path: "/unknown-abort.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
        )
        await #expect(throws: RemoteSyncError.uploadCommitUnknown) { try await source.uploadResuming(handle) }
        await #expect(throws: RemoteSyncError.uploadCommitUnknown) { try await source.abortResumableUpload(handle) }
        #expect(try await source.stat(path: "/unknown-abort.bin").size == 400_000)
        #expect(try store.read(handle.id)?.phase == .reconciling)
        await source.disconnect()
    }

    @Test func expiredSessionIsNotRecreated() async throws {
        let server = try OneDriveWriteServer("upload-expired")
        defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let sourceFile = try server.localFile(bytes: Data(repeating: 0x21, count: 400_000))
        let target = try await uploadTarget(source, path: "/expired.bin")
        let handle = try await source.prepareResumableUpload(
            from: sourceFile, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 320 * 1024)
        )
        await #expect(throws: RemoteSyncError.uploadSessionExpired) {
            try await source.uploadResuming(handle)
        }
        #expect((try await source.uploadCheckpoint(handle))?.phase == .uploading)
        #expect(try server.requests().filter { ($0["path"] as? String)?.contains("createUploadSession") == true }.count == 1)
        await source.disconnect()
    }
    @Test func expectedETagIsRejectedBeforeCreatingSnapshotOrSession() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data([1, 2, 3]))
        let directory = server.workspace.appendingPathComponent("snapshots")
        let target = try await uploadTarget(source, path: "/conditional.bin")
        await #expect(throws: RemoteSyncError.unsupported(operation: "OneDrive 可恢复上传不支持最终提交条件 ETag")) {
            try await source.prepareResumableUpload(from: file, to: target,
                options: .init(overwrite: true, expectedETag: "v1", snapshotDirectory: directory))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try server.requests().filter { ($0["method"] as? String) == "POST" }.isEmpty)
        await source.disconnect()
    }

    @Test func statusAndPartialResponsesNeedNotRepeatSecretURL() async throws {
        let server = try OneDriveWriteServer("upload-status-without-url"); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 7, count: 400_000))
        let target = try await uploadTarget(source, path: "/status.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 327680))
        #expect(try await source.uploadResuming(handle).state == .committed)
        await source.disconnect()
    }

    @Test func failedFinalIntentPersistencePreventsFinalPut() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 7, count: 10))
        let target = try await uploadTarget(source, path: "/intent.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots")))
        store.setFailPhase(.reconciling)
        await #expect(throws: RemoteSyncError.secureStorageUnavailable) { try await source.uploadResuming(handle) }
        #expect(try server.requests().filter { ($0["method"] as? String) == "PUT" }.isEmpty)
        await source.disconnect()
    }

    @Test func commitReceiptSurvivesFailureToPersistIt() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 7, count: 10))
        let target = try await uploadTarget(source, path: "/receipt.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots")))
        store.setFailPhase(.committed)
        let result = try await source.uploadResuming(handle)
        #expect(result.state == .committedCleanupPending)
        #expect(result.entry?.size == 10)
        #expect(try store.read(handle.id)?.phase == .reconciling)
        await source.disconnect()
    }

    @Test func prepareIsLocalOnlyAndCommittedReceiptCanBeReadAgain() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 9, count: 10))
        let target = try await uploadTarget(source, path: "/local-prepare.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots")))
        #expect(try server.requests().filter { ($0["method"] as? String) == "POST" }.isEmpty)
        #expect(try await source.uploadCheckpoint(handle)?.phase == .preparing)
        let first = try await source.uploadResuming(handle)
        let count = try server.requests().count
        let again = try await source.uploadResuming(handle)
        #expect(first.entry == again.entry)
        #expect(again.state == .committed)
        #expect(try server.requests().count == count)
        #expect(try await source.uploadCheckpoint(handle)?.phase == .committed)
        await source.disconnect()
    }

    @Test func modificationAfterInitialHashCannotChangeUploadedBytes() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 9, count: 400_000))
        let target = try await uploadTarget(source, path: "/changed-midway.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 327680))
        let record = try #require(try store.read(handle.id))
        await #expect(throws: RemoteSyncError.sourceSnapshotMissing) {
            try await source.uploadResuming(handle, progress: { _ in
                // First callback is after initial snapshot verification. Keep inode and size.
                let writer = try! FileHandle(forWritingTo: record.snapshotURL)
                try! writer.seek(toOffset: 327680)
                try! writer.write(contentsOf: Data([0]))
                try! writer.close()
            })
        }
        #expect(try server.requests().filter { ($0["method"] as? String) == "PUT" }.count <= 1)
        await source.disconnect()
    }

    @Test func creationUnknownIsDurableAndNeverReposts() async throws {
        let server = try OneDriveWriteServer("upload-create-unknown"); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 1, count: 10))
        let target = try await uploadTarget(source, path: "/creation.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots")))
        for _ in 0..<2 {
            await #expect(throws: RemoteSyncError.uploadCommitUnknown) { try await source.uploadResuming(handle) }
        }
        #expect(try await source.uploadCheckpoint(handle)?.phase == .creationUnknown)
        #expect(try server.requests().filter { ($0["method"] as? String) == "POST" }.count == 1)
        await source.disconnect()
    }

    @Test(arguments: ["upload-416-always", "upload-no-progress", "upload-retry-after", "upload-wrong-target"])
    func abnormalResponsesStayBoundedAndPreserveEvidence(_ scenario: String) async throws {
        let server = try OneDriveWriteServer(scenario); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 1, count: 400_000))
        let target = try await uploadTarget(source, path: "/bounded.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 327680))
        let expected: RemoteSyncError = switch scenario {
        case "upload-wrong-target": .uploadCommitUnknown
        case "upload-retry-after": .rateLimited(retryAfter: 120)
        default: .conflict(path: "upload-session-range")
        }
        await #expect(throws: expected) { try await source.uploadResuming(handle) }
        #expect(try server.requests().filter { ($0["method"] as? String) == "PUT" }.count <= 5)
        #expect(try server.requests().filter { ($0["method"] as? String) == "POST" }.count == 1)
        #expect(try store.read(handle.id) != nil)
        await source.disconnect()
    }

    @Test func createOnlyDoesNotReplaceAnExistingFile() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 1, count: 10))
        let target = try await uploadTarget(source, path: "/keep.txt")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots")))
        await #expect(throws: RemoteSyncError.conflict(path: "upload-session")) { try await source.uploadResuming(handle) }
        #expect(try await source.stat(path: "/keep.txt").size == 5)
        try await source.abortResumableUpload(handle)
        #expect(try store.read(handle.id)?.phase == .aborted)
        await source.disconnect()
    }

    @Test func lostAbortResponseIsNotReplayed() async throws {
        let server = try OneDriveWriteServer("upload-abort-unknown"); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 1, count: 400_000))
        let target = try await uploadTarget(source, path: "/abort.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 327680))
        let task = Task {
            try await source.uploadResuming(handle, progress: { _ in
                // The next status persistence fails, leaving a known nonterminal session.
                store.setFailReplace(true)
            })
        }
        await #expect(throws: RemoteSyncError.secureStorageUnavailable) { try await task.value }
        store.setFailReplace(false)
        for _ in 0..<2 {
            await #expect(throws: RemoteSyncError.uploadCommitUnknown) { try await source.abortResumableUpload(handle) }
        }
        #expect(try await source.uploadCheckpoint(handle)?.phase == .abortUnknown)
        #expect(try server.requests().filter { ($0["method"] as? String) == "DELETE" }.count == 1)
        await source.disconnect()
    }

    @Test func unifiedUploadRecoveryUsesOnlyPreparedHandle() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let target = try await uploadTarget(source, path: "/unified.bin")
        let recovery = RemoteUploadRecovery(source: source, binding: target.source)
        let file = try server.localFile(bytes: Data(repeating: 8, count: 1234))
        let handle = try await recovery.prepare(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots")))
        let restored = try JSONDecoder().decode(RemoteUploadHandle.self, from: JSONEncoder().encode(handle))
        #expect(try await recovery.checkpoint(restored)?.phase == .preparing)
        #expect(try await recovery.resume(restored).entry?.size == 1234)
        #expect(try await recovery.resume(restored).state == .committed)
        await source.disconnect()
    }

    @Test func forgetRequiresTerminalReceiptAndDoesNotDeleteReplacedSnapshot() async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 8, count: 1234))
        let target = try await uploadTarget(source, path: "/forget.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots")))
        await #expect(throws: RemoteSyncError.conflict(path: "upload-receipt-not-terminal")) {
            try await source.forgetResumableUpload(handle)
        }
        _ = try await source.uploadResuming(handle)
        let record = try #require(try store.read(handle.id))
        try Data([42]).write(to: record.snapshotURL)
        await #expect(throws: RemoteSyncError.sourceSnapshotMissing) { try await source.forgetResumableUpload(handle) }
        #expect(try Data(contentsOf: record.snapshotURL) == Data([42]))
        try FileManager.default.removeItem(at: record.snapshotURL)
        try await source.forgetResumableUpload(handle)
        #expect(try store.read(handle.id) == nil)
        await source.disconnect()
    }

    @Test func rejectedSessionCreationRemainsRetryableAndAbortable() async throws {
        let server = try OneDriveWriteServer("upload-create-429"); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data([1]))
        let target = try await uploadTarget(source, path: "/retry-create.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots")))
        for _ in 0..<2 {
            await #expect(throws: RemoteSyncError.rateLimited(retryAfter: 120)) { try await source.uploadResuming(handle) }
            #expect(try await source.uploadCheckpoint(handle)?.phase == .preparing)
        }
        #expect(try server.requests().filter { ($0["method"] as? String) == "POST" }.count == 2)
        try await source.abortResumableUpload(handle)
        #expect(try store.read(handle.id)?.phase == .aborted)
        await source.disconnect()
    }

    @Test(arguments: [false, true])
    func cancellationDuringReconciliationKeepsUnknownCommit(storageReadFails: Bool) async throws {
        let server = try OneDriveWriteServer(); defer { server.cleanUp() }
        let store = MemoryUploadSessionStore()
        let source = try OneDriveSource(configuration: server.configuration, endpoints: server.endpoints,
                                        resumableUploadService: "fixture", sessionStore: store)
        try await source.connect(server.credential)
        let file = try server.localFile(bytes: Data(repeating: 1, count: 400_000))
        let target = try await uploadTarget(source, path: "/cancel-reconcile.bin")
        let handle = try await source.prepareResumableUpload(from: file, to: target,
            options: .init(snapshotDirectory: server.workspace.appendingPathComponent("snapshots"), chunkSize: 327680))
        await #expect(throws: RemoteSyncError.secureStorageUnavailable) {
            try await source.uploadResuming(handle, progress: { _ in store.setFailReplace(true) })
        }
        store.setFailReplace(false)
        var record = try #require(try store.read(handle.id))
        record.phase = .reconciling
        try store.replace(record)
        let hold = server.workspace.appendingPathComponent("requests.jsonl.hold-status")
        try Data().write(to: hold)
        let before = try server.requests().count
        let operation = Task { try await source.uploadResuming(handle) }
        for _ in 0..<200 {
            if try server.requests().count > before { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try server.requests().count > before)
        store.setFailRead(storageReadFails)
        operation.cancel()
        await #expect(throws: RemoteSyncError.uploadCommitUnknown) { try await operation.value }
        store.setFailRead(false)
        #expect(try await source.uploadCheckpoint(handle)?.phase == .reconciling)
        try FileManager.default.removeItem(at: hold)
        await source.disconnect()
    }

}
#endif
