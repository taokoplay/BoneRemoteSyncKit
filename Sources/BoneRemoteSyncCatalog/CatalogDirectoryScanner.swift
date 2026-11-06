import Foundation
import BoneRemoteSyncCore

actor CatalogScanBudget {
    let options: RemoteCatalogRefreshOptions
    private var entries = 0
    private var directories = 1
    private var lastRequestAdmission: TimeInterval?
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(_ options: RemoteCatalogRefreshOptions,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.options = options; self.now = now; self.sleep = sleep
    }

    /// Recheck after every suspension: delayed wakeups must not release a burst of reserved slots.
    func waitForRequest() async throws {
        while true {
            try Task.checkCancellation()
            guard options.requestInterval > 0 else { return }
            let instant = now()
            if let lastRequestAdmission {
                let remaining = options.requestInterval - (instant - lastRequestAdmission)
                if remaining > 0 {
                    try await sleep(UInt64((remaining * 1_000_000_000).rounded(.up)))
                    continue
                }
            }
            lastRequestAdmission = instant
            return
        }
    }

    func consume(entries count: Int) throws {
        guard count <= options.maxEntries - entries else { throw RemoteCatalogError.budgetExceeded }
        entries += count
    }
    func reserveDirectory(depth: Int) throws {
        guard depth <= options.maxDepth, directories < options.maxDirectories else { throw RemoteCatalogError.budgetExceeded }
        directories += 1
    }
}
struct CatalogScannedDirectory: Sendable {
    let path: String
    let depth: Int
    let published: Int?
    let children: [String]
    let fileCount: Int64
    let directoryCount: Int64
    let knownBytes: Int64
    let hasUnknownSize: Bool
    let failure: RemoteCatalogFailureReason?
}

struct CatalogDirectoryScanner: Sendable {
    let store: SQLiteRemoteCatalogStore
    let source: any RemoteSource
    let run: CatalogRun
    let options: RemoteCatalogRefreshOptions
    let budget: CatalogScanBudget
    let permit: CatalogCommitPermit
    func scan(path: String, depth: Int) async -> CatalogScannedDirectory {
        var ticket: CatalogDirectoryTicket?
        do {
            try Task.checkCancellation()
            let current = try await store.beginDirectory(run: run, path: path)
            ticket = current
            try await verifySelection(path: path, expectedID: current.providerID)
            var cursor: String?
            var seenCursors: Set<String> = []
            var pageCount = 0
            var children: [String] = []
            var fileCount: Int64 = 0
            var directoryCount: Int64 = 0
            var knownBytes: Int64 = 0
            var hasUnknownSize = false
            repeat {
                try Task.checkCancellation()
                guard pageCount < options.maxPagesPerDirectory else { throw RemoteCatalogError.budgetExceeded }
                try await budget.waitForRequest()
                let page = try await source.list(path: path, request: .init(cursor: cursor, limit: options.pageSize, includeHidden: run.root.includeHidden))
                pageCount += 1
                guard page.coverage == .complete else { throw RemoteCatalogError.incompleteListing }
                try await budget.consume(entries: page.entries.count)
                for entry in page.entries {
                    if entry.isDirectory {
                        directoryCount += 1
                    } else {
                        fileCount += 1
                        guard let size = entry.size, size >= 0, !hasUnknownSize else {
                            hasUnknownSize = true
                            continue
                        }
                        let (sum, overflow) = knownBytes.addingReportingOverflow(size)
                        if overflow { hasUnknownSize = true } else { knownBytes = sum }
                    }
                }
                if let next = page.nextCursor {
                    guard !next.isEmpty, next.utf8.count <= 32768, seenCursors.insert(next).inserted else { throw RemoteCatalogError.incompleteListing }
                }
                try await store.stage(page.entries, ticket: current)
                if options.scope == .subtree {
                    for entry in page.entries where entry.isDirectory {
                        try await budget.reserveDirectory(depth: depth + 1)
                        children.append(entry.path!)
                    }
                }
                cursor = page.nextCursor
            } while cursor != nil
            try await verifySelection(path: path, expectedID: current.providerID)
            try Task.checkCancellation()
            let count = try await withTaskCancellationHandler {
                try await store.publish(ticket: current, permit: permit)
            } onCancel: { permit.cancel() }
            return .init(path: path, depth: depth, published: count, children: children,
                         fileCount: fileCount, directoryCount: directoryCount,
                         knownBytes: knownBytes, hasUnknownSize: hasUnknownSize, failure: nil)
        } catch {
            if let ticket { try? await store.failDirectory(ticket: ticket) }
            return .init(path: path, depth: depth, published: nil, children: [],
                         fileCount: 0, directoryCount: 0, knownBytes: 0,
                         hasUnknownSize: true, failure: .map(error))
        }
    }

    private func verifySelection(path: String, expectedID: String) async throws {
        try await budget.waitForRequest()
        let selected = try await source.stat(path: run.root.path)
        guard selected.isDirectory, selected.path == run.root.path, selected.id == run.root.entryID else { throw RemoteCatalogError.identityChanged }
        let directory: RemoteEntry
        if path == run.root.path { directory = selected }
        else {
            try await budget.waitForRequest()
            directory = try await source.stat(path: path)
        }
        guard directory.isDirectory, directory.path == path, directory.id == expectedID else { throw RemoteCatalogError.identityChanged }
    }
}
