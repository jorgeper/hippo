// `hippo index` and `hippo status` (spec section 5, "Where results go" 2 and 3). Builds or updates the local
// index and thumbnails from the folder. No model, and nothing is ever written into the folder.
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { scanFolder, sha256File } from '../core/folder.ts';
import { indexPath, thumbsDir } from '../core/paths.ts';
import { buildRecord } from '../core/record.ts';
import type { CaptureRecord } from '../core/record.ts';
import { resolved } from '../core/resolve.ts';
import type { Kind, RawCapture } from '../core/types.ts';
import { openFailureStore } from '../enrich/state.ts';
import { ensureThumbs } from './thumbs.ts';
import { getMeta, INDEX_TABLES, openIndex, SCHEMA_VERSION, setMeta } from './db.ts';
import type { IndexDb } from './db.ts';

export interface IndexReport { captures: number; added: number; updated: number; removed: number; thumbnails: number;
  thumbFailures: { id: string; reason: string }[] }
export interface Status { folder: string; total: number; byKind: Record<Kind, number>; enriched: number; pending: number;
  failures: { id: string; attempts: number; error: string }[]; lastEnrichAt?: string; lastIndexAt?: string }

const KINDS: Kind[] = ['note', 'link', 'photo', 'screenshot', 'recording', 'video', 'file'];
const RANK: Record<string, number> = { low: 1, medium: 2, high: 3 };
/** Circumstance labels in words, so a search for "car" or "headphones" finds them. Other labels: underscores become spaces. */
const LABEL_WORDS: Record<string, string> = { in_car: 'in a car', on_headphones: 'on headphones', in_a_burst: 'in a burst' };
const labelWords = (label: string) => LABEL_WORDS[label] ?? label.replace(/_/g, ' ');

/** For originals with no `mime_type` in the metadata. */
const MIME_BY_EXT: Record<string, string> = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.gif': 'image/gif', '.webp': 'image/webp', '.heic': 'image/heic',
  '.heif': 'image/heif', '.tif': 'image/tiff', '.tiff': 'image/tiff', '.bmp': 'image/bmp', '.avif': 'image/avif',
  '.mov': 'video/quicktime', '.mp4': 'video/mp4', '.m4v': 'video/x-m4v', '.3gp': 'video/3gpp',
  '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.aif': 'audio/aiff', '.aiff': 'audio/aiff', '.caf': 'audio/x-caf',
  '.pdf': 'application/pdf', '.txt': 'text/plain', '.md': 'text/markdown', '.json': 'application/json',
};
const mimeByExt = (p: string) => MIME_BY_EXT[path.extname(p).toLowerCase()] ?? 'application/octet-stream';
const validMime = (v: unknown): v is string => typeof v === 'string' && /^[\w.+-]+\/[\w.+-]+$/.test(v.trim());

function isObject(v: unknown): v is Record<string, any> { return typeof v === 'object' && v !== null && !Array.isArray(v); }

function inside(base: string, p: string): boolean {
  const r = path.relative(path.resolve(base), path.resolve(p));
  return r !== '' && !r.startsWith('..') && !path.isAbsolute(r);
}

function isFile(p: string): boolean { try { return fs.statSync(p).isFile(); } catch { return false; } }

interface MediaRow { ref: string; path: string; mime: string }
interface Entry { record: CaptureRecord; fingerprint: string; media: MediaRow[] }

async function readBytes(p: string): Promise<Buffer | undefined> {
  try { return await fsp.readFile(p); } catch { return undefined; }
}

/** A digest of everything the capture's index rows are made from: the package, both enrichment documents, the comment files. */
async function fingerprint(folder: string, c: RawCapture): Promise<string> {
  const h = crypto.createHash('sha256');
  const part = (label: string, value: Buffer | string | undefined) => {
    const b = value === undefined ? Buffer.alloc(0) : Buffer.isBuffer(value) ? value : Buffer.from(value);
    h.update(`${label}\u0000${value === undefined ? '-' : b.length}\u0000`); h.update(b);
  };
  part('schema', String(SCHEMA_VERSION));
  part('folder', path.resolve(folder));
  part('package', c.packageDigest);
  part('device', await readBytes(path.resolve(folder, 'enrichments', 'device', ...c.datePath.split('/'), c.id, 'enrichment.json')));
  part('server', await readBytes(c.serverPath));
  let names: string[] = [];
  try { names = (await fsp.readdir(path.join(c.dir, 'comments'))).sort(); } catch { /* none */ }
  for (const n of names) {
    part('comment', n);
    if (n.endsWith('.json')) part('comment-json', await readBytes(path.join(c.dir, 'comments', n)));
  }
  return h.digest('hex');
}

