import Foundation
import CryptoKit
import Darwin
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncWebDAV

struct CheckpointFileFixture {
    let directory: URL
    let target: WebDAVDownloadTarget
    let handle: FileHandle
    let record: DAVCheckpointRecord
    let store: DAVCheckpointStore
    init(part: Data = Data("abcde".utf8), committedBytes: Int64 = 3) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoneCheckpoint-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        target = try WebDAVDownloadTarget(destination: directory.appendingPathComponent("target"))
        try part.write(to: target.part)
        handle = try FileHandle(forUpdating: target.part)
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw RemoteSyncError.conflict(path: "fixture") }
        let binding = DAVCheckpointBinding(sourceNamespace: "account", root: "https://example.com/dav/", remotePath: "/file", destination: target.lockKey)
        record = DAVCheckpointRecord(binding: binding, etag: "\"v1\"", expectedSize: 26, committedBytes: committedBytes,
            prefixSHA256: DAVPartHasher.hex(SHA256.hash(data: part.prefix(Int(committedBytes)))) ,
            partDevice: UInt64(info.st_dev), partInode: UInt64(info.st_ino))
        store = DAVCheckpointStore(target: target, binding: binding)
    }
    func cleanUp() { try? handle.close(); try? FileManager.default.removeItem(at: directory) }
}

@Suite struct DAVCheckpointTests {
    @Test func roundTripAndPermissions() throws {
        let f = try CheckpointFileFixture(); defer { f.cleanUp() }
        #expect(try f.store.load() == nil)
        try f.store.save(f.record)
        #expect(try f.store.load() == f.record)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try f.store.removeIfMatching(f.record)
        #expect(try f.store.load() == nil)
    }

    @Test func tailIsNotIncludedInCommittedPrefix() throws {
        let f = try CheckpointFileFixture(); defer { f.cleanUp() }
        let hasher = try DAVPartHasher.verifyPrefix(handle: f.handle, record: f.record, check: {})
        #expect(DAVPartHasher.hex(hasher.finalize()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try Data(contentsOf: f.target.part) == Data("abcde".utf8))
    }

    @Test func modifiedShortOrReplacedPartCannotValidate() throws {
        for content in ["ab", "axcde"] {
            let f = try CheckpointFileFixture(); defer { f.cleanUp() }
            try f.handle.truncate(atOffset: 0); try f.handle.seek(toOffset: 0)
            try f.handle.write(contentsOf: Data(content.utf8))
            #expect(throws: (any Error).self) { try DAVPartHasher.verifyPrefix(handle: f.handle, record: f.record, check: {}) }
        }
    }

    @Test func corruptOversizedAndForeignBindingAreRejected() throws {
        let f = try CheckpointFileFixture(); defer { f.cleanUp() }
        try f.store.save(f.record)
        let foreign = DAVCheckpointStore(target: f.target, binding: .init(sourceNamespace: "other", root: "https://example.com/dav/", remotePath: "/file", destination: f.target.lockKey))
        #expect(throws: (any Error).self) { try foreign.load() }
        for data in [Data("{}".utf8), Data(repeating: 120, count: 65537)] {
            try data.write(to: f.store.url)
            #expect(throws: (any Error).self) { try f.store.load() }
        }
    }

    @Test(arguments: ["symlink", "hardlink", "directory", "fifo"])
    func unsafeCheckpointIsNeverReadOverwrittenOrRemoved(kind: String) throws {
        let f = try CheckpointFileFixture(); defer { f.cleanUp() }
        let protected = f.directory.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: protected)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: f.store.url, withDestinationURL: protected)
        case "hardlink": try FileManager.default.linkItem(at: protected, to: f.store.url)
        case "directory": try FileManager.default.createDirectory(at: f.store.url, withIntermediateDirectories: false)
        default: #expect(mkfifo(f.store.url.path, 0o600) == 0)
        }
        #expect(throws: (any Error).self) { try f.store.load() }
        #expect(throws: (any Error).self) { try f.store.save(f.record) }
        #expect(throws: (any Error).self) { try f.store.removeIfMatching(f.record) }
        #expect(try Data(contentsOf: protected) == Data("keep".utf8))
    }

    @Test func invalidRecordAndCancellationCannotCommit() throws {
        let f = try CheckpointFileFixture(); defer { f.cleanUp() }
        var record = f.record
        record.schemaVersion = 2
        #expect(throws: (any Error).self) { try f.store.save(record) }
        record = f.record; record.committedBytes = -1
        #expect(throws: (any Error).self) { try f.store.save(record) }
        record = f.record; record.phase = .readyToInstall
        #expect(throws: (any Error).self) { try f.store.save(record) }
        #expect(throws: CancellationError.self) { try DAVPartHasher.verifyPrefix(handle: f.handle, record: f.record, check: { throw CancellationError() }) }
    }
}
