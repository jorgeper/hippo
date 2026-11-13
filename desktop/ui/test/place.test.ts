import test from 'node:test';
import assert from 'node:assert/strict';
import { layouts } from '../src/layout/index.ts';
import { NO_LOCATION, PILE_GAP, placeStages, SPLIT_MAX } from '../src/layout/place.ts';
import type { PlacePoint } from '../src/layout/place.ts';
import { byTime, clampPoint, halfExtents, jitterOf, marginOf, PILE_CAP } from '../src/layout/pile.ts';
import type { LayoutResult, Size, View } from '../src/layout/types.ts';
import type { DeskItem } from '../../src/server/wire.ts';
import type { Kind } from '../../src/core/types.ts';
import { SIZES, item } from './items.ts';

const EPS = 1e-6;
const KINDS: Kind[] = ['link', 'photo', 'screenshot', 'note', 'recording', 'video', 'file'];

/** mulberry32: the same random item sets on every run. */
function rng(seed: number): () => number {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const HOODS = ['Baixa', 'Alfama', 'Chiado', 'Belém', 'Lumiar', 'Graça'];
const TOWNS = ['Lisboa', 'Sintra', 'Porto'];

/**
 * `n` items: most bunched around a few spots (a street, a café: metres apart), some along trails, some scattered over
 * `spreadKm`, and one in ten with no location at all.
 */
function randomItems(n: number, spreadKm: number, seed: number): DeskItem[] {
  const r = rng(seed);
  const deg = spreadKm / 111;
  const spots = Array.from({ length: 1 + Math.floor(r() * 8) }, () => ({ lat: 38.72 + (r() - 0.5) * deg, lon: -9.14 + (r() - 0.5) * deg }));
  return Array.from({ length: n }, (_, k) => {
    const kind = KINDS[Math.floor(r() * KINDS.length)];
    const time = `${String(Math.floor(r() * 24)).padStart(2, '0')}:${String(Math.floor(r() * 60)).padStart(2, '0')}`;
    const roll = r();
    if (roll < 0.1) return item(k, { kind, time });
    let lat: number, lon: number;
    if (roll < 0.7) { const s = spots[Math.floor(r() * spots.length)]; lat = s.lat + (r() - 0.5) * deg * 0.02; lon = s.lon + (r() - 0.5) * deg * 0.02; }
    else if (roll < 0.85) { const t = r(); lat = 38.72 + (t - 0.5) * deg * 0.6; lon = -9.14 + (t - 0.5) * deg; }
    else { lat = 38.72 + (r() - 0.5) * deg; lon = -9.14 + (r() - 0.5) * deg; }
    return item(k, { kind, time, place: { lat, lon, locality: TOWNS[Math.floor(r() * TOWNS.length)], sub_locality: HOODS[Math.floor(r() * HOODS.length)] } });
  });
}

type Box = { x0: number; x1: number; y0: number; y1: number };
const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[xs.length >> 1];

/**
 * What is drawn of a pile standing at x,y with `members`: its newest PILE_CAP sheets, each turned and jittered as the
 * stacking does it, and (when more are under them) the thickness block, the drawn sheets' middle size, at the pile's point.
 */
function drawnBox(members: DeskItem[], x: number, y: number): Box {
  const top = [...members].sort(byTime).slice(-PILE_CAP);
  const f = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
  const add = (cx: number, cy: number, hw: number, hh: number) => {
    f.x0 = Math.min(f.x0, cx - hw); f.x1 = Math.max(f.x1, cx + hw); f.y0 = Math.min(f.y0, cy - hh); f.y1 = Math.max(f.y1, cy + hh);
  };
  for (const it of top) {
    const j = jitterOf(it.id), { w, h }: Size = SIZES[it.kind];
    const c = Math.abs(Math.cos(j.rot)), s = Math.abs(Math.sin(j.rot));
    add(x + j.dx, y + j.dy, (w * c + h * s) / 2, (w * s + h * c) / 2);
  }
  if (members.length > PILE_CAP) add(x, y, median(top.map(i => SIZES[i.kind].w)) / 2, median(top.map(i => SIZES[i.kind].h)) / 2);
  return f;
}

/** Each pile's drawn footprint on the desk, from the layout's piles and the sizes alone. */
function footprints(items: DeskItem[], r: LayoutResult): Map<string, Box> {
  const byId = new Map(items.map(i => [i.id, i]));
  const at = new Map(r.placements.map(p => [p.id, p]));
  const out = new Map<string, Box>();
  for (const pile of r.piles) {
    const members = pile.ids.map(id => byId.get(id)!);
    // The placements must be the stacking's own: each member at the pile's point plus its jitter.
    for (const id of pile.ids) {
      const p = at.get(id)!, j = jitterOf(id);
      assert.ok(Math.abs(p.x - pile.x - j.dx) < EPS && Math.abs(p.y - pile.y - j.dy) < EPS && p.pile === pile.key, `${id} stacked on its pile`);
    }
    out.set(pile.key, drawnBox(members, pile.x, pile.y));
  }
  return out;
}

const gapOverlap = (p: Box, q: Box) => p.x0 < q.x1 + PILE_GAP - EPS && q.x0 < p.x1 + PILE_GAP - EPS && p.y0 < q.y1 + PILE_GAP - EPS && q.y0 < p.y1 + PILE_GAP - EPS;

/**
 * Minimal merging: no located pile made of several leader clusters (the clustering stage before merging) can be split into
 * two piles of whole clusters, each at its members' centre, that come within PILE_GAP of neither each other nor any other
 * pile. Piles of more than SPLIT_MAX clusters are not checked (the layout does not try them either). Returns how many piles
 * were checked.
 */
function assertMinimal(items: DeskItem[], view: View, r: LayoutResult, what: string): number {
  const stages = placeStages(items, view);
  if (!stages) return 0;
  const f = footprints(items, r);
  const pileOf = new Map(r.placements.map(p => [p.id, p.pile]));
  let checked = 0;
  for (const pile of r.piles) {
    if (pile.label === NO_LOCATION) continue;
    const parts: PlacePoint[][] = stages.leaders.filter(l => pileOf.get(l[0].it.id) === pile.key);
    for (const l of parts) assert.ok(l.every(m => pileOf.get(m.it.id) === pile.key), `${what}: a leader cluster is never torn apart`);
    if (parts.length < 2 || parts.length > SPLIT_MAX) continue;
    checked++;
    const others = r.piles.filter(p => p.key !== pile.key).map(p => f.get(p.key)!);
    const box = (ls: PlacePoint[][]): Box => {
      const ms = ls.flat();
      const at = clampPoint(ms.reduce((s, m) => s + m.x, 0) / ms.length, ms.reduce((s, m) => s + m.y, 0) / ms.length, marginOf(ms.map(m => m.it), SIZES), stages.map);
      return drawnBox(ms.map(m => m.it), at.x, at.y);
    };
    for (let mask = 1; mask < 2 ** (parts.length - 1); mask++) {
      const a = box(parts.filter((_, i) => mask & (1 << i))), b = box(parts.filter((_, i) => !(mask & (1 << i))));
      const fits: boolean = !gapOverlap(a, b) && !others.some(o => gapOverlap(a, o) || gapOverlap(b, o));
      assert.ok(!fits, `${what}: ${pile.label} (${pile.count} items, ${parts.length} clusters) splits into two piles that overlap nothing`);
    }
  }
  return checked;
}

/** The commonest name among a pile's members (sub-locality, else locality), ties by code-unit order. */
function commonest(names: (string | undefined)[]): string | undefined {
  const counts = new Map<string, number>();
  for (const n of names) if (n) counts.set(n, (counts.get(n) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))[0]?.[0];
}

function assertNoOverlap(items: DeskItem[], view: View, what: string): LayoutResult {
  const r = layouts.place(items, view, SIZES);
  assert.equal(r.placements.length, items.length, what);
  assert.equal(new Set(r.placements.map(p => p.id)).size, items.length, `${what}: every item once`);
  const f = footprints(items, r);
  for (let a = 0; a < r.piles.length; a++) {
    for (let b = a + 1; b < r.piles.length; b++) {
      const p = f.get(r.piles[a].key)!, q = f.get(r.piles[b].key)!;
      const overlap = p.x0 < q.x1 - EPS && q.x0 < p.x1 - EPS && p.y0 < q.y1 - EPS && q.y0 < p.y1 - EPS;
      assert.ok(!overlap, `${what}: ${r.piles[a].label} at ${r.piles[a].x.toFixed(2)},${r.piles[a].y.toFixed(2)} overlaps ${r.piles[b].label} at ${r.piles[b].x.toFixed(2)},${r.piles[b].y.toFixed(2)}`);
    }
  }
  // A pile is labelled with the name most of its members share.
  const byId = new Map(items.map(i => [i.id, i]));
  for (const p of r.piles) {
    if (p.label === NO_LOCATION) continue;
    const want = commonest(p.ids.map(id => { const pl = byId.get(id)!.place!; return pl.sub_locality ?? pl.locality; })) ?? '';
    assert.equal(p.label, want, `${what}: pile label`);
  }
  return r;
}

const VIEWS: View[] = [
  { width: 160, height: 100 },
  { width: 120.3, height: 60.9 },   // the stage's view at 1440 x 900
  { width: 90, height: 45 },
  { width: 90, height: 24 },
  { width: 240, height: 130 },
];
const COUNTS = [1, 2, 7, 40, 300, 2000];
const SPREADS_KM = [0.3, 3, 25, 400];

test('place: no two pile footprints overlap, for many random item sets and view sizes', () => {
  let seed = 1, runs = 0;
  for (const n of COUNTS) {
    for (const km of SPREADS_KM) {
      for (const view of VIEWS) {
        assertNoOverlap(randomItems(n, km, seed++), view, `${n} items over ${km} km, view ${view.width}x${view.height}, seed ${seed - 1}`);
        runs++;
      }
    }
  }
  const r = rng(77);
  for (let k = 0; k < 60; k++) {
    const n = 1 + Math.floor(r() * r() * 600);
    assertNoOverlap(randomItems(n, SPREADS_KM[k % SPREADS_KM.length], 5000 + k), VIEWS[k % VIEWS.length], `extra ${k}: ${n} items`);
    runs++;
  }
  assert.ok(runs >= 160);
});

test('place: piles merge only as far as they must; no merged pile could be split in two without an overlap', () => {
  let seed = 1, checked = 0;
  for (const n of [7, 40, 300]) {
    for (const km of SPREADS_KM) {
      for (const view of VIEWS) {
        const items = randomItems(n, km, seed + 100_000);
        seed++;
        const r = layouts.place(items, view, SIZES);
        checked += assertMinimal(items, view, r, `${n} items over ${km} km, view ${view.width}x${view.height}, seed ${seed - 1 + 100_000}`);
      }
    }
  }
  // The same sets the no-overlap test uses at 1440 x 900.
  for (let k = 0; k < COUNTS.length * SPREADS_KM.length; k++) {
    const n = COUNTS[Math.floor(k / SPREADS_KM.length)], km = SPREADS_KM[k % SPREADS_KM.length];
    const s = 1 + k * VIEWS.length + 1, items = randomItems(n, km, s);
    checked += assertMinimal(items, VIEWS[1], layouts.place(items, VIEWS[1], SIZES), `${n} items over ${km} km at 1440 x 900, seed ${s}`);
  }
  assert.ok(checked >= 20, `${checked} merged piles checked`);
});

test('place: 300 items over 3 km at 1440 x 900 (seed 87) lie in three located piles, not two', () => {
  const items = randomItems(300, 3, 87);
  const r = assertNoOverlap(items, VIEWS[1], 'seed 87');
  const located = r.piles.filter(p => p.label !== NO_LOCATION);
  assert.equal(located.length, 3, located.map(p => `${p.label} ${p.count}`).join(', '));
  assert.equal(assertMinimal(items, VIEWS[1], r, 'seed 87') >= 1, true);
});

test('place: two close spots whose piles would overlap become one pile at their members\' centre', () => {
  // Two cafés 1 km apart in a 4 km spread: their own piles would lie about 9 units apart, photos 15 wide lying across each other.
  const base = { lat: 38.7139, lon: -9.1334 };
  const a = Array.from({ length: 3 }, (_, k) => item(10 + k, { kind: 'photo', place: { lat: base.lat, lon: base.lon, locality: 'Lisboa', sub_locality: 'Baixa' } }));
  const b = Array.from({ length: 2 }, (_, k) => item(20 + k, { kind: 'photo', place: { lat: base.lat, lon: base.lon + 0.012, locality: 'Lisboa', sub_locality: 'Chiado' } }));
  const far = item(30, { kind: 'photo', place: { lat: base.lat + 0.03, lon: base.lon - 0.03, locality: 'Lisboa', sub_locality: 'Campolide' } });
  const items = [...a, ...b, far];
  const r = assertNoOverlap(items, { width: 120.3, height: 60.9 }, 'two cafés');
  const pileOf = (id: string) => r.placements.find(p => p.id === id)!.pile;
  assert.equal(pileOf(a[0].id), pileOf(b[0].id), 'the two cafés share a pile');
  assert.notEqual(pileOf(a[0].id), pileOf(far.id));
  const merged = r.piles.find(p => p.key === pileOf(a[0].id))!;
  assert.equal(merged.label, 'Baixa', 'labelled by the name most members share');
  assert.equal(merged.count, 5);
});
