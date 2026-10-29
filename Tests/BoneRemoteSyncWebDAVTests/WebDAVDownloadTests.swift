#if os(macOS)
import Foundation
import Testing
import BoneRemoteSyncTestSupport
import BoneRemoteSyncCore
import BoneRemoteSyncWebDAV

private final class DAVPhaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RemoteDownloadProgress] = []
    func record(_ event: RemoteDownloadProgress) { lock.withLock { events.append(event) } }
    var values: [RemoteDownloadProgress] { lock.withLock { events } }
}
@Suite(.enabled(if: PythonFixture.isAvailable, "HTTP fixture 需要 Python 3")) struct WebDAVDownloadTests {
    @Test func completeDownloadAndEmptyFileUseAtomicTargetAndReportBytes() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let progress = DAVProgress()
        let target = server.file()
        try Data("old".utf8).write(to: target)
        let result = try await source.download(path: "/hello.txt", to: target, options: .init(expectedETag: "\"v1\"", progress: { progress.record($0) }))
        #expect(try String(contentsOf: target, encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
        #expect(result.size == 26 && result.etag == "\"v1\"")
        #expect(progress.snapshot().last == 26)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("part").path))
        let empty = server.file("nested/empty")
        _ = try await source.download(path: "/empty.txt", to: empty)
        #expect(try Data(contentsOf: empty).isEmpty)
        await source.disconnect()
    }

    @Test func resumedDownloadReportsTransferPhaseAndSourceTotal() async throws {
        let server = try WebDAVTestServer(); defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let probe = DAVPhaseProbe()
        let target = server.file()
        try Data("abcde".utf8).write(to: target.appendingPathExtension("part"))
        _ = try await source.download(path: "/hello.txt", to: target,
            options: .init(resumeFrom: 5, expectedETag: "\"v1\"", phaseProgress: { probe.record($0) }))
        #expect(probe.values.first?.completedBytes == 5)
        #expect(probe.values.last?.completedBytes == 26)
        #expect(probe.values.last?.fractionCompleted == 1)
        #expect(probe.values.allSatisfy { $0.phase == .transferring && $0.totalBytes == 26 })
        await source.disconnect()
    }

    @Test func resumeRequestsRangeAndIfMatchAndAppendsOnlyMatchingRepresentation() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        try Data("abcde".utf8).write(to: target.appendingPathExtension("part"))
        _ = try await source.download(path: "/hello.txt", to: target, options: .init(resumeFrom: 5, expectedETag: "\"v1\""))
        #expect(try String(contentsOf: target, encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
        let request = try #require(server.requests().last)
        #expect(request["range"] as? String == "bytes=5-")
        #expect(request["ifMatch"] as? String == "\"v1\"")
        await source.disconnect()
    }

    @Test(arguments: ["ignore-range.txt", "bad-range.txt", "changed.txt", "wrong-etag.txt", "no-etag.txt", "weak.txt"])
    func invalidResumeResponsePreservesOldTargetAndPart(name: String) async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        let part = target.appendingPathExtension("part")
        try Data("old".utf8).write(to: target)
        try Data("abcde".utf8).write(to: part)
        await #expect(throws: (any Error).self) {
            try await source.download(path: "/\(name)", to: target, options: .init(resumeFrom: 5, expectedETag: "\"v1\""))
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(try String(contentsOf: part, encoding: .utf8) == "abcde")
        await source.disconnect()
    }

    @Test(arguments: [Int64(-1), 4, 5])
    func badResumeOffsetOrMissingStrongETagDoesNotWrite(offset: Int64) async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        try Data("abcde".utf8).write(to: target.appendingPathExtension("part"))
        await #expect(throws: (any Error).self) {
            try await source.download(path: "/hello.txt", to: target, options: .init(resumeFrom: offset))
        }
        #expect(try String(contentsOf: target.appendingPathExtension("part"), encoding: .utf8) == "abcde")
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        await source.disconnect()
    }

    @Test func cancellationAfterReceivingBytesRetainsPartAndOldTargetThenCanResume() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        try Data("old".utf8).write(to: target)
        let progress = DAVProgress()
        let task = Task {
            try await source.download(path: "/large.bin", to: target, options: .init(progress: { bytes in
                progress.record(bytes)
                if bytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }))
        }
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        let offset = try #require(progress.snapshot().last)
        #expect(offset > 0 && offset < 3_145_728)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(try Data(contentsOf: target.appendingPathExtension("part")).count == offset)
        _ = try await source.download(path: "/large.bin", to: target, options: .init(resumeFrom: offset, expectedETag: "\"v1\""))
        let contents = try Data(contentsOf: target)
        #expect(contents.count == 3_145_728)
        #expect(contents.prefix(256) == Data((0...255).map(UInt8.init)))
        await source.disconnect()
    }

    @Test func truncatedAndRedirectedDownloadNeverInstallsTarget() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        try Data("old".utf8).write(to: target)
        let truncatedEntry = RemoteEntry(id: "truncated.txt", path: "/truncated.txt", name: "truncated.txt", type: .file)
        await #expect(throws: (any Error).self) { try await source.download(truncatedEntry, to: target, options: .init()) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        let redirectEntry = RemoteEntry(id: "redirect.txt", path: "/redirect.txt", name: "redirect.txt", type: .file)
        await #expect(throws: RemoteSyncError.unsupported(operation: "WebDAV 重定向；请使用最终地址")) {
            try await source.download(redirectEntry, to: target, options: .init())
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        await source.disconnect()
    }

    @Test func existingDestinationIsPreservedWhenOverwriteDisabled() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        try Data("old".utf8).write(to: target)
        await #expect(throws: RemoteSyncError.conflict(path: target.path)) {
            try await source.download(path: "/hello.txt", to: target, options: .init(overwrite: false))
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("part").path))
        await source.disconnect()
    }

    @Test func disconnectCancelsOldTransferAndReconnectCannotInstallItsTarget() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        try Data("old".utf8).write(to: target)
        let (events, continuation) = AsyncStream<Int64>.makeStream()
        let task = Task {
            try await source.download(path: "/slow.bin", to: target, options: .init(progress: { continuation.yield($0) }))
        }
        defer { task.cancel(); continuation.finish() }
        for await count in events where count > 0 { break }
        await source.disconnect()
        try await source.connect(.anonymous)
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        _ = try await source.download(path: "/hello.txt", to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
        await source.disconnect()
    }

    @Test func rejectsConcurrentSameOrOverlappingDestination() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        let (events, continuation) = AsyncStream<Int64>.makeStream()
        let task = Task {
            try await source.download(path: "/slow.bin", to: target, options: .init(progress: { continuation.yield($0) }))
        }
        defer { task.cancel(); continuation.finish() }
        for await count in events where count > 0 { break }
        for destination in [target, target.appendingPathExtension("part")] {
            await #expect(throws: RemoteSyncError.conflict(path: destination.path)) {
                try await source.download(path: "/hello.txt", to: destination)
            }
        }
        task.cancel()
        await #expect(throws: RemoteSyncError.cancelled) { try await task.value }
        await source.disconnect()
    }

    @Test func caseEquivalentDestinationCannotModifySuccessfulDownload() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file("target")
        let alias = server.file("TARGET")
        let (events, continuation) = AsyncStream<Int64>.makeStream()
        let task = Task {
            try await source.download(path: "/slow.bin", to: target, options: .init(progress: { continuation.yield($0) }))
        }
        defer { task.cancel(); continuation.finish() }
        for await count in events where count > 0 { break }
        await #expect(throws: RemoteSyncError.conflict(path: alias.path)) {
            try await source.download(path: "/hello.txt", to: alias)
        }
        task.cancel()
        _ = try? await task.value
        _ = try await source.download(path: "/hello.txt", to: alias)
        #expect(try String(contentsOf: alias, encoding: .utf8) == "abcdefghijklmnopqrstuvwxyz")
        await source.disconnect()
    }

    @Test func nonOverwritingInstallRejectsDestinationCreatedDuringTransfer() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        let didWrite = DAVProgress()
        await #expect(throws: RemoteSyncError.conflict(path: target.path)) {
            try await source.download(path: "/large.bin", to: target, options: .init(overwrite: false, progress: { count in
                if count > 0, didWrite.snapshot().isEmpty {
                    try? Data("race winner".utf8).write(to: target)
                    didWrite.record(count)
                }
            }))
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "race winner")
        #expect(try Data(contentsOf: target.appendingPathExtension("part")).count == 3_145_728)
        await source.disconnect()
    }

    @Test func mismatchedPartLengthWithStrongETagDoesNotSendGET() async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        let part = target.appendingPathExtension("part")
        try Data("abcde".utf8).write(to: part)
        await #expect(throws: RemoteSyncError.conflict(path: part.path)) {
            try await source.download(path: "/hello.txt", to: target, options: .init(resumeFrom: 4, expectedETag: "\"v1\""))
        }
        #expect(try server.requests().allSatisfy { $0["method"] as? String != "GET" })
        await source.disconnect()
    }

    @Test(arguments: ["target", "part", "hardlink", "directory"])
    func localSymlinkOrHardlinkedPartIsNotTruncated(kind: String) async throws {
        let server = try WebDAVTestServer()
        defer { server.cleanUp() }
        let source = try server.source()
        try await source.connect(.anonymous)
        let target = server.file()
        let protected = server.file("protected.txt")
        try Data("keep".utf8).write(to: protected)
        let link = kind == "target" ? target : target.appendingPathExtension("part")
        if kind == "hardlink" { try FileManager.default.linkItem(at: protected, to: link) }
        else if kind == "directory" { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
        else { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protected) }
        await #expect(throws: (any Error).self) { try await source.download(path: "/hello.txt", to: target) }
        #expect(try String(contentsOf: protected, encoding: .utf8) == "keep")
        await source.disconnect()
    }
}
#endif
