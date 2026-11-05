#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer
import BoneRemoteSyncTestSupport
@testable import BoneRemoteSyncOPDS

@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python 3")) struct OPDSDownloadTests {
    func selection(_ source: OPDSSource, index: Int = 0) async throws -> RemoteEntry {
        let book = try #require(await source.browse().publications.first)
        let reference = try await source.prepareDownload(book, acquisition: book.acquisitions[index])
        guard case .path(let path) = reference.locator else { throw OPDSError.invalidReference }
        return try await source.stat(path: path)
    }
    @Test func genericAcquisitionAcceptsConcreteSupportedResponse() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source("/catalog/root?target=/files/generic.pdf")
        try await source.connect(.anonymous)
        let entry = try await selection(source)
        #expect(entry.contentType == "application/octet-stream")
        _ = try await source.download(entry, to: server.file("generic"), options: .init())
        #expect(try Data(contentsOf: server.file("generic")) == OPDSTestServer.payload)
        await source.disconnect()
    }

    @Test(arguments: [0, 1, 2]) func selectedFormatsDownloadWithoutFileVersion(_ index: Int) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source(); try await source.connect(.anonymous)
        let entry = try await selection(source, index: index)
        #expect(entry.size == nil && entry.etag == nil && entry.modifiedAt == nil)
        let progress = OPDSProgressBox()
        let output = server.file("book")
        _ = try await source.download(entry, to: output, options: .init(overwrite: false, phaseProgress: { progress.append($0) }))
        #expect(try Data(contentsOf: output) == OPDSTestServer.payload)
        #expect(progress.values.last?.completedBytes == Int64(OPDSTestServer.payload.count))
        #expect(try await source.stat(path: #require(entry.path)) == entry)
        await #expect(throws: RemoteSyncError.conflict(path: output.path)) {
            try await source.download(entry, to: output, options: .init(overwrite: false))
        }
        await #expect(throws: RemoteSyncError.self) { try await source.download(entry, to: output, options: .init(resumeFrom: 1)) }
        await #expect(throws: RemoteSyncError.self) { try await source.download(entry, to: output, options: .init(expectedETag: "v1")) }
        await #expect(throws: RemoteSyncError.self) { try await source.list(path: "/") }
        await source.disconnect()
    }
    @Test(arguments: ["/html", "/fake-html", "/short"])
    func failedDownloadsPreserveOriginalAndCleanStaging(_ target: String) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source("/catalog/root?target=\(target)"); try await source.connect(.anonymous)
        let entry = try await selection(source)
        let output = server.file("book"); try Data("original".utf8).write(to: output)
        await #expect(throws: (any Error).self) { try await source.download(entry, to: output, options: .init()) }
        #expect(try String(contentsOf: output, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-opds-") })
        await source.disconnect()
    }
    @Test func unknownLengthHasNoInventedFractionAndCrossOriginHasNoCredentials() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source("/catalog/root?target=/unknown"); try await source.connect(.anonymous)
        let entry = try await selection(source); let box = OPDSProgressBox()
        _ = try await source.download(entry, to: server.file("unknown"), options: .init(phaseProgress: { box.append($0) }))
        #expect(!box.values.isEmpty && box.values.allSatisfy { $0.totalBytes == nil && $0.fractionCompleted == nil })
        await source.disconnect()
        let cross = try server.source("/catalog/root?target=/cross-download")
        try await cross.connect(.basic(username: "user", password: "pass"))
        let crossEntry = try await selection(cross)
        _ = try await cross.download(crossEntry, to: server.file("cross"), options: .init())
        #expect(try Data(contentsOf: server.file("cross")) == OPDSTestServer.payload)
        #expect(try server.requests().last?["authorization"] is NSNull)
        await cross.disconnect()
    }
    @Test(arguments: [false, true]) func cancellationOrDisconnectCannotInstall(_ disconnect: Bool) async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source("/catalog/root?target=/slow"); try await source.connect(.anonymous)
        let entry = try await selection(source); let output = server.file("cancelled")
        try Data("original".utf8).write(to: output)
        let task = Task { try await source.download(entry, to: output, options: .init()) }
        try await server.waitForRequest("/slow")
        if disconnect { await source.disconnect() } else { task.cancel() }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try String(contentsOf: output, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.workspace.path).allSatisfy { !$0.hasPrefix(".bone-opds-") })
        await source.disconnect()
    }
    @Test func sameDestinationAndModifiedEntriesAreRejected() async throws {
        let server = try OPDSTestServer(); defer { server.cleanUp() }
        let source = try server.source("/catalog/root?target=/slow"); try await source.connect(.anonymous)
        let entry = try await selection(source); let output = server.file("locked")
        let task = Task { try await source.download(entry, to: output, options: .init()) }
        try await server.waitForRequest("/slow")
        await #expect(throws: RemoteSyncError.conflict(path: output.path)) { try await source.download(entry, to: output, options: .init()) }
        let forged = RemoteEntry(id: entry.id, path: entry.path, name: "changed", type: .file)
        await #expect(throws: OPDSError.invalidReference) { try await source.download(forged, to: server.file("forged"), options: .init()) }
        task.cancel(); _ = await task.result
        await source.disconnect()
    }
}
#endif
