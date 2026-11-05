import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncOPDS

@Suite struct OPDSLocationTests {
    @Test func originsUseEffectivePortsAndIgnorePaths() {
        #expect(OPDSLocation.sameOrigin(URL(string: "https://EXAMPLE.test/catalog?q=1")!, URL(string: "https://example.test:443/book")!))
        #expect(OPDSLocation.sameOrigin(URL(string: "http://example.test/a")!, URL(string: "http://example.test:80/b")!))
        #expect(!OPDSLocation.sameOrigin(URL(string: "https://example.test")!, URL(string: "https://example.test:8443")!))
        #expect(!OPDSLocation.sameOrigin(URL(string: "https://example.test")!, URL(string: "http://example.test:443")!))
    }

    @Test func catalogOriginsAndFragments() throws {
        let config = try OPDSConfiguration(rootURL: URL(string: "https://library.test/catalog")!,
                                           allowedCatalogOrigins: [URL(string: "https://search.test:443")!])
        let result = try OPDSLocation.validate(URL(string: "https://search.test/find?q=a%26b#entry")!, configuration: config, catalog: true)
        #expect(result.absoluteString == "https://search.test/find?q=a%26b")
        #expect(throws: OPDSError.disallowedOrigin) {
            try OPDSLocation.validate(URL(string: "https://cdn.test/book")!, configuration: config, catalog: true)
        }
        #expect(try OPDSLocation.validate(URL(string: "https://cdn.test/book")!, configuration: config, catalog: false).host == "cdn.test")
    }

    @Test(arguments: ["https://user:secret@library.test/book", "https://@library.test/book", "file:///book", "ftp://library.test/book", "http://library.test/book", "https://library.test:0/book", "https://library.test:65536/book"])
    func unsafeURLsAreRejected(value: String) throws {
        let config = try OPDSConfiguration(rootURL: URL(string: "https://library.test/catalog")!)
        let url = try #require(URL(string: value))
        #expect(throws: OPDSError.invalidURL) { try OPDSLocation.validate(url, configuration: config, catalog: false) }
    }

    @Test func explicitHTTPAndRelativeQueries() throws {
        let config = try OPDSConfiguration(rootURL: URL(string: "http://localhost:8123/catalog")!, allowsInsecureHTTP: true)
        #expect(try OPDSLocation.validate(URL(string: "http://localhost:8123/catalog?page=2#entry")!, configuration: config, catalog: true).fragment == nil)
        #expect(OPDSLocation.resolve("../book?q=a%2Fb", relativeTo: URL(string: "https://library.test/catalog/feed")!)?.absoluteString == "https://library.test/book?q=a%2Fb")
        #expect(OPDSLocation.resolve("/book\nsecret", relativeTo: config.rootURL) == nil)
    }

    @Test func stagingInstallsOnlyAfterExplicitCommit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("book.epub")
        let old = Data("old".utf8), book = Data(repeating: 65, count: 150_000)
        try old.write(to: destination)
        let file = try OPDSDownloadFile(destination: destination)
        defer { file.cleanup() }
        try file.validate(overwrite: true)
        try file.open()
        try file.write(book)
        try file.sync()
        #expect(try Data(contentsOf: destination) == old)
        try file.install(overwrite: true, bytes: Int64(book.count))
        file.cleanup()
        #expect(try Data(contentsOf: destination) == book)
        #expect(!FileManager.default.fileExists(atPath: file.staging.path))
    }

    @Test func lateNonOverwriteConflictPreservesDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("book.pdf")
        let file = try OPDSDownloadFile(destination: destination)
        try file.validate(overwrite: false)
        try file.open()
        try file.write(Data("new".utf8))
        try file.sync()
        try Data("other writer".utf8).write(to: destination)
        #expect(throws: RemoteSyncError.conflict(path: destination.path)) { try file.install(overwrite: false, bytes: 3) }
        file.cleanup()
        #expect(try Data(contentsOf: destination) == Data("other writer".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.staging.path))
    }

    @Test(arguments: [false, true])
    func destinationLinksCannotBeOverwritten(hardlink: Bool) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim"), destination = root.appendingPathComponent("book")
        try Data("keep".utf8).write(to: victim)
        if hardlink { try FileManager.default.linkItem(at: victim, to: destination) }
        else { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim) }
        let file = try OPDSDownloadFile(destination: destination)
        #expect(throws: RemoteSyncError.conflict(path: destination.path)) { try file.validate(overwrite: true) }
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
    }

    @Test func replacedStagingIsNeitherInstalledNorRemoved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("book")
        let file = try OPDSDownloadFile(destination: destination)
        try file.open()
        try file.write(Data("new".utf8))
        try FileManager.default.removeItem(at: file.staging)
        try Data("unrelated".utf8).write(to: file.staging)
        #expect(throws: RemoteSyncError.conflict(path: destination.path)) { try file.install(overwrite: false, bytes: 3) }
        file.cleanup()
        #expect(try Data(contentsOf: file.staging) == Data("unrelated".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func parentAliasesShareDestinationLock() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let direct = try OPDSDownloadFile(destination: directory.appendingPathComponent("new/book"))
        let throughAlias = try OPDSDownloadFile(destination: alias.appendingPathComponent("new/book"))
        #expect(direct.lockKey == throughAlias.lockKey)
    }

    private func temporaryDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["PI_SCRATCH_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("BoneOPDSLocation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
