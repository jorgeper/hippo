import test from 'node:test';
import assert from 'node:assert/strict';
import { fitLines, isRtl } from '../src/scene/textures.ts';

// A stand-in for canvas measureText: every code point is one unit wide, so widths are easy to check.
const measure = (s: string) => [...s].length;
const lone = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

test('fitLines wraps on spaces and keeps every line within the width', () => {
  const lines = fitLines('the quick brown fox jumps over the lazy dog', 12, 5, measure);
  assert.deepEqual(lines, ['the quick', 'brown fox', 'jumps over', 'the lazy dog']);
});

test('fitLines ends the last allowed line with an ellipsis when the text does not fit', () => {
  const lines = fitLines('the quick brown fox jumps over the lazy dog', 12, 2, measure);
  assert.equal(lines.length, 2);
  assert.equal(lines[0], 'the quick');
  assert.ok(lines[1].endsWith('…'));
  for (const l of lines) assert.ok(measure(l) <= 12, l);
});

test('a 200-character single word is broken and ellipsised, never wider than the line', () => {
  const word = 'x'.repeat(200);
  const lines = fitLines(word, 20, 3, measure);
  assert.equal(lines.length, 3);
  for (const l of lines) assert.ok(measure(l) <= 20, `${measure(l)}`);
  assert.ok(lines[2].endsWith('…'));
});

test('emoji and other astral characters are never split into lone surrogates', () => {
  const text = '🦛🦛🦛 👩‍👩‍👧‍👦 '.repeat(20) + '𝔘𝔫𝔦𝔠𝔬𝔡𝔢'.repeat(10);
  for (const width of [1, 2, 3, 5, 9]) {
    const lines = fitLines(text, width, 4, measure);
    assert.ok(lines.length > 0 && lines.length <= 4);
    for (const l of lines) assert.ok(!lone.test(l), JSON.stringify(l));
  }
});

test('right-to-left text wraps like any other and is recognised as right-to-left', () => {
  const text = 'שלום עולם זה טקסט ארוך מאוד שצריך לעטוף';
  const lines = fitLines(text, 10, 3, measure);
  for (const l of lines) assert.ok(measure(l) <= 10);
  assert.ok(isRtl(text));
  assert.ok(isRtl('مرحبا بالعالم'));
  assert.ok(!isRtl('Hello עולם'));
  assert.ok(!isRtl('123 hello'));
});

test('empty, whitespace-only and zero-width cases give no lines and do not throw', () => {
  assert.deepEqual(fitLines('', 10, 2, measure), []);
  assert.deepEqual(fitLines('   \n\t ', 10, 2, measure), []);
  assert.deepEqual(fitLines('hello', 10, 0, measure), []);
  assert.deepEqual(fitLines('hello', 0, 2, measure), []);
});

test('line breaks in the text start new lines', () => {
  assert.deepEqual(fitLines('one\ntwo three', 20, 4, measure), ['one', 'two three']);
});
