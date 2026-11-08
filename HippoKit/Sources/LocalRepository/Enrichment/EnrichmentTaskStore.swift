import Foundation
import CaptureCore

/// One (capture, facet kind) row of silver enrichment work.
public struct EnrichmentTask: Sendable, Equatable {
    public var captureID: String
    public var kind: FacetKind
    public var version: Int
    /// `pending`, `ok`, `empty`, `failed` or `not_applicable`.
    public var status: String
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var lastErrorCode: String?

    public init(captureID: String, kind: FacetKind, version: Int, status: String, attemptCount: Int,
                nextAttemptAt: Date?, lastErrorCode: String?) {
        self.captureID = captureID; self.kind = kind; self.version = version; self.status = status
        self.attemptCount = attemptCount; self.nextAttemptAt = nextAttemptAt; self.lastErrorCode = lastErrorCode
    }
}

/// Silver enrichment work per (capture, kind) (design §6.2). Only the app's runner uses it, one task at a
/// time, so there are no leases: `claimNext` reads, and the runner records the outcome.
public final class EnrichmentTaskStore: Sendable {
    private let db: Database

    public init(db: Database) { self.db = db }

    /// Captures with no row for `kind`, or a row at another version. Newest first.
    public func capturesNeeding(kind: FacetKind, version: Int, limit: Int) throws -> [String] {
        try db.query("""
            SELECT c.capture_id FROM captures c
            LEFT JOIN enrichment_tasks t ON t.capture_id = c.capture_id AND t.kind = ?
            WHERE t.capture_id IS NULL OR t.version <> ?
            ORDER BY c.captured_at_ms DESC, c.capture_id DESC LIMIT ?
            """, [.text(kind.rawValue), .int(Int64(version)), .int(Int64(max(limit, 0)))])
            .compactMap { $0.string("capture_id") }
    }

    /// Creates or replaces the row, resetting attempts, the retry time and the error.
    public func set(captureID: String, kind: FacetKind, version: Int, status: String, now: Date) throws {
        try db.execute("""
            INSERT INTO enrichment_tasks(capture_id, kind, version, status, updated_at_ms) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(capture_id, kind) DO UPDATE SET version = excluded.version, status = excluded.status,
              attempt_count = 0, next_attempt_at_ms = NULL, last_error_code = NULL, updated_at_ms = excluded.updated_at_ms
            """, [.text(captureID), .text(kind.rawValue), .int(Int64(version)), .text(status), .int(Self.ms(now))])
    }

    /// The next due `pending` task whose kind is in `kinds`: newest capture first and, within a capture,
    /// `data_detection` after the other kinds (it reads their output). Changes nothing.
    public func claimNext(kinds: Set<FacetKind>, now: Date) throws -> EnrichmentTask? {
        guard !kinds.isEmpty else { return nil }
        let rows = try db.query("""
            SELECT t.* FROM enrichment_tasks t JOIN captures c ON c.capture_id = t.capture_id
            WHERE t.status = 'pending' AND (t.next_attempt_at_ms IS NULL OR t.next_attempt_at_ms <= ?)
              AND t.kind IN (\(Self.placeholders(kinds.count)))
            ORDER BY c.captured_at_ms DESC, c.capture_id DESC, (t.kind = ?) ASC, t.kind ASC LIMIT 1
            """, [.int(Self.ms(now))] + Self.kindArgs(kinds) + [.text(FacetKind.dataDetection.rawValue)])
        return rows.first.map(Self.decodeTask)
    }

    /// The capture's row for `kind`, whatever its status. Nil if there is none.
    public func task(captureID: String, kind: FacetKind) throws -> EnrichmentTask? {
        try db.query("SELECT * FROM enrichment_tasks WHERE capture_id = ? AND kind = ?",
                     [.text(captureID), .text(kind.rawValue)]).first.map(Self.decodeTask)
    }

    /// Records the outcome of an attempt. `incrementAttempts` is false for attempts that don't count
    /// (for example, ones cancelled before they ran).
    public func recordAttempt(captureID: String, kind: FacetKind, status: String, errorCode: String?,
                              nextAttemptAt: Date?, incrementAttempts: Bool, now: Date) throws {
        try db.execute("""
            UPDATE enrichment_tasks SET status = ?, last_error_code = ?, next_attempt_at_ms = ?,
              attempt_count = attempt_count + ?, updated_at_ms = ?
            WHERE capture_id = ? AND kind = ?
            """, [.text(status), errorCode.map { .text($0) } ?? .null, nextAttemptAt.map { .int(Self.ms($0)) } ?? .null,
                  .int(incrementAttempts ? 1 : 0), .int(Self.ms(now)), .text(captureID), .text(kind.rawValue)])
    }

    /// Makes an existing task `pending` again with fresh attempts. Does nothing if there is no row or
    /// the task is `not_applicable`.
    public func resetToPending(captureID: String, kind: FacetKind, now: Date) throws {
        try db.execute("""
            UPDATE enrichment_tasks SET status = 'pending', attempt_count = 0, next_attempt_at_ms = NULL,
              last_error_code = NULL, updated_at_ms = ?
            WHERE capture_id = ? AND kind = ? AND status <> 'not_applicable'
            """, [.int(Self.ms(now)), .text(captureID), .text(kind.rawValue)])
    }

    /// Row counts by kind, then status.
    public func counts() throws -> [String: [String: Int]] {
        var out: [String: [String: Int]] = [:]
        for row in try db.query("SELECT kind, status, count(*) AS n FROM enrichment_tasks GROUP BY kind, status") {
            guard let kind = row.string("kind"), let status = row.string("status") else { continue }
            out[kind, default: [:]][status] = Int(row.int("n") ?? 0)
        }
        return out
    }

    /// True if `claimNext(kinds:now:)` would return a task.
    public func hasDueWork(kinds: Set<FacetKind>, now: Date) throws -> Bool {
        guard !kinds.isEmpty else { return false }
        return try !db.query("""
            SELECT 1 FROM enrichment_tasks
            WHERE status = 'pending' AND (next_attempt_at_ms IS NULL OR next_attempt_at_ms <= ?)
              AND kind IN (\(Self.placeholders(kinds.count))) LIMIT 1
            """, [.int(Self.ms(now))] + Self.kindArgs(kinds)).isEmpty
    }

    /// True if enrichment has work for any kind in `versions` (kind → its enricher's version): a due
    /// `pending` task, or a capture with no row for the kind, or a row at another version, that still
    /// needs scheduling (a capture saved by the Share Extension has no rows yet).
    public func hasWork(versions: [FacetKind: Int], now: Date) throws -> Bool {
        if try hasDueWork(kinds: Set(versions.keys), now: now) { return true }
        for (kind, version) in versions.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where try !capturesNeeding(kind: kind, version: version, limit: 1).isEmpty {
            return true
        }
        return false
    }

    // MARK: Helpers

    private static func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    private static func kindArgs(_ kinds: Set<FacetKind>) -> [SQLValue] { kinds.map(\.rawValue).sorted().map { .text($0) } }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    private static func decodeTask(_ r: Row) -> EnrichmentTask {
        EnrichmentTask(captureID: r.string("capture_id") ?? "", kind: FacetKind(rawValue: r.string("kind") ?? ""),
                       version: Int(r.int("version") ?? 0), status: r.string("status") ?? "",
                       attemptCount: Int(r.int("attempt_count") ?? 0), nextAttemptAt: r.date("next_attempt_at_ms"),
                       lastErrorCode: r.string("last_error_code"))
    }
}
