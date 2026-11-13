import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { copyFixtures, snapshot } from './helpers.ts';
import { scanFolder } from '../src/core/folder.ts';
import { buildRecord } from '../src/core/record.ts';
import { indexPath, thumbsDir } from '../src/core/paths.ts';
import { enrichFolder } from '../src/enrich/enrich.ts';
import { openFailureStore } from '../src/enrich/state.ts';
import { fakeProvider } from '../src/providers/fake.ts';
import { openIndex, getMeta } from '../src/index/db.ts';
import { buildIndex, status } from '../src/index/build.ts';
import type { Status } from '../src/index/build.ts';
import { writeSample } from '../src/index/sample.ts';
import { hasContent, modelInput } from '../src/enrich/prompt.ts';
import os from 'node:os';

const id = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;
const capDir = (folder: string, n: number) => path.join(folder, 'captures/2026/11/07', id(n));
const now = () => new Date('2026-11-12T10:00:00Z');
const never = () => fakeProvider(() => { throw new Error('must not be called'); });
const sha = (b: Buffer) => crypto.createHash('sha256').update(b).digest('hex');

/** Every index row, in a stable order, without the internal row numbers. */
function dump(folder: string) {
  const db = openIndex(folder);
  try {
    const q = (sql: string) => db.raw.prepare(sql).all().map(r => ({ ...r }));
    return {
      captures: q(`SELECT id, fingerprint, record, kind, captured_at, local_date, local_hour, weekday, part_of_day, lat, lon, locality,
        site, topic, method, enriched FROM captures ORDER BY id`),
      tags: q('SELECT * FROM capture_tags ORDER BY capture_id, tag'),
      people: q('SELECT * FROM capture_people ORDER BY capture_id, name, source'),
      circumstances: q('SELECT * FROM capture_circumstances ORDER BY capture_id, label'),
      has: q('SELECT * FROM capture_has ORDER BY capture_id, value'),
      media: q('SELECT * FROM media ORDER BY capture_id, ref'),
      fts: q(`SELECT c.id, f.title, f.summary, f.text, f.image_descriptions, f.tags, f.topic, f.people, f.site, f.circumstances
        FROM capture_fts f JOIN captures c ON c.seq = f.rowid ORDER BY c.id`),
    };
  } finally { db.close(); }
}

/** Rewrites a file in a capture and fixes its size and hash in complete.json, so the capture stays complete. */
function replaceInCapture(folder: string, n: number, rel: string, bytes: Buffer) {
  const dir = capDir(folder, n);
  fs.writeFileSync(path.join(dir, rel), bytes);
  const completePath = path.join(dir, 'complete.json');
  const complete = JSON.parse(fs.readFileSync(completePath, 'utf8'));
  for (const f of complete.files) if (f.relative_path === rel) { f.byte_count = bytes.length; f.sha256 = sha(bytes); }
  fs.writeFileSync(completePath, JSON.stringify(complete, null, 2));
}

