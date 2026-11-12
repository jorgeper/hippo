import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { copyFixtures, enrichmentErrors, snapshot } from './helpers.ts';
import { enrichFolder } from '../src/enrich/enrich.ts';
import { openFailureStore } from '../src/enrich/state.ts';
import { fakeEnrichment, fakeProvider } from '../src/providers/fake.ts';
import { ProviderError } from '../src/providers/types.ts';
import { DatabaseSync } from 'node:sqlite';
import { indexPath } from '../src/core/paths.ts';
import type { ModelRequest } from '../src/providers/types.ts';

const id = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;
const capDir = (folder: string, n: number) => path.join(folder, 'captures/2026/11/07', id(n));
const serverDoc = (folder: string, n: number) => path.join(folder, 'enrichments/server/2026/11/07', id(n), 'enrichment.json');
const deviceDoc = (folder: string, n: number) => path.join(folder, 'enrichments/device/2026/11/07', id(n), 'enrichment.json');
const now = () => new Date('2026-11-12T10:00:00Z');
const never = () => fakeProvider(() => { throw new Error('must not be called'); });

function allServerDocs(folder: string): string[] {
  return Object.keys(snapshot(folder)).filter(p => p.startsWith('enrichments/server/')).map(p => path.join(folder, p));
}

test('first run enriches, second run does nothing', async () => {
  const folder = copyFixtures(); const before = snapshot(folder);
  const r1 = await enrichFolder({ folder, provider: fakeProvider(), now });
  assert.equal(r1.captures, 7); assert.equal(r1.failed.length, 0);
  assert.equal(r1.modelCalls, 5);        // 1 note, 2 link, 3 photo, 4 mixed, 7 context; 5 (video, no text) and 6 (silent audio) have nothing to send
  assert.equal(r1.written, 5); assert.equal(r1.unchanged, 2);
  const after = snapshot(folder);
  for (const [p, h] of Object.entries(before)) if (!p.startsWith('enrichments/server/')) assert.equal(after[p], h);
  for (const p of Object.keys(after)) if (!(p in before)) assert.match(p, /^enrichments\/server\/\d{4}\/\d\d\/\d\d\/[0-9a-f-]{36}\/enrichment\.json$/);
  const r2 = await enrichFolder({ folder, provider: never() });
  assert.equal(r2.modelCalls, 0); assert.equal(r2.written, 0); assert.deepEqual(snapshot(folder), after);
  assert.equal(r2.unchanged, 7);
});

test('every document written validates against the schema; fake answers land in the facets', async () => {
  const folder = copyFixtures();
  await enrichFolder({ folder, provider: fakeProvider(), now });
  const docs = allServerDocs(folder);
  assert.equal(docs.length, 5);
  for (const p of docs) assert.deepEqual(enrichmentErrors(JSON.parse(fs.readFileSync(p, 'utf8'))), [], p);
  const d1 = JSON.parse(fs.readFileSync(serverDoc(folder, 1), 'utf8'));
  assert.equal(d1.facets.display.data.title, 'Call the plumber about the upstairs');
  assert.equal(d1.facets.display.provenance, 'fake:fake');
  assert.deepEqual(d1.facets.tags.data.values, ['fake', 'note']);
  const d3 = JSON.parse(fs.readFileSync(serverDoc(folder, 3), 'utf8'));
  assert.equal(d3.facets.display.data.title, 'Untitled photo');
  assert.deepEqual(d3.facets.image_description.data.items, [{ attachment_id: '00000000-0000-4000-8000-000300000001', text: 'Fake description of 00000000-0000-4000-8000-000300000001.' }]);
  const d7 = JSON.parse(fs.readFileSync(serverDoc(folder, 7), 'utf8'));
  assert.equal(d7.producer.name, 'hippo-desk');
  assert.equal(d7.facets.circumstance.generated_at, '2026-11-07T18:00:00.000Z', 'unchanged rule facet keeps its old object');
  assert.equal(d7.facets.people, undefined, 'the fixture people facet is replaced by the (empty) model answer');
  assert.ok(fs.readFileSync(serverDoc(folder, 7), 'utf8').endsWith('\n'));
  // Thumbnails and the failures table live under HIPPO_DESK_HOME, never in the folder.
  assert.ok(fs.readdirSync(path.join(process.env.HIPPO_DESK_HOME!, 'thumbs')).length > 0);
});

