import test from 'node:test';
import assert from 'node:assert/strict';
import { fitLines, fitWord, isRtl } from '../src/scene/textures.ts';

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

// A stand-in for measureText at a font size: every code point is `size` wide.
const measureAt = (s: string, size: number) => [...s].length * size;

test('fitWord keeps a word that fits at its size, whole', () => {
  assert.deepEqual(fitWord('meet', 10, 2, 0.8, measureAt), { text: 'meet', size: 2 });
});

test('fitWord shrinks a heavy word that is too wide before it cuts anything', () => {
  // "packing" is 7 wide per unit of size: at 1.9 it needs 13.3; the line is 7.6, so it shrinks to fit whole.
  const f = fitWord('packing', 7.6, 1.9, 0.78, measureAt);
  assert.equal(f.text, 'packing');
  assert.ok(f.size < 1.9 && f.size >= 0.78, `${f.size}`);
  assert.ok(measureAt(f.text, f.size) <= 7.6 + 1e-9);
  assert.ok(f.size > 1.0, 'only as small as it has to be');
});

test('fitWord ellipsises only at the smallest size, and never returns anything wider than the line', () => {
  const f = fitWord('internationalisation', 7.6, 1.9, 0.78, measureAt);
  assert.equal(f.size, 0.78);
  assert.ok(f.text.endsWith('…'));
  assert.ok(measureAt(f.text, f.size) <= 7.6 + 1e-9);
  // An emoji word is cut by grapheme, never into a lone surrogate.
  const e = fitWord('🦛'.repeat(30), 7.6, 1.9, 0.78, measureAt);
  assert.ok(!lone.test(e.text) && measureAt(e.text, e.size) <= 7.6 + 1e-9);
});
