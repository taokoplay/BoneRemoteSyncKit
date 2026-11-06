import Foundation
import Testing
import BoneRemoteSyncCore
@testable import BoneRemoteSyncCatalog

/// A monotonic test clock that can make one sleep wake early or late.
private final class CatalogIntervalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 100
    private var firstSleepAdvance: TimeInterval?
    private var sleeps: [UInt64] = []

    init(firstSleepAdvance: TimeInterval) { self.firstSleepAdvance = firstSleepAdvance }
    func now() -> TimeInterval { lock.withLock { instant } }
    func sleep(_ nanoseconds: UInt64) {
        lock.withLock {
            sleeps.append(nanoseconds)
            instant += firstSleepAdvance ?? TimeInterval(nanoseconds) / 1_000_000_000
            firstSleepAdvance = nil
        }
    }
    var recordedSleeps: [UInt64] { lock.withLock { sleeps } }
}

@Suite struct CatalogRequestIntervalTests {
    @Test func defaultsAndBounds() throws {
        #expect(RemoteCatalogRefreshOptions().requestInterval == 0)
        for interval in [0.0, 0.5, 86_400] {
            try RemoteCatalogRefreshOptions(requestInterval: interval).validate()
        }
    }

    @Test(arguments: [-0.1, Double.nan, Double.infinity, -Double.infinity, 86_401])
    func invalidIntervalFailsBeforeRootPreflight(interval: TimeInterval) async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        try FileManager.default.createDirectory(at: fixture.directory.appendingPathComponent("selected"), withIntermediateDirectories: true)
        let store = try fixture.store()
        let credentials = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let resolver = GatedResolver(fixture.directory)
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: credentials, localResolver: resolver))
        let profile = try await catalog.saveSource(displayName: "Local", configuration: .local(accessReference: "bookmark"))
        let root = try await catalog.selectRoot(sourceID: profile.id, path: "/selected")
        let calls = await resolver.calls
        await #expect(throws: RemoteCatalogError.invalidConfiguration) {
            try await catalog.refresh(rootID: root.id, options: .init(requestInterval: interval))
        }
        #expect(await resolver.calls == calls)
        try await store.close()
    }

    @Test func zeroIntervalDoesNotReadClockOrSleep() async throws {
        let budget = CatalogScanBudget(.init(), now: {
            Issue.record("Disabled pacing should not read the clock")
            return 0
        }, sleep: { _ in
            Issue.record("Disabled pacing should not sleep")
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { try await budget.waitForRequest() } }
            try await group.waitForAll()
        }
    }

    @Test func lateWakeDoesNotAccumulateCatchUpSlots() async throws {
        let clock = CatalogIntervalClock(firstSleepAdvance: 10)
        let budget = CatalogScanBudget(.init(requestInterval: 1), now: { clock.now() }, sleep: { clock.sleep($0) })
        try await budget.waitForRequest()
        #expect(clock.now() == 100)
        try await budget.waitForRequest()
        #expect(clock.now() == 110)
        try await budget.waitForRequest()
        #expect(clock.now() == 111)
        #expect(clock.recordedSleeps == [1_000_000_000, 1_000_000_000])
    }

    @Test func earlyWakeWaitsForRemainingInterval() async throws {
        let clock = CatalogIntervalClock(firstSleepAdvance: 0.25)
        let budget = CatalogScanBudget(.init(requestInterval: 1), now: { clock.now() }, sleep: { clock.sleep($0) })
        try await budget.waitForRequest()
        try await budget.waitForRequest()
        #expect(clock.now() == 101)
        #expect(clock.recordedSleeps == [1_000_000_000, 750_000_000])
    }

    @Test func parallelDirectoriesPagesAndMetadataShareOneInterval() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store(); let root = try await fixture.selected(store)
        let source = CatalogSource()
        await source.synchronize(["/A", "/B"])
        await source.configure(pages: [
            "/|": .init(coverage: .complete, entries: [catalogEntry("/A", directory: true), catalogEntry("/B", directory: true)]),
            "/A|": .init(coverage: .complete, entries: [catalogEntry("/A/one")], nextCursor: "next"),
            "/A|next": .init(coverage: .complete, entries: [catalogEntry("/A/two")]),
            "/B|": .init(coverage: .complete, entries: [catalogEntry("/B/one")], nextCursor: "next"),
            "/B|next": .init(coverage: .complete, entries: [catalogEntry("/B/two")])
        ], identities: ["/": "root", "/A": "/A", "/B": "/B"])
        let options = RemoteCatalogRefreshOptions(scope: .subtree, concurrency: 2, requestInterval: 0.05)
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .subtree)
        let scanner = CatalogDirectoryScanner(store: store, source: source, run: run, options: options,
                                              budget: .init(options), permit: .init())
        let report = await CatalogTreeScanner(scanner: scanner).scan()
        #expect(report.state == .success && report.storageSummary?.recursiveFileCount == 4)
        #expect(await source.peak == 2) // Pacing does not silently replace the concurrency setting.
        let times = await source.requestTimes
        #expect(times.count == 15) // Five list pages and ten before/after stat calls.
        for (earlier, later) in zip(times, times.dropFirst()) {
            // Admission is before the actor hop into the provider; allow 10 ms scheduling variation.
            #expect(later - earlier >= 0.04)
        }
        try await store.finishRun(run, state: report.state.rawValue, failures: report.failures, storageSummary: report.storageSummary)
        try await store.close()
    }

    @Test func cancellationDuringIntervalKeepsOldDirectoryAndStopsRequests() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let store = try fixture.store(); let root = try await fixture.selected(store)
        try await seed(store, root: root, path: "/", entries: [catalogEntry("/old")])
        let source = CatalogSource()
        await source.configure(pages: ["/|": .init(coverage: .complete, entries: [catalogEntry("/new")])])
        let options = RemoteCatalogRefreshOptions(scope: .subtree, requestInterval: 60)
        let run = try await store.beginRun(rootID: root.id, path: "/", scope: .subtree)
        let scanner = CatalogDirectoryScanner(store: store, source: source, run: run, options: options,
                                              budget: .init(options), permit: .init())
        let task = Task { await CatalogTreeScanner(scanner: scanner).scan() }
        defer { task.cancel() }
        for _ in 0..<2_000 {
            if await !source.statRequests.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(await source.statRequests.count == 1)
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let report = await task.value
        #expect(ProcessInfo.processInfo.systemUptime - cancelledAt < 5)
        #expect(report.state == .cancelled && report.storageSummary == nil)
        #expect(await source.requests.isEmpty)
        #expect(await source.statRequests.count == 1)
        #expect(try await store.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["old"])
        try await store.finishRun(run, state: report.state.rawValue, failures: report.failures)
        try await store.close()
    }

    @Test func publicRefreshTimeoutInterruptsIntervalAndNextRefreshSucceeds() async throws {
        let fixture = try CatalogFixture(); defer { withExtendedLifetime(fixture) {} }
        let upstream = fixture.directory.appendingPathComponent("upstream")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: upstream.appendingPathComponent("old.txt"))
        let store = try fixture.store()
        let credentials = try KeychainRemoteCredentialStore(service: "test.\(UUID())", backend: MemorySecurityBackend())
        let catalog = RemoteCatalog(store: store, sessions: .init(credentials: credentials, localResolver: GatedResolver(upstream)))
        let profile = try await catalog.saveSource(displayName: "Local", configuration: .local(accessReference: "bookmark"))
        let root = try await catalog.selectRoot(sourceID: profile.id, path: "/", defaultScope: .subtree)
        #expect(try await catalog.refresh(rootID: root.id).state == .success)
        try Data("new".utf8).write(to: upstream.appendingPathComponent("new.txt"))
        let started = ProcessInfo.processInfo.systemUptime
        let report = try await catalog.refresh(rootID: root.id, options: .init(scope: .subtree, timeout: 0.1, requestInterval: 60))
        #expect(ProcessInfo.processInfo.systemUptime - started < 5)
        #expect(report.state == .failed && report.publishedDirectories == 0 && report.storageSummary == nil)
        #expect(report.failures.contains { $0.reason == .deadline })
        #expect(try await catalog.listCached(rootID: root.id, directory: "/").entries.map(\.name) == ["old.txt"])
        #expect(try await catalog.storageSummary(rootID: root.id)?.isStale == true)
        #expect(try await catalog.refresh(rootID: root.id).state == .success)
        #expect(try await catalog.listCached(rootID: root.id, directory: "/").entries.count == 2)
        try await store.close()
    }
}
