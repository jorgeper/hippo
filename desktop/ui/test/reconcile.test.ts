import test from 'node:test';
import assert from 'node:assert/strict';
import { reconcile } from '../src/reconcile.ts';

test('reconcile splits the ids into who leaves, who stays and who arrives', () => {
  assert.deepEqual(reconcile(['a', 'b', 'c'], ['b', 'c', 'd']), { leave: ['a'], stay: ['b', 'c'], arrive: ['d'] });
});

test('reconcile keeps the order of the new set for stayers and arrivals, and of the old set for leavers', () => {
  assert.deepEqual(reconcile(['c', 'x', 'a', 'y'], ['a', 'z', 'c', 'w']), { leave: ['x', 'y'], stay: ['a', 'c'], arrive: ['z', 'w'] });
  assert.deepEqual(reconcile([], ['a']), { leave: [], stay: [], arrive: ['a'] });
  assert.deepEqual(reconcile(['a'], []), { leave: ['a'], stay: [], arrive: [] });
});
