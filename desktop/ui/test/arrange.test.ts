import test from 'node:test';
import assert from 'node:assert/strict';
import { PILE_CAP, dealOrder, nearestEdge, placeLabels, planChange, planPile, settle } from '../src/scene/arrange.ts';
import type { Phase } from '../src/scene/arrange.ts';

const ids = (n: number) => Array.from({ length: n }, (_, k) => `id${String(k).padStart(2, '0')}`);

test('planPile draws the 12 top ids of 40 and hides 28; of 5 it draws all 5', () => {
  assert.equal(PILE_CAP, 12);
  const forty = ids(40);
  assert.deepEqual(planPile(forty), { drawn: forty.slice(0, 12), hidden: 28 });
  assert.deepEqual(planPile(ids(5)), { drawn: ids(5), hidden: 0 });
  assert.deepEqual(planPile(ids(12)), { drawn: ids(12), hidden: 0 });
  assert.deepEqual(planPile(forty, 3), { drawn: forty.slice(0, 3), hidden: 37 });
  assert.deepEqual(planPile([]), { drawn: [], hidden: 0 });
});

test('nearestEdge names the closest side of the area and how far it is', () => {
  const r = { x0: -50, x1: 50, y0: -30, y1: 30 };
  assert.deepEqual(nearestEdge(-45, 0, r), { edge: 'left', distance: 5 });
  assert.deepEqual(nearestEdge(48, 0, r), { edge: 'right', distance: 2 });
  assert.deepEqual(nearestEdge(0, 27, r), { edge: 'far', distance: 3 });
  assert.deepEqual(nearestEdge(0, -29, r), { edge: 'near', distance: 1 });
  // Outside the area counts as at its edge.
  assert.deepEqual(nearestEdge(-80, 0, r), { edge: 'left', distance: 0 });
});

test('arrivals are dealt in order of distance from their dealing edge, ties by id', () => {
  const r = { x0: -50, x1: 50, y0: -30, y1: 30 };
  const order = dealOrder([
    { id: 'centre', x: 0, y: 0 },
    { id: 'b-near-left', x: -46, y: 0 },
    { id: 'a-near-left', x: -46, y: 1 },
    { id: 'far', x: 10, y: 22 },
    { id: 'right', x: 41, y: -2 },
  ], r);
  assert.deepEqual(order.map(o => o.id), ['a-near-left', 'b-near-left', 'far', 'right', 'centre']);
  assert.deepEqual(order.map(o => o.edge), ['left', 'left', 'far', 'right', 'near']);
  for (let k = 1; k < order.length; k++) assert.ok(order[k].distance >= order[k - 1].distance);
});

const phases = (m: ReadonlyMap<string, Phase>) => Object.fromEntries([...m].sort(([a], [b]) => (a < b ? -1 : 1)));

