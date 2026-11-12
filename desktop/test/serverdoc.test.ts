import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { copyFixtures, enrichmentErrors } from './helpers.ts';
import { scanFolder } from '../src/core/folder.ts';
import { composeServerDoc, facetsDiffer, writeServerDoc, OWNED_KINDS } from '../src/enrich/serverdoc.ts';
import type { ModelEnrichment } from '../src/enrich/normalize.ts';
import type { RawCapture } from '../src/core/types.ts';

const now = new Date('2026-11-12T10:00:00Z');
const value: ModelEnrichment = { title: 'Example page', summary: 'A sample page.', image_descriptions: [], tags: ['example', 'web'],
  topic: 'reference', people: [], keywords: [] };

async function fixture(n: number): Promise<RawCapture> {
  const s = await scanFolder(copyFixtures());
  return s.captures.find(c => c.id.endsWith(`00${n}`))!;
}

test('the seven owned kinds', () => {
  assert.deepEqual([...OWNED_KINDS], ['summary', 'tags', 'display', 'image_description', 'people', 'circumstance', 'hippo_desk_state']);
});

test('capture 2: link_preview kept, summary and tags replaced, display and hippo_desk_state added', async () => {
  const c = await fixture(2);
  const before = structuredClone(c.server!.facets.link_preview);
  const doc = composeServerDoc(c, { model: { value, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now })!;
  assert.deepEqual(doc.facets.link_preview, before);
  assert.deepEqual(doc.facets.summary, { version: 1, status: 'ok', generated_at: '2026-11-12T10:00:00.000Z', provenance: 'fake:fake', data: { text: 'A sample page.' } });
  assert.deepEqual(doc.facets.tags.data, { values: ['example', 'web'] });
  assert.deepEqual(doc.facets.display.data, { title: 'Example page', topic: 'reference' });
  assert.deepEqual(doc.facets.hippo_desk_state, { version: 1, status: 'ok', generated_at: '2026-11-12T10:00:00.000Z', provenance: 'hippo-desk',
    data: { input_digest: 'b'.repeat(64), prompt_version: 1 } });
  assert.equal(doc.facets.people, undefined); assert.equal(doc.facets.image_description, undefined); assert.equal(doc.facets.circumstance, undefined);
  assert.equal(doc.schema_version, 1); assert.equal(doc.schema_minor, 2); assert.equal(doc.layer, 'server');
  assert.equal(doc.capture_id, c.id); assert.equal(doc.package_digest, c.packageDigest);
  assert.deepEqual(doc.producer, { name: 'hippo-desk', version: '0.1.0', build: '1' });
  assert.equal(doc.generated_at, '2026-11-12T10:00:00.000Z');
  assert.deepEqual(enrichmentErrors(doc), []);
});

test('capture 2 with no model result carries summary and tags over unchanged', async () => {
  const c = await fixture(2);
  const doc = composeServerDoc(c, { circumstances: [], now })!;
  assert.equal(doc.facets.summary, c.server!.facets.summary);
  assert.equal(doc.facets.tags, c.server!.facets.tags);
  assert.equal(facetsDiffer(c.server, doc), false);
});

test('capture 1 with no model result and no circumstances returns undefined', async () => {
  assert.equal(composeServerDoc(await fixture(1), { circumstances: [], now }), undefined);
});

test('circumstances alone make a document with provenance rules', async () => {
  const c = await fixture(1);
  const doc = composeServerDoc(c, { circumstances: [{ label: 'dark', confidence: 'high', evidence: [] }], now })!;
  assert.deepEqual(Object.keys(doc.facets), ['circumstance']);
  assert.deepEqual(doc.facets.circumstance.data, { items: [{ label: 'dark', confidence: 'high' }] });
  assert.equal(doc.facets.circumstance.provenance, 'rules');
  assert.deepEqual(enrichmentErrors(doc), []);
});

test('facetsDiffer ignores generated_at only', async () => {
  const c = await fixture(2);
  const a = composeServerDoc(c, { model: { value, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now })!;
  const b = composeServerDoc(c, { model: { value, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now: new Date('2027-01-01T00:00:00Z') })!;
  assert.notEqual(a.facets.summary.generated_at, b.facets.summary.generated_at);
  assert.equal(facetsDiffer(a, b), false);
  const c2 = composeServerDoc(c, { model: { value: { ...value, topic: 'other' }, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now })!;
  assert.equal(facetsDiffer(a, c2), true);
  assert.equal(facetsDiffer(a, composeServerDoc(c, { model: { value, provenance: 'other:x', digest: 'b'.repeat(64) }, circumstances: [], now })), true);
  assert.equal(facetsDiffer(undefined, a), true);
  assert.equal(facetsDiffer(undefined, undefined), false);
});

test('an unchanged facet keeps the old object and its generated_at', async () => {
  const c = await fixture(2);
  const first = composeServerDoc(c, { model: { value, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now })!;
  c.server = first;
  const again = composeServerDoc(c, { model: { value, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now: new Date('2027-01-01T00:00:00Z') })!;
  assert.equal(again.facets.display, first.facets.display);
  assert.equal(again.facets.display.generated_at, '2026-11-12T10:00:00.000Z');
});

test('writeServerDoc leaves exactly one file, sorted keys, two-space indent, trailing newline', async () => {
  const c = await fixture(1);
  const doc = composeServerDoc(c, { model: { value, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now })!;
  await writeServerDoc(c, doc);
  assert.deepEqual(fs.readdirSync(path.dirname(c.serverPath)), ['enrichment.json']);
  const text = fs.readFileSync(c.serverPath, 'utf8');
  assert.ok(text.endsWith('}\n'));
  assert.ok(text.startsWith('{\n  "capture_id": '));
  assert.deepEqual(JSON.parse(text), doc);
  assert.ok(c.serverPath.endsWith(path.join('enrichments', 'server', '2026', '11', '07', c.id, 'enrichment.json')));
  // Replacing it again still leaves one file.
  await writeServerDoc(c, { ...doc, generated_at: '2026-11-13T10:00:00.000Z' });
  assert.deepEqual(fs.readdirSync(path.dirname(c.serverPath)), ['enrichment.json']);
});

test('writeServerDoc refuses a document over 1 MiB and leaves nothing behind', async () => {
  const c = await fixture(1);
  const big = composeServerDoc(c, { model: { value: { ...value, summary: 'x'.repeat(1_100_000) }, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now })!;
  await assert.rejects(writeServerDoc(c, big), /1 MiB/);
  assert.equal(fs.existsSync(path.dirname(c.serverPath)) ? fs.readdirSync(path.dirname(c.serverPath)).length : 0, 0);
});

test('a failed write removes its temp file and the directories it made', async (t) => {
  const c = await fixture(1);
  const doc = composeServerDoc(c, { model: { value, provenance: 'fake:fake', digest: 'b'.repeat(64) }, circumstances: [], now })!;
  // A directory where the file should go: the rename fails, the temp file goes, the existing directory stays.
  fs.mkdirSync(c.serverPath, { recursive: true });
  fs.writeFileSync(path.join(c.serverPath, 'x'), '');
  await assert.rejects(writeServerDoc(c, doc));
  assert.deepEqual(fs.readdirSync(path.dirname(c.serverPath)), ['enrichment.json']);
  // A failed temp write inside directories this call made: they are removed again.
  const fresh = await fixture(1);
  fresh.serverPath = path.join(path.dirname(fresh.serverPath), '..', '..', '..', '..', '2030', '01', '02', fresh.id, 'enrichment.json');
  const serverRoot = path.resolve(fresh.serverPath, '../../../../..');
  const before = fs.readdirSync(serverRoot).sort();
  t.mock.method(fsp, 'writeFile', async () => { throw new Error('disk full'); });
  await assert.rejects(writeServerDoc(fresh, doc), /disk full/);
  assert.deepEqual(fs.readdirSync(serverRoot).sort(), before);
});
