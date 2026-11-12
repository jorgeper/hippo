// The local failures table, in the index database file under the app-data directory (never in the folder).
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { indexPath } from '../core/paths.ts';

export interface FailureRow { capture_id: string; input_digest: string; attempts: number; last_error: string; last_at: string }

export interface FailureStore {
  get(id: string): FailureRow | undefined;
  /** Adds one attempt for this digest (a different digest starts again at 1) and returns the new count. */
  record(id: string, digest: string, error: string, at: Date): number;
  clear(id: string): void;
  all(): FailureRow[];
  close(): void;
}

export const MAX_ATTEMPTS = 3;

const SCHEMA = `CREATE TABLE IF NOT EXISTS enrich_failures (
  capture_id TEXT PRIMARY KEY, input_digest TEXT NOT NULL, attempts INTEGER NOT NULL, last_error TEXT NOT NULL, last_at TEXT NOT NULL)`;

/** A store that reads nothing and keeps nothing: used by a dry run when no database exists yet. */
function emptyStore(): FailureStore {
  return { get: () => undefined, record: () => 1, clear: () => {}, all: () => [], close: () => {} };
}

/** `readOnly` (dry run) never creates the database file and never writes to it. */
export function openFailureStore(folder: string, opts: { readOnly?: boolean } = {}): FailureStore {
  const file = indexPath(folder);
  let db: DatabaseSync;
  if (opts.readOnly) {
    if (!fs.existsSync(file)) return emptyStore();
    db = new DatabaseSync(file, { readOnly: true });
    const has = db.prepare(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'enrich_failures'`).get();
    if (!has) { db.close(); return emptyStore(); }
  } else {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    db = new DatabaseSync(file);
    db.exec(SCHEMA);
  }
  const row = (r: unknown): FailureRow | undefined => (r ? { ...(r as FailureRow) } : undefined);
  return {
    get: id => row(db.prepare('SELECT * FROM enrich_failures WHERE capture_id = ?').get(id)),
    record(id, digest, error, at) {
      if (opts.readOnly) return 1;
      const prev = row(db.prepare('SELECT * FROM enrich_failures WHERE capture_id = ?').get(id));
      const attempts = prev && prev.input_digest === digest ? prev.attempts + 1 : 1;
      db.prepare(`INSERT INTO enrich_failures (capture_id, input_digest, attempts, last_error, last_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(capture_id) DO UPDATE SET input_digest = excluded.input_digest, attempts = excluded.attempts,
        last_error = excluded.last_error, last_at = excluded.last_at`).run(id, digest, attempts, error, at.toISOString());
      return attempts;
    },
    clear(id) { if (!opts.readOnly) db.prepare('DELETE FROM enrich_failures WHERE capture_id = ?').run(id); },
    all: () => db.prepare('SELECT * FROM enrich_failures ORDER BY capture_id').all().map(r => row(r)!),
    close: () => db.close(),
  };
}
