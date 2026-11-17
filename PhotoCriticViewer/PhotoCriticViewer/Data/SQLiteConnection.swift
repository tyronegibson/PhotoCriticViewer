import SQLite3
import Foundation

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): "Could not open database: \(msg)"
        case .queryFailed(let msg): "Query failed: \(msg)"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the C sqlite3 API — no third-party dependency needed for
/// read-only access. This app never writes; the Python pipeline
/// (photocritic/db.py) owns all writes to this database.
///
/// Opened READWRITE with `query_only` rather than SQLITE_OPEN_READONLY: the
/// database is in WAL mode, and a truly read-only connection can't create the
/// `-shm`/`-wal` sidecar files. Whenever the last writer closes cleanly those
/// files are deleted, and a READONLY open then fails with "unable to open
/// database file". `query_only` still makes any write statement an error.
final class SQLiteConnection {
    private var db: OpaquePointer?

    init(path: String) throws {
        // FULLMUTEX: the connection is handed from a detached task to the main actor, so the
        // library's serialized-threading guarantee must be explicit rather than the default.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown error"
            sqlite3_close(db)
            throw DatabaseError.openFailed(msg)
        }
        sqlite3_busy_timeout(db, 5000)
        // If query_only doesn't take, this connection could write; refuse to hand it out.
        if sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw DatabaseError.openFailed("could not enforce read-only access: \(msg)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// Runs `sql` with positional `bind` parameters, invoking `row` once per result row.
    func query(_ sql: String, bind: [Any?] = [], row: (Row) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            row(Row(stmt: stmt!))
        }
    }

    /// Convenience wrapper for single-row-per-id-list queries (SELECT ... WHERE id IN (...)).
    func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    struct Row {
        let stmt: OpaquePointer

        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
                  let cStr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: cStr)
        }

        func int64(_ index: Int32) -> Int64 {
            sqlite3_column_int64(stmt, index)
        }

        func intOpt(_ index: Int32) -> Int? {
            sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, index))
        }

        func int64Opt(_ index: Int32) -> Int64? {
            sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, index)
        }

        func doubleOpt(_ index: Int32) -> Double? {
            sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
        }
    }
}
