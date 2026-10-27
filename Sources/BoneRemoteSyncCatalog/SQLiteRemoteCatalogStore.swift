import Foundation
import Darwin
import BoneRemoteSyncCore

/// One owner per database, in a host-selected private local directory. Never share a live WAL database over a network.
/// All SQLite work runs on a dedicated serial queue. Transactions contain no suspension points or network requests.
public final class SQLiteRemoteCatalogStore: RemoteCatalogStore, @unchecked Sendable {
    let queue = DispatchQueue(label: "BoneRemoteSyncCatalog.SQLite")
    let database: SQLiteConnection
    private let ownerPath: String
    private let ownerID = UUID()
    private let queueKey = DispatchSpecificKey<Bool>()
    private static let owners = CatalogDatabaseOwners()

    public let logger: RemoteLogger

    public convenience init(databaseURL: URL, logger: RemoteLogger = .disabled) throws {
        do { try self.init(opening: databaseURL, logger: logger) }
        catch let failure as CatalogRecoveryFailure {
            logger.record(failure.underlying, component: .sqlite, operation: .databaseRecovery)
            throw failure.underlying
        } catch {
            logger.record(error, component: .sqlite, operation: .databaseOpen)
            throw error
        }
    }

    private init(opening databaseURL: URL, logger: RemoteLogger) throws {
        self.logger = logger
        guard databaseURL.isFileURL, databaseURL.host == nil || databaseURL.host == "localhost",
              databaseURL.query == nil, databaseURL.fragment == nil,
              !databaseURL.path.utf8.contains(0), databaseURL.path != "/" else { throw RemoteCatalogError.invalidConfiguration }
        let input = databaseURL.standardizedFileURL
        // Canonicalize only the parent. Resolving an existing target through Foundation may open/close
        // its descriptor, which must not disturb another SQLite owner's process-wide file locks.
        let url = input.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(input.lastPathComponent)
        // Resolve file identity before SQLite creates/opens a WAL. Hard-link aliases are unsupported.
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw RemoteCatalogError.invalidConfiguration }
            let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw RemoteCatalogError.invalidConfiguration }
            Darwin.close(descriptor)
            guard lstat(url.path, &info) == 0 else { throw RemoteCatalogError.invalidConfiguration }
        }
        // Do not open and close another descriptor for an existing database: POSIX close can
        // release locks belonging to SQLite's connection in this process.
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw RemoteCatalogError.invalidConfiguration }
        ownerPath = "\(info.st_dev):\(info.st_ino)"
        try Self.owners.acquire(ownerPath, owner: ownerID)
        queue.setSpecific(key: queueKey, value: true)
        do {
            let opened = try queue.sync {
                let db = try SQLiteConnection(url: url)
                try db.installSchema()
                do { return (db, try db.recoverInterruptedRuns()) }
                catch { throw CatalogRecoveryFailure(underlying: error) }
            }
            database = opened.0
            // Delivery is outside the SQLite queue/transaction and only after successful recovery.
            if opened.1 > 0 {
                logger.emit(.init(component: .sqlite, operation: .databaseRecovery, code: .interrupted, occurrenceCount: opened.1))
            }
        } catch { Self.owners.release(ownerPath, owner: ownerID); throw error }
    }
    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true { database.close() }
        else { queue.sync { database.close() } }
        Self.owners.release(ownerPath, owner: ownerID)
    }
    func perform<T: Sendable>(_ operation: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard database.isOpen else { throw RemoteCatalogError.closed }
                    continuation.resume(returning: try operation(database))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func close() async throws {
        do {
            try await perform { [self] db in
                try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                db.close(); Self.owners.release(ownerPath, owner: ownerID)
            }
        } catch {
            logger.record(error, component: .sqlite, operation: .databaseClose)
            throw error
        }
    }
    public func saveProfile(_ profile: RemoteSourceProfile, expectedRevision: Int64? = nil) async throws {
        try profile.validate()
        try await perform { db in
            try db.transaction {
                let old = try db.optionalProfile(id: profile.id)
                if let old {
                    guard expectedRevision == old.configurationRevision,
                          profile.configurationRevision == old.configurationRevision + 1 else { throw RemoteCatalogError.staleRevision }
                    if old.bindingID == profile.bindingID {
                        guard old.configuration.sameBinding(as: profile.configuration),
                              old.credentialReference == profile.credentialReference else { throw RemoteCatalogError.invalidConfiguration }
                    } else if let reference = profile.credentialReference, reference == old.credentialReference {
                        throw RemoteCatalogError.invalidConfiguration
                    }
                } else {
                    guard expectedRevision == nil, profile.configurationRevision == 1 else { throw RemoteCatalogError.staleRevision }
                }
                if old?.bindingID != profile.bindingID {
                    guard try db.scalar("SELECT count(*) FROM retired_bindings WHERE binding=?", [.uuid(profile.bindingID)]) == 0 else { throw RemoteCatalogError.invalidConfiguration }
                    if let old { try db.execute("INSERT OR IGNORE INTO retired_bindings(binding) VALUES(?)", [.uuid(old.bindingID)]) }
                }
                if let reference = profile.credentialReference {
                    let peers = try db.statement("SELECT payload FROM source_profiles WHERE credential=? AND id<>?", [.uuid(reference), .uuid(profile.id)])
                    while try peers.step() {
                        let peer = try CatalogValidation.decode(RemoteSourceProfile.self, peers.data(0)); try peer.validate()
                        guard peer.bindingID == profile.bindingID, peer.configuration.sameBinding(as: profile.configuration) else {
                            throw RemoteCatalogError.invalidConfiguration
                        }
                    }
                }
                let values: [SQLValue] = [.uuid(profile.bindingID), .integer(profile.configurationRevision),
                    profile.credentialReference.map(SQLValue.uuid) ?? .null, .blob(try CatalogValidation.encode(profile)), .uuid(profile.id)]
                if old == nil {
                    try db.execute("INSERT INTO source_profiles(binding,revision,credential,payload,id) VALUES(?,?,?,?,?)", values)
                } else {
                    try db.execute("UPDATE source_profiles SET binding=?,revision=?,credential=?,payload=? WHERE id=?", values)
                    try db.execute("UPDATE catalog_directories SET stale=1 WHERE root IN (SELECT id FROM catalog_roots WHERE source=?)", [.uuid(profile.id)])
                    let affected = "SELECT id FROM refresh_runs WHERE state='running' AND root IN (SELECT id FROM catalog_roots WHERE source=?)"
                    try db.execute("DELETE FROM staged_entries WHERE run IN (\(affected))", [.uuid(profile.id)])
                    try db.execute("UPDATE refresh_directories SET state='interrupted' WHERE state='staging' AND run IN (\(affected))", [.uuid(profile.id)])
                    try db.execute("UPDATE refresh_runs SET state='interrupted',ended=? WHERE state='running' AND root IN (SELECT id FROM catalog_roots WHERE source=?)",
                        [.real(Date().timeIntervalSince1970), .uuid(profile.id)])
                }
            }
        }
    }
    public func profile(id: UUID) async throws -> RemoteSourceProfile { try await perform { try $0.profile(id: id) } }
    public func profiles() async throws -> [RemoteSourceProfile] {
        try await perform { db in
            let statement = try db.statement("SELECT payload FROM source_profiles ORDER BY id")
            var profiles: [RemoteSourceProfile] = []
            while try statement.step() {
                let p = try CatalogValidation.decode(RemoteSourceProfile.self, statement.data(0)); try p.validate(); profiles.append(p)
            }
            return profiles
        }
    }
    public func saveRoot(_ root: RemoteCatalogRoot, expectedRevision: Int64? = nil) async throws {
        try root.validate()
        try await perform { db in
            try db.transaction {
                let profile = try db.profile(id: root.sourceID)
                guard profile.bindingID == root.bindingID else { throw RemoteCatalogError.staleRevision }
                let statement = try db.statement("SELECT payload FROM catalog_roots WHERE id=?", [.uuid(root.id)])
                if try statement.step() {
                    let old = try CatalogValidation.decode(RemoteCatalogRoot.self, statement.data(0))
                    guard expectedRevision == old.selectionRevision, root.selectionRevision == old.selectionRevision + 1,
                          root.sourceID == old.sourceID else { throw RemoteCatalogError.staleRevision }
                    try db.execute("DELETE FROM catalog_roots WHERE id=?", [.uuid(root.id)])
                } else {
                    guard expectedRevision == nil, root.selectionRevision == 1 else { throw RemoteCatalogError.staleRevision }
                }
                try db.execute("INSERT INTO catalog_roots(id,source,binding,selection,payload) VALUES(?,?,?,?,?)",
                    [.uuid(root.id), .uuid(root.sourceID), .uuid(root.bindingID), .integer(root.selectionRevision), .blob(try CatalogValidation.encode(root))])
                try db.insertRootDirectory(root)
            }
        }
    }
    func selectionForManagement(id: UUID) async throws -> RemoteCatalogRoot { try await perform { try $0.rawRoot(id: id) } }
    public func root(id: UUID) async throws -> RemoteCatalogRoot { try await perform { try $0.root(id: id) } }
    public func roots(sourceID: UUID) async throws -> [RemoteCatalogRoot] {
        try await perform { db in
            let statement = try db.statement("SELECT payload FROM catalog_roots WHERE source=? ORDER BY id", [.uuid(sourceID)])
            var roots: [RemoteCatalogRoot] = []
            while try statement.step() {
                let root = try CatalogValidation.decode(RemoteCatalogRoot.self, statement.data(0)); try root.validate(); roots.append(root)
            }
            return roots
        }
    }
    public func listCached(rootID: UUID, directory: String, query: RemoteCatalogQuery = .init()) async throws -> RemoteCatalogSnapshot {
        try CatalogValidation.path(directory)
        guard (1...1000).contains(query.limit) else { throw RemoteCatalogError.invalidConfiguration }
        return try await perform { db in
            let root = try db.root(id: rootID)
            let state = try db.directory(root: root, path: directory)
            var offset: Int64 = 0
            if let raw = query.pageToken {
                guard raw.utf8.count <= 8192, let data = Data(base64Encoded: raw),
                      let token = try? JSONDecoder().decode(CatalogPageToken.self, from: data),
                      token.root == rootID, token.selection == root.selectionRevision,
                      token.epoch == state.epoch, token.version == state.version,
                      token.limit == query.limit, token.offset >= 0 else { throw RemoteCatalogError.invalidPageToken }
                offset = token.offset
            }
            let statement = try db.statement("""
                SELECT payload FROM catalog_entries WHERE root=? AND parent=? AND parent_epoch=?
                ORDER BY directory DESC,name COLLATE BINARY,path COLLATE BINARY LIMIT ? OFFSET ?
                """, [.uuid(rootID), .text(directory), .text(state.epoch), .integer(Int64(query.limit + 1)), .integer(offset)])
            var entries: [RemoteEntry] = []
            while try statement.step() { entries.append(try CatalogValidation.decode(RemoteEntry.self, statement.data(0))) }
            let hasMore = entries.count > query.limit
            if hasMore { entries.removeLast() }
            let next = hasMore ? try CatalogValidation.encode(CatalogPageToken(root: rootID, selection: root.selectionRevision,
                epoch: state.epoch, version: state.version, limit: query.limit, offset: offset + Int64(entries.count))).base64EncodedString() : nil
            return RemoteCatalogSnapshot(entries: entries, state: state.success == nil ? .notInitialized : (state.stale ? .stale : .current),
                version: state.version, lastSuccessfulAt: state.success, lastAttemptAt: state.attempt, nextPageToken: next)
        }
    }
    public func clearIndex(rootID: UUID) async throws {
        try await perform { db in
            try db.transaction {
                // Management is allowed offline even after a binding change; cache reads remain isolated.
                let root = try db.rawRoot(id: rootID)
                try db.execute("DELETE FROM refresh_runs WHERE root=?", [.uuid(rootID)])
                try db.execute("DELETE FROM catalog_entries WHERE root=?", [.uuid(rootID)])
                try db.execute("DELETE FROM catalog_directories WHERE root=?", [.uuid(rootID)])
                try db.execute("UPDATE catalog_roots SET full_success=NULL WHERE id=?", [.uuid(rootID)])
                try db.insertRootDirectory(root)
            }
        }
    }
    /// Removes only local records; never removes Keychain items or remote resources.
    public func removeProfile(id: UUID) async throws {
        try await perform { db in try db.execute("DELETE FROM source_profiles WHERE id=?", [.uuid(id)]); return () }
    }
}

