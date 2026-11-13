import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { copyFixtures, fixturesDir, snapshot } from './helpers.ts';
import { enrichFolder } from '../src/enrich/enrich.ts';
import { fakeProvider } from '../src/providers/fake.ts';
import { buildIndex } from '../src/index/build.ts';
import { openIndex } from '../src/index/db.ts';
import type { IndexDb } from '../src/index/db.ts';
import { facets, ftsQuery, search, show } from '../src/recall/engine.ts';
import type { SearchSpec } from '../src/recall/spec.ts';

const id = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;
const now = () => new Date('2026-11-12T10:00:00Z');
const sha = (b: Buffer) => crypto.createHash('sha256').update(b).digest('hex');

// One fixture copy, enriched with the fake provider and indexed, shared by the read-only tests below.
const folder = copyFixtures();
await enrichFolder({ folder, provider: fakeProvider(), now });
await buildIndex(folder);
const before = snapshot(folder);
const db: IndexDb = openIndex(folder);
test.after(() => db.close());

/** The fixture numbers (1-7) of the result, in result order. */
const nums = (spec: SearchSpec) => search(db, spec).items.map(r => Number(r.id.slice(-1)));
const sorted = (xs: number[]) => [...xs].sort((a, b) => a - b);

test('kinds: screenshot is capture 7 only', () => {
  assert.deepEqual(nums({ kinds: ['screenshot'] }), [7]);
});

test('circumstances: in_car is capture 7, also at min_confidence high; walking matches none', () => {
  assert.deepEqual(nums({ circumstances: { labels: ['in_car'] } }), [7]);
  assert.deepEqual(nums({ circumstances: { labels: ['in_car'], min_confidence: 'high' } }), [7]);
  assert.deepEqual(nums({ circumstances: { labels: ['walking'] } }), []);
  assert.deepEqual(nums({ circumstances: { labels: ['in_a_burst'], min_confidence: 'high' } }), [], 'in_a_burst is only medium');
});

test('has: comment is capture 4; all listed must hold', () => {
  assert.deepEqual(nums({ has: ['comment'] }), [4]);
  assert.deepEqual(sorted(nums({ has: ['picture', 'location'] })), [4, 7]);
  assert.deepEqual(nums({ has: ['comment', 'link', 'audio'] }), [4]);
});

test('sites: example.com is captures 2 and 4, whatever their kind, case-insensitively', () => {
  assert.deepEqual(sorted(nums({ sites: ['example.com'] })), [2, 4]);
  assert.deepEqual(sorted(nums({ sites: ['EXAMPLE.com'] })), [2, 4]);
  assert.deepEqual(nums({ sites: ['ample.com'] }), [], 'only whole labels of the domain');
});

test('text: cafe and cafes (stemming) are capture 7', () => {
  assert.deepEqual(nums({ text: ['cafe'] }), [7]);
  assert.deepEqual(nums({ text: ['cafes'] }), [7]);
  assert.deepEqual(nums({ text: ['plumb'] }), [1], 'a one-word entry also matches as a prefix');
  assert.deepEqual(sorted(nums({ text: ['plumber', 'cafe'] })), [1, 7], 'entries combine with OR');
  assert.deepEqual(nums({ text: ['the corner'] }), [7], 'a phrase');
  assert.deepEqual(nums({ text: ['corner the'] }), [], 'a phrase keeps its word order');
});

test('text with FTS syntax runs and matches literally (Review Focus 3)', () => {
  assert.deepEqual(nums({ text: ['"quoted" AND (x:y) -z *'] }), []);
  // Each of these would match capture 7 if its words were read as operators.
  for (const entry of ['cafe AND menu', 'menu NEAR cafe', 'zzz OR cafe', 'cafe NOT zzz', 'say "cafe" \u0007 NEAR AND NOT', 'menu -cafe', '"cafe"', 'cafe:menu'])
    assert.deepEqual(nums({ text: [entry] }), entry === '"cafe"' ? [7] : [], entry);
  for (const entry of ['*', '"', '-', '()', '\u0001', '   ', 'NEAR', 'AND', 'NOT', 'OR'])
    assert.doesNotThrow(() => search(db, { text: [entry] }), JSON.stringify(entry));
});