test('two quick changes: nothing half-way, nothing twice, nothing left showing that should have gone', () => {
  // First fill: a, b, c drawn.
  const one = planChange(new Map(), ['a', 'b', 'c'], new Set(['a', 'b', 'c']));
  assert.deepEqual(one.arrive, ['a', 'b', 'c']);
  assert.deepEqual([one.move, one.tuck, one.leave], [[], [], []]);

  // While they are still flying in: c stays, d arrives, a and b are swept off.
  const two = planChange(one.phases, ['c', 'd'], new Set(['c', 'd']));
  assert.deepEqual(two.arrive, ['d']);
  assert.deepEqual(two.move, ['c']);
  assert.deepEqual(two.leave, ['a', 'b']);
  assert.deepEqual(phases(two.phases), { a: 'leaving', b: 'leaving', c: 'shown', d: 'shown' });

  // Before a and b are off the desk: a is wanted again, c goes, e is in the set but under a pile's cap.
  const three = planChange(two.phases, ['a', 'd'], new Set(['a', 'd', 'e']));
  assert.deepEqual(three.move, ['a', 'd'], 'a turns back from where it is, as the same object');
  assert.deepEqual(three.arrive, [], 'a is not dealt in a second time');
  assert.deepEqual(three.leave, ['c']);
  assert.deepEqual(three.tuck, []);
  assert.deepEqual(phases(three.phases), { a: 'shown', b: 'leaving', c: 'leaving', d: 'shown' });
  assert.ok(!three.leave.includes('b'), 'b keeps leaving, it is not swept a second time');

  // b gets off the desk: it is hidden and forgotten; the next change deals it in again if wanted.
  const after = settle(three.phases, 'b');
  assert.deepEqual(phases(after), { a: 'shown', c: 'leaving', d: 'shown' });
  const four = planChange(after, ['b', 'd'], new Set(['b', 'd', 'a']));
  assert.deepEqual(four.arrive, ['b']);
  assert.deepEqual(four.move, ['d']);
  assert.deepEqual(four.tuck, ['a'], 'a is still in the set but under the cap: it glides into its pile, then hides');
  assert.deepEqual(four.leave, []);
  assert.deepEqual(phases(four.phases), { a: 'tucking', b: 'shown', c: 'leaving', d: 'shown' });

  // Every list is disjoint, and every drawn id is shown.
  for (const p of [one, two, three, four]) {
    const all = [...p.arrive, ...p.move, ...p.tuck, ...p.leave];
    assert.equal(new Set(all).size, all.length);
  }
  for (const id of ['b', 'd']) assert.equal(four.phases.get(id), 'shown');

  // A tucked item that is drawn again glides back out; one that leaves the set is swept off.
  const five = planChange(four.phases, ['a'], new Set(['a']));
  assert.deepEqual(five.move, ['a']);
  assert.deepEqual(five.leave, ['b', 'd']);
  assert.equal(settle(settle(five.phases, 'a'), 'zz').get('a'), 'shown', 'settling a shown item leaves it shown');
});

test('a hundred quick changes leave exactly the last set shown and nothing else once the leavers settle', () => {
  let m: ReadonlyMap<string, Phase> = new Map();
  let last: string[] = [];
  for (let k = 0; k < 100; k++) {
    last = ids(30).filter((_, j) => (j * 7 + k) % 3 !== 0);
    const p = planChange(m, last, new Set(last));
    m = p.phases;
  }
  for (const [id, ph] of m) if (ph !== 'shown') m = settle(m, id);
  assert.deepEqual([...m.keys()].sort(), [...last].sort());
});

test('placeLabels puts a label under its pile unless that would cover another pile or label, and drops it when nothing fits', () => {
  const piles = [
    { key: 'top', x0: -5, x1: 5, y0: 5, y1: 15, weight: 1 },
    { key: 'below', x0: -5, x1: 5, y0: -9, y1: 3, weight: 2 },
    { key: 'alone', x0: 40, x1: 50, y0: -5, y1: 5, weight: 1 },
  ];
  const bounds = { x0: -60, x1: 60, y0: -40, y1: 40 };
  const out = placeLabels(piles, { top: { w: 8, h: 3 }, below: { w: 8, h: 3 }, alone: { w: 8, h: 3 } }, bounds, 1);
  const below = out.get('below')!, top = out.get('top')!, alone = out.get('alone')!;
  assert.ok(below.y < -9, 'the bigger pile keeps the spot under it');
  assert.ok(top.y > 15, 'the upper pile takes the spot above, not the one on the pile under it');
  assert.ok(alone.y < -5 && Math.abs(alone.x - 45) < 1e-9);

  const crowded = placeLabels([{ key: 'p', x0: -5, x1: 5, y0: -5, y1: 5, weight: 1 }], { p: { w: 8, h: 3 } },
    { x0: -6, x1: 6, y0: -6, y1: 6 }, 1);
  assert.equal(crowded.get('p'), null, 'no room inside the bounds');
});