/** The capture's record and media rows; makes missing thumbnails. A picture that cannot be decoded is reported and left without one. */
async function prepare(folder: string, c: RawCapture, fp: string, report: IndexReport): Promise<Entry> {
  const record = await buildRecord(c);
  const media: MediaRow[] = [];
  const thumbs = thumbsDir();
  const add = (ref: string, p: string, mime: string, base: string) => {
    // Defence in depth: the server serves only these paths, so nothing outside the folder or the thumbs directory.
    if (path.isAbsolute(p) && inside(base, p) && isFile(p)) media.push({ ref, path: path.resolve(p), mime });
  };
  const manifest = new Map<string, Record<string, any>>();
  for (const a of Array.isArray(c.metadata.attachments) ? c.metadata.attachments : [])
    if (isObject(a) && typeof a.attachment_id === 'string') manifest.set(a.attachment_id, a);

  for (const a of record.attachments) {
    const declared = manifest.get(a.id)?.mime_type;
    add(a.id, a.path, validMime(declared) ? declared.trim().toLowerCase() : mimeByExt(a.path), folder);
    if (a.type !== 'picture' || !isFile(a.path)) continue;
    try {
      const sha = /^[0-9a-f]{64}$/.test(a.sha256) ? a.sha256 : await sha256File(a.path);
      const t = await ensureThumbs(a.path, sha);
      add(`thumb-${a.id}`, t.small, 'image/jpeg', thumbs);
      add(`display-${a.id}`, t.display, 'image/jpeg', thumbs);
      report.thumbnails++;
    } catch (e) {
      report.thumbFailures.push({ id: c.id, reason: e instanceof Error ? e.message : String(e) });
    }
  }
  if (record.link?.thumbPath) {
    const declared = resolved(c).linkPreviews.get(record.link.url)?.thumbnail?.mime_type;
    add('link-thumb', record.link.thumbPath, validMime(declared) ? declared.trim().toLowerCase() : mimeByExt(record.link.thumbPath), folder);
  }
  for (const k of record.comments) if (k.audioPath) add(`comment-${k.id}`, k.audioPath, mimeByExt(k.audioPath), folder);
  return { record, fingerprint: fp, media };
}

function deleteCapture(db: IndexDb, id: string): void {
  db.raw.prepare('DELETE FROM capture_fts WHERE rowid IN (SELECT seq FROM captures WHERE id = ?)').run(id);
  for (const t of ['media', 'capture_has', 'capture_circumstances', 'capture_people', 'capture_tags'])
    db.raw.prepare(`DELETE FROM ${t} WHERE capture_id = ?`).run(id);
  db.raw.prepare('DELETE FROM captures WHERE id = ?').run(id);
}