private struct CatalogPageToken: Codable {
    let root: UUID
    let selection: Int64
    let epoch: String
    let version: Int64
    let limit: Int
    let offset: Int64
}

struct CatalogDirectoryState: Sendable {
    let epoch: String
    let providerID: String
    let parentEpoch: String
    let version: Int64
    let success: Date?
    let attempt: Date?
    let stale: Bool
}

extension SQLiteConnection {
    func optionalProfile(id: UUID) throws -> RemoteSourceProfile? {
        let s = try statement("SELECT payload FROM source_profiles WHERE id=?", [.uuid(id)])
        guard try s.step() else { return nil }
        let p = try CatalogValidation.decode(RemoteSourceProfile.self, s.data(0)); try p.validate(); return p
    }
    func profile(id: UUID) throws -> RemoteSourceProfile {
        guard let profile = try optionalProfile(id: id) else { throw RemoteCatalogError.notFound }; return profile
    }
    func root(id: UUID) throws -> RemoteCatalogRoot {
        let root = try rawRoot(id: id)
        guard try profile(id: root.sourceID).bindingID == root.bindingID else { throw RemoteCatalogError.staleRevision }
        return root
    }
    func rawRoot(id: UUID) throws -> RemoteCatalogRoot {
        let s = try statement("SELECT payload FROM catalog_roots WHERE id=?", [.uuid(id)])
        guard try s.step() else { throw RemoteCatalogError.notFound }
        let root = try CatalogValidation.decode(RemoteCatalogRoot.self, s.data(0)); try root.validate()
        return root
    }
    func insertRootDirectory(_ root: RemoteCatalogRoot) throws {
        try execute("INSERT INTO catalog_directories(root,path,epoch,provider_id) VALUES(?,?,?,?)",
                    [.uuid(root.id), .text(root.path), .uuid(UUID()), .text(root.entryID)])
    }
    func rawDirectory(rootID: UUID, path: String) throws -> CatalogDirectoryState {
        let s = try statement("SELECT epoch,provider_id,parent_epoch,version,success,attempt,stale FROM catalog_directories WHERE root=? AND path=?",
                              [.uuid(rootID), .text(path)])
        guard try s.step() else { throw RemoteCatalogError.notFound }
        return .init(epoch: s.text(0), providerID: s.text(1), parentEpoch: s.text(2), version: s.int(3), success: s.date(4), attempt: s.date(5), stale: s.int(6) != 0)
    }
    func directory(root: RemoteCatalogRoot, path: String) throws -> CatalogDirectoryState {
        guard CatalogValidation.contains(path, in: root.path) else { throw RemoteCatalogError.invalidPath }
        var chain: [String] = []; var cursor = path
        while cursor != root.path {
            chain.append(cursor)
            guard let parent = RemotePath.parent(of: cursor) else { throw RemoteCatalogError.invalidPath }
            cursor = parent
        }
        var state = try rawDirectory(rootID: root.id, path: root.path)
        for child in chain.reversed() {
            let next = try rawDirectory(rootID: root.id, path: child)
            guard next.parentEpoch == state.epoch else { throw RemoteCatalogError.notFound }
            let s = try statement("SELECT provider_id FROM catalog_entries WHERE root=? AND parent_epoch=? AND path=? AND directory=1",
                                  [.uuid(root.id), .text(state.epoch), .text(child)])
            guard try s.step(), s.text(0) == next.providerID else { throw RemoteCatalogError.notFound }
            state = next
        }
        return state
    }
}

private final class CatalogDatabaseOwners: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: UUID] = [:]
    func acquire(_ path: String, owner: UUID) throws {
        try lock.withLock {
            guard paths[path] == nil else { throw RemoteCatalogError.busy }
            paths[path] = owner
        }
    }
    func release(_ path: String, owner: UUID) {
        lock.withLock { if paths[path] == owner { paths[path] = nil } }
    }
}
