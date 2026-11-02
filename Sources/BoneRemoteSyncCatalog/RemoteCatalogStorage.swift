import Foundation
import BoneRemoteSyncCore

extension SQLiteRemoteCatalogStore {
    func saveStorageSummary(_ summary: RemoteCatalogStorageSummary) async throws {
        try await perform { db in
            try db.transaction {
                let root = try db.root(id: summary.rootID)
                guard root.path == summary.path else { throw RemoteCatalogError.staleRevision }
                try db.replaceStorageSummary(summary, bindingID: root.bindingID, selection: root.selectionRevision)
            }
        }
    }

    /// 读取指定 Catalog root 最近一次持久化的存储统计。
    ///
    /// - Parameter rootID: 要查询统计的 Catalog 根目录 ID。
    /// - Returns: 没有完成过完整 subtree 扫描时返回 `nil`。
    public func storageSummary(rootID: UUID) async throws -> RemoteCatalogStorageSummary? {
        try await perform { db in
            let root = try db.root(id: rootID)
            let statement = try db.statement("""
                SELECT path,file_count,directory_count,total_bytes,capacity_bytes,used_bytes,
                       complete,stale,measured,quota_measured,binding,selection
                FROM catalog_summaries WHERE root=?
                """, [.uuid(rootID)])
            guard try statement.step() else { return nil }
            guard statement.text(10) == root.bindingID.uuidString,
                  statement.int(11) == root.selectionRevision else {
                throw RemoteCatalogError.staleRevision
            }
            return .init(
                rootID: rootID,
                path: statement.text(0),
                recursiveFileCount: statement.optionalInt(1),
                recursiveDirectoryCount: statement.optionalInt(2),
                totalBytes: statement.optionalInt(3),
                capacityBytes: statement.optionalInt(4),
                usedBytes: statement.optionalInt(5),
                isComplete: statement.int(6) != 0,
                isStale: statement.int(7) != 0,
                measuredAt: statement.date(8),
                quotaMeasuredAt: statement.date(9)
            )
        }
    }

    /// 将指定目录的列表缓存和 root 统计标记为过期。
    ///
    /// - Parameters:
    ///   - rootID: 要失效的 Catalog 根目录 ID。
    ///   - directory: 已发生远端 mutation 的目录路径；省略时使用 root 路径。
    public func invalidateCache(rootID: UUID, directory: String? = nil) async throws {
        try await perform { db in
            try db.transaction {
                let root = try db.root(id: rootID)
                let path = directory ?? root.path
                _ = try db.directory(root: root, path: path)
                try db.execute("UPDATE catalog_directories SET stale=1 WHERE root=? AND path=?", [.uuid(rootID), .text(path)])
                try db.execute("UPDATE catalog_roots SET full_success=NULL WHERE id=?", [.uuid(rootID)])
                try db.execute("UPDATE catalog_summaries SET stale=1 WHERE root=?", [.uuid(rootID)])
            }
        }
    }
}

extension SQLiteConnection {
    func replaceStorageSummary(_ summary: RemoteCatalogStorageSummary, bindingID: UUID, selection: Int64) throws {
        try execute("DELETE FROM catalog_summaries WHERE root=?", [.uuid(summary.rootID)])
        try execute("""
            INSERT INTO catalog_summaries(
                root,binding,selection,path,file_count,directory_count,total_bytes,
                capacity_bytes,used_bytes,complete,stale,measured,quota_measured
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, summary.values(bindingID: bindingID, selection: selection))
    }
}

private extension RemoteCatalogStorageSummary {
    func values(bindingID: UUID, selection: Int64) -> [SQLValue] {
        [
            .uuid(rootID), .uuid(bindingID), .integer(selection), .text(path),
            recursiveFileCount.map(SQLValue.integer) ?? .null,
            recursiveDirectoryCount.map(SQLValue.integer) ?? .null,
            totalBytes.map(SQLValue.integer) ?? .null,
            capacityBytes.map(SQLValue.integer) ?? .null,
            usedBytes.map(SQLValue.integer) ?? .null,
            .integer(isComplete ? 1 : 0), .integer(isStale ? 1 : 0),
            measuredAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            quotaMeasuredAt.map { .real($0.timeIntervalSince1970) } ?? .null
        ]
    }
}

private extension SQLiteStatement {
    func optionalInt(_ column: Int32) -> Int64? {
        isNull(column) ? nil : int(column)
    }
}
