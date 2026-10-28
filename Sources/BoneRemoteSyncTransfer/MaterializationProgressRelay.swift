import Foundation
import BoneRemoteSyncCore

/// Synchronous source callbacks may arrive on arbitrary executors. The lock only
/// protects subscriber state; user callbacks always run outside it.
final class MaterializationProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: RemoteMaterializationOptions] = [:]
    private var sequence: UInt64 = 0
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64?
    private var closed = false

    func add(_ id: UUID, options: RemoteMaterializationOptions) {
        lock.lock(); defer { lock.unlock() }
        if !closed { subscribers[id] = options }
    }
    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        subscribers[id] = nil
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; subscribers.removeAll()
    }
    func report(_ phase: RemoteTransferPhase, download: RemoteDownloadProgress? = nil) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        sequence += 1
        if let download {
            completedBytes = max(completedBytes, download.completedBytes)
            if let total = download.totalBytes { totalBytes = total }
        }
        let progress = RemoteTransferProgress(phase: phase, completedBytes: completedBytes,
                                              totalBytes: totalBytes, sequence: sequence)
        let targets = Array(subscribers.values)
        lock.unlock()
        for options in targets {
            if let download { options.phaseProgress?(download) }
            options.transferProgress?(progress)
        }
    }
}
