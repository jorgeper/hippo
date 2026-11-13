import test from 'node:test';
import assert from 'node:assert/strict';
import { validateSpec } from '../src/recall/spec.ts';

const errorsOf = (input: unknown) => {
  const r = validateSpec(input);
  assert.equal(r.ok, false, 'expected the spec to be rejected');
  return r.ok ? [] : r.errors;
};

test('an empty spec and a full spec are accepted', () => {
  assert.deepEqual(validateSpec({}), { ok: true, spec: {} });
  const full = {
    kinds: ['link', 'video'], text: ['banana', 'yellow fruit'], tags: ['food'], topics: ['cooking'], people: ['Ana'], sites: ['youtube.com'],
    time: { from: '2026-11-03', to: '2026-11-09', weekdays: ['sat'], parts_of_day: ['morning'] },
    place: { localities: ['Lisbon'], near: { lat: 38.72, lon: -9.14, radius_m: 500 } },
    circumstances: { labels: ['in_car', 'some_future_label'], min_confidence: 'medium' },
    has: ['picture', 'comment'], include_ids: ['a'], exclude_ids: ['b'], sort: 'relevance', limit: 5000,
  };
  assert.deepEqual(validateSpec(full), { ok: true, spec: full });
});

test('unknown top-level keys are rejected, each named', () => {
  const errors = errorsOf({ kinds: ['link'], colour: 'red', when: 'today' });
  assert.ok(errors.some(e => e.startsWith('colour:')), errors.join('; '));
  assert.ok(errors.some(e => e.startsWith('when:')), errors.join('; '));
});

test('a spec that is not an object is rejected', () => {
  for (const v of [null, [], 'kinds', 3]) assert.equal(validateSpec(v).ok, false);
});

test('unknown kinds are rejected; unknown circumstance labels and tags are allowed', () => {
  assert.ok(errorsOf({ kinds: ['link', 'gif'] }).some(e => e.startsWith('kinds:') && e.includes('gif')));
  assert.equal(validateSpec({ circumstances: { labels: ['on_a_boat'] }, tags: ['never-seen'] }).ok, true);
});

test('labels that are not strings are rejected', () => {
  assert.ok(errorsOf({ circumstances: { labels: ['in_car', 3] } }).some(e => e.startsWith('circumstances.labels')));
  assert.ok(errorsOf({ circumstances: {} }).some(e => e.startsWith('circumstances.labels')));
  assert.ok(errorsOf({ tags: [true] }).some(e => e.startsWith('tags')));
  assert.ok(errorsOf({ text: 'banana' }).some(e => e.startsWith('text:')));
});

test('dates that are not YYYY-MM-DD are rejected, naming the field', () => {
  assert.ok(errorsOf({ time: { from: '7 Nov 2026' } }).includes('time.from: expected YYYY-MM-DD'));
  assert.ok(errorsOf({ time: { to: '2026-11-7' } }).includes('time.to: expected YYYY-MM-DD'));
  assert.ok(errorsOf({ time: { to: '2026-02-30' } }).includes('time.to: expected YYYY-MM-DD'));
});

test('limit outside 1-5000 is rejected, naming limit', () => {
  for (const limit of [0, 5001, 2.5, '10', -1]) assert.ok(errorsOf({ limit }).some(e => e.startsWith('limit:')), String(limit));
  assert.equal(validateSpec({ limit: 1 }).ok, true);
});

test('other closed sets are checked: has, sort, min_confidence, weekdays, parts of day, near', () => {
  assert.ok(errorsOf({ has: ['smell'] }).some(e => e.startsWith('has:')));
  assert.ok(errorsOf({ sort: 'random' }).some(e => e.startsWith('sort:')));
  assert.ok(errorsOf({ circumstances: { labels: ['in_car'], min_confidence: 'certain' } }).some(e => e.startsWith('circumstances.min_confidence:')));
  assert.ok(errorsOf({ time: { weekdays: ['someday'] } }).some(e => e.startsWith('time.weekdays:')));
  assert.ok(errorsOf({ time: { parts_of_day: ['dawn'] } }).some(e => e.startsWith('time.parts_of_day:')));
  assert.ok(errorsOf({ place: { near: { lat: 91, lon: 0, radius_m: 10 } } }).some(e => e.startsWith('place.near.lat:')));
  assert.ok(errorsOf({ place: { near: { lat: 0, lon: 0, radius_m: 0 } } }).some(e => e.startsWith('place.near.radius_m:')));
  assert.ok(errorsOf({ time: { since: '2026-11-01' } }).some(e => e.startsWith('time.since:')));
});

test('full weekday names are accepted as their short form', () => {
  assert.deepEqual(validateSpec({ time: { weekdays: ['Saturday', 'sun'] } }), { ok: true, spec: { time: { weekdays: ['sat', 'sun'] } } });
});

test('every error is reported, not only the first', () => {
  const errors = errorsOf({ kinds: ['gif'], limit: 0, time: { from: 'x' } });
  assert.equal(errors.length, 3, errors.join('; '));
});
