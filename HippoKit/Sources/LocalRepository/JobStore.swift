import Foundation

/// Upload state of one capture-destination pair (spec §10).
public enum JobState: String, Sendable, CaseIterable {
    case pending, uploading, synced
    case retryableFailure = "retryable_failure"
    case needsAuthentication = "needs_authentication"
    case blocked, paused
}

public struct UploadJob: Sendable, Equatable {
    public let jobID: String
    public let captureID: String
    public let destinationID: String
    public let state: JobState
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let lastErrorCode: String?
    public let cancelRequested: Bool
}

/// Proof that one package file reached the destination.
public struct StoredReceipt: Sendable, Equatable {
    public let relativePath: String
    public let byteCount: Int64
    public let evidenceKind: String
    public let evidenceValue: String

    public init(relativePath: String, byteCount: Int64, evidenceKind: String, evidenceValue: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.evidenceKind = evidenceKind
        self.evidenceValue = evidenceValue
    }
}

public enum JobError: Error, Equatable {
    /// The caller no longer owns the job's lease (it expired and was reclaimed, or was revoked).
    case leaseLost
    case notFound
    /// `markFailed` was given a state that is not a failure state.
    case invalidState
}

/// Upload jobs with leases, so only one worker (app or Share Extension) owns a job at a time.
public final class JobStore: Sendable {
    private let db: Database

    public init(db: Database) { self.db = db }

    /// Creates a pending job for the active destination, if there is one and the pair has no job yet.
    public func enqueueIfActive(captureID: String) throws {
        try db.execute("""
            INSERT OR IGNORE INTO jobs(job_id, capture_id, destination_id, state, updated_at_ms)
            SELECT ?, ?, destination_id, 'pending', ? FROM destinations WHERE status = 'active'
            ORDER BY destination_id LIMIT 1
            """, [.text(Self.newJobID()), .text(captureID), .int(Self.ms(Date()))])
    }

    /// Atomically takes the next eligible job: a due `pending`/`retryable_failure` job, or an
    /// `uploading` job whose lease expired; in both cases the destination must be active and no
    /// cancel requested. Does not change `attempt_count`.
    public func claimNext(owner: String, now: Date, lease: TimeInterval) throws -> UploadJob? {
        let nowMS = Self.ms(now)
        return try db.transaction { tx in
            let candidates = try tx.query("""
                SELECT j.job_id FROM jobs j JOIN destinations d ON d.destination_id = j.destination_id
                WHERE d.status = 'active' AND j.cancel_requested = 0 AND (
                  (j.state IN ('pending', 'retryable_failure')
                     AND (j.next_attempt_at_ms IS NULL OR j.next_attempt_at_ms <= ?))
                  OR (j.state = 'uploading' AND (j.lease_expires_at_ms IS NULL OR j.lease_expires_at_ms <= ?)))
                ORDER BY (j.next_attempt_at_ms IS NULL) DESC, j.next_attempt_at_ms ASC, j.updated_at_ms ASC, j.job_id ASC
                LIMIT 1
                """, [.int(nowMS), .int(nowMS)])
            guard let jobID = candidates.first?.string("job_id") else { return nil }
            let rows = try tx.query("""
                UPDATE jobs SET state = 'uploading', lease_owner = ?, lease_expires_at_ms = ?, updated_at_ms = ?
                WHERE job_id = ? RETURNING *
                """, [.text(owner), .int(nowMS + Self.ms(lease)), .int(nowMS), .text(jobID)])
            return rows.first.map(Self.job)
        }
    }

    /// Extends the lease. False if `owner` no longer holds it.
    public func renewLease(jobID: String, owner: String, now: Date, lease: TimeInterval) throws -> Bool {
        let nowMS = Self.ms(now)
        return try !db.query("""
            UPDATE jobs SET lease_expires_at_ms = ?, updated_at_ms = ? WHERE job_id = ? AND lease_owner = ?
            RETURNING job_id
            """, [.int(nowMS + Self.ms(lease)), .int(nowMS), .text(jobID), .text(owner)]).isEmpty
    }

