import Foundation
import BoneRemoteSyncCore

struct CatalogRun: Sendable {
    let id: UUID
    let root: RemoteCatalogRoot
    let configurationRevision: Int64
    let path: String
    let scope: RemoteCatalogRefreshScope
}

/// Only the final cancellation check + COMMIT holds this lock, not the transaction's row processing.
/// Cancellation after COMMIT does not undo that publication.
final class CatalogCommitPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: TimeInterval?
    init(timeout: TimeInterval? = nil) { deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 } }
    var isExpired: Bool { deadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false }
    func check() throws { try withCommit {} }
    func cancel() { lock.withLock { cancelled = true } }
    func withCommit<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard !cancelled, deadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true else { throw CancellationError() }
            return try operation()
        }
    }
}

struct CatalogDirectoryTicket: Sendable {
    let run: CatalogRun
    let path: String
    let epoch: String
    let providerID: String
}

extension SQLiteRemoteCatalogStore {
    func beginRun(rootID: UUID, path: String, scope: RemoteCatalogRefreshScope) async throws -> CatalogRun {
        try CatalogValidation.path(path)
        return try await perform { db in
            try db.transaction {
                let root = try db.root(id: rootID)
                _ = try db.directory(root: root, path: path)
                guard try db.scalar("SELECT count(*) FROM refresh_runs WHERE root=? AND state='running'", [.uuid(rootID)]) == 0 else { throw RemoteCatalogError.busy }
                let run = CatalogRun(id: UUID(), root: root, configurationRevision: try db.profile(id: root.sourceID).configurationRevision, path: path, scope: scope)
                try db.execute("INSERT INTO refresh_runs(id,root,binding,configuration,selection,path,scope,started,state) VALUES(?,?,?,?,?,?,?,?,'running')",
                    [.uuid(run.id), .uuid(rootID), .uuid(root.bindingID), .integer(run.configurationRevision), .integer(root.selectionRevision),
                     .text(path), .text(scope.rawValue), .real(Date().timeIntervalSince1970)])
                try db.execute("UPDATE catalog_directories SET attempt=?,stale=1 WHERE root=? AND path=?", [.real(Date().timeIntervalSince1970), .uuid(rootID), .text(path)])
                return run
            }
        }
    }
    func beginDirectory(run: CatalogRun, path: String) async throws -> CatalogDirectoryTicket {
        try CatalogValidation.path(path)
        return try await perform { db in
            try db.transaction {
                try db.validate(run)
                guard CatalogValidation.contains(path, in: run.path), run.scope == .subtree || path == run.path else { throw RemoteCatalogError.invalidPath }
                let state = try db.directory(root: run.root, path: path)
                try db.execute("INSERT INTO refresh_directories(run,path,epoch,state) VALUES(?,?,?,'staging')", [.uuid(run.id), .text(path), .text(state.epoch)])
                try db.execute("UPDATE catalog_directories SET attempt=?,stale=1 WHERE root=? AND path=?", [.real(Date().timeIntervalSince1970), .uuid(run.root.id), .text(path)])
                return .init(run: run, path: path, epoch: state.epoch, providerID: state.providerID)
            }
        }
    }
    func stage(_ entries: [RemoteEntry], ticket: CatalogDirectoryTicket) async throws {
        for entry in entries {
            guard let path = entry.path else { throw RemoteCatalogError.invalidPath }
            try CatalogValidation.path(path)
            guard RemotePath.parent(of: path) == ticket.path, entry.name == RemotePath.name(of: path),
                  CatalogValidation.text(entry.id, max: 32768),
                  ticket.run.root.includeHidden || !entry.name.hasPrefix("."),
                  entry.size.map({ $0 >= 0 }) ?? true,
                  entry.createdAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  entry.modifiedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw RemoteCatalogError.incompleteListing }
        }
        // Bound each transaction even when a Local/WebDAV page materializes a very large directory.
        for start in stride(from: 0, to: entries.count, by: 500) {
            let batch = Array(entries[start..<min(start + 500, entries.count)])
            try Task.checkCancellation()
            try await perform { db in
                try db.transaction {
                    try db.validate(ticket)
                    let insert = try db.statement("INSERT INTO staged_entries(run,directory,path,provider_id,is_directory,name,payload) VALUES(?,?,?,?,?,?,?)",
                        [.uuid(ticket.run.id), .text(ticket.path), .text(""), .text(""), .integer(0), .text(""), .blob(Data())])
                    for entry in batch {
                        try insert.bind([.uuid(ticket.run.id), .text(ticket.path), .text(entry.path!), .text(entry.id),
                            .integer(entry.isDirectory ? 1 : 0), .text(entry.name), .blob(try CatalogValidation.encode(entry))])
                        _ = try insert.step()
                    }
                }
            }
        }
    }
    func publish(ticket: CatalogDirectoryTicket, permit: CatalogCommitPermit) async throws -> Int {
        try await perform { db in
            try db.transaction(permit: permit) {
                    try db.validate(ticket)
                    let args: [SQLValue] = [.uuid(ticket.run.root.id), .text(ticket.path), .text(ticket.epoch)]
                    let stageArgs: [SQLValue] = [.uuid(ticket.run.id), .text(ticket.path)]
                    // Invalidate each changed/removed direct directory's epoch. Old descendants fail ancestry checks.
                    let oldDirs = try db.statement("SELECT path,provider_id FROM catalog_entries WHERE root=? AND parent=? AND parent_epoch=? AND directory=1", args)
                    while try oldDirs.step() {
                        try permit.check()
                        let path = oldDirs.text(0)
                        let match = try db.scalar("SELECT count(*) FROM staged_entries WHERE run=? AND directory=? AND path=? AND provider_id=? AND is_directory=1",
                            stageArgs + [.text(path), .text(oldDirs.text(1))])
                        if match == 0 { try db.execute("DELETE FROM catalog_directories WHERE root=? AND path=?", [.uuid(ticket.run.root.id), .text(path)]) }
                    }
                    try db.execute("""
                        DELETE FROM catalog_entries WHERE root=? AND parent=? AND parent_epoch=? AND NOT EXISTS
                        (SELECT 1 FROM staged_entries s WHERE s.run=? AND s.directory=? AND s.path=catalog_entries.path)
                        """, args + stageArgs)
                    let staged = try db.statement("SELECT path,provider_id,is_directory,name,payload FROM staged_entries WHERE run=? AND directory=?", stageArgs)
                    var count = 0
                    while try staged.step() {
                        try permit.check()
                        let path = staged.text(0); let id = staged.text(1); let isDirectory = staged.int(2); let payload = staged.data(4)
                        let old = try db.statement("SELECT payload FROM catalog_entries WHERE root=? AND parent_epoch=? AND path=?",
                            [.uuid(ticket.run.root.id), .text(ticket.epoch), .text(path)])
                        if try old.step() {
                            if old.data(0) != payload {
                                try db.execute("UPDATE catalog_entries SET provider_id=?,directory=?,name=?,payload=? WHERE root=? AND parent_epoch=? AND path=?",
                                    [.text(id), .integer(isDirectory), .text(staged.text(3)), .blob(payload), .uuid(ticket.run.root.id), .text(ticket.epoch), .text(path)])
                            }
                        } else {
                            try db.execute("INSERT INTO catalog_entries(root,parent,parent_epoch,path,provider_id,directory,name,payload) VALUES(?,?,?,?,?,?,?,?)",
                                args + [.text(path), .text(id), .integer(isDirectory), .text(staged.text(3)), .blob(payload)])
                        }
                        if isDirectory == 1 {
                            let existing = try db.statement("SELECT parent_epoch,provider_id FROM catalog_directories WHERE root=? AND path=?", [.uuid(ticket.run.root.id), .text(path)])
                            let valid = try existing.step() && existing.text(0) == ticket.epoch && existing.text(1) == id
                            if !valid {
                                try db.execute("DELETE FROM catalog_directories WHERE root=? AND path=?", [.uuid(ticket.run.root.id), .text(path)])
                                try db.execute("INSERT INTO catalog_directories(root,path,epoch,parent_epoch,provider_id) VALUES(?,?,?,?,?)",
                                    [.uuid(ticket.run.root.id), .text(path), .uuid(UUID()), .text(ticket.epoch), .text(id)])
                            }
                        }
                        count += 1
                    }
                    try db.execute("UPDATE catalog_directories SET version=version+1,success=?,stale=0 WHERE root=? AND path=? AND epoch=?",
                        [.real(Date().timeIntervalSince1970)] + args)
                    try db.execute("UPDATE refresh_directories SET state='published',entry_count=? WHERE run=? AND path=?",
                        [.integer(Int64(count))] + stageArgs)
                    try db.execute("DELETE FROM staged_entries WHERE run=? AND directory=?", stageArgs)
                    return count
            }
        }
    }
    func failDirectory(ticket: CatalogDirectoryTicket) async throws {
        try await perform { db in
            try db.transaction {
                try db.execute("DELETE FROM staged_entries WHERE run=? AND directory=?", [.uuid(ticket.run.id), .text(ticket.path)])
                try db.execute("UPDATE refresh_directories SET state='failed' WHERE run=? AND path=? AND state='staging'", [.uuid(ticket.run.id), .text(ticket.path)])
            }
        }
    }
    func finishRun(_ run: CatalogRun, state: String, failures: [RemoteCatalogDirectoryFailure] = []) async throws {
        guard ["success", "partial", "failed", "cancelled", "interrupted"].contains(state) else { throw RemoteCatalogError.invalidConfiguration }
        try await perform { db in
            try db.transaction {
                try db.execute("DELETE FROM staged_entries WHERE run=?", [.uuid(run.id)])
                try db.execute("UPDATE refresh_directories SET state='interrupted' WHERE run=? AND state='staging'", [.uuid(run.id)])
                if state == "success", run.scope == .subtree, run.path == run.root.path {
                    try db.validate(run)
                    try db.execute("UPDATE catalog_roots SET full_success=? WHERE id=?", [.real(Date().timeIntervalSince1970), .uuid(run.root.id)])
                }
                try db.execute("UPDATE refresh_runs SET state=?,ended=?,failures=? WHERE id=? AND state='running'", [.text(state), .real(Date().timeIntervalSince1970), .blob(try CatalogValidation.encode(failures)), .uuid(run.id)])
            }
        }
    }
}

extension SQLiteConnection {
    func validate(_ run: CatalogRun) throws {
        let root = try root(id: run.root.id)
        guard root == run.root, try profile(id: root.sourceID).configurationRevision == run.configurationRevision else { throw RemoteCatalogError.staleRevision }
        let row = try statement("SELECT state FROM refresh_runs WHERE id=? AND root=?", [.uuid(run.id), .uuid(root.id)])
        guard try row.step(), row.text(0) == "running" else { throw RemoteCatalogError.staleRevision }
    }
    func validate(_ ticket: CatalogDirectoryTicket) throws {
        try validate(ticket.run)
        let directory = try directory(root: ticket.run.root, path: ticket.path)
        guard directory.epoch == ticket.epoch, directory.providerID == ticket.providerID else { throw RemoteCatalogError.identityChanged }
        let row = try statement("SELECT epoch,state FROM refresh_directories WHERE run=? AND path=?", [.uuid(ticket.run.id), .text(ticket.path)])
        guard try row.step(), row.text(0) == ticket.epoch, row.text(1) == "staging" else { throw RemoteCatalogError.staleRevision }
    }
}
