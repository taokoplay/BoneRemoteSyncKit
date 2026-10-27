import Foundation

public struct RemoteCatalogRunStatus: Sendable {
    public let refreshID: UUID
    public let directory: String
    public let scope: RemoteCatalogRefreshScope
    /// running, success, partial, failed, cancelled, or interrupted.
    public let state: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let publishedDirectories: Int
    public let publishedEntries: Int
    public let failures: [RemoteCatalogDirectoryFailure]
}
public struct RemoteCatalogStatus: Sendable {
    public let root: RemoteCatalogRoot
    public let lastFullSubtreeSuccessfulAt: Date?
    public let latestRun: RemoteCatalogRunStatus?
}
extension SQLiteRemoteCatalogStore {
    /// Purely local run history summary; does not restore a network cursor or start work.
    public func status(rootID: UUID) async throws -> RemoteCatalogStatus {
        try await perform { db in
            let root = try db.root(id: rootID)
            let record = try db.statement("SELECT full_success FROM catalog_roots WHERE id=?", [.uuid(rootID)])
            _ = try record.step()
            let fullSuccess = record.date(0)
            let row = try db.statement("SELECT id,path,scope,state,started,ended,failures FROM refresh_runs WHERE root=? ORDER BY started DESC,rowid DESC LIMIT 1", [.uuid(rootID)])
            var latest: RemoteCatalogRunStatus?
            if try row.step() {
                guard let id = UUID(uuidString: row.text(0)), let scope = RemoteCatalogRefreshScope(rawValue: row.text(2)), let start = row.date(4) else {
                    throw RemoteCatalogError.unsupportedSchema
                }
                let counts = try db.statement("SELECT count(*),coalesce(sum(entry_count),0) FROM refresh_directories WHERE run=? AND state='published'", [.uuid(id)])
                _ = try counts.step()
                let payload = row.data(6)
                let failures = payload.isEmpty ? [] : try CatalogValidation.decode([RemoteCatalogDirectoryFailure].self, payload)
                latest = .init(refreshID: id, directory: row.text(1), scope: scope, state: row.text(3), startedAt: start, finishedAt: row.date(5),
                    publishedDirectories: Int(counts.int(0)), publishedEntries: Int(counts.int(1)), failures: failures)
            }
            return .init(root: root, lastFullSubtreeSuccessfulAt: fullSuccess, latestRun: latest)
        }
    }
}