test('the model is shown pictures as display JPEGs from the thumbnail directory, named by attachment id', async () => {
  const folder = copyFixtures();
  const seen: ModelRequest[] = [];
  await enrichFolder({ folder, provider: fakeProvider(req => { seen.push(req); return fakeEnrichment(req); }), now });
  const r4 = seen.find(r => r.prompt.includes('Bought this one.'))!;
  assert.equal(r4.images?.length, 2);
  for (const p of r4.images!) { assert.ok(p.startsWith(path.join(process.env.HIPPO_DESK_HOME!, 'thumbs'))); assert.match(p, /-1024\.jpg$/); }
  assert.ok(r4.prompt.includes('00000000-0000-4000-8000-000400000001') && r4.prompt.includes('00000000-0000-4000-8000-000400000002'));
  assert.ok(r4.prompt.split('\n').includes('TASK: enrich'));
  assert.equal(r4.model, 'haiku');
  assert.ok(seen.every(r => r.system === seen[0].system && r.system.length > 0));
});

test('topics in use are listed in the prompt and grow during the run', async () => {
  const folder = copyFixtures();
  const prompts: string[] = [];
  await enrichFolder({ folder, concurrency: 1, now, provider: fakeProvider(req => { prompts.push(req.prompt); return { ...(fakeEnrichment(req) as object), topic: `t${prompts.length}` }; }) });
  assert.match(prompts[0], /food/);                     // fixture 7's display.topic
  assert.match(prompts[1], /\bt1\b/);
  assert.match(prompts[4], /\bt4\b/);
});

test('noModel on the untouched fixtures writes nothing (rules reproduce the fixture circumstance facet)', async () => {
  const folder = copyFixtures(); const before = snapshot(folder);
  const r = await enrichFolder({ folder, noModel: true, now });
  assert.equal(r.written, 0); assert.equal(r.modelCalls, 0); assert.equal(r.unchanged, 7);
  assert.deepEqual(snapshot(folder), before);
});

test('noModel after deleting capture 7 server document writes only circumstance for 7', async () => {
  const folder = copyFixtures();
  fs.rmSync(serverDoc(folder, 7));
  const before = snapshot(folder);
  const r = await enrichFolder({ folder, noModel: true, provider: never(), now });
  assert.equal(r.written, 1); assert.equal(r.modelCalls, 0);
  const after = snapshot(folder);
  assert.deepEqual(Object.keys(after).filter(p => !(p in before)), [`enrichments/server/2026/11/07/${id(7)}/enrichment.json`]);
  const doc = JSON.parse(fs.readFileSync(serverDoc(folder, 7), 'utf8'));
  assert.deepEqual(Object.keys(doc.facets), ['circumstance']);
  assert.equal(doc.facets.circumstance.provenance, 'rules');
  assert.deepEqual(enrichmentErrors(doc), []);
});

test('dryRun reports what it would call and write and changes no file', async () => {
  const folder = copyFixtures(); const before = snapshot(folder);
  const home = process.env.HIPPO_DESK_HOME!;
  const r = await enrichFolder({ folder, dryRun: true, provider: never(), now });
  assert.equal(r.modelCalls, 0); assert.equal(r.written, 0);
  assert.deepEqual(r.wouldCall, [1, 2, 3, 4, 7].map(id));
  assert.deepEqual(r.wouldWrite, [1, 2, 3, 4, 7].map(id));
  assert.deepEqual(snapshot(folder), before);
  assert.deepEqual(fs.readdirSync(home), [], 'dry run creates no database or thumbnails');
});

test('dryRun with noModel lists only rule-made writes', async () => {
  const folder = copyFixtures();
  fs.rmSync(serverDoc(folder, 7));
  const r = await enrichFolder({ folder, dryRun: true, noModel: true, now });
  assert.deepEqual(r.wouldCall, []); assert.deepEqual(r.wouldWrite, [id(7)]);
  assert.equal(fs.existsSync(serverDoc(folder, 7)), false);
});

test('limit caps the model calls; the rest wait for the next run', async () => {
  const folder = copyFixtures();
  const r = await enrichFolder({ folder, provider: fakeProvider(), limit: 3, now });
  assert.equal(r.modelCalls, 3); assert.equal(r.written, 3);
  assert.equal(allServerDocs(folder).length, 4);       // 1, 2, 3 written; 7 untouched fixture
  const r2 = await enrichFolder({ folder, provider: fakeProvider(), now });
  assert.equal(r2.modelCalls, 2);
});

