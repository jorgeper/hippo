// The recall engine (spec section 7): runs a search spec against the local index. Reads the index only: no model, no network,
// nothing written into the folder. `hippo search`, `show` and `facets`, the local server and the desk all call it.
import type { SQLInputValue } from 'node:sqlite';
import type { CaptureRecord } from '../core/record.ts';
import type { IndexDb } from '../index/db.ts';
import { DEFAULT_LIMIT, KINDS } from './spec.ts';
import type { SearchSpec } from './spec.ts';

export interface SearchResult { total: number; items: CaptureRecord[] }
export interface FacetValue { value: string; count: number }
export interface Facets { total: number; kinds: Record<string, number>; topics: FacetValue[];
  tags: FacetValue[]; people: FacetValue[]; sites: FacetValue[];
  localities: FacetValue[]; circumstances: FacetValue[];
  date_range?: { from: string; to: string } }
export interface MediaRef { ref: string; path: string; mime: string }

const RANK = { low: 1, medium: 2, high: 3 } as const;
const EARTH_RADIUS_M = 6371008.8;

/** How whole values (tags, topics, people, sites, localities) are compared: trimmed, NFC, lower case. */
export const fold = (s: string) => s.trim().normalize('NFC').toLowerCase();

function distanceM(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(a)));
}

// SQL functions on the connection (not stored in the file): SQLite's lower() folds ASCII only.
const withFunctions = new WeakSet<object>();
function ensureFunctions(db: IndexDb): void {
  if (withFunctions.has(db.raw)) return;
  db.raw.function('hippo_fold', { deterministic: true }, (v: unknown) => (typeof v === 'string' ? fold(v) : null));
  db.raw.function('hippo_distance_m', { deterministic: true }, (lat1: unknown, lon1: unknown, lat2: unknown, lon2: unknown) =>
    [lat1, lon1, lat2, lon2].every(x => typeof x === 'number') ? distanceM(lat1 as number, lon1 as number, lat2 as number, lon2 as number) : null);
  withFunctions.add(db.raw);
}

/** The FTS5 query for `text`: every entry is one quoted phrase (inner double quotes doubled), so no character the person typed is
 *  ever FTS syntax; a one-word entry also matches as a prefix; entries are joined with OR. Undefined when no entry has content. */
export function ftsQuery(entries: string[]): string | undefined {
  const parts = entries.map(e => e.replace(/\u0000/g, ' ').trim()).filter(e => e !== '')
    .map(e => { const quoted = `"${e.replace(/"/g, '""')}"`; return /\s/.test(e) ? quoted : `${quoted}*`; });
  return parts.length ? parts.join(' OR ') : undefined;
}

