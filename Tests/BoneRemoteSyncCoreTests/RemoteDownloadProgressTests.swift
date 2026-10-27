import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

@Suite struct RemoteDownloadProgressTests {
    @Test func localTransferReportsBytesIncludingResumeOffset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BonePhase-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abcdef".utf8).write(to: root.appendingPathComponent("in"))
        let output = root.appendingPathComponent("out")
        try Data("abc".utf8).write(to: output.appendingPathExtension("part"))
        let source = LocalFileSource(root: root)
        try await source.connect(.anonymous)
        let probe = DownloadPhaseProbe()
        _ = try await source.download(path: "/in", to: output, options: .init(resumeFrom: 3, phaseProgress: { probe.record($0) }))
        #expect(probe.values.map(\.completedBytes) == [3, 6])
        #expect(probe.values.map(\.fractionCompleted) == [0.5, 1])
        #expect(probe.values.allSatisfy { $0.phase == .transferring && $0.preparationState == nil && $0.totalBytes == 6 })
    }

    @Test func snapshotsNormalizeInvalidValuesAndKeepStagesSeparate() {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(RemoteDownloadProgress(phase: .preparing, fractionCompleted: value).fractionCompleted == nil)
        }
        #expect(RemoteDownloadProgress(phase: .preparing, fractionCompleted: 2).fractionCompleted == 1)
        #expect(RemoteDownloadProgress(phase: .preparing, fractionCompleted: -1).fractionCompleted == 0)
        let invalid = RemoteDownloadProgress(phase: .transferring, preparationState: .ready, completedBytes: -1, totalBytes: -5)
        #expect(invalid.completedBytes == 0 && invalid.totalBytes == 0)
        #expect(invalid.preparationState == nil)
    }
}

private final class DownloadPhaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [RemoteDownloadProgress] = []
    func record(_ value: RemoteDownloadProgress) { lock.withLock { snapshots.append(value) } }
    var values: [RemoteDownloadProgress] { lock.withLock { snapshots } }
}
