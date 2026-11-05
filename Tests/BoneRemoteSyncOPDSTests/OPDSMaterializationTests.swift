#if os(macOS)
import Foundation
import CryptoKit
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
import BoneRemoteSyncTestSupport
import BoneRemoteSyncOPDS

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python 3")) struct OPDSMaterializationTests {
    @Test func materializationNoVersionReuseChecksumAndLease() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let book = try #require(await source.browse().publications.first)
        let reference = try await source.prepareDownload(book, acquisition: book.acquisitions[0])
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: try await source.sourceBinding(), cacheDirectory: server.file("cache"))
        let coordinator = RemoteTransferCoordinator(materializer: materializer)
        let checksum = try RemoteContentChecksum(algorithm: .sha256, digest: Data(SHA256.hash(data: OPDSTestServer.payload)))
        let options = RemoteMaterializationOptions(retention: .persistent, expectedChecksum: checksum)
        let firstID = await coordinator.submit(.init(reference: reference, options: options))
        let first = try await coordinator.wait(for: firstID)
        #expect(first.version == nil && first.entry.size == nil)
        #expect(try Data(contentsOf: first.url) == OPDSTestServer.payload)
        let second = try await materializer.materialize(reference, options: options)
        #expect(first.url != second.url)
        #expect(try server.requests().filter { ($0["path"] as? String) == "/files/book.epub" }.count == 2)
        let badChecksum = try RemoteContentChecksum(algorithm: .sha256, digest: Data(repeating: 0, count: 32))
        await #expect(throws: RemoteSyncError.self) {
            try await materializer.materialize(reference, options: .init(expectedChecksum: badChecksum))
        }
        let version = RemoteVersion(source: reference.source, locator: reference.locator, value: "fake", strength: .strongConditional)
        await #expect(throws: RemoteSyncError.self) { try await materializer.materialize(reference, options: .init(consistency: .requireVersion(version))) }
        await #expect(throws: RemoteByteRangeError.unavailable) { try await materializer.materialize(reference, options: .init(downloadStrategy: .segmentedRequired())) }
        await first.release(); await second.release()
        await coordinator.shutdown(); await materializer.shutdown()
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        await source.disconnect()
    }
    @Test func concurrencyAndShutdownUseExistingTransferLimits() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source("/catalog/root?target=/slow", concurrent: 1); try await source.connect(.anonymous)
        let book = try #require(await source.browse().publications.first)
        let reference = try await source.prepareDownload(book, acquisition: book.acquisitions[0])
        let materializer = RemoteFileMaterializer(source: source, sourceBinding: try await source.sourceBinding(), cacheDirectory: server.file("cache"))
        let coordinator = RemoteTransferCoordinator(materializer: materializer, maxConcurrentTransfers: 3)
        let a = await coordinator.submit(.init(reference: reference)); let b = await coordinator.submit(.init(reference: reference))
        let first = try await coordinator.wait(for: a); let second = try await coordinator.wait(for: b)
        let maximum = try String(contentsOf: server.file("maximum.txt"), encoding: .utf8)
        #expect(maximum == "1")
        await first.release(); await second.release()
        let cancelled = await coordinator.submit(.init(reference: reference))
        await coordinator.shutdown()
        await #expect(throws: (any Error).self) { try await coordinator.wait(for: cancelled) }
        await materializer.shutdown(); await source.disconnect()
    }
}
#endif