/** A site as stored: host, lower case, without a leading "www.". Accepts a URL too. */
function siteValue(s: string): string {
  let v = fold(s);
  try { if (/^[a-z][a-z0-9+.-]*:\/\//.test(v)) v = new URL(v).hostname; } catch { /* keep as typed */ }
  return v.replace(/^www\./, '').replace(/\.$/, '');
}

const marks = (n: number) => Array(n).fill('?').join(', ');
const nonEmpty = <T>(xs: T[] | undefined): xs is T[] => Array.isArray(xs) && xs.length > 0;

export function search(db: IndexDb, spec: SearchSpec): SearchResult {
  ensureFunctions(db);
  const where: string[] = [];
  const params: SQLInputValue[] = [];
  const add = (sql: string, ...values: SQLInputValue[]) => { where.push(sql); params.push(...values); };

  if (nonEmpty(spec.kinds)) add(`c.kind IN (${marks(spec.kinds.length)})`, ...spec.kinds);
  if (nonEmpty(spec.tags)) add(`EXISTS (SELECT 1 FROM capture_tags t WHERE t.capture_id = c.id AND hippo_fold(t.tag) IN (${marks(spec.tags.length)}))`,
    ...spec.tags.map(fold));
  if (nonEmpty(spec.topics)) add(`hippo_fold(c.topic) IN (${marks(spec.topics.length)})`, ...spec.topics.map(fold));
  if (nonEmpty(spec.people)) add(`EXISTS (SELECT 1 FROM capture_people p WHERE p.capture_id = c.id AND hippo_fold(p.name) IN (${marks(spec.people.length)}))`,
    ...spec.people.map(fold));
  if (nonEmpty(spec.sites)) {
    // The whole host, or a parent domain of it: "youtube.com" matches "m.youtube.com", never "notyoutube.com".
    const sites = spec.sites.map(siteValue).filter(s => s !== '');
    if (sites.length) add(`(${sites.map(() => '(hippo_fold(c.site) = ? OR substr(hippo_fold(c.site), ?) = ?)').join(' OR ')})`,
      ...sites.flatMap(s => [s, -([...s].length + 1), `.${s}`]));
    else where.push('0');
  }
  const t = spec.time;
  if (t?.from) add('c.local_date >= ?', t.from);
  if (t?.to) add('c.local_date <= ?', t.to);
  if (nonEmpty(t?.weekdays)) add(`c.weekday IN (${marks(t.weekdays.length)})`, ...t.weekdays);
  if (nonEmpty(t?.parts_of_day)) add(`c.part_of_day IN (${marks(t.parts_of_day.length)})`, ...t.parts_of_day);
  const p = spec.place;
  if (nonEmpty(p?.localities)) add(`hippo_fold(c.locality) IN (${marks(p.localities.length)})`, ...p.localities.map(fold));
  if (p?.near) add('c.lat IS NOT NULL AND c.lon IS NOT NULL AND hippo_distance_m(c.lat, c.lon, ?, ?) <= ?', p.near.lat, p.near.lon, p.near.radius_m);
  const circ = spec.circumstances;
  if (circ && nonEmpty(circ.labels)) add(`EXISTS (SELECT 1 FROM capture_circumstances x WHERE x.capture_id = c.id
    AND x.label IN (${marks(circ.labels.length)}) AND x.rank >= ?)`, ...circ.labels, RANK[circ.min_confidence ?? 'low']);
  for (const h of spec.has ?? []) add('EXISTS (SELECT 1 FROM capture_has h WHERE h.capture_id = c.id AND h.value = ?)', h);

  const match = ftsQuery(spec.text ?? []);
  const join = match === undefined ? '' :
    'LEFT JOIN (SELECT rowid AS rid, bm25(capture_fts) AS score FROM capture_fts WHERE capture_fts MATCH ?) f ON f.rid = c.seq';
  if (match !== undefined) where.push('f.rid IS NOT NULL');

  const include = (spec.include_ids ?? []).map(s => s.trim().toLowerCase());
  const exclude = (spec.exclude_ids ?? []).map(s => s.trim().toLowerCase());
  let condition = where.length ? where.map(w => `(${w})`).join(' AND ') : '1';
  const all: SQLInputValue[] = [...(match === undefined ? [] : [match]), ...params];
  if (include.length) { condition = `(${condition}) OR c.id IN (SELECT value FROM json_each(?))`; all.push(JSON.stringify(include)); }
  if (exclude.length) { condition = `(${condition}) AND c.id NOT IN (SELECT value FROM json_each(?))`; all.push(JSON.stringify(exclude)); }

  const sort = spec.sort === 'relevance' && match === undefined ? 'newest' : spec.sort ?? 'newest';
  const order = sort === 'oldest' ? 'c.captured_at ASC, c.id ASC'
    : sort === 'relevance' ? 'f.score IS NULL, f.score ASC, c.captured_at DESC, c.id DESC'
    : 'c.captured_at DESC, c.id DESC';
  const rows = db.raw.prepare(`SELECT c.id AS id FROM captures c ${join} WHERE ${condition} ORDER BY ${order}`).all(...all) as { id: string }[];

  // The limit never cuts a pinned item: pinned ones keep their place in the order, the others fill the remaining room.
  const limit = spec.limit ?? DEFAULT_LIMIT;
  const pinned = new Set(include);
  let room = Math.max(0, limit - rows.filter(r => pinned.has(r.id)).length);
  const chosen = rows.filter(r => pinned.has(r.id) || room-- > 0).map(r => r.id);

  const records = new Map<string, CaptureRecord>();
  if (chosen.length) {
    for (const r of db.raw.prepare('SELECT id, record FROM captures WHERE id IN (SELECT value FROM json_each(?))').all(JSON.stringify(chosen)) as
      { id: string; record: string }[]) records.set(r.id, JSON.parse(r.record) as CaptureRecord);
  }
  return { total: rows.length, items: chosen.map(id => records.get(id)!).filter(Boolean) };
}

/** The ids a whole id or a prefix of 8 or more characters names (case-insensitively), at most 10. */
export function matchIds(db: IndexDb, idOrPrefix: string): string[] {
  const q = idOrPrefix.trim().toLowerCase();
  if (q === '') return [];
  if (db.raw.prepare('SELECT 1 FROM captures WHERE id = ?').get(q)) return [q];
  if ([...q].length < 8) return [];
  return (db.raw.prepare('SELECT id FROM captures WHERE substr(id, 1, ?) = ? ORDER BY id LIMIT 10').all([...q].length, q) as
    { id: string }[]).map(r => r.id);
}

/** One capture by its id or a unique id prefix of 8 or more characters. */
export function show(db: IndexDb, id: string): CaptureRecord | undefined {
  const ids = matchIds(db, id);
  if (ids.length !== 1) return undefined;
  const row = db.raw.prepare('SELECT record FROM captures WHERE id = ?').get(ids[0]) as { record: string } | undefined;
  return row ? JSON.parse(row.record) as CaptureRecord : undefined;
}

/** The files the index recorded for a capture: originals, thumbnails, link thumbnail, comment audio. */
export function mediaOf(db: IndexDb, id: string): MediaRef[] {
  return (db.raw.prepare('SELECT ref, path, mime FROM media WHERE capture_id = ? ORDER BY ref').all(id) as unknown as MediaRef[])
    .map(m => ({ ref: m.ref, path: m.path, mime: m.mime }));
}

/** The vocabulary: which values exist and how many captures carry each, most common first. */
export function facets(db: IndexDb): Facets {
  const count = (sql: string) => (db.raw.prepare(sql).all() as unknown as FacetValue[]).map(r => ({ value: r.value, count: r.count }));
  const total = (db.raw.prepare('SELECT COUNT(*) AS n FROM captures').get() as { n: number }).n;
  const kinds: Record<string, number> = Object.fromEntries(KINDS.map(k => [k, 0]));
  for (const r of count('SELECT kind AS value, COUNT(*) AS count FROM captures GROUP BY kind')) kinds[r.value] = r.count;
  const column = (col: string) => count(`SELECT ${col} AS value, COUNT(*) AS count FROM captures WHERE ${col} IS NOT NULL AND ${col} != ''
    GROUP BY ${col} ORDER BY count DESC, value`);
  const child = (table: string, col: string) => count(`SELECT ${col} AS value, COUNT(DISTINCT capture_id) AS count FROM ${table}
    GROUP BY ${col} ORDER BY count DESC, value`);
  const out: Facets = { total, kinds, topics: column('topic'), tags: child('capture_tags', 'tag'), people: child('capture_people', 'name'),
    sites: column('site'), localities: column('locality'), circumstances: child('capture_circumstances', 'label') };
  const range = db.raw.prepare('SELECT MIN(local_date) AS lo, MAX(local_date) AS hi FROM captures').get() as { lo: string | null; hi: string | null };
  if (range.lo && range.hi) out.date_range = { from: range.lo, to: range.hi };
  return out;
}