test('changing capture 4 comment text calls the model for capture 4 only', async () => {
  const folder = copyFixtures();
  await enrichFolder({ folder, provider: fakeProvider(), now });
  const p = path.join(capDir(folder, 4), 'comments/00000000-0000-4000-8000-00000000c001.json');
  const j = JSON.parse(fs.readFileSync(p, 'utf8')); j.text = 'Bought this one, twice.'; fs.writeFileSync(p, JSON.stringify(j));
  const prompts: string[] = [];
  const r = await enrichFolder({ folder, provider: fakeProvider(req => { prompts.push(req.prompt); return fakeEnrichment(req); }), now });
  assert.equal(r.modelCalls, 1); assert.equal(r.written, 1);
  assert.ok(prompts[0].includes('Bought this one, twice.'));
});

test('a weather facet added to capture 3 device document causes no model call', async () => {
  const folder = copyFixtures();
  await enrichFolder({ folder, provider: fakeProvider(), now });
  const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join(capDir(folder, 3), 'complete.json'))).digest('hex');
  fs.mkdirSync(path.dirname(deviceDoc(folder, 3)), { recursive: true });
  fs.writeFileSync(deviceDoc(folder, 3), JSON.stringify({ schema_version: 1, schema_minor: 1, capture_id: id(3), layer: 'device', package_digest: digest,
    producer: { name: 'test', version: '1', build: '1' }, generated_at: '2026-11-07T18:00:00.000Z',
    facets: { weather: { version: 1, status: 'ok', generated_at: '2026-11-07T18:00:00.000Z', provenance: 'open_meteo',
      data: { observed_hour: '2026-11-07T17:00:00.000Z', is_day: true, source: 'open-meteo.com', requested_latitude: 37.77, requested_longitude: -122.42 } } } }));
  const r = await enrichFolder({ folder, provider: never(), now });
  assert.equal(r.modelCalls, 0); assert.equal(r.failed.length, 0); assert.equal(r.written, 1);
  const doc = JSON.parse(fs.readFileSync(serverDoc(folder, 3), 'utf8'));
  assert.equal(doc.facets.circumstance.data.items[0].label, 'daylight');
  assert.ok(doc.facets.display, 'model facets carried over');
});

test('failures are retried at most three times per digest, then skipped', async () => {
  const folder = copyFixtures();
  const bad = () => fakeProvider(() => { throw new ProviderError('failed', 'boom'); });
  for (let i = 1; i <= 3; i++) {
    const r = await enrichFolder({ folder, provider: bad(), now });
    assert.equal(r.modelCalls, 5, `run ${i}`); assert.equal(r.failed.length, 5); assert.equal(r.written, 0);
    assert.match(r.failed[0].reason, /boom/);
  }
  const store = openFailureStore(folder);
  assert.equal(store.get(id(1))?.attempts, 3);
  store.close();
  const r4 = await enrichFolder({ folder, provider: never(), now });
  assert.equal(r4.modelCalls, 0); assert.equal(r4.skippedAfterRetries, 5);
  // A changed digest resets the count; success deletes the row.
  fs.appendFileSync(path.join(capDir(folder, 1), 'content/00000000-0000-4000-8000-000100000001.txt'), '');
  const p = path.join(capDir(folder, 4), 'comments/00000000-0000-4000-8000-00000000c001.json');
  const j = JSON.parse(fs.readFileSync(p, 'utf8')); j.text = 'Changed.'; fs.writeFileSync(p, JSON.stringify(j));
  const r5 = await enrichFolder({ folder, provider: fakeProvider(), now });
  assert.equal(r5.modelCalls, 1); assert.equal(r5.skippedAfterRetries, 4);
  const s2 = openFailureStore(folder);
  assert.equal(s2.get(id(4)), undefined); assert.equal(s2.get(id(1))?.attempts, 3);
  s2.close();
});

test('a bad answer is a failure, not a write', async () => {
  const folder = copyFixtures();
  const r = await enrichFolder({ folder, provider: fakeProvider(() => 'hello'), now });
  assert.equal(r.failed.length, 5); assert.equal(r.written, 0);
  assert.match(r.failed[0].reason, /bad_output/);
});

