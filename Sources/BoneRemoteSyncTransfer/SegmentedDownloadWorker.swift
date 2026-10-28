import Foundation
import Darwin
import BoneRemoteSyncCore

/// One parent owns staging writes; children only return bounded immutable Data.
/// No persistent fragment bitmap or cross-process recovery is implied.
enum SegmentedDownloadWorker {
    static func download(source: any RemoteSource, entry: RemoteEntry, staging: URL,
                         strategy: RemoteDownloadStrategy, gate: MaterializationReadGate,
                         progress: @Sendable (Int64, Int64) -> Void) async throws -> Bool {
        guard let config = strategy.configuration else { return false }
        guard let ranged = source as? any RemoteByteRangeSource,
              let total = entry.size, total > 0,
              let version = ranged.byteRangeVersion(for: entry), !version.isEmpty,
              strategy.isRequired || total >= config.minimumFileSize else {
            if strategy.isRequired { throw RemoteByteRangeError.unavailable }
            return false
        }
        let first = try RemoteByteRange(offset: 0, length: min(config.segmentSize, total))
        // Probe with the actual first segment, never a redundant full-file HEAD/GET.
        let initial: Data
        do {
            initial = try await read(ranged, entry: entry, range: first, version: version, gate: gate)
        } catch RemoteByteRangeError.unavailable where !strategy.isRequired {
            try Task.checkCancellation()
            return false
        }
        try Task.checkCancellation()
        let descriptor = staging.withUnsafeFileSystemRepresentation {
            open($0!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw RemoteSyncError.permissionDenied(path: "segmented-staging") }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1 else { throw RemoteSyncError.integrityMismatch(path: "segmented-staging") }
        try output.write(contentsOf: initial)
        var completed = first.length
        progress(completed, total)
        // At most window child results plus the current write are resident.
        let window = min(config.maxConcurrentSegments, max(1, source.capabilities.maxConcurrentTransfers))
        try await withThrowingTaskGroup(of: (RemoteByteRange, Data).self) { group in
            var next = first.endExclusive
            func enqueue() throws -> Bool {
                guard next < total else { return false }
                let range = try RemoteByteRange(offset: next, length: min(config.segmentSize, total - next))
                next = range.endExclusive
                group.addTask {
                    (range, try await read(ranged, entry: entry, range: range, version: version, gate: gate))
                }
                return true
            }
            for _ in 0..<window { if try !enqueue() { break } }
            do {
                while let (range, data) = try await group.next() {
                    try Task.checkCancellation()
                    try output.seek(toOffset: UInt64(range.offset))
                    try output.write(contentsOf: data)
                    completed += range.length
                    progress(completed, total) // sum of verified written ranges, not contiguous prefix
                    try Task.checkCancellation()
                    _ = try enqueue()
                }
            } catch {
                group.cancelAll()
                throw error // structured scope drains all children before staging cleanup
            }
        }
        try Task.checkCancellation()
        guard completed == total, fstat(descriptor, &metadata) == 0, metadata.st_size == total else {
            throw RemoteSyncError.integrityMismatch(path: "segmented-staging")
        }
        try output.synchronize()
        return true
    }

    private static func read(_ source: any RemoteByteRangeSource, entry: RemoteEntry,
                             range: RemoteByteRange, version: String,
                             gate: MaterializationReadGate) async throws -> Data {
        try await gate.run {
            let data = try await source.readBytes(entry, range: range, requiringVersion: version)
            try Task.checkCancellation()
            guard Int64(data.count) == range.length else {
                throw RemoteSyncError.integrityMismatch(path: entry.path ?? entry.id)
            }
            return data
        }
    }
}