    public func markSynced(jobID: String, owner: String) throws {
        try ownerWrite(jobID: jobID, owner: owner, set: """
            state = 'synced', last_error_code = NULL, next_attempt_at_ms = NULL
            """, [])
    }

    /// Records a failed attempt: increments `attempt_count` and releases the lease. `state` must be a
    /// failure state (`retryableFailure`, `needsAuthentication`, `blocked` or `paused`), otherwise
    /// it throws `JobError.invalidState` and changes nothing.
    public func markFailed(jobID: String, owner: String, state: JobState, errorCode: String,
                           nextAttemptAt: Date?) throws {
        guard Self.failureStates.contains(state) else { throw JobError.invalidState }
        try ownerWrite(jobID: jobID, owner: owner, set: """
            state = ?, attempt_count = attempt_count + 1, last_error_code = ?, next_attempt_at_ms = ?
            """, [.text(state.rawValue), .text(errorCode), nextAttemptAt.map { .int(Self.ms($0)) } ?? .null])
    }

    public func requestCancel(captureID: String) throws {
        try db.execute("UPDATE jobs SET cancel_requested = 1, updated_at_ms = ? WHERE capture_id = ?",
                       [.int(Self.ms(Date())), .text(captureID)])
    }

    /// Undoes `requestCancel` for a capture whose deletion did not complete.
    public func clearCancel(captureID: String) throws {
        try db.execute("UPDATE jobs SET cancel_requested = 0, updated_at_ms = ? WHERE capture_id = ?",
                       [.int(Self.ms(Date())), .text(captureID)])
    }

    /// Manual "retry now": makes the capture's `blocked` and `retryable_failure` jobs claimable
    /// immediately. Jobs with a cancel requested are left alone; `attempt_count` and `last_error_code`
    /// are kept for display. Returns how many jobs were reset.
    @discardableResult
    public func retryNow(captureID: String) throws -> Int {
        try retry(where: "capture_id = ?", [.text(captureID)])
    }

    /// Like `retryNow` for every capture bound to the destination.
    @discardableResult
    public func retryAll(destinationID: String) throws -> Int {
        try retry(where: "destination_id = ?", [.text(destinationID)])
    }

    private func retry(where clause: String, _ args: [SQLValue]) throws -> Int {
        try db.query("""
            UPDATE jobs SET state = 'pending', next_attempt_at_ms = NULL, updated_at_ms = ?
            WHERE \(clause) AND state IN ('blocked', 'retryable_failure') AND cancel_requested = 0
            RETURNING job_id
            """, [.int(Self.ms(Date()))] + args).count
    }

    /// True if some job for the capture is `uploading` under a lease that has not expired at `now`.
    public func activeLeaseExists(captureID: String, now: Date) throws -> Bool {
        try !db.query("""
            SELECT 1 FROM jobs WHERE capture_id = ? AND state = 'uploading' AND lease_owner IS NOT NULL
              AND lease_expires_at_ms > ? LIMIT 1
            """, [.text(captureID), .int(Self.ms(now))]).isEmpty
    }

    /// Every job for the capture, ordered by destination ID.
    public func jobs(captureID: String) throws -> [UploadJob] {
        try db.query("SELECT * FROM jobs WHERE capture_id = ? ORDER BY destination_id", [.text(captureID)])
            .map(Self.job)
    }

    /// The job's current row, or nil if it no longer exists.
    public func job(jobID: String) throws -> UploadJob? {
        try db.query("SELECT * FROM jobs WHERE job_id = ?", [.text(jobID)]).first.map(Self.job)
    }

    // MARK: Receipts and checkpoints

    public func saveReceipt(jobID: String, _ r: StoredReceipt) throws {
        try db.execute("""
            INSERT INTO receipts(job_id, relative_path, byte_count, evidence_kind, evidence_value) VALUES (?,?,?,?,?)
            ON CONFLICT(job_id, relative_path) DO UPDATE SET byte_count = excluded.byte_count,
              evidence_kind = excluded.evidence_kind, evidence_value = excluded.evidence_value
            """, [.text(jobID), .text(r.relativePath), .int(r.byteCount), .text(r.evidenceKind), .text(r.evidenceValue)])
    }

