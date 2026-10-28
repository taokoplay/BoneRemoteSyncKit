import Foundation
import Testing
import BoneRemoteSyncCore
import BoneRemoteSyncTransfer

@Suite struct SegmentedDownloadTests {
    private let binding = RemoteSourceBinding(kind: .cloudAPI, identity: "range-fixture")
    private let config = RemoteSegmentedDownloadOptions(segmentSize: 8, maxConcurrentSegments: 3, minimumFileSize: 1)

    @Test func protocolAloneEnablesAnotherProviderAndAssemblesOutOfOrder() async throws {
        let source = RangeSource()
        let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
        let progress = SegmentProgress()
        let lease = try await m.materialize(.init(source: binding, path: "/file"), options: .init(
            downloadStrategy: .segmentedRequired(config), phaseProgress: { progress.record($0.completedBytes) }))
        #expect(try Data(contentsOf: lease.url) == RangeSource.payload)
        #expect(await source.ordinary == 0)
        let ranges = await source.ranges.sorted { $0.offset < $1.offset }
        #expect(ranges.map(\.offset) == [0, 8, 16, 24, 32, 40, 48, 56])
        #expect(ranges.last?.length == 3)
        #expect(await source.peak == 3)
        let bytes = progress.values
        #expect(bytes == bytes.sorted())
        #expect(bytes.last == 59)
        await lease.release(); await m.shutdown()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func firstRangeUnavailableCanFallBackButRequiredCannot() async throws {
        for required in [false, true] {
            let source = RangeSource(mode: .unavailable)
            let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
            let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
            let options = RemoteMaterializationOptions(downloadStrategy: required ? .segmentedRequired(config) : .segmentedIfSupported(config))
            if required {
                await #expect(throws: RemoteByteRangeError.unavailable) {
                    try await m.materialize(.init(source: binding, path: "/file"), options: options)
                }
            } else {
                let lease = try await m.materialize(.init(source: binding, path: "/file"), options: options)
                #expect(try Data(contentsOf: lease.url) == RangeSource.payload)
                await lease.release()
            }
            #expect(await source.ordinary == (required ? 0 : 1))
            #expect(await source.ranges.count == 1)
            await m.shutdown()
        }
    }

