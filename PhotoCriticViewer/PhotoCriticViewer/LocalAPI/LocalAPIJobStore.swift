import Foundation
import SQLite3

/// Persistent tracking for /critique's jobs, backed by a small SQLite file the local API owns
/// entirely on its own: `<workspace>/database/local_api_jobs.sqlite`. This is a DELIBERATE,
/// narrow exception to "Python is the sole writer" -- that rule protects photo/shoot/evaluation
/// data integrity in photocritic.db, which this never touches; it's a second, separate database
/// file holding nothing but this API's own job bookkeeping, which Python never reads or writes.
///
/// Survives an app relaunch: job rows persist in the file. A job still marked "running" (or
/// "queued") when the app starts is NOT resumed -- the subprocess that was running it is gone
/// (or, if it somehow outlived the app via launchd reparenting the way organize.py/evaluate.py
/// can, this app has no record of its PID to re-attach to) -- it's marked "failed" with an
/// explanatory error instead, so its history is still visible via GET /jobs/{id} rather than
/// just vanishing.
///
/// An actor: every query/write goes through one serial queue, matching SQLiteConnection's own
/// FULLMUTEX reasoning elsewhere in this app, and giving queue() (the dispatcher) a safe place
/// to pop the next job without a race against a concurrent create().
actor LocalAPIJobStore {
    enum Status: String {
        case queued, running, done, failed
    }

    struct Job {
        let id: String
        var status: Status
        var stage: String?
        var current: Int?
        var total: Int?
        var result: Data?
        var error: String?
        var createdAt: Double
        /// What the job was asked to do, e.g. "shoot:42" or "files:3" (set at create()).
        var params: String? = nil
    }

    static let shared = LocalAPIJobStore()

    private var db: OpaquePointer?
    private let retentionSeconds: Double = 24 * 60 * 60 // prune finished jobs older than this

    /// Not delegated to separate instance methods: an actor's own init isn't considered fully
    /// actor-isolated until it completes, so synchronous actor-isolated methods can't be called
    /// from within it (Swift 6 mode flags it as an error) -- only direct access to stored
    /// properties is allowed here, so both steps are inlined.
    private init() {
        let path = WorkspaceConfig.root.appendingPathComponent("database/local_api_jobs.sqlite").path
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    stage TEXT,
                    current INTEGER,
                    total INTEGER,
                    result BLOB,
                    error TEXT,
                    created_at REAL NOT NULL,
                    params TEXT
                )
                """, nil, nil, nil)
            // A job left "queued" or "running" from before this launch -- the subprocess
            // behind it is gone (no PID was recorded to reattach to even if it somehow
            // survived) -- so its outcome is unknowable, not silently "still running" forever.
            sqlite3_exec(db, """
                UPDATE jobs SET status = 'failed', error = 'interrupted by an app restart'
                WHERE status IN ('queued', 'running')
                """, nil, nil, nil)
        } else {
            db = nil
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func pruneOldFinishedJobs() {
        guard let db else { return }
        let cutoff = Date().timeIntervalSince1970 - retentionSeconds
        var stmt: OpaquePointer?
        let sql = "DELETE FROM jobs WHERE status IN ('done', 'failed') AND created_at < ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }

    @discardableResult
    func create(paramsDescription: String) -> String {
        pruneOldFinishedJobs()
        let id = UUID().uuidString
        guard let db else { return id }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO jobs (id, status, created_at, params) VALUES (?, 'queued', ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return id }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, paramsDescription, -1, transient)
        sqlite3_step(stmt)
        return id
    }

    func get(_ id: String) -> Job? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT id, status, stage, current, total, result, error, created_at, params FROM jobs WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.row(from: stmt)
    }

    /// The oldest still-queued job, if any -- what the dispatcher (LocalAPICriticJobQueue)
    /// picks up next once the current evaluate.py run finishes.
    func nextQueued() -> Job? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT id, status, stage, current, total, result, error, created_at, params FROM jobs " +
                  "WHERE status = 'queued' ORDER BY created_at ASC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.row(from: stmt)
    }

    /// Most recent first -- GET /jobs. Includes finished jobs until the 24h prune.
    func list(limit: Int) -> [Job] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT id, status, stage, current, total, result, error, created_at, params FROM jobs " +
                  "ORDER BY created_at DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var jobs: [Job] = []
        while sqlite3_step(stmt) == SQLITE_ROW { jobs.append(Self.row(from: stmt)) }
        return jobs
    }

    func update(_ id: String, status: Status? = nil, stage: String? = nil, current: Int? = nil, total: Int? = nil, result: Data? = nil, error: String? = nil) {
        guard let job = get(id), let db else { return }
        var stmt: OpaquePointer?
        let sql = "UPDATE jobs SET status = ?, stage = ?, current = ?, total = ?, result = ?, error = ? WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (status ?? job.status).rawValue, -1, transient)
        if let s = stage ?? job.stage { sqlite3_bind_text(stmt, 2, s, -1, transient) } else { sqlite3_bind_null(stmt, 2) }
        if let c = current ?? job.current { sqlite3_bind_int64(stmt, 3, Int64(c)) } else { sqlite3_bind_null(stmt, 3) }
        if let t = total ?? job.total { sqlite3_bind_int64(stmt, 4, Int64(t)) } else { sqlite3_bind_null(stmt, 4) }
        if let r = result ?? job.result { _ = r.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32(r.count), transient) } } else { sqlite3_bind_null(stmt, 5) }
        if let e = error ?? job.error { sqlite3_bind_text(stmt, 6, e, -1, transient) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_text(stmt, 7, id, -1, transient)
        sqlite3_step(stmt)
    }

    private static func row(from stmt: OpaquePointer?) -> Job {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let status = Status(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .failed
        let stage = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let current = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3))
        let total = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 4))
        var result: Data?
        if sqlite3_column_type(stmt, 5) != SQLITE_NULL, let blob = sqlite3_column_blob(stmt, 5) {
            result = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 5)))
        }
        let error = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let createdAt = sqlite3_column_double(stmt, 7)
        let params = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        return Job(id: id, status: status, stage: stage, current: current, total: total, result: result, error: error, createdAt: createdAt, params: params)
    }
}
