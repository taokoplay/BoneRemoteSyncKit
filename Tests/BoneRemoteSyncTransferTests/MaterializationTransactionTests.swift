import Foundation
import Testing
@testable import BoneRemoteSyncTransfer
import BoneRemoteSyncCore

@Suite struct MaterializationTransactionTests {
    @Test func rejectsSymbolicAndHardLinkedStaging() throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let outside = f.root.appendingPathComponent("outside")
        try Data("original".utf8).write(to: outside)
        for symlink in [true, false] {
            let transaction = try MaterializationTransaction(cacheDirectory: f.cache)
            if symlink { try FileManager.default.createSymbolicLink(at: transaction.staging, withDestinationURL: outside) }
            else { try FileManager.default.linkItem(at: outside, to: transaction.staging) }
            #expect(throws: RemoteSyncError.self) { try transaction.verify(expectedSize: nil) }
            transaction.cleanupUncommitted()
            #expect(try Data(contentsOf: outside) == Data("original".utf8))
        }
    }
    @Test func replacedStagingCannotBeInstalledAndExistingTargetIsNotOverwritten() throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let transaction = try MaterializationTransaction(cacheDirectory: f.cache)
        defer { transaction.cleanupUncommitted() }
        try Data("valid".utf8).write(to: transaction.staging)
        try transaction.verify(expectedSize: 5)
        try Data("other".utf8).write(to: transaction.staging, options: .atomic)
        #expect(throws: RemoteSyncError.self) { try transaction.commit() }
        try transaction.verify(expectedSize: 5)
        let final = transaction.staging.deletingLastPathComponent().appendingPathComponent("content")
        try Data("keep".utf8).write(to: final)
        #expect(throws: RemoteSyncError.self) { try transaction.commit() }
        #expect(try Data(contentsOf: final) == Data("keep".utf8))
    }
    @Test func rejectsSymlinkCacheRootAndNonFileURL() throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.cache, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try MaterializationTransaction(cacheDirectory: f.cache) }
        for address in ["https://example.com/cache", "https://localhost/cache", "file://remote-host/cache"] {
            #expect(throws: RemoteSyncError.unsupported(operation: "缓存必须为本地文件目录")) {
                try MaterializationTransaction(cacheDirectory: URL(string: address)!)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
