import test from 'node:test';
import assert from 'node:assert/strict';
import { layouts } from '../src/layout/index.ts';
import { NO_LOCATION } from '../src/layout/place.ts';
import type { LayoutResult, View } from '../src/layout/types.ts';
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
/** Each pile's extent on the desk: every member as placed, turned and jittered, from the sizes alone. */
function footprints(items: DeskItem[], r: LayoutResult): Map<string, Box> {
  const kind = new Map(items.map(i => [i.id, i.kind]));
  const out = new Map<string, Box>();
  for (const p of r.placements) {
    const { w, h } = SIZES[kind.get(p.id)!];
    const c = Math.abs(Math.cos(p.rot)), s = Math.abs(Math.sin(p.rot));
    const hw = (w * c + h * s) / 2, hh = (w * s + h * c) / 2;
    const f = out.get(p.pile) ?? { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
    f.x0 = Math.min(f.x0, p.x - hw); f.x1 = Math.max(f.x1, p.x + hw);
    f.y0 = Math.min(f.y0, p.y - hh); f.y1 = Math.max(f.y1, p.y + hh);
    out.set(p.pile, f);
  }
  return out;
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