    @Test(arguments: [RangeSource.Mode.short, .oversized, .conflict, .network, .lateUnavailable])
    fileprivate func failedSegmentsNeverFallbackOrPublish(mode: RangeSource.Mode) async throws {
        let source = RangeSource(mode: mode)
        let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
        await #expect(throws: (any Error).self) {
            try await m.materialize(.init(source: binding, path: "/file"), options: .init(
                verifySize: false, downloadStrategy: .segmentedIfSupported(config)))
        }
        #expect(await source.ordinary == 0)
        #expect(await source.active == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await m.shutdown()
    }

    @Test func multipleFilesShareSourceRequestLimit() async throws {
        let source = RangeSource()
        let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
        let options = RemoteMaterializationOptions(downloadStrategy: .segmentedRequired(config))
        async let a = m.materialize(.init(source: binding, path: "/a"), options: options)
        async let b = m.materialize(.init(source: binding, path: "/b"), options: options)
        async let c = m.materialize(.init(source: binding, path: "/c"))
        let leases = try await [a, b, c]
        #expect(await source.peak <= 3)
        #expect(await source.ranges.count == 16)
        for lease in leases { await lease.release() }
        await m.shutdown()
    }

    @Test func cancellationDrainsChildrenBeforeCleanup() async throws {
        let source = RangeSource(mode: .slow)
        let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
        let task = Task { try await m.materialize(.init(source: binding, path: "/file"), options: .init(downloadStrategy: .segmentedRequired(config))) }
        for _ in 0..<1000 {
            if await source.ranges.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await source.ranges.count >= 3)
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await source.active == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await m.shutdown()
    }

    @Test func strategyDoesNotReuseASequentialFlightOrCache() async throws {
        let source = RangeSource()
        let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
        let reference = RemoteFileReference(source: binding, path: "/file")
        let first = try await m.materialize(reference, options: .init(retention: .persistent))
        let second = try await m.materialize(reference, options: .init(downloadStrategy: .segmentedRequired(config)))
        #expect(await source.ranges.count == 8)
        #expect(first.url != second.url)
        await first.release(); await second.release(); await m.shutdown()
    }

    @Test func invalidConfigRejectedBeforeSourceIO() async throws {
        let source = RangeSource()
        let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
        await #expect(throws: RemoteSyncError.unsupported(operation: "无效的分片下载配置")) {
            try await m.materialize(.init(source: binding, path: "/file"), options: .init(
                downloadStrategy: .segmentedRequired(.init(segmentSize: 0))))
        }
        #expect(await source.stats == 0)
        await m.shutdown()
    }

    @Test func protocolIsRequiredAndThresholdOnlyAffectsOptionalMode() async throws {
        for required in [false, true] {
            let source = OrdinaryRangeFixture()
            let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
            let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
            if required {
                await #expect(throws: RemoteByteRangeError.unavailable) {
                    try await m.materialize(.init(source: binding, path: "/file"), options: .init(downloadStrategy: .segmentedRequired(config)))
                }
            } else {
                let lease = try await m.materialize(.init(source: binding, path: "/file"), options: .init(downloadStrategy: .segmentedIfSupported(config)))
                await lease.release()
            }
            #expect(await source.backing.ordinary == (required ? 0 : 1))
            await m.shutdown()
        }
        let source = RangeSource()
        let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
        let small = RemoteSegmentedDownloadOptions(segmentSize: 8, minimumFileSize: 1000)
        let a = try await m.materialize(.init(source: binding, path: "/file"), options: .init(downloadStrategy: .segmentedIfSupported(small)))
        #expect(await source.ranges.isEmpty)
        let b = try await m.materialize(.init(source: binding, path: "/file"), options: .init(downloadStrategy: .segmentedRequired(small)))
        #expect(await source.ranges.count == 8)
        await a.release(); await b.release(); await m.shutdown()
    }

    @Test func rangeOnlyProviderHonorsRequiredVersionAndCannotWeakenFallback() async throws {
        for mode in [RangeSource.Mode.normal, .unavailable] {
            let source = RangeSource(mode: mode)
            let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
            let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
            let reference = RemoteFileReference(source: binding, path: "/file")
            let version = RemoteVersion(source: binding, locator: reference.locator, value: "\"v1\"", strength: .strongConditional)
            let options = RemoteMaterializationOptions(consistency: .requireVersion(version), downloadStrategy: .segmentedIfSupported(config))
            if mode == .normal {
                let lease = try await m.materialize(reference, options: options)
                #expect(lease.version == version)
                await lease.release()
            } else {
                await #expect(throws: RemoteSyncError.unsupported(operation: "所请求的版本无法保证条件读取")) {
                    try await m.materialize(reference, options: options)
                }
            }
            #expect(await source.ordinary == 0)
            await m.shutdown()
        }
    }

    @Test func changedMetadataOrWrongChecksumNeverPublishes() async throws {
        for mode in [RangeSource.Mode.normal, .changedAfter] {
            let source = RangeSource(mode: mode)
            let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
            let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
            let checksum: RemoteContentChecksum? = mode == .normal ? try .init(algorithm: .sha256, digest: Data(repeating: 0, count: 32)) : nil
            await #expect(throws: (any Error).self) {
                try await m.materialize(.init(source: binding, path: "/file"), options: .init(expectedChecksum: checksum, downloadStrategy: .segmentedRequired(config)))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            await m.shutdown()
        }
    }

    @Test func shutdownDrainsQueuedAndRunningRangeRequests() async throws {
        let source = RangeSource(mode: .slow)
        let root = workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let m = RemoteFileMaterializer(source: source, sourceBinding: binding, cacheDirectory: root)
        let jobs = (0..<8).map { index in
            Task { try await m.materialize(.init(source: binding, path: "/\(index)"), options: .init(downloadStrategy: .segmentedRequired(config))) }
        }
        for _ in 0..<1000 {
            if await source.ranges.contains(where: { $0.offset > 0 }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await m.shutdown()
        for job in jobs { await #expect(throws: (any Error).self) { try await job.value } }
        #expect(await source.active == 0)
        #expect(await source.peak <= 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func rangeBoundsCannotOverflow() throws {
        #expect(throws: (any Error).self) { try RemoteByteRange(offset: -1, length: 1) }
        #expect(throws: (any Error).self) { try RemoteByteRange(offset: 0, length: 0) }
        #expect(throws: (any Error).self) { try RemoteByteRange(offset: Int64.max, length: 1) }
        #expect(throws: (any Error).self) { try RemoteByteRange(offset: 0, length: RemoteByteRange.maximumLength + 1) }
        #expect(try RemoteByteRange(offset: Int64.max - 1, length: 1).endExclusive == Int64.max)
    }

    private func workspace() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Segmented-\(UUID())")
    }
}

private actor RangeSource: RemoteByteRangeSource {
    enum Mode: Sendable { case normal, unavailable, lateUnavailable, short, oversized, conflict, network, slow, changedAfter }
    static let payload = Data((0..<59).map(UInt8.init))
    nonisolated let kind: RemoteSourceKind = .cloudAPI
    // Deliberately no rangedDownload flag: the optional protocol is authoritative.
    nonisolated let capabilities = RemoteCapabilities(maxConcurrentTransfers: 3)
    let mode: Mode
    var ranges: [RemoteByteRange] = []
    var ordinary = 0
    var stats = 0
    var active = 0
    var peak = 0
    init(mode: Mode = .normal) { self.mode = mode }
    func connect(_ credential: RemoteCredential) async throws {}
    func disconnect() async {}
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage { .init(coverage: .complete, entries: []) }
    func stat(path: String) async throws -> RemoteEntry {
        stats += 1
        return RemoteEntry(id: path, path: path, name: path, type: .file, size: 59, etag: mode == .changedAfter && stats > 1 ? "\"v2\"" : "\"v1\"")
    }
    nonisolated func byteRangeVersion(for entry: RemoteEntry) -> String? { entry.etag }
    func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        ordinary += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(25))
        try Self.payload.write(to: destination)
        return entry
    }
    func readBytes(_ entry: RemoteEntry, range: RemoteByteRange, requiringVersion: String) async throws -> Data {
        ranges.append(range); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        #expect(requiringVersion == "\"v1\"")
        if mode == .unavailable || (mode == .lateUnavailable && range.offset > 0) { throw RemoteByteRangeError.unavailable }
        if mode == .conflict { throw RemoteSyncError.conflict(path: entry.path!) }
        if mode == .network { throw RemoteSyncError.network("fixture") }
        if mode == .slow && range.offset > 0 { try await Task.sleep(for: .seconds(10)) }
        else { try await Task.sleep(for: .milliseconds(range.offset == 8 ? 30 : 5)) }
        let data = Self.payload.subdata(in: Int(range.offset)..<Int(range.endExclusive))
        if mode == .short { return data.dropLast() }
        if mode == .oversized { return data + Data([0]) }
        return data
    }
}

private final class SegmentProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    var values: [Int64] { lock.withLock { storage } }
    func record(_ value: Int64) { lock.withLock { storage.append(value) } }
}

/// A rangedDownload flag does not supply the stronger closed-range contract.
private struct OrdinaryRangeFixture: RemoteSource {
    let backing = RangeSource()
    let kind: RemoteSourceKind = .cloudAPI
    let capabilities = RemoteCapabilities(rangedDownload: true)
    func connect(_ credential: RemoteCredential) async throws {}
    func disconnect() async {}
    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage { .init(coverage: .complete, entries: []) }
    func stat(path: String) async throws -> RemoteEntry { try await backing.stat(path: path) }
    func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        try await backing.download(entry, to: destination, options: options)
    }
}