test('indexing a fixture copy: seven captures counted by kind; nothing in the folder changes; the file is under HIPPO_DESK_HOME', async () => {
  const folder = copyFixtures(); const before = snapshot(folder);
  const r = await buildIndex(folder);
  assert.equal(r.captures, 7); assert.equal(r.added, 7); assert.equal(r.updated, 0); assert.equal(r.removed, 0);
  assert.deepEqual(r.thumbFailures, []);
  assert.deepEqual(snapshot(folder), before);
  const file = indexPath(folder);
  assert.ok(fs.existsSync(file));
  assert.ok(!path.relative(process.env.HIPPO_DESK_HOME!, file).startsWith('..'));
  const s = status(folder);
  assert.equal(s.folder, path.resolve(folder));
  assert.equal(s.total, 7);
  assert.deepEqual(s.byKind, { note: 1, link: 1, photo: 2, video: 1, recording: 1, screenshot: 1, file: 0 });
  assert.equal(s.enriched, 0); assert.equal(s.pending, 0); assert.deepEqual(s.failures, []);
  assert.equal(s.lastEnrichAt, undefined);
  assert.match(s.lastIndexAt ?? '', /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
});

test('the row JSON for capture 7 round-trips to the buildRecord result; the filter columns match it', async () => {
  const folder = copyFixtures();
  await buildIndex(folder);
  const c7 = (await scanFolder(folder)).captures.find(c => c.id === id(7))!;
  const expected = await buildRecord(c7);
  const db = openIndex(folder);
  try {
    const row = db.raw.prepare('SELECT * FROM captures WHERE id = ?').get(id(7)) as Record<string, any>;
    assert.deepEqual(JSON.parse(row.record), expected);
    assert.equal(row.kind, expected.kind); assert.equal(row.local_date, expected.local_date);
    assert.equal(row.local_hour, Number(expected.local_time.slice(0, 2)));
    assert.equal(row.lat, expected.place!.lat); assert.equal(row.lon, expected.place!.lon);
    assert.equal(row.topic, 'food'); assert.equal(row.enriched, 0);
    const tags = db.raw.prepare('SELECT tag FROM capture_tags WHERE capture_id = ? ORDER BY tag').all(id(7)).map(r => r.tag);
    assert.deepEqual(tags, [...expected.tags].sort());
    const circ = db.raw.prepare('SELECT label, confidence, rank FROM capture_circumstances WHERE capture_id = ?').all(id(7)).map(r => ({ ...r }));
    assert.ok(circ.length > 0);
    for (const c of circ) assert.equal(c.rank, { low: 1, medium: 2, high: 3 }[c.confidence as string]);
    const fts = db.raw.prepare(`SELECT c.id FROM capture_fts f JOIN captures c ON c.seq = f.rowid WHERE capture_fts MATCH ?`).all('"in a car"').map(r => r.id);
    assert.deepEqual(fts, expected.circumstances.some(c => c.label === 'in_car') ? [id(7)] : []);
  } finally { db.close(); }
});

test('a second buildIndex adds and updates nothing', async () => {
  const folder = copyFixtures();
  await buildIndex(folder);
  const r = await buildIndex(folder);
  assert.equal(r.captures, 7); assert.equal(r.added, 0); assert.equal(r.updated, 0); assert.equal(r.removed, 0);
});

test('after enrichment with the fake provider, changed captures are re-indexed and status counts the enriched ones', async () => {
  const folder = copyFixtures();
  await buildIndex(folder);
  await enrichFolder({ folder, provider: fakeProvider(), now });
  const r = await buildIndex(folder);
  assert.ok(r.updated >= 5, `updated ${r.updated}`); assert.equal(r.added, 0);
  const records = await Promise.all((await scanFolder(folder)).captures.map(buildRecord));
  const enriched = records.filter(x => x.enriched).length;
  assert.ok(enriched >= 5);
  const st = status(folder);
  assert.equal(st.enriched, enriched);
  // The fixtures: 5 enriched, 2 with nothing to describe (a video, a recording without a transcript), 0 pending, 0 failures.
  assert.deepEqual([st.enriched, st.nothingToDescribe, st.pending, st.failures.length, st.total], [5, 2, 0, 0, 7]);
});

test('status counts captures with nothing to describe before any enrichment too, and after a rebuild', async () => {
  const folder = copyFixtures();
  await buildIndex(folder);
  assert.equal(status(folder).nothingToDescribe, 2);
  await buildIndex(folder, { rebuild: true });
  assert.equal(status(folder).nothingToDescribe, 2);
});

test('status lists enrichment failures with their reasons and the last enrich time', async () => {
  const folder = copyFixtures();
  await buildIndex(folder);
  const store = openFailureStore(folder);
  store.record(id(1), 'd'.repeat(64), 'bad_output: no', now());
  store.record(id(1), 'd'.repeat(64), 'bad_output: no', now());
  store.close();
  const db = openIndex(folder);
  try { db.raw.prepare(`INSERT INTO meta (key, value) VALUES ('last_enrich_at', ?)`).run('2026-11-12T10:00:00.000Z'); } finally { db.close(); }
  const s = status(folder);
  assert.deepEqual(s.failures, [{ id: id(1), attempts: 2, error: 'bad_output: no' }]);
  assert.equal(s.lastEnrichAt, '2026-11-12T10:00:00.000Z');
});

test('removing a capture directory removes its rows', async () => {
  const folder = copyFixtures();
  await buildIndex(folder);
  fs.rmSync(capDir(folder, 4), { recursive: true });
  const r = await buildIndex(folder);
  assert.equal(r.removed, 1); assert.equal(r.captures, 6);
  const d = dump(folder);
  for (const rows of Object.values(d)) assert.ok(rows.every(row => row.id !== id(4) && row.capture_id !== id(4)));
  assert.equal(d.captures.length, 6); assert.equal(d.fts.length, 6);
});

test('a capture that becomes incomplete is counted as pending and leaves the index', async () => {
  const folder = copyFixtures();
  await buildIndex(folder);
  fs.rmSync(path.join(capDir(folder, 3), 'complete.json'));
  const r = await buildIndex(folder);
  assert.equal(r.removed, 1);
  assert.equal(status(folder).pending, 1);
});

test('rebuild yields the same rows and keeps the enrichment failures', async () => {
  const folder = copyFixtures();
  await enrichFolder({ folder, provider: fakeProvider(), now });
  await buildIndex(folder);
  const store = openFailureStore(folder);
  store.record(id(5), 'e'.repeat(64), 'boom', now());
  store.close();
  const before = dump(folder);
  const r = await buildIndex(folder, { rebuild: true });
  assert.equal(r.added, 7); assert.equal(r.updated, 0); assert.equal(r.removed, 0);
  assert.deepEqual(dump(folder), before);
  assert.deepEqual(status(folder).failures, [{ id: id(5), attempts: 1, error: 'boom' }]);
});

test('deleting the database file and rebuilding gives the same rows, with no model call', async () => {
  const folder = copyFixtures();
  await enrichFolder({ folder, provider: fakeProvider(), now });
  await buildIndex(folder);
  const before = dump(folder);
  fs.rmSync(indexPath(folder));
  const again = await enrichFolder({ folder, provider: never(), now });
  assert.equal(again.modelCalls, 0); assert.equal(again.written, 0); assert.deepEqual(again.failed, []);
  await buildIndex(folder, { rebuild: true });
  assert.deepEqual(dump(folder), before);
});

test('a corrupt picture is indexed without its thumbnail and reported once', async () => {
  const folder = copyFixtures();
  const png = 'content/00000000-0000-4000-8000-000300000001.png';
  const junk = crypto.randomBytes(1500);
  // The metadata names the attachment's size and hash too: keep it consistent, then the manifest.
  const mdPath = path.join(capDir(folder, 3), 'metadata.json');
  const md = JSON.parse(fs.readFileSync(mdPath, 'utf8'));
  for (const a of md.attachments) if (a.relative_path === png) { a.byte_count = junk.length; a.sha256 = sha(junk); }
  replaceInCapture(folder, 3, png, junk);
  replaceInCapture(folder, 3, 'metadata.json', Buffer.from(JSON.stringify(md, null, 2)));
  const r = await buildIndex(folder);
  assert.equal(r.captures, 7);
  assert.equal(r.thumbFailures.length, 1);
  assert.equal(r.thumbFailures[0].id, id(3));
  assert.match(r.thumbFailures[0].reason, /Cannot decode/);
  const media = dump(folder).media.filter(m => m.capture_id === id(3)).map(m => m.ref);
  assert.deepEqual(media, ['00000000-0000-4000-8000-000300000001']);
});

test('media rows: originals, thumbnails, display pictures, link thumbnail, comment audio; every path inside the folder or the thumbs directory', async () => {
  const folder = copyFixtures();
  const r = await buildIndex(folder);
  const media = dump(folder).media as { capture_id: string; ref: string; path: string; mime: string }[];
  const refs = (n: number) => media.filter(m => m.capture_id === id(n)).map(m => m.ref).sort();
  const a3 = '00000000-0000-4000-8000-000300000001';
  assert.deepEqual(refs(3), [a3, `display-${a3}`, `thumb-${a3}`].sort());
  assert.ok(refs(2).includes('link-thumb'));
  assert.ok(refs(4).includes('comment-00000000-0000-4000-8000-00000000c002'));
  assert.ok(r.thumbnails >= 4, `thumbnails ${r.thumbnails}`);   // pictures in captures 3, 4 (two) and 7
  const byRef = (n: number, ref: string) => media.find(m => m.capture_id === id(n) && m.ref === ref)!;
  assert.equal(byRef(3, a3).mime, 'image/png');
  assert.equal(byRef(3, `thumb-${a3}`).mime, 'image/jpeg');
  assert.equal(byRef(3, `display-${a3}`).mime, 'image/jpeg');
  assert.equal(byRef(2, 'link-thumb').mime, 'image/jpeg');
  assert.equal(byRef(4, 'comment-00000000-0000-4000-8000-00000000c002').mime, 'audio/mp4');
  assert.equal(byRef(5, '00000000-0000-4000-8000-000500000001').mime, 'video/quicktime');
  const inside = (base: string, p: string) => { const rel = path.relative(base, p); return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel); };
  for (const m of media) {
    assert.ok(path.isAbsolute(m.path), m.path);
    assert.ok(inside(folder, m.path) || inside(thumbsDir(), m.path), m.path);
    assert.ok(fs.statSync(m.path).isFile(), m.path);
  }
});

