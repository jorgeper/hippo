import Foundation
import CryptoKit
import CaptureCore

/// The phone's searchable index of committed captures (timeline, filters, full-text search).
public final class CaptureIndex: Sendable {
    private let db: Database

    public init(db: Database) { self.db = db }

    // MARK: Register / remove / count

    /// Returns true if inserted, false if the capture was already present.
    public func register(_ p: CommittedPackage, noteBody: String?) throws -> Bool {
        let m = p.metadata
        let digest = try Self.markerDigest(in: p.directoryURL)
        let title = DisplayTitle.make(m, noteBody: noteBody)
        let types = "," + m.contentTypes.map(\.rawValue).joined(separator: ",") + ","
        let hasLocation = m.captureLocation != nil || m.attachments.contains { $0.media?.embeddedLocation != nil }
        let note = m.userNote.flatMap { $0.isEmpty ? nil : $0 }
        let shared = [m.sharedText, noteBody].compactMap { $0 }.joined(separator: "\n")
        let now = Self.ms(Date())

        return try db.transaction { tx in
            guard try tx.query("SELECT 1 FROM captures WHERE capture_id = ?", [.text(m.captureID)]).isEmpty else {
                return false
            }
            try tx.execute("""
                INSERT INTO captures(capture_id, captured_at_ms, local_day, method, content_types, title, note_excerpt,
                  has_comment, has_location, attachment_count, primary_attachment_path, relative_directory,
                  package_digest, registered_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(m.captureID), .int(Self.ms(m.capturedAt)), .text(String(m.localDatetime.prefix(10))),
                      .text(m.captureMethod.rawValue), .text(types), .text(title),
                      note.map { .text(String($0.prefix(120))) } ?? .null,
                      .int(note == nil ? 0 : 1), .int(hasLocation ? 1 : 0), .int(Int64(m.attachments.count)),
                      Self.primaryPath(m).map { .text($0) } ?? .null, .text(p.relativeDirectory),
                      .text(digest), .int(now)])
            try tx.execute("""
                INSERT INTO captures_fts(capture_id, title, user_note, shared_text, urls, filenames) VALUES (?,?,?,?,?,?)
                """, [.text(m.captureID), .text(title), .text(m.userNote ?? ""), .text(shared),
                      .text(m.urls.map(\.url).joined(separator: " ")),
                      .text(m.attachments.compactMap(\.originalFilename).joined(separator: " "))])
            return true
        }
    }

    public func remove(captureID: String) throws {
        try db.transaction { tx in
            try tx.execute("DELETE FROM captures_fts WHERE capture_id = ?", [.text(captureID)])
            try tx.execute("DELETE FROM captures WHERE capture_id = ?", [.text(captureID)])
        }
    }

    /// Every indexed capture's ID and package directory (relative to the store root).
    public func indexedDirectories() throws -> [(captureID: String, relativeDirectory: String)] {
        try db.query("SELECT capture_id, relative_directory FROM captures").map {
            ($0.string("capture_id") ?? "", $0.string("relative_directory") ?? "")
        }
    }

    public func count() throws -> Int {
        Int(try db.query("SELECT count(*) AS n FROM captures")[0].int("n") ?? 0)
    }

    /// Loads `metadata.json` from the capture's package. Nil if the capture isn't indexed; throws if unreadable.
    public func metadata(captureID: String, layout: StoreLayout) throws -> CaptureMetadata? {
        let rows = try db.query("SELECT relative_directory FROM captures WHERE capture_id = ?", [.text(captureID)])
        guard let dir = rows.first?.string("relative_directory") else { return nil }
        let url = layout.packageURL(relativeDirectory: dir).appendingPathComponent("metadata.json")
        return try HippoJSON.decodeMetadata(Data(contentsOf: url))
    }

    // MARK: Paging

    private static let syncBucketSQL = """
        CASE
          WHEN NOT EXISTS (SELECT 1 FROM jobs j WHERE j.capture_id = c.capture_id) THEN 'notSynced'
          WHEN EXISTS (SELECT 1 FROM jobs j WHERE j.capture_id = c.capture_id
                       AND j.state IN ('needs_authentication','blocked','paused')) THEN 'needsAttention'
          WHEN NOT EXISTS (SELECT 1 FROM jobs j WHERE j.capture_id = c.capture_id AND j.state <> 'synced') THEN 'synced'
          ELSE 'notSynced' END
        """

    public func page(_ f: CaptureFilter, after: PageCursor?, limit: Int) throws -> [CaptureSummary] {
        var clauses: [String] = []
        var args: [SQLValue] = []

        if let range = f.dateRange {
            clauses.append("c.captured_at_ms >= ? AND c.captured_at_ms < ?")
            args += [.int(Self.ms(range.lowerBound)), .int(Self.ms(range.upperBound))]
        }
        if !f.contentTypes.isEmpty {
            let any = f.contentTypes.map { _ in "c.content_types LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            clauses.append("(\(any))")
            args += f.contentTypes.map { .text("%," + Self.likeEscaped($0.rawValue) + ",%") }
        }
        if !f.methods.isEmpty {
            clauses.append("c.method IN (\(f.methods.map { _ in "?" }.joined(separator: ",")))")
            args += f.methods.map { .text($0.rawValue) }
        }
        if let v = f.hasComment { clauses.append("c.has_comment = ?"); args.append(.int(v ? 1 : 0)) }
        if let v = f.hasLocation { clauses.append("c.has_location = ?"); args.append(.int(v ? 1 : 0)) }
        if !f.syncBuckets.isEmpty {
            clauses.append("(\(Self.syncBucketSQL)) IN (\(f.syncBuckets.map { _ in "?" }.joined(separator: ",")))")
            args += f.syncBuckets.map { .text($0.rawValue) }
        }
        if let match = f.searchText.flatMap(Self.ftsQuery) {
            clauses.append("c.capture_id IN (SELECT capture_id FROM captures_fts WHERE captures_fts MATCH ?)")
            args.append(.text(match))
        }
        let newest = f.sort == .newestFirst
        if let after {
            clauses.append("(c.captured_at_ms, c.capture_id) \(newest ? "<" : ">") (?, ?)")
            args += [.int(Self.ms(after.capturedAt)), .text(after.captureID)]
        }
        args.append(.int(Int64(min(max(limit, 1), 500))))

        let dir = newest ? "DESC" : "ASC"
        let sql = """
            SELECT c.*, (\(Self.syncBucketSQL)) AS sync_bucket FROM captures c
            \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "))
            ORDER BY c.captured_at_ms \(dir), c.capture_id \(dir) LIMIT ?
            """
        return try db.query(sql, args).map { r in
            CaptureSummary(
                id: r.string("capture_id") ?? "",
                capturedAt: r.date("captured_at_ms") ?? Date(timeIntervalSince1970: 0),
                localDay: r.string("local_day") ?? "",
                title: r.string("title") ?? "",
                noteExcerpt: r.string("note_excerpt"),
                contentTypes: (r.string("content_types") ?? "").split(separator: ",").map { ContentType(rawValue: String($0)) },
                method: CaptureMethod(rawValue: r.string("method") ?? ""),
                attachmentCount: Int(r.int("attachment_count") ?? 0),
                primaryAttachmentPath: r.string("primary_attachment_path"),
                relativeDirectory: r.string("relative_directory") ?? "",
                syncBucket: SyncBucket(rawValue: r.string("sync_bucket") ?? "") ?? .notSynced)
        }
    }

    // MARK: Helpers

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    private static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Each whitespace-separated token becomes a quoted prefix phrase; the phrases are ANDed. Nil if empty.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map { token in
            "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }

    private static func markerDigest(in directory: URL) throws -> String {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("complete.json"))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func primaryPath(_ m: CaptureMetadata) -> String? {
        func visual(_ a: Attachment) -> Bool {
            if let mime = a.mimeType, mime.hasPrefix("image/") || mime.hasPrefix("video/") { return true }
            let uti = a.uti.lowercased()
            return ["image", "jpeg", "png", "heic", "movie", "video", "mpeg-4", "quicktime"].contains { uti.contains($0) }
        }
        return (m.attachments.first(where: visual) ?? m.attachments.first)?.relativePath
    }
}
