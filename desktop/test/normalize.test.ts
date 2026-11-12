import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFixtures, enrichmentErrors } from './helpers.ts';
import { scanFolder } from '../src/core/folder.ts';
import { normalize } from '../src/enrich/normalize.ts';
import type { ModelEnrichment } from '../src/enrich/normalize.ts';
import { composeServerDoc } from '../src/enrich/serverdoc.ts';
import type { RawCapture } from '../src/core/types.ts';

const scan = await scanFolder(copyFixtures());
const cap = (n: number): RawCapture => scan.captures.find(c => c.id.endsWith(`00${n}`))!;
const PIC7 = '00000000-0000-4000-8000-000700000001';
const base = { title: 'Cafe menu', summary: 'A menu.', image_descriptions: [], tags: ['cafe', 'menu', 'food'], topic: 'food', people: [], keywords: [] };

/** Normalizes, composes the server document and checks it against the schema (Review Focus 2). */
function run(raw: unknown, c: RawCapture, known: string[] = []): ModelEnrichment {
  const v = normalize(raw, c, known);
  assert.ok(v, 'normalize returned undefined');
  const doc = composeServerDoc(c, { model: { value: v, provenance: 'fake:fake', digest: 'a'.repeat(64) }, circumstances: [], now: new Date('2026-11-12T10:00:00Z') });
  assert.deepEqual(enrichmentErrors(doc), []);
  return v;
}

test('a 90-character title is cut to at most 60 and ends on a whole word', () => {
  const title = 'Notes from my long walk along the river past the old mill and the bakery at the corner now';
  assert.equal(title.length, 90);
  const v = run({ ...base, title }, cap(7));
  assert.ok([...v.title].length <= 60, v.title);
  assert.ok(title.startsWith(v.title));
  assert.equal(title[v.title.length], ' ', `"${v.title}" does not end on a whole word`);
});

test('a title of 70 astral characters is cut by code point and validates', () => {
  const v = run({ ...base, title: '🦛'.repeat(70) }, cap(7));
  assert.ok([...v.title].length <= 60);
  assert.ok(v.title.length > 0);
});

test('a blank title drops the answer', () => {
  assert.equal(normalize({ ...base, title: '   ' }, cap(7), []), undefined);
  assert.equal(normalize({ ...base, title: 42 }, cap(7), []), undefined);
});

test('tags are lower-cased, unique, without blanks, at most 8', () => {
  const v = run({ ...base, tags: ['Food', 'food', ' ', 'A', 'b', 'c', 'd', 'e', 'f', 'g', 'h'] }, cap(7));
  assert.deepEqual(v.tags, ['food', 'a', 'b', 'c', 'd', 'e', 'f', 'g']);
});

test('a description for an attachment the capture does not have is dropped', () => {
  const v = run({ ...base, image_descriptions: [{ attachment_id: 'nope', text: 'Nothing.' }, { attachment_id: PIC7, text: ' A menu. ' }] }, cap(7));
  assert.deepEqual(v.image_descriptions, [{ attachment_id: PIC7, text: 'A menu.' }]);
});

test('a person with no source, or a source the capture does not have, is dropped', () => {
  const v = run({ ...base, people: [{ name: 'Ana' }, { name: 'Bo', source: 'somewhere' }, { name: ' ', source: 'user_note' },
    { name: 'Cy', source: 'user_note' }, { name: 'cy', source: 'shared_text' }] }, cap(7));
  assert.deepEqual(v.people, [{ name: 'Cy', source: 'user_note' }]);
});

test('an empty topic falls back to the first tag, else other', () => {
  assert.equal(run({ ...base, topic: '', tags: ['cafe'] }, cap(7)).topic, 'cafe');
  assert.equal(run({ ...base, topic: '  ', tags: [] }, cap(7)).topic, 'other');
  assert.equal(run({ ...base, topic: ' Food ' }, cap(7)).topic, 'food');
});

test('a topic matching a known one up to spacing and dashes takes the known spelling', () => {
  assert.equal(run({ ...base, topic: 'Home-Repair' }, cap(1), ['home repair']).topic, 'home repair');
});

test('keyword weights are clamped to 0..1, only for notes and recordings', () => {
  const kw = [{ word: 'plumber', weight: 2 }, { word: 'sink', weight: -1 }, { word: ' ', weight: 0.5 }, { word: 'x', weight: 'heavy' }];
  assert.deepEqual(run({ ...base, keywords: kw }, cap(1)).keywords, [{ word: 'plumber', weight: 1 }, { word: 'sink', weight: 0 }]);
  assert.deepEqual(run({ ...base, keywords: kw }, cap(7)).keywords, []);
});

test('a non-object answer returns undefined', () => {
  assert.equal(normalize('hello', cap(7), []), undefined);
  assert.equal(normalize(null, cap(7), []), undefined);
  assert.equal(normalize([base], cap(7), []), undefined);
});

test('a blank summary is omitted', () => {
  assert.equal(run({ ...base, summary: ' ' }, cap(7)).summary, undefined);
});