test('usage_limit on the third call stops new calls and records no failure', async () => {
  const folder = copyFixtures();
  const concurrency = 2;
  let calls = 0;
  const provider = fakeProvider(async req => {
    const n = ++calls;
    if (n === 3) { await delay(10); throw new ProviderError('usage_limit', 'limit reached'); }
    if (n > 3) await delay(40);               // still in flight when the third call fails
    return fakeEnrichment(req);
  });
  const r = await enrichFolder({ folder, provider, concurrency, now });
  assert.equal(r.stoppedBy, 'usage_limit');
  assert.ok(calls <= 3 + (concurrency - 1), `calls ${calls}`);
  assert.ok(r.deferred >= 1, `deferred ${r.deferred}`);
  assert.equal(r.failed.length, 0);
  const store = openFailureStore(folder);
  assert.deepEqual(store.all(), []);
  store.close();
});

test('not_signed_in stops the run with the error as the reason', async () => {
  const folder = copyFixtures();
  const r = await enrichFolder({ folder, concurrency: 1, now, provider: fakeProvider(() => { throw new ProviderError('not_signed_in', 'claude is not signed in'); }) });
  assert.equal(r.stoppedBy, 'not_signed_in'); assert.equal(r.stopReason, 'claude is not signed in');
  assert.equal(r.modelCalls, 1); assert.equal(r.failed.length, 0);
});

test('a pending capture is skipped and nothing is written for it', async () => {
  const folder = copyFixtures();
  fs.rmSync(path.join(capDir(folder, 3), 'complete.json'));
  const r = await enrichFolder({ folder, provider: fakeProvider(), now });
  assert.equal(r.captures, 6); assert.equal(r.pending, 1); assert.equal(r.modelCalls, 4);
  assert.equal(fs.existsSync(path.dirname(serverDoc(folder, 3))), false);
});

test('a capture with an unreadable server document keeps its bytes', async () => {
  const folder = copyFixtures();
  fs.writeFileSync(serverDoc(folder, 2), '{not json');
  const r = await enrichFolder({ folder, provider: fakeProvider(), now });
  assert.deepEqual(r.failed, [{ id: id(2), reason: 'existing server document is unreadable' }]);
  assert.equal(fs.readFileSync(serverDoc(folder, 2), 'utf8'), '{not json');
  assert.equal(r.modelCalls, 4);
});

test('concurrency never exceeds 3', async () => {
  const folder = copyFixtures();
  let active = 0, peak = 0;
  const provider = fakeProvider(async req => {
    active++; peak = Math.max(peak, active);
    await delay(15);
    active--;
    return fakeEnrichment(req);
  });
  const r = await enrichFolder({ folder, provider, now });
  assert.equal(r.modelCalls, 5); assert.ok(peak <= 3, `peak ${peak}`); assert.ok(peak > 1, `peak ${peak}`);
});

test('a document over 1 MiB is a failure, not a write', async () => {
  const folder = copyFixtures();
  const r = await enrichFolder({ folder, now, provider: fakeProvider(req => ({ ...(fakeEnrichment(req) as object), summary: 'x'.repeat(1_100_000) })) });
  assert.equal(r.written, 0); assert.equal(r.failed.length, 5);
  assert.match(r.failed[0].reason, /1 MiB/);
});

test('a non-numeric concurrency falls back to 3 and still makes every call', async () => {
  const folder = copyFixtures();
  const r = await enrichFolder({ folder, provider: fakeProvider(), concurrency: NaN as number, now });
  assert.equal(r.modelCalls, 5); assert.equal(r.written, 5);
});

const TEMP = '.enrichment.json.12345.0a1b2c3d.tmp';
const age = (p: string, seconds: number) => { const t = new Date(Date.now() - seconds * 1000); fs.utimesSync(p, t, t); };

test('a stale temp file is swept; enrichment.json beside it stays byte-identical', async () => {
  const folder = copyFixtures();
  const dir = path.dirname(serverDoc(folder, 2));
  const before = fs.readFileSync(serverDoc(folder, 2));
  fs.writeFileSync(path.join(dir, TEMP), '{"half":'); age(path.join(dir, TEMP), 120);
  const r = await enrichFolder({ folder, noModel: true, now });
  assert.equal(r.tempFilesRemoved, 1);
  assert.deepEqual(fs.readdirSync(dir), ['enrichment.json']);
  assert.deepEqual(fs.readFileSync(serverDoc(folder, 2)), before);
});

