import Foundation
import SQLite3

// This connection is confined to its owner's serial queue, including construction and close.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK else { close(); throw RemoteCatalogError.database(result) }
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { close() }
    func close() { if let handle { sqlite3_close_v2(handle); self.handle = nil } }
    var isOpen: Bool { handle != nil }

    func statement(_ sql: String, _ values: [SQLValue] = []) throws -> SQLiteStatement {
        guard let handle else { throw RemoteCatalogError.closed }
        return try SQLiteStatement(handle: handle, sql: sql, values: values)
    }
    @discardableResult func execute(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let statement = try statement(sql, values)
        while try statement.step() {}
        return Int(sqlite3_changes(handle))
    }
    func script(_ sql: String) throws {
        guard let handle else { throw RemoteCatalogError.closed }
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw RemoteCatalogError.database(code) }
    }
    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        let statement = try statement(sql, values)
        guard try statement.step() else { throw RemoteCatalogError.notFound }
        return statement.int(0)
    }
    func transaction<T>(permit: CatalogCommitPermit, _ operation: () throws -> T) throws -> T {
        try permit.check()
        try script("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try permit.withCommit { try script("COMMIT") }
            return result
        } catch { try? script("ROLLBACK"); throw error }
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try script("COMMIT")
            return result
        } catch { try? script("ROLLBACK"); throw error }
    }
}

enum SQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
    static func uuid(_ value: UUID) -> Self { .text(value.uuidString) }
}

final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let database: OpaquePointer
    init(handle database: OpaquePointer, sql: String, values: [SQLValue]) throws {
        self.database = database
        let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard code == SQLITE_OK else { throw RemoteCatalogError.database(code) }
        do { try bind(values) } catch { sqlite3_finalize(handle); handle = nil; throw error }
    }
    deinit { sqlite3_finalize(handle) }
    func bind(_ values: [SQLValue]) throws {
        guard let handle, sqlite3_bind_parameter_count(handle) == values.count else { throw RemoteCatalogError.database(SQLITE_MISUSE) }
        sqlite3_reset(handle); sqlite3_clear_bindings(handle)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(handle, index, text, -1, transient)
            case .integer(let integer): code = sqlite3_bind_int64(handle, index, integer)
            case .real(let real): code = sqlite3_bind_double(handle, index, real)
            case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: code = sqlite3_bind_null(handle, index)
            }
            guard code == SQLITE_OK else { throw RemoteCatalogError.database(code) }
        }
    }
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        // Do not expose sqlite3_errmsg: it can include private values and paths.
        throw RemoteCatalogError.database(sqlite3_extended_errcode(database))
    }
    func text(_ column: Int32) -> String { sqlite3_column_text(handle, column).map { String(cString: $0) } ?? "" }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func date(_ column: Int32) -> Date? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(handle, column))
    }
    func data(_ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