    /// The job's receipts, ordered by relative path.
    public func receipts(jobID: String) throws -> [StoredReceipt] {
        try db.query("SELECT * FROM receipts WHERE job_id = ? ORDER BY relative_path", [.text(jobID)]).map { r in
            StoredReceipt(relativePath: r.string("relative_path") ?? "", byteCount: r.int("byte_count") ?? 0,
                          evidenceKind: r.string("evidence_kind") ?? "", evidenceValue: r.string("evidence_value") ?? "")
        }
    }

    public func saveCheckpoint(jobID: String, relativePath: String, data: Data) throws {
        try db.execute("""
            INSERT INTO checkpoints(job_id, relative_path, data) VALUES (?,?,?)
            ON CONFLICT(job_id, relative_path) DO UPDATE SET data = excluded.data
            """, [.text(jobID), .text(relativePath), .blob(data)])
    }

    public func checkpoint(jobID: String, relativePath: String) throws -> Data? {
        let rows = try db.query("SELECT data FROM checkpoints WHERE job_id = ? AND relative_path = ?",
                                [.text(jobID), .text(relativePath)])
        guard case .blob(let data) = rows.first?["data"] else { return nil }
        return data
    }

    public func clearCheckpoint(jobID: String, relativePath: String) throws {
        try db.execute("DELETE FROM checkpoints WHERE job_id = ? AND relative_path = ?",
                       [.text(jobID), .text(relativePath)])
    }

    // MARK: Internals shared with DestinationStore

    /// Inserts `pending` jobs binding each capture to the destination. Returns how many were created.
    static func insertPending(captureIDs: [String], destinationID: String, in tx: Database) throws -> Int {
        let now = ms(Date())
        var created = 0
        for captureID in captureIDs {
            created += try tx.query("""
                INSERT OR IGNORE INTO jobs(job_id, capture_id, destination_id, state, updated_at_ms)
                VALUES (?, ?, ?, 'pending', ?) RETURNING job_id
                """, [.text(newJobID()), .text(captureID), .text(destinationID), .int(now)]).count
        }
        return created
    }

    static func ms(_ d: Date) -> Int64 { ms(d.timeIntervalSince1970) }
    private static func ms(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1000).rounded()) }

    // MARK: Helpers

    private static let failureStates: Set<JobState> = [.retryableFailure, .needsAuthentication, .blocked, .paused]

    private static func newJobID() -> String { UUID().uuidString.lowercased() }

    /// Applies `set` and releases the lease, only if `owner` holds it.
    private func ownerWrite(jobID: String, owner: String, set: String, _ args: [SQLValue]) throws {
        try db.transaction { tx in
            let updated = try tx.query("""
                UPDATE jobs SET \(set), lease_owner = NULL, lease_expires_at_ms = NULL, updated_at_ms = ?
                WHERE job_id = ? AND lease_owner = ? RETURNING job_id
                """, args + [.int(Self.ms(Date())), .text(jobID), .text(owner)])
            guard updated.isEmpty else { return }
            if try tx.query("SELECT 1 FROM jobs WHERE job_id = ?", [.text(jobID)]).isEmpty { throw JobError.notFound }
            throw JobError.leaseLost
        }
    }

    private static func job(_ r: Row) -> UploadJob {
        UploadJob(
            jobID: r.string("job_id") ?? "",
            captureID: r.string("capture_id") ?? "",
            destinationID: r.string("destination_id") ?? "",
            // A state this build doesn't know is surfaced as needing attention; it is never claimable.
            state: JobState(rawValue: r.string("state") ?? "") ?? .blocked,
            attemptCount: Int(r.int("attempt_count") ?? 0),
            nextAttemptAt: r.date("next_attempt_at_ms"),
            lastErrorCode: r.string("last_error_code"),
            cancelRequested: (r.int("cancel_requested") ?? 0) != 0)
    }
}
