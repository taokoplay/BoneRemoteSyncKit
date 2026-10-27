import Foundation

extension SQLiteConnection {
    func installSchema() throws {
        let version = try scalar("PRAGMA user_version")
        let application = try scalar("PRAGMA application_id")
        let tables = try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        // Inspect before changing journal mode: never adopt a foreign/unsupported database.
        guard (version == 0 && application == 0 && tables == 0) || (version == 1 && application == 1112687435) else {
            throw RemoteCatalogError.unsupportedSchema
        }
        try script("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=1000;")
        if version == 0 {
            try transaction {
                try script(Self.schema)
                try script("PRAGMA application_id=1112687435; PRAGMA user_version=1;")
            }
        }
    }

    func recoverInterruptedRuns() throws -> Int {
        // Recovery never publishes staging, resumes cursors, or removes profiles.
        return try transaction {
            let interrupted = try execute("UPDATE refresh_runs SET state='interrupted',ended=? WHERE state='running'", [.real(Date().timeIntervalSince1970)])
            try execute("UPDATE refresh_directories SET state='interrupted' WHERE state='staging'")
            try execute("DELETE FROM staged_entries")
            return interrupted
        }
    }

    private static let schema = """
    CREATE TABLE retired_bindings (binding TEXT PRIMARY KEY NOT NULL);
    CREATE TABLE source_profiles (
        id TEXT PRIMARY KEY NOT NULL, binding TEXT NOT NULL, revision INTEGER NOT NULL,
        credential TEXT, payload BLOB NOT NULL
    );
    CREATE INDEX profiles_credential ON source_profiles(credential);
    CREATE TABLE catalog_roots (
        id TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL REFERENCES source_profiles(id) ON DELETE CASCADE,
        binding TEXT NOT NULL, selection INTEGER NOT NULL, payload BLOB NOT NULL, full_success REAL
    );
    CREATE INDEX roots_source ON catalog_roots(source);
    CREATE TABLE catalog_directories (
        root TEXT NOT NULL REFERENCES catalog_roots(id) ON DELETE CASCADE,
        path TEXT NOT NULL, epoch TEXT NOT NULL, parent_epoch TEXT, provider_id TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 0, success REAL, attempt REAL, stale INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY(root,path)
    );
    CREATE TABLE catalog_entries (
        root TEXT NOT NULL REFERENCES catalog_roots(id) ON DELETE CASCADE,
        parent TEXT NOT NULL, parent_epoch TEXT NOT NULL, path TEXT NOT NULL, provider_id TEXT NOT NULL,
        directory INTEGER NOT NULL, name TEXT NOT NULL COLLATE BINARY, payload BLOB NOT NULL,
        PRIMARY KEY(root,parent_epoch,path)
    );
    CREATE INDEX entries_parent_order ON catalog_entries(root,parent,parent_epoch,directory DESC,name COLLATE BINARY,path COLLATE BINARY);
    CREATE INDEX entries_identity ON catalog_entries(root,provider_id);
    CREATE TABLE refresh_runs (
        id TEXT PRIMARY KEY NOT NULL, root TEXT NOT NULL REFERENCES catalog_roots(id) ON DELETE CASCADE,
        binding TEXT NOT NULL, configuration INTEGER NOT NULL, selection INTEGER NOT NULL,
        path TEXT NOT NULL, scope TEXT NOT NULL, started REAL NOT NULL, ended REAL, state TEXT NOT NULL, failures BLOB
    );
    CREATE UNIQUE INDEX one_running_root ON refresh_runs(root) WHERE state='running';
    CREATE TABLE refresh_directories (
        run TEXT NOT NULL REFERENCES refresh_runs(id) ON DELETE CASCADE,
        path TEXT NOT NULL, epoch TEXT NOT NULL, state TEXT NOT NULL, entry_count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(run,path)
    );
    CREATE TABLE staged_entries (
        run TEXT NOT NULL REFERENCES refresh_runs(id) ON DELETE CASCADE,
        directory TEXT NOT NULL, path TEXT NOT NULL, provider_id TEXT NOT NULL,
        is_directory INTEGER NOT NULL, name TEXT NOT NULL, payload BLOB NOT NULL,
        PRIMARY KEY(run,directory,path), UNIQUE(run,directory,provider_id)
    );
    """
}
