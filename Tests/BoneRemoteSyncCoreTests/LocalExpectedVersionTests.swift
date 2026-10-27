import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

@Suite struct LocalExpectedVersionTests {
    @Test func unsupportedConditionalUploadDoesNotCreateParentsOrReplaceTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVersion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        try Data("keep".utf8).write(to: input)
        let source = LocalFileSource(root: root); try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.self) {
            try await source.upload(from: input, to: "/new/file", options: .init(expectedETag: "v1"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        await source.disconnect()
    }
}