test('openIndex coexists with the failures table in the same file', async () => {
  const folder = copyFixtures();
  const store = openFailureStore(folder);
  store.record(id(2), 'f'.repeat(64), 'first', now());
  store.close();
  const db = openIndex(folder);
  try {
    assert.equal((db.raw.prepare('PRAGMA user_version').get() as any).user_version, 1);
    assert.equal(getMeta(db, 'folder'), undefined);
  } finally { db.close(); }
  await buildIndex(folder);
  const db2 = openIndex(folder);
  try { assert.equal(getMeta(db2, 'folder'), path.resolve(folder)); } finally { db2.close(); }
  assert.deepEqual(status(folder).failures, [{ id: id(2), attempts: 1, error: 'first' }]);
});

test('status on a folder never indexed reports nothing indexed', () => {
  const folder = copyFixtures();
  const s = status(folder);
  assert.equal(s.total, 0); assert.equal(s.enriched, 0); assert.equal(s.nothingToDescribe, 0);
  assert.deepEqual(s.byKind, { note: 0, link: 0, photo: 0, video: 0, recording: 0, screenshot: 0, file: 0 });
  assert.equal(s.lastIndexAt, undefined);
});

test('a capture whose metadata.json is valid JSON of the wrong shape is skipped and reported; the others are indexed', async () => {
  const folder = copyFixtures();
  const mdPath = path.join(capDir(folder, 6), 'metadata.json');
  const good = fs.readFileSync(mdPath);
  const md = JSON.parse(good.toString('utf8'));
  md.timezone_identifier = 5; md.utc_offset_seconds = 1e20;     // wrong type, and an offset no date survives
  replaceInCapture(folder, 6, 'metadata.json', Buffer.from(JSON.stringify(md, null, 2)));

  const r = await buildIndex(folder);
  assert.equal(r.captures, 7);
  assert.equal(r.added, 6);
  assert.deepEqual(r.failed.map(f => f.id), [id(6)]);
  assert.ok(r.failed[0].reason.length > 0);
  const rows = dump(folder);
  assert.deepEqual(rows.captures.map(c => c.id), [1, 2, 3, 4, 5, 7].map(id));
  assert.ok(rows.media.every(m => m.capture_id !== id(6)) && rows.fts.every(f => f.id !== id(6)), 'nothing half-written');
  assert.deepEqual(status(folder).indexFailures, r.failed);

  replaceInCapture(folder, 6, 'metadata.json', good);
  const fixed = await buildIndex(folder);
  assert.deepEqual(fixed.failed, []);
  assert.equal(fixed.added, 1);
  assert.deepEqual(status(folder).indexFailures, []);
});

