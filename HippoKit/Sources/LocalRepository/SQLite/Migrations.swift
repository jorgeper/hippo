import SQLite3

enum Migrations {
    static let currentVersion: Int64 = 5

    /// Applies pending migrations up to `target` inside `BEGIN IMMEDIATE`. `user_version` is re-read
    /// after the write lock is held, so two connections opening a fresh file cannot
    /// both apply the same migration.
    static func apply(on db: Database, upTo target: Int64) throws {
        try db.transaction { tx in
            let version = try tx.query("PRAGMA user_version")[0].int("user_version") ?? 0
            if version < 1, target >= 1 {
                try tx.executeScript(v1)
                try tx.executeScript("PRAGMA user_version = 1")
            }
            if version < 2, target >= 2 {
                try tx.executeScript(v2)
                try tx.executeScript("PRAGMA user_version = 2")
            }
            if version < 3, target >= 3 {
                try tx.executeScript(v3)
                try tx.executeScript("PRAGMA user_version = 3")
            }
            if version < 4, target >= 4 {
                try tx.executeScript(v4)
                try tx.executeScript("PRAGMA user_version = 4")
            }
            if version < 5, target >= 5 {
                try tx.executeScript(v5)
                try tx.executeScript("PRAGMA user_version = 5")
            }
        }
    }

    /// Number of comments added to a capture (`has_comment` stays the filter flag).
    static let v5 = "ALTER TABLE captures ADD COLUMN comment_count INTEGER NOT NULL DEFAULT 0;"

    /// Remote-delete tombstones, local-delete records, per-destination change cursors, review items,
    /// "changed in the destination" records and trimmed attachments.
    static let v4 = """
    CREATE TABLE remote_tombstones(capture_id TEXT PRIMARY KEY, relative_directory TEXT NOT NULL,
      destination_id TEXT NOT NULL REFERENCES destinations, account_identifier TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at_ms INTEGER, last_error_code TEXT,
      created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
    CREATE TABLE local_deletes(capture_id TEXT PRIMARY KEY, relative_directory TEXT NOT NULL,
      account_identifier TEXT, deleted_at_ms INTEGER NOT NULL);
    CREATE TABLE remote_cursors(destination_id TEXT PRIMARY KEY REFERENCES destinations, cursor TEXT,
      updated_at_ms INTEGER NOT NULL);
    CREATE TABLE remote_review_items(capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE,
      destination_id TEXT NOT NULL REFERENCES destinations, reason TEXT NOT NULL, created_at_ms INTEGER NOT NULL,
      PRIMARY KEY(capture_id, destination_id));
    CREATE TABLE remote_changed(capture_id TEXT PRIMARY KEY REFERENCES captures ON DELETE CASCADE,
      destination_id TEXT NOT NULL REFERENCES destinations, paths TEXT NOT NULL /* JSON array */,
      detected_at_ms INTEGER NOT NULL);
    CREATE TABLE trimmed_attachments(capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE,
      attachment_id TEXT NOT NULL, relative_path TEXT NOT NULL, byte_count INTEGER NOT NULL, sha256 TEXT NOT NULL,
      destination_id TEXT NOT NULL REFERENCES destinations, state TEXT NOT NULL /* trimmed|mismatch */,
      trimmed_at_ms INTEGER NOT NULL, PRIMARY KEY(capture_id, attachment_id));
    """

    /// Enrichment work, silver uploads and gold cursors. FTS5 tables can't gain columns, so `captures_fts`
    /// is rebuilt with an `enrichment` column and its rows copied over.
    static let v3 = """
    ALTER TABLE captures ADD COLUMN device_revision TEXT;
    CREATE TABLE enrichment_tasks(capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE, kind TEXT NOT NULL,
      version INTEGER NOT NULL, status TEXT NOT NULL /* pending|ok|empty|failed|not_applicable */,
      attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at_ms INTEGER, last_error_code TEXT,
      updated_at_ms INTEGER NOT NULL, PRIMARY KEY(capture_id, kind));
    CREATE TABLE enrichment_uploads(capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE,
      destination_id TEXT NOT NULL REFERENCES destinations, uploaded_revision TEXT, attempted_revision TEXT,
      blocked INTEGER NOT NULL DEFAULT 0, attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at_ms INTEGER,
      last_error_code TEXT, updated_at_ms INTEGER NOT NULL, PRIMARY KEY(capture_id, destination_id));
    CREATE TABLE gold_cursors(destination_id TEXT PRIMARY KEY REFERENCES destinations, cursor TEXT,
      last_result_code TEXT, last_pull_at_ms INTEGER);
    CREATE VIRTUAL TABLE captures_fts_v3 USING fts5(capture_id UNINDEXED, title, user_note, shared_text, urls, filenames,
      enrichment, tokenize='unicode61 remove_diacritics 2');
    INSERT INTO captures_fts_v3(capture_id, title, user_note, shared_text, urls, filenames, enrichment)
      SELECT capture_id, title, user_note, shared_text, urls, filenames, '' FROM captures_fts;
    DROP TABLE captures_fts;
    ALTER TABLE captures_fts_v3 RENAME TO captures_fts;
    """

    static let v2 = "ALTER TABLE captures ADD COLUMN utc_offset_seconds INTEGER;"

    static let v1 = """
    CREATE TABLE captures(capture_id TEXT PRIMARY KEY, captured_at_ms INTEGER NOT NULL, local_day TEXT NOT NULL,
      method TEXT NOT NULL, content_types TEXT NOT NULL /* ",image,url," */, title TEXT NOT NULL,
      note_excerpt TEXT, has_comment INTEGER NOT NULL, has_location INTEGER NOT NULL,
      attachment_count INTEGER NOT NULL, primary_attachment_path TEXT, relative_directory TEXT NOT NULL,
      package_digest TEXT NOT NULL, registered_at_ms INTEGER NOT NULL);
    CREATE INDEX captures_order ON captures(captured_at_ms DESC, capture_id DESC);
    CREATE VIRTUAL TABLE captures_fts USING fts5(capture_id UNINDEXED, title, user_note, shared_text, urls, filenames,
      tokenize='unicode61 remove_diacritics 2');
    CREATE TABLE destinations(destination_id TEXT PRIMARY KEY, provider_kind TEXT NOT NULL, account_identifier TEXT NOT NULL,
      remote_root TEXT NOT NULL, display_name TEXT NOT NULL, status TEXT NOT NULL /* active|signed_out|disabled */,
      created_at_ms INTEGER NOT NULL);
    CREATE TABLE jobs(job_id TEXT PRIMARY KEY, capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE,
      destination_id TEXT NOT NULL REFERENCES destinations, state TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
      next_attempt_at_ms INTEGER, last_error_code TEXT, lease_owner TEXT, lease_expires_at_ms INTEGER,
      cancel_requested INTEGER NOT NULL DEFAULT 0, updated_at_ms INTEGER NOT NULL, UNIQUE(capture_id, destination_id));
    CREATE TABLE receipts(job_id TEXT NOT NULL REFERENCES jobs ON DELETE CASCADE, relative_path TEXT NOT NULL,
      byte_count INTEGER NOT NULL, evidence_kind TEXT NOT NULL, evidence_value TEXT NOT NULL, PRIMARY KEY(job_id, relative_path));
    CREATE TABLE checkpoints(job_id TEXT NOT NULL REFERENCES jobs ON DELETE CASCADE, relative_path TEXT NOT NULL,
      data BLOB NOT NULL, PRIMARY KEY(job_id, relative_path));
    """
}