test('ftsQuery quotes every entry as a phrase, doubles inner quotes, and adds a prefix star to one-word entries only', () => {
  assert.equal(ftsQuery(['banan']), '"banan"*');
  assert.equal(ftsQuery(['yellow fruit', 'say "hi"']), '"yellow fruit" OR "say ""hi"""');
  assert.equal(ftsQuery(['  ', '']), undefined);
});

test('time: every fixture is on 2026-11-07; none on or after 2026-11-08', () => {
  assert.deepEqual(sorted(nums({ time: { from: '2026-11-07', to: '2026-11-07' } })), [1, 2, 3, 4, 5, 6, 7]);
  assert.deepEqual(nums({ time: { from: '2026-11-08' } }), []);
  assert.deepEqual(nums({ time: { to: '2026-11-06' } }), []);
  assert.equal(nums({ time: { weekdays: ['sat'], parts_of_day: ['morning'] } }).length, 7);
  assert.deepEqual(nums({ time: { weekdays: ['sun'] } }), []);
});

test('place near: the two captures at the point; a 1 m radius a kilometre away finds none', () => {
  assert.deepEqual(sorted(nums({ place: { near: { lat: 37.7749, lon: -122.4194, radius_m: 500 } } })), [4, 7]);
  assert.deepEqual(nums({ place: { near: { lat: 37.7839, lon: -122.4194, radius_m: 1 } } }), []);
  assert.deepEqual(sorted(nums({ place: { near: { lat: 37.7839, lon: -122.4194, radius_m: 1100 } } })), [4, 7]);
  assert.deepEqual(nums({ place: { localities: ['Nowhere'] } }), []);
});

test('tags and topics match the whole value, case-insensitively', () => {
  assert.deepEqual(sorted(nums({ tags: ['FAKE'] })), [1, 2, 3, 4, 7]);
  assert.deepEqual(nums({ tags: ['fak'] }), []);
  assert.deepEqual(sorted(nums({ topics: ['Fake'] })), [1, 2, 3, 4, 7]);
  assert.deepEqual(nums({ people: ['nobody'] }), []);
});

test('fields combine with AND, values within a field with OR', () => {
  assert.deepEqual(sorted(nums({ kinds: ['screenshot', 'video'] })), [5, 7]);
  assert.deepEqual(nums({ kinds: ['screenshot', 'video'], has: ['location'] }), [7]);
});

test('include_ids are returned even when they do not match; exclude_ids are removed last', () => {
  assert.deepEqual(nums({ include_ids: [id(1)], kinds: ['video'] }), [5, 1]);
  assert.deepEqual(nums({ exclude_ids: [id(5)], kinds: ['video'] }), []);
  assert.deepEqual(nums({ include_ids: [id(5)], exclude_ids: [id(5)] }).includes(5), false);
});

test('limit cuts the items, total counts before it; sort oldest starts with capture 1', () => {
  const r = search(db, { limit: 2 });
  assert.equal(r.items.length, 2); assert.equal(r.total, 7);
  assert.deepEqual(r.items.map(x => x.id), [id(7), id(6)], 'newest first by default');
  assert.equal(nums({ sort: 'oldest' })[0], 1);
  assert.deepEqual(nums({ sort: 'relevance' }), [7, 6, 5, 4, 3, 2, 1], 'relevance without text is newest');
  assert.deepEqual(nums({ include_ids: [id(1)], limit: 1 }), [1], 'a pinned item is never cut by the limit');
});

test('sort relevance ranks by bm25', () => {
  assert.equal(nums({ text: ['cafe', 'example'], sort: 'relevance' }).length, 3);
});

test('results are full capture records', () => {
  const [r] = search(db, { kinds: ['screenshot'] }).items;
  assert.equal(r.id, id(7)); assert.equal(r.kind, 'screenshot'); assert.ok(r.circumstances.some(c => c.label === 'in_car'));
  assert.ok(path.isAbsolute(r.attachments[0].path));
});