/** Every capture in exactly one place: enriched, nothing to describe, not described yet, failed; pending ones are not indexed. */
function assertAddsUp(s: Status) {
  assert.equal(s.enriched + s.nothingToDescribe + s.notDescribed + s.failures.length, s.total, JSON.stringify(s));
}

test('status accounts for every capture: indexed only, after an enrich, and with one enrichment document deleted', async () => {
  // (a) a fixtures copy, indexed only.
  const folder = copyFixtures();
  await buildIndex(folder);
  let s = status(folder);
  assert.deepEqual([s.total, s.enriched, s.nothingToDescribe, s.notDescribed, s.pending, s.failures.length], [7, 0, 2, 5, 0, 0]);
  assertAddsUp(s);
  // (b) the same after a fake-provider enrich.
  await enrichFolder({ folder, provider: fakeProvider(), now });
  await buildIndex(folder);
  s = status(folder);
  assert.deepEqual([s.total, s.enriched, s.nothingToDescribe, s.notDescribed, s.pending, s.failures.length], [7, 5, 2, 0, 0, 0]);
  assertAddsUp(s);
  // (c) a sample folder with one capture's enrichment document deleted.
  const sample = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-sample-')), 'sample');
  await writeSample({ out: sample, count: 40, seed: 3, end: '2026-11-12' });
  const victim = (await scanFolder(sample)).captures.find(c => hasContent(modelInput(c)) && c.server)!;
  fs.rmSync(victim.serverPath);
  await buildIndex(sample);
  s = status(sample);
  assert.equal(s.total, 40);
  assert.equal(s.notDescribed, 1);
  assertAddsUp(s);
});

test('a capture with a failure is counted once, as a failure, even when an older enrichment is on it', async () => {
  const folder = copyFixtures();
  await enrichFolder({ folder, provider: fakeProvider(), now });
  await buildIndex(folder);
  const store = openFailureStore(folder);
  store.record(id(1), 'e'.repeat(64), 'boom', now());                           // enriched before, failed since
  store.record('00000000-0000-4000-8000-0000000000ff', 'e'.repeat(64), 'gone', now()); // no longer in the folder
  store.close();
  const s = status(folder);
  assert.deepEqual([s.enriched, s.nothingToDescribe, s.notDescribed, s.failures.length, s.total], [4, 2, 0, 1, 7]);
  assert.deepEqual(s.failures, [{ id: id(1), attempts: 1, error: 'boom' }]);
  assertAddsUp(s);
});