test('a fresh temp file and files that do not match the pattern are never touched', async () => {
  const folder = copyFixtures();
  const dir = path.dirname(serverDoc(folder, 2));
  const others = ['enrichment.json.bak', '.enrichment.json.tmp', '.enrichment.json.777.ABCDEF01.tmp', 'x.enrichment.json.1.0a1b2c3d.tmp'];
  for (const n of others) { fs.writeFileSync(path.join(dir, n), 'keep'); age(path.join(dir, n), 3600); }
  fs.writeFileSync(path.join(dir, TEMP), 'in progress elsewhere');
  const r = await enrichFolder({ folder, provider: fakeProvider(), now });
  assert.equal(r.tempFilesRemoved, 0);
  assert.deepEqual(fs.readdirSync(dir).sort(), [...others, TEMP, 'enrichment.json'].sort());
});

test('dryRun removes no temp file and lists it', async () => {
  const folder = copyFixtures();
  const dir = path.dirname(serverDoc(folder, 7));
  fs.writeFileSync(path.join(dir, TEMP), ''); age(path.join(dir, TEMP), 120);
  const before = snapshot(folder);
  const r = await enrichFolder({ folder, dryRun: true, now });
  assert.equal(r.tempFilesRemoved, 0);
  assert.deepEqual(r.wouldRemove, [path.join(dir, TEMP)]);
  assert.deepEqual(snapshot(folder), before);
});

test('an abort stops new calls and writes, lets the call in flight finish, records no failure', async () => {
  const folder = copyFixtures();
  const ac = new AbortController();
  let calls = 0;
  const provider = fakeProvider(req => { if (++calls === 2) ac.abort(); return fakeEnrichment(req); });
  const r = await enrichFolder({ folder, provider, concurrency: 1, signal: ac.signal, now });
  assert.equal(r.modelCalls, 2); assert.equal(calls, 2);
  assert.equal(r.stoppedBy, 'interrupted');
  assert.ok(r.deferred >= 1, `deferred ${r.deferred}`);
  assert.equal(r.failed.length, 0);
  assert.ok(Object.keys(snapshot(folder)).every(p => !p.endsWith('.tmp')));
  const store = openFailureStore(folder);
  assert.deepEqual(store.all(), []);
  store.close();
});

test('an abort during the pass over captures that need no model stops further writes', async () => {
  const folder = copyFixtures();
  const ac = new AbortController(); ac.abort();
  fs.rmSync(serverDoc(folder, 7));
  const r = await enrichFolder({ folder, noModel: true, signal: ac.signal, now });
  assert.equal(r.stoppedBy, 'interrupted'); assert.equal(r.written, 0);
  assert.equal(fs.existsSync(serverDoc(folder, 7)), false);
});

test('a failures-table error is reported for that capture and never rejects the run', async () => {
  const folder = copyFixtures();
  let calls = 0;
  const provider = fakeProvider(req => {
    if (++calls === 1) {
      const db = new DatabaseSync(indexPath(folder)); db.exec('DROP TABLE enrich_failures'); db.close();
      throw new ProviderError('failed', 'boom');
    }
    return fakeEnrichment(req);
  });
  const r = await enrichFolder({ folder, provider, concurrency: 1, now });
  assert.equal(r.modelCalls, 5); assert.equal(r.written, 4);
  assert.equal(r.failed.length, 1);
  assert.match(r.failed[0].reason, /boom/);
  assert.match(r.failed[0].reason, /could not record/);
  assert.ok(r.warnings.length >= 1 && r.warnings.every(w => /failures table/.test(w)), JSON.stringify(r.warnings));
});

test('a server document whose facets is not an object is reported and keeps its bytes', async () => {
  const folder = copyFixtures();
  const text = '{"schema_version":1,"layer":"server","facets":[]}';
  fs.writeFileSync(serverDoc(folder, 2), text);
  const r = await enrichFolder({ folder, provider: fakeProvider(), now });
  assert.deepEqual(r.failed, [{ id: id(2), reason: 'existing server document is unreadable' }]);
  assert.equal(fs.readFileSync(serverDoc(folder, 2), 'utf8'), text);
});
