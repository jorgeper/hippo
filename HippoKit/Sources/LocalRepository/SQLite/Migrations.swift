import SQLite3

enum Migrations {
    static let currentVersion: Int64 = 1

    /// Applies pending migrations inside `BEGIN IMMEDIATE`. `user_version` is re-read
    /// after the write lock is held, so two connections opening a fresh file cannot
    /// both apply v1.
    static func run(on db: Database) throws {
        try db.transaction { tx in
            let version = try tx.query("PRAGMA user_version")[0].int("user_version") ?? 0
            if version < 1 {
                try tx.executeScript(v1)
                try tx.executeScript("PRAGMA user_version = 1")
            }
        }
    }

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
