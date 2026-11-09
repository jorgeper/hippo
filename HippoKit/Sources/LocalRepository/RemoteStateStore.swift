import Foundation

public struct RemoteTombstone: Sendable, Equatable {
    public let captureID: String
    public let relativeDirectory: String
    public let destinationID: String
    public let accountIdentifier: String
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let lastErrorCode: String?
}

public struct ReviewItem: Sendable, Equatable {
    public let captureID: String
    public let destinationID: String
    public let reason: String
    public let createdAt: Date

    public init(captureID: String, destinationID: String, reason: String, createdAt: Date) {
        self.captureID = captureID; self.destinationID = destinationID
        self.reason = reason; self.createdAt = createdAt
    }
}

public struct RemoteChangedRecord: Sendable, Equatable {
    public let captureID: String
    public let destinationID: String
    public let paths: [String]
    public let detectedAt: Date
}

/// Durable remote state: delete tombstones, local-delete records, the per-destination change cursor,
/// review items and "changed in the destination" records. Nothing here is deleted by a sign-out.
public final class RemoteStateStore: Sendable {
    private let db: Database

    public init(db: Database) { self.db = db }

    // MARK: Tombstones

    /// Records that the capture must be deleted remotely. Re-adding resets the retry state.
    public func addTombstone(captureID: String, relativeDirectory: String, destinationID: String,
                             accountIdentifier: String, now: Date) throws {
        let ms = JobStore.ms(now)
        try db.execute("""
            INSERT INTO remote_tombstones(capture_id, relative_directory, destination_id, account_identifier,
              created_at_ms, updated_at_ms) VALUES (?,?,?,?,?,?)
            ON CONFLICT(capture_id) DO UPDATE SET relative_directory = excluded.relative_directory,
              destination_id = excluded.destination_id, account_identifier = excluded.account_identifier,
              attempt_count = 0, next_attempt_at_ms = NULL, last_error_code = NULL, updated_at_ms = excluded.updated_at_ms
            """, [.text(captureID), .text(relativeDirectory), .text(destinationID), .text(accountIdentifier),
                  .int(ms), .int(ms)])
    }

    /// Tombstones for the destination and account that are due at `now`, oldest first.
    public func dueTombstones(destinationID: String, accountIdentifier: String, now: Date,
                              limit: Int) throws -> [RemoteTombstone] {
        try db.query("""
            SELECT * FROM remote_tombstones WHERE destination_id = ? AND account_identifier = ?
              AND (next_attempt_at_ms IS NULL OR next_attempt_at_ms <= ?)
            ORDER BY created_at_ms, capture_id LIMIT ?
            """, [.text(destinationID), .text(accountIdentifier), .int(JobStore.ms(now)), .int(Int64(limit))])
            .map { r in
                RemoteTombstone(captureID: r.string("capture_id") ?? "",
                                relativeDirectory: r.string("relative_directory") ?? "",
                                destinationID: r.string("destination_id") ?? "",
                                accountIdentifier: r.string("account_identifier") ?? "",
                                attemptCount: Int(r.int("attempt_count") ?? 0),
                                nextAttemptAt: r.date("next_attempt_at_ms"), lastErrorCode: r.string("last_error_code"))
            }
    }

    public func pendingTombstoneCount(destinationID: String) throws -> Int {
        Int(try db.query("SELECT count(*) AS n FROM remote_tombstones WHERE destination_id = ?",
                         [.text(destinationID)]).first?.int("n") ?? 0)
    }

    public func hasTombstone(captureID: String) throws -> Bool {
        try !db.query("SELECT 1 FROM remote_tombstones WHERE capture_id = ?", [.text(captureID)]).isEmpty
    }

    public func removeTombstone(captureID: String) throws {
        try db.execute("DELETE FROM remote_tombstones WHERE capture_id = ?", [.text(captureID)])
    }

    public func markTombstoneFailed(captureID: String, code: String, nextAttemptAt: Date?, now: Date) throws {
        try db.execute("""
            UPDATE remote_tombstones SET attempt_count = attempt_count + 1, last_error_code = ?,
              next_attempt_at_ms = ?, updated_at_ms = ? WHERE capture_id = ?
            """, [.text(code), nextAttemptAt.map { .int(JobStore.ms($0)) } ?? .null, .int(JobStore.ms(now)),
                  .text(captureID)])
    }

    // MARK: Local deletes

