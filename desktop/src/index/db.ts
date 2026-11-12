// The local index: one SQLite file per folder under the app-data directory, never in the synced folder.
// It is rebuildable from the folder at any time. The same file holds the enricher's `enrich_failures`
// table (src/enrich/state.ts), which this module never creates, changes or drops.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { indexPath } from '../core/paths.ts';

export interface IndexDb { raw: DatabaseSync; close(): void }

/** Bump when the tables or what goes into them change: an older file is emptied and rebuilt on the next index run. */
export const SCHEMA_VERSION = 1;
/** The same busy timeout as the failures store, so the enricher and the index wait for each other instead of failing. */
export const BUSY_TIMEOUT_MS = 5000;

/** The index's own tables, children first. `enrich_failures` is not among them. */
export const INDEX_TABLES = ['capture_fts', 'media', 'capture_has', 'capture_circumstances', 'capture_people', 'capture_tags', 'captures', 'meta'];

const SCHEMA = `
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE captures (
  seq INTEGER PRIMARY KEY,               -- also the rowid of the capture's capture_fts row
  id TEXT NOT NULL UNIQUE,
  fingerprint TEXT NOT NULL,             -- of the inputs; a change re-indexes the capture
  record TEXT NOT NULL,                  -- the whole CaptureRecord as JSON
  kind TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  local_date TEXT NOT NULL,              -- the capture's own local date, YYYY-MM-DD
  local_hour INTEGER NOT NULL,           -- 0-23, the capture's own local hour
  weekday TEXT NOT NULL,                 -- mon ... sun
  part_of_day TEXT NOT NULL,             -- morning, afternoon, evening, night
  lat REAL, lon REAL, locality TEXT, site TEXT, topic TEXT,
  method TEXT NOT NULL,
  enriched INTEGER NOT NULL              -- 1 when the server document carries display from hippo-desk
);
CREATE INDEX captures_kind ON captures (kind);
CREATE INDEX captures_local_date ON captures (local_date);
CREATE INDEX captures_captured_at ON captures (captured_at);
CREATE TABLE capture_tags (capture_id TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY (capture_id, tag));
CREATE INDEX capture_tags_tag ON capture_tags (tag);
CREATE TABLE capture_people (capture_id TEXT NOT NULL, name TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY (capture_id, name, source));
CREATE INDEX capture_people_name ON capture_people (name);
CREATE TABLE capture_circumstances (capture_id TEXT NOT NULL, label TEXT NOT NULL, confidence TEXT NOT NULL,
  rank INTEGER NOT NULL,                 -- low 1, medium 2, high 3
  PRIMARY KEY (capture_id, label));
CREATE INDEX capture_circumstances_label ON capture_circumstances (label, rank);
CREATE TABLE capture_has (capture_id TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (capture_id, value));
-- The only source of paths the local server may serve: originals inside the folder, thumbnails in the thumbs directory.
CREATE TABLE media (capture_id TEXT NOT NULL, ref TEXT NOT NULL, path TEXT NOT NULL, mime TEXT NOT NULL, PRIMARY KEY (capture_id, ref));
CREATE VIRTUAL TABLE capture_fts USING fts5 (title, summary, text, image_descriptions, tags, topic, people, site, circumstances,
  tokenize = 'porter unicode61 remove_diacritics 2');
`;

/** Opens (creating when missing) the folder's index. A file from another schema version has its index tables emptied and recreated. */
export function openIndex(folder: string): IndexDb {
  const file = indexPath(folder);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const raw = new DatabaseSync(file, { timeout: BUSY_TIMEOUT_MS });
  try {
    const version = (raw.prepare('PRAGMA user_version').get() as { user_version: number }).user_version;
    if (version !== SCHEMA_VERSION) {
      raw.exec('BEGIN IMMEDIATE');
      try {
        // Re-read inside the write lock: another process may have just done this.
        const again = (raw.prepare('PRAGMA user_version').get() as { user_version: number }).user_version;
        if (again !== SCHEMA_VERSION) {
          for (const t of INDEX_TABLES) raw.exec(`DROP TABLE IF EXISTS ${t}`);
          raw.exec(SCHEMA);
          raw.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
        }
        raw.exec('COMMIT');
      } catch (e) { raw.exec('ROLLBACK'); throw e; }
    }
  } catch (e) { raw.close(); throw e; }
  return { raw, close: () => raw.close() };
}

export function getMeta(db: IndexDb, key: string): string | undefined {
  const row = db.raw.prepare('SELECT value FROM meta WHERE key = ?').get(key) as { value: string } | undefined;
  return row?.value;
}

export function setMeta(db: IndexDb, key: string, value: string): void {
  db.raw.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').run(key, value);
}
