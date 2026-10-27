import Foundation
import BoneRemoteSyncCore

actor CatalogScanBudget {
    let options: RemoteCatalogRefreshOptions
    private var entries = 0
    private var directories = 1
    init(_ options: RemoteCatalogRefreshOptions) { self.options = options }
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
            repeat {
                try Task.checkCancellation()
                guard pageCount < options.maxPagesPerDirectory else { throw RemoteCatalogError.budgetExceeded }
                let page = try await source.list(path: path, request: .init(cursor: cursor, limit: options.pageSize, includeHidden: run.root.includeHidden))
                pageCount += 1
                guard page.coverage == .complete else { throw RemoteCatalogError.incompleteListing }
                try await budget.consume(entries: page.entries.count)
                if let next = page.nextCursor {
                    guard !next.isEmpty, next.utf8.count <= 32768, seenCursors.insert(next).inserted else { throw RemoteCatalogError.incompleteListing }
                }
                try await store.stage(page.entries, ticket: current)
                if options.scope == .subtree {
                    for entry in page.entries where entry.isDirectory {
                        try await budget.reserveDirectory(depth: depth + 1)
                        children.append(entry.path!) // stage already validated the path.
                    }
                }
                cursor = page.nextCursor
            } while cursor != nil
            try await verifySelection(path: path, expectedID: current.providerID)
            try Task.checkCancellation()
            let count = try await withTaskCancellationHandler {
                try await store.publish(ticket: current, permit: permit)
            } onCancel: { permit.cancel() }
            return .init(path: path, depth: depth, published: count, children: children, failure: nil)
        } catch {
            if let ticket { try? await store.failDirectory(ticket: ticket) }
            return .init(path: path, depth: depth, published: nil, children: [], failure: .map(error))
        }
    }

    private func verifySelection(path: String, expectedID: String) async throws {
        let selected = try await source.stat(path: run.root.path)
        guard selected.isDirectory, selected.path == run.root.path, selected.id == run.root.entryID else { throw RemoteCatalogError.identityChanged }
        let directory = path == run.root.path ? selected : try await source.stat(path: path)
        guard directory.isDirectory, directory.path == path, directory.id == expectedID else { throw RemoteCatalogError.identityChanged }
    }
}