function insertCapture(db: IndexDb, e: Entry): void {
  const r = e.record;
  const { lastInsertRowid } = db.raw.prepare(`INSERT INTO captures (id, fingerprint, record, kind, captured_at, local_date, local_hour,
    weekday, part_of_day, lat, lon, locality, site, topic, method, enriched) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
    r.id, e.fingerprint, JSON.stringify(r), r.kind, r.captured_at, r.local_date, Number(r.local_time.slice(0, 2)), r.weekday, r.part_of_day,
    r.place?.lat ?? null, r.place?.lon ?? null, r.place?.locality ?? null, r.site ?? null, r.topic ?? null, r.method, r.enriched ? 1 : 0);
  const tag = db.raw.prepare('INSERT OR IGNORE INTO capture_tags (capture_id, tag) VALUES (?, ?)');
  for (const t of r.tags) tag.run(r.id, t);
  const person = db.raw.prepare('INSERT OR IGNORE INTO capture_people (capture_id, name, source) VALUES (?, ?, ?)');
  for (const p of r.people) person.run(r.id, p.name, p.source);
  const circ = db.raw.prepare('INSERT OR IGNORE INTO capture_circumstances (capture_id, label, confidence, rank) VALUES (?, ?, ?, ?)');
  for (const c of r.circumstances) if (RANK[c.confidence]) circ.run(r.id, c.label, c.confidence, RANK[c.confidence]);
  const has = db.raw.prepare('INSERT OR IGNORE INTO capture_has (capture_id, value) VALUES (?, ?)');
  for (const h of r.has) has.run(r.id, h);
  const media = db.raw.prepare('INSERT OR IGNORE INTO media (capture_id, ref, path, mime) VALUES (?, ?, ?, ?)');
  for (const m of e.media) media.run(r.id, m.ref, m.path, m.mime);
  const join = (xs: string[], sep: string) => (xs.length ? xs.join(sep) : null);
  db.raw.prepare(`INSERT INTO capture_fts (rowid, title, summary, text, image_descriptions, tags, topic, people, site, circumstances)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(lastInsertRowid, r.title, r.summary ?? null, r.text || null,
    join(r.image_descriptions.map(d => d.text), '\n'), join(r.tags, ' '), r.topic ?? null, join(r.people.map(p => p.name), '\n'),
    r.site ?? null, join(r.circumstances.map(c => labelWords(c.label)), '\n'));
}

/** Indexes every complete capture whose inputs changed, removes captures gone from the folder. `rebuild` starts from empty tables
 *  (the enrichment failures are kept). All changes land in one transaction, so a killed run leaves the previous index intact. */
export async function buildIndex(folder: string, opts: { rebuild?: boolean } = {}): Promise<IndexReport> {
  const scan = await scanFolder(folder);
  const report: IndexReport = { captures: scan.captures.length, added: 0, updated: 0, removed: 0, thumbnails: 0, thumbFailures: [] };

  const known = new Map<string, { fingerprint: string; paths: string[] }>();
  let db = openIndex(folder);
  try {
    if (!opts.rebuild) {
      for (const row of db.raw.prepare('SELECT id, fingerprint FROM captures').all() as { id: string; fingerprint: string }[])
        known.set(row.id, { fingerprint: row.fingerprint, paths: [] });
      for (const row of db.raw.prepare('SELECT capture_id, path FROM media').all() as { capture_id: string; path: string }[])
        known.get(row.capture_id)?.paths.push(row.path);
    }
  } finally { db.close(); }

  // Phase 1, without holding the database: records and thumbnails for the captures that changed.
  const entries: { entry: Entry; isNew: boolean }[] = [];
  for (const c of scan.captures) {
    const fp = await fingerprint(folder, c);
    const k = known.get(c.id);
    // Unchanged inputs and every media file still there (thumbnails can be deleted): nothing to do.
    if (k && k.fingerprint === fp && k.paths.every(isFile)) continue;
    entries.push({ entry: await prepare(folder, c, fp, report), isNew: !k });
  }
  const present = new Set(scan.captures.map(c => c.id));
  const gone = [...known.keys()].filter(id => !present.has(id));

  // Phase 2: one transaction.
  db = openIndex(folder);
  try {
    db.raw.exec('BEGIN IMMEDIATE');
    try {
      if (opts.rebuild) for (const t of INDEX_TABLES) db.raw.exec(`DELETE FROM ${t}`);
      for (const id of gone) deleteCapture(db, id);
      for (const { entry } of entries) { deleteCapture(db, entry.record.id); insertCapture(db, entry); }
      setMeta(db, 'folder', path.resolve(folder));
      setMeta(db, 'pending', String(scan.pending.length));
      setMeta(db, 'last_index_at', new Date().toISOString());
      db.raw.exec('COMMIT');
    } catch (e) { db.raw.exec('ROLLBACK'); throw e; }
  } finally { db.close(); }

  report.removed = gone.length;
  for (const { isNew } of entries) if (isNew) report.added++; else report.updated++;
  return report;
}

/** Records the end of an enrichment run (`hippo enrich`, not a dry run). */
export function markEnriched(folder: string, at: Date = new Date()): void {
  const db = openIndex(folder);
  try { setMeta(db, 'last_enrich_at', at.toISOString()); } finally { db.close(); }
}

export function status(folder: string): Status {
  const byKind = Object.fromEntries(KINDS.map(k => [k, 0])) as Record<Kind, number>;
  const out: Status = { folder: path.resolve(folder), total: 0, byKind, enriched: 0, pending: 0, failures: [] };
  if (!fs.existsSync(indexPath(folder))) return out;
  const db = openIndex(folder);
  try {
    for (const row of db.raw.prepare('SELECT kind, COUNT(*) AS n, SUM(enriched) AS e FROM captures GROUP BY kind').all() as
      { kind: string; n: number; e: number }[]) {
      if (Object.hasOwn(byKind, row.kind)) byKind[row.kind as Kind] = row.n;
      out.total += row.n; out.enriched += row.e;
    }
    const pending = Number(getMeta(db, 'pending'));
    if (Number.isSafeInteger(pending) && pending > 0) out.pending = pending;
    const lastEnrich = getMeta(db, 'last_enrich_at'); if (lastEnrich) out.lastEnrichAt = lastEnrich;
    const lastIndex = getMeta(db, 'last_index_at'); if (lastIndex) out.lastIndexAt = lastIndex;
  } finally { db.close(); }
  const store = openFailureStore(folder, { readOnly: true });
  try { out.failures = store.all().map(f => ({ id: f.capture_id, attempts: f.attempts, error: f.last_error })); } finally { store.close(); }
  return out;
}
