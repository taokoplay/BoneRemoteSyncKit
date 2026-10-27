import Foundation
import XCTest
import BoneRemoteSyncCore

final class RemoteWalkTests: XCTestCase, @unchecked Sendable {
    func testReadsDirectoriesConcurrentlyWithinConfiguredBound() async throws {
        let entered = expectation(description: "three directory requests entered")
        entered.expectedFulfillmentCount = 3
        let gate = WalkGate()
        let directories = (0..<9).map { directory("/d\($0)") }
        var pages: [WalkKey: RemoteListPage] = [.init("/"): .init(coverage: .complete, entries: directories)]
        var gates: [WalkKey: WalkGate] = [:]
        var starts: [WalkKey: XCTestExpectation] = [:]
        for index in 0..<9 {
            let key = WalkKey("/d\(index)")
            pages[key] = .init(coverage: .complete, entries: [file("/d\(index)/f")])
            gates[key] = gate
            if index < 3 { starts[key] = entered }
        }
        let source = WalkSource(pages: pages, gates: gates, starts: starts)
        let sink = WalkSink()
        let task = Task {
            try await source.walk(path: "/", options: .init(maxConcurrentRequests: 3)) {
                await sink.append($0)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let blocked = await source.snapshot()
        XCTAssertEqual(blocked.active, 3)
        XCTAssertEqual(blocked.calls.count, 4, "Only root plus three gated directory requests may start")
        await gate.open()
        let summary = try await task.value
        let final = await source.snapshot()
        let entries = await sink.entries
        XCTAssertEqual(summary.entryCount, 18)
        XCTAssertEqual(summary.directoryCount, 10)
        XCTAssertEqual(entries.count, 18)
        XCTAssertEqual(final.maximumActive, 3)
        XCTAssertEqual(final.active, 0)
    }

    func testSlowVisitorStopsFurtherSchedulingAndIsNeverConcurrent() async throws {
        let paused = expectation(description: "visitor paused")
        let unexpectedStart = expectation(description: "no directory scheduling while visitor is paused")
        unexpectedStart.isInverted = true
        let visitorGate = WalkGate()
        let requestGate = WalkGate()
        let requestsEntered = expectation(description: "initial bounded batch entered")
        requestsEntered.expectedFulfillmentCount = 3
        let phase = WalkPhase()
        let directories = (0..<12).map { directory("/d\($0)") }
        var pages: [WalkKey: RemoteListPage] = [.init("/"): .init(coverage: .complete, entries: directories)]
        for index in 0..<12 { pages[.init("/d\(index)")] = .init(coverage: .complete, entries: [file("/d\(index)/f")]) }
        let source = WalkSource(
            pages: pages,
            gates: [.init("/d0"): requestGate, .init("/d1"): requestGate, .init("/d2"): requestGate],
            starts: [.init("/d0"): requestsEntered, .init("/d1"): requestsEntered, .init("/d2"): requestsEntered],
            phase: phase, startedWhilePaused: unexpectedStart
        )
        let sink = WalkSink()
        let task = Task {
            try await source.walk(path: "/", options: .init(maxConcurrentRequests: 3)) { entry in
                await sink.begin(entry)
                if entry.type == .file {
                    let first = await phase.pauseOnce()
                    if first {
                        paused.fulfill()
                        try await visitorGate.wait()
                        await phase.resume()
                    }
                }
                await sink.end()
            }
        }
        await fulfillment(of: [requestsEntered], timeout: 2)
        await requestGate.open()
        await fulfillment(of: [paused], timeout: 2)
        // An inverted event checks absence of additional producer work, rather than a sleep.
        await fulfillment(of: [unexpectedStart], timeout: 0.1)
        let snapshot = await source.snapshot()
        XCTAssertLessThanOrEqual(snapshot.calls.count, 4)
        await visitorGate.open()
        _ = try await task.value
        let maximumVisitors = await sink.maximumActive
        XCTAssertEqual(maximumVisitors, 1)
    }

    func testSlowVisitorDoesNotPrefetchNextCursor() async throws {
        let paused = expectation(description: "first page visitor paused")
        let unexpectedPage = expectation(description: "next page cannot start before visitor completes")
        unexpectedPage.isInverted = true
        let gate = WalkGate()
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [file("/a")], nextCursor: "next"),
            .init("/", "next"): .init(coverage: .complete, entries: [file("/b")]),
        ], starts: [.init("/", "next"): unexpectedPage])
        let task = Task {
            try await source.walk(path: "/", options: .init()) { entry in
                if entry.path == "/a" {
                    paused.fulfill()
                    try await gate.wait()
                }
            }
        }
        await fulfillment(of: [paused], timeout: 2)
        await fulfillment(of: [unexpectedPage], timeout: 0.1)
        let beforeResume = await source.snapshot()
        XCTAssertEqual(beforeResume.calls.map(\.key), [.init("/")])
        await gate.open()
        let summary = try await task.value
        XCTAssertEqual(summary.entryCount, 2)
    }

    func testPaginationIsSequentialAndPreservesSourceEntriesAndHiddenOption() async throws {
        let original = RemoteEntry(id: "opaque-id", path: "/root/a/../visible", name: "Display name", type: .file, size: 12, etag: "tag")
        let source = WalkSource(pages: [
            .init("/root"): .init(coverage: .complete, entries: [original], nextCursor: "page-2"),
            .init("/root", "page-2"): .init(coverage: .complete, entries: [file("/root/.hidden")]),
        ])
        let sink = WalkSink()
        let summary = try await source.walk(path: "//root/.", options: .init(includeHidden: true)) {
            await sink.append($0)
        }
        let entries = await sink.entries
        let calls = await source.snapshot().calls
        XCTAssertEqual(entries, [original, file("/root/.hidden")])
        XCTAssertEqual(calls.map(\.key), [.init("/root"), .init("/root", "page-2")])
        XCTAssertTrue(calls.allSatisfy(\.request.includeHidden))
        XCTAssertEqual(summary.entryCount, 2)
        XCTAssertEqual(summary.directoryCount, 1, "Root is counted once, not once per page")
    }

    func testDefaultHiddenRequestDoesNotChangeConnectionIdentity() async throws {
        let source = WalkSource(pages: [.init("/"): .init(coverage: .complete, entries: [file("/visible")])])
        try await source.connect(.anonymous)
        _ = try await source.walk(path: "/", options: .init()) { _ in }
        let state = await source.snapshot()
        XCTAssertFalse(try XCTUnwrap(state.calls.first).request.includeHidden)
        XCTAssertEqual(state.connections, 1)
        XCTAssertEqual(state.disconnections, 0)
    }

    func testCursorCycleFailsInsteadOfRepeatingRequests() async throws {
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [], nextCursor: "a"),
            .init("/", "a"): .init(coverage: .complete, entries: [], nextCursor: "b"),
            .init("/", "b"): .init(coverage: .complete, entries: [], nextCursor: "a"),
        ])
        await assertUnsupported {
            _ = try await source.walk(path: "/", options: .init()) { _ in }
        }
        let calls = await source.snapshot().calls
        XCTAssertEqual(calls.map(\.key), [.init("/"), .init("/", "a"), .init("/", "b")])
    }

    func testNormalizedDuplicateAcrossPagesFailsBeforeSecondVisit() async throws {
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [file("/a")], nextCursor: "second"),
            .init("/", "second"): .init(coverage: .complete, entries: [file("//a/.")]),
        ])
        let sink = WalkSink()
        await assertUnsupported {
            _ = try await source.walk(path: "/", options: .init()) { await sink.append($0) }
        }
        let entries = await sink.entries
        XCTAssertEqual(entries.map(\.path), ["/a"])
    }

    func testRejectsSelfAncestorDescendantSiblingAndMissingPath() async throws {
        let invalid: [RemoteEntry] = [
            directory("/root"), directory("/root/.."), file("/root/nested/file"),
            file("/elsewhere/file"), file("/root/../../escape"),
            RemoteEntry(id: "opaque", path: nil, name: "no path", type: .file),
        ]
        for entry in invalid {
            let source = WalkSource(pages: [.init("/root"): .init(coverage: .complete, entries: [entry])])
            let sink = WalkSink()
            await assertUnsupported {
                _ = try await source.walk(path: "/root", options: .init()) { await sink.append($0) }
            }
            let visited = await sink.entries
            let calls = await source.snapshot().calls
            XCTAssertTrue(visited.isEmpty, "Invalid entry must never reach visitor: \(entry)")
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testDepthZeroReadsRootFilesButRejectsDirectoryDescent() async throws {
        let files = WalkSource(pages: [.init("/"): .init(coverage: .complete, entries: [file("/a")])])
        let summary = try await files.walk(path: "/", options: .init(maxDepth: 0)) { _ in }
        XCTAssertEqual(summary.entryCount, 1)
        XCTAssertEqual(summary.directoryCount, 1)
        let noDescent = WalkSource(pages: [.init("/"): .init(coverage: .complete, entries: [directory("/a")])])
        await assertUnsupported {
            _ = try await noDescent.walk(path: "/", options: .init(maxDepth: 0)) { _ in }
        }
        let rootCalls = await noDescent.snapshot().calls
        XCTAssertEqual(rootCalls.map(\.key), [.init("/")])
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [directory("/a")]),
            .init("/a"): .init(coverage: .complete, entries: [directory("/a/b")]),
        ])
        await assertUnsupported {
            _ = try await source.walk(path: "/", options: .init(maxDepth: 1)) { _ in }
        }
        let calls = await source.snapshot().calls
        XCTAssertEqual(calls.map(\.key), [.init("/"), .init("/a")])
    }

    func testEntryLimitRejectsOversizedDiscoveryBeforeQueueingOrVisitingPage() async throws {
        let source = WalkSource(pages: [.init("/"): .init(coverage: .complete, entries: [directory("/a"), directory("/b"), directory("/c")])])
        let sink = WalkSink()
        await assertUnsupported {
            _ = try await source.walk(path: "/", options: .init(maxEntries: 2)) { await sink.append($0) }
        }
        let state = await source.snapshot()
        let entries = await sink.entries
        XCTAssertEqual(state.calls.count, 1)
        XCTAssertTrue(entries.isEmpty)
    }

    func testEntryLimitIncludesDiscoveredDirectoriesAndDescendantFiles() async throws {
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [directory("/a"), directory("/b")]),
            .init("/a"): .init(coverage: .complete, entries: [file("/a/1"), file("/a/2")]),
            .init("/b"): .init(coverage: .complete, entries: [file("/b/1")]),
        ])
        let sink = WalkSink()
        await assertUnsupported {
            _ = try await source.walk(path: "/", options: .init(maxConcurrentRequests: 1, maxEntries: 3)) {
                await sink.append($0)
            }
        }
        let entries = await sink.entries
        let state = await source.snapshot()
        XCTAssertEqual(entries.map(\.path), ["/a", "/b"])
        XCTAssertEqual(state.calls.map(\.key), [.init("/"), .init("/a")])
        XCTAssertEqual(state.active, 0)
    }

    func testEmptyRootIsCountedAndSingleRequestModeStaysSerial() async throws {
        let empty = try await WalkSource(pages: [.init("/"): .init(coverage: .complete, entries: [])])
            .walk(path: "/", options: .init(maxConcurrentRequests: 16, maxDepth: 0, maxEntries: 1)) { _ in }
        XCTAssertEqual(empty.entryCount, 0)
        XCTAssertEqual(empty.directoryCount, 1)
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [directory("/a"), directory("/b")]),
            .init("/a"): .init(coverage: .complete, entries: []), .init("/b"): .init(coverage: .complete, entries: []),
        ])
        let serial = try await source.walk(path: "/", options: .init(maxConcurrentRequests: 1, maxDepth: 1)) { _ in }
        let state = await source.snapshot()
        XCTAssertEqual(serial.entryCount, 2)
        XCTAssertEqual(serial.directoryCount, 3)
        XCTAssertEqual(state.maximumActive, 1)
    }

    func testEntryLimitAppliesAcrossPagesAndAcceptsExactBoundary() async throws {
        let pages: [WalkKey: RemoteListPage] = [
            .init("/"): .init(coverage: .complete, entries: [file("/a")], nextCursor: "next"),
            .init("/", "next"): .init(coverage: .complete, entries: [file("/b")]),
        ]
        let source = WalkSource(pages: pages)
        let sink = WalkSink()
        await assertUnsupported {
            _ = try await source.walk(path: "/", options: .init(maxEntries: 1)) { await sink.append($0) }
        }
        let partial = await sink.entries
        XCTAssertEqual(partial.map(\.path), ["/a"])
        let exact = try await WalkSource(pages: pages).walk(path: "/", options: .init(maxEntries: 2)) { _ in }
        XCTAssertEqual(exact.entryCount, 2)
    }

    func testInvalidOptionsFailBeforeAnyListRequest() async throws {
        let invalid: [RemoteWalkOptions] = [
            .init(maxConcurrentRequests: 0), .init(maxConcurrentRequests: 17),
            .init(maxDepth: -1), .init(maxEntries: 0), .init(maxEntries: -1),
        ]
        for options in invalid {
            let source = WalkSource(pages: [:])
            await assertUnsupported { _ = try await source.walk(path: "/", options: options) { _ in } }
            let state = await source.snapshot()
            XCTAssertTrue(state.calls.isEmpty)
        }
    }

    func testVisitorErrorCancelsAndJoinsOutstandingRequests() async throws {
        let siblingsStarted = expectation(description: "all three sibling requests entered")
        siblingsStarted.expectedFulfillmentCount = 3
        let releaseFirst = WalkGate()
        let holdSiblings = WalkGate()
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [directory("/a"), directory("/b"), directory("/c")]),
            .init("/a"): .init(coverage: .complete, entries: [file("/a/f")]),
            .init("/b"): .init(coverage: .complete, entries: []), .init("/c"): .init(coverage: .complete, entries: []),
        ], gates: [.init("/a"): releaseFirst, .init("/b"): holdSiblings, .init("/c"): holdSiblings],
           starts: [.init("/a"): siblingsStarted, .init("/b"): siblingsStarted, .init("/c"): siblingsStarted])
        let task = Task {
            try await source.walk(path: "/", options: .init(maxConcurrentRequests: 3)) { entry in
                if entry.type == .file { throw WalkFailure.visitor }
            }
        }
        await fulfillment(of: [siblingsStarted], timeout: 2)
        await releaseFirst.open()
        do { _ = try await task.value; XCTFail("Expected original visitor error") }
        catch { XCTAssertEqual(error as? WalkFailure, .visitor) }
        let state = await source.snapshot()
        XCTAssertEqual(state.active, 0, "walk must join cancelled list requests before throwing")
        XCTAssertEqual(state.cancelled, 2)
        XCTAssertEqual(state.calls.count, 4)
    }

    func testListErrorCancelsAndJoinsSiblingRequests() async throws {
        let entered = expectation(description: "two siblings entered")
        entered.expectedFulfillmentCount = 2
        let releaseError = WalkGate()
        let holdSibling = WalkGate()
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [directory("/a"), directory("/b")]),
            .init("/b"): .init(coverage: .complete, entries: []),
        ], gates: [.init("/a"): releaseError, .init("/b"): holdSibling],
           starts: [.init("/a"): entered, .init("/b"): entered], failures: [.init("/a"): .listing])
        let task = Task { try await source.walk(path: "/", options: .init(maxConcurrentRequests: 2)) { _ in } }
        await fulfillment(of: [entered], timeout: 2)
        await releaseError.open()
        do { _ = try await task.value; XCTFail("Expected original list error") }
        catch { XCTAssertEqual(error as? WalkFailure, .listing) }
        let state = await source.snapshot()
        XCTAssertEqual(state.active, 0)
        XCTAssertEqual(state.cancelled, 1)
    }

    func testCallerCancellationJoinsAllListTasksBeforeReturning() async throws {
        let entered = expectation(description: "three children blocked")
        entered.expectedFulfillmentCount = 3
        let gate = WalkGate()
        let source = WalkSource(pages: [
            .init("/"): .init(coverage: .complete, entries: [directory("/a"), directory("/b"), directory("/c")]),
            .init("/a"): .init(coverage: .complete, entries: []), .init("/b"): .init(coverage: .complete, entries: []), .init("/c"): .init(coverage: .complete, entries: []),
        ], gates: [.init("/a"): gate, .init("/b"): gate, .init("/c"): gate],
           starts: [.init("/a"): entered, .init("/b"): entered, .init("/c"): entered])
        let task = Task { try await source.walk(path: "/", options: .init(maxConcurrentRequests: 3)) { _ in } }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = await source.snapshot()
        XCTAssertEqual(state.active, 0)
        XCTAssertEqual(state.cancelled, 3)
    }

    func testCancellationDuringVisitorStopsRemainingEntries() async throws {
        let entered = expectation(description: "visitor entered")
        let gate = WalkGate()
        let source = WalkSource(pages: [.init("/"): .init(coverage: .complete, entries: [file("/a"), file("/b")])])
        let sink = WalkSink()
        let task = Task {
            try await source.walk(path: "/", options: .init()) { entry in
                await sink.append(entry)
                entered.fulfill()
                try await gate.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let entries = await sink.entries
        XCTAssertEqual(entries.map(\.path), ["/a"])
        let state = await source.snapshot()
        XCTAssertEqual(state.active, 0)
    }

    private func assertUnsupported(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected unsupported", file: file, line: line) }
        catch let error as RemoteSyncError {
            guard case .unsupported = error else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}

private func file(_ path: String) -> RemoteEntry {
    RemoteEntry(id: path, path: path, name: path.split(separator: "/").last.map(String.init) ?? "", type: .file)
}

private func directory(_ path: String) -> RemoteEntry {
    RemoteEntry(id: path, path: path, name: path.split(separator: "/").last.map(String.init) ?? "", type: .directory)
}

private struct WalkKey: Hashable, Sendable {
    let path: String
    let cursor: String?
    init(_ path: String, _ cursor: String? = nil) { self.path = path; self.cursor = cursor }
}

private enum WalkFailure: Error, Equatable, Sendable { case visitor, listing }

/// A cancellation-cooperative gate: tests control progress with events, never network or sleeps.
private actor WalkGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if isOpen { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

private actor WalkPhase {
    private var used = false
    private(set) var paused = false
    func pauseOnce() -> Bool {
        guard !used else { return false }
        used = true
        paused = true
        return true
    }
    func resume() { paused = false }
}

private actor WalkSink {
    private(set) var entries: [RemoteEntry] = []
    private var active = 0
    private(set) var maximumActive = 0
    func append(_ entry: RemoteEntry) { entries.append(entry) }
    func begin(_ entry: RemoteEntry) {
        entries.append(entry)
        active += 1
        maximumActive = max(maximumActive, active)
    }
    func end() { active -= 1 }
}

private actor WalkSource: RemoteSource {
    nonisolated let kind: RemoteSourceKind = .webdav
    nonisolated let capabilities = RemoteCapabilities.readOnly
    struct Call: Sendable { let key: WalkKey; let request: RemoteListRequest }
    struct Snapshot: Sendable {
        let calls: [Call]
        let active: Int
        let maximumActive: Int
        let cancelled: Int
        let connections: Int
        let disconnections: Int
    }
    private let pages: [WalkKey: RemoteListPage]
    private let gates: [WalkKey: WalkGate]
    private let starts: [WalkKey: XCTestExpectation]
    private let failures: [WalkKey: WalkFailure]
    private let phase: WalkPhase?
    private let startedWhilePaused: XCTestExpectation?
    private var calls: [Call] = []
    private var active = 0
    private var maximumActive = 0
    private var cancelled = 0
    private var connections = 0
    private var disconnections = 0

    init(pages: [WalkKey: RemoteListPage], gates: [WalkKey: WalkGate] = [:],
         starts: [WalkKey: XCTestExpectation] = [:], failures: [WalkKey: WalkFailure] = [:],
         phase: WalkPhase? = nil, startedWhilePaused: XCTestExpectation? = nil) {
        self.pages = pages; self.gates = gates; self.starts = starts; self.failures = failures
        self.phase = phase; self.startedWhilePaused = startedWhilePaused
    }

    func connect(_ credential: RemoteCredential) async throws { connections += 1 }
    func disconnect() async { disconnections += 1 }
    func stat(path: String) async throws -> RemoteEntry { throw WalkFailure.listing }
    func download(_ entry: RemoteEntry, to destination: URL, options: RemoteDownloadOptions) async throws -> RemoteEntry {
        throw WalkFailure.listing
    }

    func list(path: String, request: RemoteListRequest) async throws -> RemoteListPage {
        let key = WalkKey(path, request.cursor)
        calls.append(.init(key: key, request: request))
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        do {
            if let phase, await phase.paused { startedWhilePaused?.fulfill() }
            starts[key]?.fulfill()
            if let gate = gates[key] { try await gate.wait() }
            try Task.checkCancellation()
            if let failure = failures[key] { throw failure }
            guard let page = pages[key] else { throw RemoteSyncError.notFound(path: path) }
            return page
        } catch {
            if error is CancellationError { cancelled += 1 }
            throw error
        }
    }

    func snapshot() -> Snapshot {
        .init(calls: calls, active: active, maximumActive: maximumActive, cancelled: cancelled,
              connections: connections, disconnections: disconnections)
    }
}
