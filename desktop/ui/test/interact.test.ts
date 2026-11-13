import test from 'node:test';
import assert from 'node:assert/strict';
import { riffle, spreadPositions } from '../src/interact/pile.ts';
import { isThrow } from '../src/interact/item.ts';

const view = { width: 120, height: 70 };

test('spreadPositions lays 30 prints out in the view without any two overlapping', () => {
  const size = { w: 15, h: 10 };
  const at = spreadPositions(30, view, size);
  assert.equal(at.length, 30);
  for (const p of at) {
    assert.ok(p.x - size.w / 2 >= -view.width / 2 && p.x + size.w / 2 <= view.width / 2, `x ${p.x} inside`);
    assert.ok(p.y - size.h / 2 >= -view.height / 2 && p.y + size.h / 2 <= view.height / 2, `y ${p.y} inside`);
  }
  for (let a = 0; a < at.length; a++) for (let b = a + 1; b < at.length; b++) {
    const apart = Math.abs(at[a].x - at[b].x) >= size.w || Math.abs(at[a].y - at[b].y) >= size.h;
    assert.ok(apart, `${a} and ${b} overlap`);
  }
});

test('spreadPositions: first item top left, reading order, a few items centred, more than fit run on in rows below', () => {
  const size = { w: 15, h: 10 };
  const few = spreadPositions(3, view, size);
  const cx = few.reduce((s, p) => s + p.x, 0) / few.length, cy = few.reduce((s, p) => s + p.y, 0) / few.length;
  assert.ok(Math.abs(cx) < 1e-9 && Math.abs(cy) < 1e-9, 'a few are centred');
  const many = spreadPositions(200, view, size);
  assert.equal(many.length, 200);
  assert.ok(many[0].x < many[1].x && many[0].y === many[1].y, 'reading order along a row');
  const top = many[0].y;
  assert.ok(top + size.h / 2 <= view.height / 2, 'the first row is inside the view');
  assert.ok(many[199].y < -view.height / 2, 'the last rows are below the view, to scroll to');
  // No overlap there either.
  for (let a = 0; a < many.length; a++) for (let b = a + 1; b < many.length; b++)
    assert.ok(Math.abs(many[a].x - many[b].x) >= size.w || Math.abs(many[a].y - many[b].y) >= size.h);
  assert.deepEqual(spreadPositions(0, view, size), []);
});

test('isThrow: fast toward an edge, or let go right at one; a slow release in the middle is a drop', () => {
  assert.equal(isThrow({ x: 90, y: 0 }, { x: 10, y: 0 }, view), true);
  assert.equal(isThrow({ x: 10, y: 0 }, { x: 0, y: 0 }, view), false);
  // Slow, 2 units from the right edge.
  assert.equal(isThrow({ x: 1, y: 0 }, { x: view.width / 2 - 2, y: 0 }, view), true);
  // Fast but back toward the middle, from well inside: brought back, not thrown.
  assert.equal(isThrow({ x: -90, y: 0 }, { x: 20, y: 0 }, view), false);
  // Fast toward the near edge.
  assert.equal(isThrow({ x: 0, y: -80 }, { x: 0, y: -5 }, view), true);
});

test('riffle sends the top of a pile to the bottom, one per step; back again with negative steps', () => {
  assert.deepEqual(riffle(['a', 'b', 'c'], 1), ['b', 'c', 'a']);
  assert.deepEqual(riffle(['a', 'b', 'c'], 2), ['c', 'a', 'b']);
  assert.deepEqual(riffle(['a', 'b', 'c'], 3), ['a', 'b', 'c']);
  assert.deepEqual(riffle(['a', 'b', 'c'], -1), ['c', 'a', 'b']);
  assert.deepEqual(riffle([], 4), []);
});
