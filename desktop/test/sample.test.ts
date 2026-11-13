import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Ajv2020 } from 'ajv/dist/2020.js';
import { enrichmentErrors, fixturesDir, snapshot } from './helpers.ts';
import { scanFolder } from '../src/core/folder.ts';
import { enrichFolder } from '../src/enrich/enrich.ts';
import { fakeProvider } from '../src/providers/fake.ts';
import { buildIndex } from '../src/index/build.ts';
import { openIndex } from '../src/index/db.ts';
import { facets, search } from '../src/recall/engine.ts';
import { linkThumb, mulberry32, screen, writeSample } from '../src/index/sample.ts';
import { PAGES, SCREENS, YOUTUBE_SHORTS, YOUTUBE_VIDEOS } from '../src/index/sample-data.ts';

const here = path.dirname(new URL(import.meta.url).pathname);
const schemaDir = path.resolve(here, '../../schema');
const ajv = new Ajv2020({ allErrors: true, strictTypes: false });
ajv.addFormat('date-time', /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
const compile = (name: string) => ajv.compile(JSON.parse(fs.readFileSync(path.join(schemaDir, name), 'utf8')));
const metadataSchema = compile('capture-metadata-v1.schema.json');
const completeSchema = compile('complete-v1.schema.json');
const commentSchema = compile('capture-comment-v1.schema.json');

const never = () => fakeProvider(() => { throw new Error('must not be called'); });
const tmp = (prefix: string) => fs.mkdtempSync(path.join(os.tmpdir(), prefix));

process.env.HIPPO_DESK_HOME = tmp('hippo-home-');
const base = tmp('hippo-sample-');
const folder = path.join(base, 'sample');
const written = await writeSample({ out: folder, count: 60, seed: 1, end: '2026-11-12' });
const first = snapshot(folder);

/** Every file under `dir`, absolute. */
function files(dir: string): string[] {
  const out: string[] = [];
  const walk = (d: string) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, e.name);
      if (e.isDirectory()) walk(full); else out.push(full);
    }
  };
  walk(dir);
  return out.sort();
}

test('writeSample reports 60 captures and scanFolder reads 60 complete captures, none pending', async () => {
  assert.equal(written.captures, 60);
  const scan = await scanFolder(folder);
  assert.equal(scan.captures.length, 60);
  assert.deepEqual(scan.pending, []);
  for (const c of scan.captures) {
    assert.ok(c.device, `${c.id} has a device enrichment for its package`);
    assert.ok(c.server, `${c.id} has a server enrichment`);
    assert.equal(c.server!.package_digest, c.packageDigest);
  }
});

test('every metadata.json, complete.json, comment and enrichment.json validates against the repository schemas', () => {
  const counts = { metadata: 0, complete: 0, comment: 0, enrichment: 0 };
  for (const f of files(folder)) {
    const rel = path.relative(folder, f).split(path.sep).join('/');
    if (!rel.endsWith('.json')) continue;
    const doc = JSON.parse(fs.readFileSync(f, 'utf8'));
    let errors: string[] = [];
    const check = (v: ReturnType<typeof compile>) => (v(doc) ? [] : (v.errors ?? []).map(e => `${e.instancePath} ${e.message}`));
    if (rel.startsWith('captures/') && rel.endsWith('/metadata.json')) { errors = check(metadataSchema); counts.metadata++; }
    else if (rel.startsWith('captures/') && rel.endsWith('/complete.json')) { errors = check(completeSchema); counts.complete++; }
    else if (/^captures\/.*\/comments\/[^/]+\.json$/.test(rel)) { errors = check(commentSchema); counts.comment++; }
    else if (rel.startsWith('enrichments/') && rel.endsWith('/enrichment.json')) { errors = enrichmentErrors(doc); counts.enrichment++; }
    else assert.fail(`unexpected JSON file ${rel}`);
    assert.deepEqual(errors, [], rel);
    assert.equal(doc.schema_minor, 2, `${rel} is format 1.2`);
  }
  assert.equal(counts.metadata, 60);
  assert.equal(counts.complete, 60);
  assert.equal(counts.enrichment, 120, 'one device and one server document per capture');
  assert.ok(counts.comment > 0, 'some captures carry comments');
});

