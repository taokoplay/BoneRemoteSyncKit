import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncTransfer

private actor CompletionGate {
    var entered = false
    var completed = false
    private var continuation: CheckedContinuation<Void, Never>?
    func run() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
    func markCompleted() { completed = true }
}

@Suite struct TransferCompletionTests {
    @Test func concurrentReleaseCallsAllWaitForCleanup() async throws {
        let gate = CompletionGate()
        let releaser = LeaseReleaser { await gate.run() }
        let first = Task { await releaser.release() }
        try await eventually { await gate.entered }
        let second = Task { await releaser.release(); await gate.markCompleted() }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await gate.completed == false)
        await gate.open()
        await first.value; await second.value
        #expect(await gate.completed)
    }

    @Test func verificationAndCommitRetainTransferredByteCounts() {
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var values: [RemoteTransferProgress] = []
            func append(_ value: RemoteTransferProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        }
        let relay = MaterializationProgressRelay()
        let probe = Probe()
        relay.add(UUID(), options: .init(transferProgress: { probe.append($0) }))
        relay.report(.transferring, download: .init(phase: .transferring, completedBytes: 7, totalBytes: 7))
        relay.report(.verifying)
        relay.report(.committing)
        #expect(probe.values.map(\.completedBytes) == [7, 7, 7])
        #expect(probe.values.map(\.totalBytes) == [7, 7, 7])
        #expect(probe.values.map(\.sequence) == [1, 2, 3])
    }
}
