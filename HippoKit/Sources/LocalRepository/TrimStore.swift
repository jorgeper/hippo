import Foundation

public enum TrimState: String, Sendable {
    /// The local original was removed after the destination's copy was verified.
    case trimmed
    /// The destination's copy no longer matches the recorded hash.
    case mismatch
}

public struct TrimmedAttachment: Sendable, Equatable {
    public let captureID: String
    public let attachmentID: String
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
    public let destinationID: String
    public let state: TrimState
    public let trimmedAt: Date

    public init(captureID: String, attachmentID: String, relativePath: String, byteCount: Int64, sha256: String,
                destinationID: String, state: TrimState, trimmedAt: Date) {
        self.captureID = captureID; self.attachmentID = attachmentID; self.relativePath = relativePath
        self.byteCount = byteCount; self.sha256 = sha256; self.destinationID = destinationID
        self.state = state; self.trimmedAt = trimmedAt
    }
}

/// Attachments whose local files were removed because the destination holds a verified copy.
public final class TrimStore: Sendable {
    private let db: Database

    public init(db: Database) { self.db = db }

    public func record(_ t: TrimmedAttachment) throws {
        try db.execute("""
            INSERT INTO trimmed_attachments(capture_id, attachment_id, relative_path, byte_count, sha256,
              destination_id, state, trimmed_at_ms) VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(capture_id, attachment_id) DO UPDATE SET relative_path = excluded.relative_path,
              byte_count = excluded.byte_count, sha256 = excluded.sha256, destination_id = excluded.destination_id,
              state = excluded.state, trimmed_at_ms = excluded.trimmed_at_ms
            """, [.text(t.captureID), .text(t.attachmentID), .text(t.relativePath), .int(t.byteCount),
                  .text(t.sha256), .text(t.destinationID), .text(t.state.rawValue), .int(JobStore.ms(t.trimmedAt))])
    }

    /// The capture's trimmed attachments, ordered by relative path.
    public func trimmed(captureID: String) throws -> [TrimmedAttachment] {
        try db.query("SELECT * FROM trimmed_attachments WHERE capture_id = ? ORDER BY relative_path, attachment_id",
                     [.text(captureID)]).map { r in
            TrimmedAttachment(captureID: r.string("capture_id") ?? "", attachmentID: r.string("attachment_id") ?? "",
                              relativePath: r.string("relative_path") ?? "", byteCount: r.int("byte_count") ?? 0,
                              sha256: r.string("sha256") ?? "", destinationID: r.string("destination_id") ?? "",
                              state: TrimState(rawValue: r.string("state") ?? "") ?? .mismatch,
                              trimmedAt: r.date("trimmed_at_ms") ?? .distantPast)
        }
    }

    public func trimmedPaths(captureID: String) throws -> Set<String> {
        Set(try db.query("SELECT relative_path FROM trimmed_attachments WHERE capture_id = ?", [.text(captureID)])
            .compactMap { $0.string("relative_path") })
    }

    public func remove(captureID: String, attachmentID: String) throws {
        try db.execute("DELETE FROM trimmed_attachments WHERE capture_id = ? AND attachment_id = ?",
                       [.text(captureID), .text(attachmentID)])
    }

    public func setState(captureID: String, attachmentID: String, state: TrimState) throws {
        try db.execute("UPDATE trimmed_attachments SET state = ? WHERE capture_id = ? AND attachment_id = ?",
                       [.text(state.rawValue), .text(captureID), .text(attachmentID)])
    }

    /// Which of `ids` have at least one trimmed attachment.
    public func captureIDsWithTrimmed(in ids: [String]) throws -> Set<String> {
        var found = Set<String>()
        // Stay well under SQLite's bound-variable limit.
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            found.formUnion(try db.query("SELECT DISTINCT capture_id FROM trimmed_attachments WHERE capture_id IN (\(marks))",
                                         chunk.map { .text($0) }).compactMap { $0.string("capture_id") })
        }
        return found
    }

    public func totals(destinationID: String) throws -> (captures: Int, bytes: Int64) {
        let r = try db.query("""
            SELECT count(DISTINCT capture_id) AS n, COALESCE(SUM(byte_count), 0) AS b
            FROM trimmed_attachments WHERE destination_id = ?
            """, [.text(destinationID)]).first
        return (Int(r?.int("n") ?? 0), r?.int("b") ?? 0)
    }

    public func allTrimmedAttachmentIDs() throws -> [String] {
        try db.query("SELECT attachment_id FROM trimmed_attachments ORDER BY attachment_id")
            .compactMap { $0.string("attachment_id") }
    }
}