test('local_datetime and utc_offset_seconds agree with captured_at in Europe/Lisbon, on both sides of the October change', async () => {
  const scan = await scanFolder(folder);
  const offsets = new Set<number>();
  for (const c of scan.captures) {
    const md = c.metadata;
    assert.equal(md.timezone_identifier, 'Europe/Lisbon');
    const t = new Date(md.captured_at).getTime();
    const local = new Date(Math.floor(t / 1000) * 1000 + md.utc_offset_seconds * 1000).toISOString().slice(0, 19);
    const sign = md.utc_offset_seconds < 0 ? '-' : '+';
    const h = String(Math.floor(Math.abs(md.utc_offset_seconds) / 3600)).padStart(2, '0');
    assert.equal(md.local_datetime, `${local}${sign}${h}:00`, c.id);
    assert.equal(c.datePath, local.slice(0, 10).replace(/-/g, '/'), `${c.id} sits under its local date`);
    offsets.add(md.utc_offset_seconds);
    const zoneOffset = (Date.parse(new Date(t).toLocaleString('sv-SE', { timeZone: 'Europe/Lisbon' }).replace(' ', 'T') + 'Z') - Math.floor(t / 1000) * 1000) / 1000;
    assert.equal(md.utc_offset_seconds, zoneOffset, `${c.id} offset is Lisbon's at that instant`);
  }
  assert.deepEqual([...offsets].sort(), [0, 3600], 'captures from before and after the last Sunday of October');
});

test('after buildIndex: all seven kinds; YouTube last week; in the car; six people; 5 to 10 topics', async () => {
  await buildIndex(folder);
  const db = openIndex(folder);
  try {
    const f = facets(db);
    for (const k of ['link', 'photo', 'screenshot', 'note', 'recording', 'video', 'file']) assert.ok(f.kinds[k] > 0, `kind ${k} occurs`);
    const week = { sites: ['youtube.com'], time: { from: '2026-11-06', to: '2026-11-12' } };
    const yt = search(db, week);
    assert.ok(yt.total >= 8, `YouTube last week: ${yt.total}`);
    assert.ok(yt.items.filter(r => r.link?.url.includes('/shorts/')).length >= 3, 'at least 3 shorts among them');
    const car = search(db, { ...week, circumstances: { labels: ['in_car'] } });
    assert.ok(car.total >= 3, `YouTube last week in the car: ${car.total}`);
    assert.equal(f.people.length, 6, JSON.stringify(f.people));
    assert.ok(f.topics.length >= 5 && f.topics.length <= 10, `topics: ${f.topics.length}`);
    assert.ok(f.localities.some(l => l.value === 'Lisboa'));
    const all = search(db, { limit: 5000 });
    assert.equal(all.total, 60);
    assert.ok(all.items.every(r => r.enriched), 'every capture counts as enriched');
    const unlocated = all.items.filter(r => !r.place).length;
    assert.ok(unlocated > 0 && unlocated < 20, `unlocated: ${unlocated}`);
  } finally { db.close(); }
});

test('the same seed, count and end give a byte-identical folder', async () => {
  const other = path.join(base, 'again');
  await writeSample({ out: other, count: 60, seed: 1, end: '2026-11-12' });
  assert.deepEqual(snapshot(other), first);
  const seed2 = path.join(base, 'seed2');
  await writeSample({ out: seed2, count: 60, seed: 2, end: '2026-11-12' });
  assert.notDeepEqual(snapshot(seed2), first, 'another seed gives another folder');
});

test('hippo enrich has nothing to do on a sample folder', async () => {
  const before = snapshot(folder);
  const noModel = await enrichFolder({ folder, noModel: true });
  assert.equal(noModel.written, 0);
  assert.equal(noModel.unchanged, 60);
  const dry = await enrichFolder({ folder, dryRun: true, provider: never() });
  assert.deepEqual(dry.wouldCall, [], 'a dry run plans no model call');
  assert.deepEqual(dry.wouldWrite, []);
  const real = await enrichFolder({ folder, provider: never() });
  assert.equal(real.modelCalls, 0);
  assert.equal(real.written, 0);
  assert.deepEqual(real.failed, []);
  assert.deepEqual(snapshot(folder), before, 'nothing in the folder changed');
});