test('facets: total, kinds, date range, circumstances', () => {
  const f = facets(db);
  assert.equal(f.total, 7);
  assert.deepEqual(f.kinds, { link: 1, photo: 2, screenshot: 1, note: 1, recording: 1, video: 1, file: 0 });
  assert.deepEqual(f.date_range, { from: '2026-11-07', to: '2026-11-07' });
  assert.ok(f.circumstances.some(c => c.value === 'in_car' && c.count === 1));
  assert.deepEqual(f.sites, [{ value: 'example.com', count: 2 }]);
  assert.deepEqual(f.topics, [{ value: 'fake', count: 5 }]);
  assert.ok(f.tags.some(t => t.value === 'fake' && t.count === 5));
});

test('show takes a whole id; a prefix shorter than 8 characters or shared by several captures finds nothing', () => {
  assert.equal(show(db, id(7))?.kind, 'screenshot');
  assert.equal(show(db, id(7).toUpperCase())?.id, id(7));
  assert.equal(show(db, '00000000'), undefined, 'all seven fixture ids start with it');
  assert.equal(show(db, 'nothing-like-it'), undefined);
});

test('recall wrote nothing into the folder', () => {
  assert.deepEqual(snapshot(folder), before);
});

// ---- captures made for these tests: a copy of capture 1 with other metadata ----

function addCapture(dir: string, newId: string, datePath: string, metadata: Record<string, unknown>): void {
  const src = path.join(fixturesDir, 'captures/2026/11/07', id(1));
  const dest = path.join(dir, 'captures', ...datePath.split('/'), newId);
  fs.cpSync(src, dest, { recursive: true });
  const md = { ...JSON.parse(fs.readFileSync(path.join(dest, 'metadata.json'), 'utf8')), capture_id: newId, ...metadata };
  const mdBytes = Buffer.from(JSON.stringify(md, null, 2));
  fs.writeFileSync(path.join(dest, 'metadata.json'), mdBytes);
  const complete = JSON.parse(fs.readFileSync(path.join(dest, 'complete.json'), 'utf8'));
  complete.capture_id = newId;
  for (const f of complete.files) if (f.relative_path === 'metadata.json') { f.byte_count = mdBytes.length; f.sha256 = sha(mdBytes); }
  fs.writeFileSync(path.join(dest, 'complete.json'), JSON.stringify(complete, null, 2));
}

test('dates are the capture\'s own local date, not the machine\'s (Review Focus 4); prefixes and parent domains', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-recall-'));
  process.env.HIPPO_DESK_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-home-'));
  const late = '8a7f3c21-0000-4000-8000-000000000008';
  addCapture(dir, late, '2026/11/07', { captured_at: '2026-11-08T07:30:00.000Z', local_datetime: '2026-11-07T23:30:00-08:00',
    timezone_identifier: 'America/Los_Angeles', utc_offset_seconds: -28800, capture_method: 'share_extension',
    urls: [{ url: 'https://m.youtube.com/shorts/abc123' }] });
  // Index as if the machine were in Lisbon, where that instant is already 2026-11-08.
  const tz = process.env.TZ;
  process.env.TZ = 'Europe/Lisbon';
  try { await buildIndex(dir); } finally { if (tz === undefined) delete process.env.TZ; else process.env.TZ = tz; }
  const d = openIndex(dir);
  try {
    const ids = (spec: SearchSpec) => search(d, spec).items.map(r => r.id);
    assert.deepEqual(ids({ time: { from: '2026-11-07', to: '2026-11-07' } }), [late]);
    assert.deepEqual(ids({ time: { from: '2026-11-08', to: '2026-11-08' } }), []);
    assert.deepEqual(ids({ time: { parts_of_day: ['night'], weekdays: ['sat'] } }), [late]);
    assert.deepEqual(ids({ sites: ['youtube.com'] }), [late], 'a parent domain matches');
    assert.deepEqual(ids({ sites: ['www.m.youtube.com'] }), [late], 'a leading www. is ignored');
    assert.deepEqual(ids({ sites: ['tube.com'] }), []);
    assert.equal(show(d, '8a7f3c21')?.id, late, 'a unique prefix of 8 characters');
    assert.equal(show(d, '8a7f3c2'), undefined, 'a prefix shorter than 8 characters');
  } finally { d.close(); }
});