    public func recordLocalDelete(captureID: String, relativeDirectory: String, accountIdentifier: String?,
                                  now: Date) throws {
        try db.execute("""
            INSERT INTO local_deletes(capture_id, relative_directory, account_identifier, deleted_at_ms)
            VALUES (?,?,?,?)
            ON CONFLICT(capture_id) DO UPDATE SET relative_directory = excluded.relative_directory,
              account_identifier = excluded.account_identifier, deleted_at_ms = excluded.deleted_at_ms
            """, [.text(captureID), .text(relativeDirectory), accountIdentifier.map { .text($0) } ?? .null,
                  .int(JobStore.ms(now))])
    }

    public func localDeletedCaptureIDs() throws -> Set<String> {
        Set(try db.query("SELECT capture_id FROM local_deletes").compactMap { $0.string("capture_id") })
    }

    public func removeLocalDelete(captureID: String) throws {
        try db.execute("DELETE FROM local_deletes WHERE capture_id = ?", [.text(captureID)])
    }

    // MARK: Change cursor

    public func changeCursor(destinationID: String) throws -> String? {
        try db.query("SELECT cursor FROM remote_cursors WHERE destination_id = ?", [.text(destinationID)])
            .first?.string("cursor")
    }

    /// Saves the cursor; nil clears it.
    public func saveChangeCursor(destinationID: String, cursor: String?, now: Date) throws {
        try db.execute("""
            INSERT INTO remote_cursors(destination_id, cursor, updated_at_ms) VALUES (?,?,?)
            ON CONFLICT(destination_id) DO UPDATE SET cursor = excluded.cursor, updated_at_ms = excluded.updated_at_ms
            """, [.text(destinationID), cursor.map { .text($0) } ?? .null, .int(JobStore.ms(now))])
    }

    // MARK: Review

    /// Adds the items; a (capture, destination) pair that already has one keeps the existing item.
    public func addReviewItems(_ items: [ReviewItem]) throws {
        try db.transaction { tx in
            for item in items {
                try tx.execute("""
                    INSERT OR IGNORE INTO remote_review_items(capture_id, destination_id, reason, created_at_ms)
                    VALUES (?,?,?,?)
                    """, [.text(item.captureID), .text(item.destinationID), .text(item.reason),
                          .int(JobStore.ms(item.createdAt))])
            }
        }
    }

    public func reviewItems(destinationID: String) throws -> [ReviewItem] {
        try db.query("""
            SELECT * FROM remote_review_items WHERE destination_id = ? ORDER BY created_at_ms, capture_id
            """, [.text(destinationID)]).map { r in
            ReviewItem(captureID: r.string("capture_id") ?? "", destinationID: r.string("destination_id") ?? "",
                       reason: r.string("reason") ?? "", createdAt: r.date("created_at_ms") ?? .distantPast)
        }
    }

    public func clearReview(destinationID: String) throws {
        try db.execute("DELETE FROM remote_review_items WHERE destination_id = ?", [.text(destinationID)])
    }

    // MARK: Changed in the destination

    /// Unions `paths` into the capture's record (sorted, de-duplicated). The first detection time is kept.
    public func markChanged(captureID: String, destinationID: String, paths: [String], now: Date) throws {
        try db.transaction { tx in
            let existing = try tx.query("SELECT paths FROM remote_changed WHERE capture_id = ?", [.text(captureID)])
                .first?.string("paths").map(Self.decodePaths) ?? []
            let merged = Array(Set(existing).union(paths)).sorted()
            let json = String(decoding: try JSONEncoder().encode(merged), as: UTF8.self)
            try tx.execute("""
                INSERT INTO remote_changed(capture_id, destination_id, paths, detected_at_ms) VALUES (?,?,?,?)
                ON CONFLICT(capture_id) DO UPDATE SET destination_id = excluded.destination_id, paths = excluded.paths
                """, [.text(captureID), .text(destinationID), .text(json), .int(JobStore.ms(now))])
        }
    }

    public func changed(captureID: String) throws -> RemoteChangedRecord? {
        try db.query("SELECT * FROM remote_changed WHERE capture_id = ?", [.text(captureID)]).first.map { r in
            RemoteChangedRecord(captureID: r.string("capture_id") ?? "", destinationID: r.string("destination_id") ?? "",
                                paths: Self.decodePaths(r.string("paths") ?? "[]"),
                                detectedAt: r.date("detected_at_ms") ?? .distantPast)
        }
    }

    public func clearChanged(captureID: String) throws {
        try db.execute("DELETE FROM remote_changed WHERE capture_id = ?", [.text(captureID)])
    }

    public func changedCount(destinationID: String) throws -> Int {
        Int(try db.query("SELECT count(*) AS n FROM remote_changed WHERE destination_id = ?",
                         [.text(destinationID)]).first?.int("n") ?? 0)
    }

    private static func decodePaths(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}
