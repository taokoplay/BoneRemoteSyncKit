#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncWebDAV

@Suite(.serialized) struct WebDAVListingCoverageTests {
    @Test(arguments: ["dav", "coverage-missing", "coverage-duplicate"])
    func filteredOrConflictingResponsesAreNotComplete(root: String) async throws {
        let server = try WebDAVTestServer(root: root)
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let page = try await source.list(path: "/")
        #expect(page.coverage == .partial)
        #expect(page.entries.allSatisfy { $0.path?.contains("steal") == false })
        await #expect(throws: RemoteSyncError.self) {
            _ = try await source.walk(path: "/", options: .init()) { _ in }
        }
        await source.disconnect()
    }

    @Test func explicitHiddenFilterAndSuccessfulMembersRemainComplete() async throws {
        let server = try WebDAVTestServer(root: "coverage-hidden-failed")
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        #expect(try await source.list(path: "/").coverage == .complete)
        #expect(try await source.list(path: "/", request: .init(includeHidden: true)).coverage == .partial)
        await source.disconnect()
    }

    @Test func cleanDirectoryCanBeWalkedCompletely() async throws {
        let server = try WebDAVTestServer(root: "coverage-complete")
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        #expect(try await source.list(path: "/").coverage == .complete)
        let result = try await source.walk(path: "/", options: .init()) { _ in }
        #expect(result.entryCount == 6)
        await source.disconnect()
    }
}
#endif