test('refuses a non-empty out, an out inside fixtures/, and an out inside a Hippo folder', async () => {
  const full = tmp('hippo-full-');
  fs.writeFileSync(path.join(full, 'x.txt'), 'x');
  await assert.rejects(writeSample({ out: full, count: 10 }), /not empty/);
  assert.deepEqual(fs.readdirSync(full), ['x.txt']);
  await assert.rejects(writeSample({ out: folder, count: 10 }), /not empty/);
  await assert.rejects(writeSample({ out: path.join(fixturesDir, 'sample-out'), count: 10 }), /fixtures/);
  assert.equal(fs.existsSync(path.join(fixturesDir, 'sample-out')), false);
  await assert.rejects(writeSample({ out: path.join(folder, 'enrichments', 'more'), count: 10 }), /Hippo folder/);
  assert.equal(fs.existsSync(path.join(folder, 'enrichments', 'more')), false);
  // Only a real Hippo-shaped ancestor refuses: captures/ with a year directory, or captures/ beside enrichments/.
  const home = tmp('hippo-unrelated-');
  fs.mkdirSync(path.join(home, 'captures', 'holiday-photos'), { recursive: true });
  const r1 = await writeSample({ out: path.join(home, 'projects', 'sample'), count: 8, end: '2026-11-12' });
  assert.equal(r1.captures, 8, 'an unrelated captures/ folder higher up does not refuse');
  const yearShaped = tmp('hippo-year-');
  fs.mkdirSync(path.join(yearShaped, 'captures', '2026'), { recursive: true });
  await assert.rejects(writeSample({ out: path.join(yearShaped, 'sub', 'sample'), count: 8 }), /Hippo folder/);
  const layered = tmp('hippo-layered-');
  fs.mkdirSync(path.join(layered, 'captures'));
  fs.mkdirSync(path.join(layered, 'enrichments'));
  await assert.rejects(writeSample({ out: path.join(layered, 'sample'), count: 8 }), /Hippo folder/);
  assert.equal(fs.existsSync(path.join(layered, 'sample')), false);
  const empty = tmp('hippo-empty-');
  const r = await writeSample({ out: empty, count: 10, end: '2026-11-12' });
  assert.equal(r.captures, 10, 'an existing empty directory is fine');
});

/** Saturated red fills (R >= 0xc0, G and B <= 0x40), and named or short red. */
function redFills(svg: string): string[] {
  const out: string[] = [];
  for (const m of svg.matchAll(/(?:fill|stroke|stop-color)="([^"]+)"/gi)) {
    const v = m[1].toLowerCase();
    if (v === 'red' || v === '#f00') { out.push(v); continue; }
    const h = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/.exec(v);
    if (h && parseInt(h[1], 16) >= 0xc0 && parseInt(h[2], 16) <= 0x40 && parseInt(h[3], 16) <= 0x40) out.push(v);
  }
  return out;
}

test('drawn link thumbnails and screenshots imitate no brand: no red play button, no brand background colours', () => {
  const r = mulberry32(7);
  const thumbs = [
    ...YOUTUBE_VIDEOS.map(video => ({ what: `video ${video.title}`, svg: linkThumb({ kind: 'link', video, short: false }, r) })),
    ...YOUTUBE_SHORTS.map(video => ({ what: `short ${video.title}`, svg: linkThumb({ kind: 'link', video, short: true }, r) })),
    ...PAGES.map(page => ({ what: `page ${page.host}`, svg: linkThumb({ kind: 'link', page }, r) })),
    ...SCREENS.map(item => ({ what: `screen ${item.style}`, svg: screen(item, 'Marta', '9:41', false, r).svg })),
  ];
  for (const t of thumbs) {
    assert.deepEqual(redFills(t.svg), [], `${t.what} has a saturated red fill`);
    for (const brand of ['#e62117', '#ff0000', '#24292e', '#f4f1ea']) assert.ok(!t.svg.toLowerCase().includes(brand), `${t.what} uses ${brand}`);
  }
});

test('the folder names no real person and holds no email address', () => {
  for (const f of files(folder)) {
    if (!/\.(json|txt|csv|md|pdf)$/.test(f)) continue;
    const text = fs.readFileSync(f, 'latin1').toLowerCase();
    for (const bad of ['jorge', 'pereira', '@']) assert.ok(!text.includes(bad), `${path.relative(folder, f)} contains ${bad}`);
  }
});
