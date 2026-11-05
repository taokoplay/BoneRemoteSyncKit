import Foundation
import Testing
@testable import BoneRemoteSyncWebDAV

@Suite struct DAVUploadProgressTests {
    @Test func completionReportsActualSentBytesWithoutIntermediateCallback() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // A real suspended task gives a deterministic observed count without network I/O.
        // WebDAVWritingTests separately verifies the final count for an actual 18-byte PUT.
        let task = session.dataTask(with: URL(string: "https://example.invalid/upload")!)
        let body = DAVBodyState()
        let delegate = DAVSessionDelegate()
        let progress = UploadProgressValues()
        delegate.register(body, for: task, progress: progress.record) { _ in }
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        #expect(progress.values == [0])
        #expect(try await body.next() == nil)
        // Late callbacks cannot append values after the task was retired.
        delegate.urlSession(session, task: task, didSendBodyData: 18, totalBytesSent: 18, totalBytesExpectedToSend: 18)
        #expect(progress.values == [0])
    }

    @Test func failedCompletionDoesNotSynthesizeSuccessfulProgress() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.invalid/upload")!)
        let body = DAVBodyState()
        let delegate = DAVSessionDelegate()
        let progress = UploadProgressValues()
        delegate.register(body, for: task, progress: progress.record) { _ in }
        delegate.urlSession(session, task: task, didSendBodyData: 5, totalBytesSent: 5, totalBytesExpectedToSend: 18)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        #expect(progress.values == [5])
        await #expect(throws: URLError.self) { try await body.next() }
    }
}


private final class UploadProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    func record(_ bytes: Int64) { lock.withLock { storage.append(bytes) } }
    var values: [Int64] { lock.withLock { storage } }
}
