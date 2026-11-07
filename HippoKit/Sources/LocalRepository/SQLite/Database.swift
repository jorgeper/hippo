import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, Equatable {
    case sqlite(code: Int32, message: String)
}

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct Row: Sendable {
    let values: [String: SQLValue]

    public subscript(_ name: String) -> SQLValue { values[name] ?? .null }

    public func string(_ name: String) -> String? {
        if case .text(let s) = self[name] { return s }
        return nil
    }

    public func int(_ name: String) -> Int64? {
        if case .int(let i) = self[name] { return i }
        return nil
    }

    public func double(_ name: String) -> Double? {
        if case .double(let d) = self[name] { return d }
        return nil
    }

    /// Dates are stored as Int64 Unix milliseconds.
    public func date(_ name: String) -> Date? {
        int(name).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// One SQLite connection. Safe to share across threads; access is serialized by an
/// internal lock. Several instances (or processes) may open the same file.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var inTransaction = false

    public init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw DatabaseError.sqlite(code: rc, message: message)
        }
        handle = db
        do {
            // Busy timeout first so the WAL switch and migration wait for other connections.
            sqlite3_busy_timeout(db, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try Migrations.run(on: self)
        } catch {
            sqlite3_close(db)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    public func execute(_ sql: String, _ args: [SQLValue] = []) throws {
        _ = try run(sql, args, collect: false)
    }

    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [Row] {
        try run(sql, args, collect: true)
    }

    /// Runs `body` inside `BEGIN IMMEDIATE`; commits on return, rolls back on throw.
    /// Not reentrant: a nested call on the same instance throws.
    public func transaction<T>(_ body: (Database) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !inTransaction else {
            throw DatabaseError.sqlite(code: SQLITE_MISUSE, message: "nested transaction")
        }
        try execute("BEGIN IMMEDIATE")
        inTransaction = true
        defer { inTransaction = false }
        do {
            let result = try body(self)
            try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    /// Executes a script of several statements (no bound values). Used by migrations.
    func executeScript(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        if rc != SQLITE_OK { throw lastError(rc) }
    }

    private func lastError(_ code: Int32) -> DatabaseError {
        .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    private func run(_ sql: String, _ args: [SQLValue], collect: Bool) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard rc == SQLITE_OK else { throw lastError(rc) }

        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(buf.count), SQLITE_TRANSIENT)
                }
            }
            guard rc == SQLITE_OK else { throw lastError(rc) }
        }

        var rows: [Row] = []
        let columns = sqlite3_column_count(stmt)
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(rc) }
            guard collect else { continue }
            var values: [String: SQLValue] = [:]
            for c in 0..<columns {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    values[name] = .blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: n))
                default: values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }
}
