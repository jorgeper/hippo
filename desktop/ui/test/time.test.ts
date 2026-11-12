import test from 'node:test';
import assert from 'node:assert/strict';
import { layouts } from '../src/layout/index.ts';
import { TIME_LABEL_ROOM, dayShare, timeUnit } from '../src/layout/time.ts';
import type { TimeUnit } from '../src/layout/time.ts';
import type { LayoutResult, PileInfo, View } from '../src/layout/types.ts';
import type { DeskItem } from '../../src/server/wire.ts';
import type { Kind } from '../../src/core/types.ts';
import { SIZES, item } from './items.ts';

const EPS = 1e-6;
const KINDS: Kind[] = ['link', 'photo', 'screenshot', 'note', 'recording', 'video', 'file'];
const pad = (n: number) => String(n).padStart(2, '0');

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

/** `n` items over `spanDays` days from 2026-01-05, at random times (half of them bunched around a few times of day). */
function randomItems(n: number, spanDays: number, seed: number): DeskItem[] {
  const r = rng(seed);
  const start = Date.UTC(2026, 0, 5);
  const bunches = [7 * 60 + 40, 12 * 60 + 15, 18 * 60 + 5, 22 * 60 + 50];
  return Array.from({ length: n }, (_, k) => {
    const date = new Date(start + Math.floor(r() * spanDays) * 86_400_000).toISOString().slice(0, 10);
    const minute = r() < 0.5 ? (bunches[Math.floor(r() * bunches.length)] + Math.floor(r() * 25)) % 1440 : Math.floor(r() * 1440);
    return item(k, { kind: KINDS[Math.floor(r() * KINDS.length)], date, time: `${pad(Math.floor(minute / 60))}:${pad(minute % 60)}` });
  });
}

/** Each pile's drawn extent (every member, turned and jittered as placed) with the label room under it. */
function footprints(items: DeskItem[], r: LayoutResult): Map<string, { x0: number; x1: number; y0: number; y1: number }> {
  const kind = new Map(items.map(i => [i.id, i.kind]));
  const out = new Map<string, { x0: number; x1: number; y0: number; y1: number }>();
  for (const p of r.placements) {
    const { w, h } = SIZES[kind.get(p.id)!];
    const c = Math.abs(Math.cos(p.rot)), s = Math.abs(Math.sin(p.rot));
    const hw = (w * c + h * s) / 2, hh = (w * s + h * c) / 2;
    const f = out.get(p.pile) ?? { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
    f.x0 = Math.min(f.x0, p.x - hw); f.x1 = Math.max(f.x1, p.x + hw);
    f.y0 = Math.min(f.y0, p.y - hh); f.y1 = Math.max(f.y1, p.y + hh);
    out.set(p.pile, f);
  }
  for (const f of out.values()) f.y0 -= TIME_LABEL_ROOM;
  return out;
}

/** The checks every time layout must pass: no two piles' footprints overlap; in each column, piles are in time-of-day order. */
function assertReadable(items: DeskItem[], view: View, what: string): LayoutResult {
  const r = layouts.time(items, view, SIZES);
  assert.equal(r.placements.length, items.length, what);
  const f = footprints(items, r);
  const piles = r.piles;
  for (let a = 0; a < piles.length; a++) {
    for (let b = a + 1; b < piles.length; b++) {
      const p = f.get(piles[a].key)!, q = f.get(piles[b].key)!;
      const overlap = p.x0 < q.x1 - EPS && q.x0 < p.x1 - EPS && p.y0 < q.y1 - EPS && q.y0 < p.y1 - EPS;
      assert.ok(!overlap, `${what}: ${piles[a].label} at ${piles[a].x.toFixed(2)},${piles[a].y.toFixed(2)} overlaps ${piles[b].label} at ${piles[b].x.toFixed(2)},${piles[b].y.toFixed(2)}`);
    }
  }
  // Column order: walking a column from the far edge to the near one, time of day only goes forward, and each pile's
  // label is the time range of its members.
  const byId = new Map(items.map(i => [i.id, i]));
  const columns = new Map<number, PileInfo[]>();
  for (const p of piles) {
    const x = Math.round(p.x * 1000);
    columns.set(x, [...(columns.get(x) ?? []), p]);
  }
  for (const col of columns.values()) {
    col.sort((a, b) => b.y - a.y);
    let last = -1;
    for (const p of col) {
      const shares = p.ids.map(id => dayShare(byId.get(id)!.local_time)).sort((a, b) => a - b);
      assert.ok(shares[0] >= last, `${what}: ${p.label} lies nearer than a pile later in the day`);
      last = shares.at(-1)!;
      const times = p.ids.map(id => byId.get(id)!.local_time).sort((a, b) => dayShare(a) - dayShare(b));
      assert.equal(p.label, times[0] === times.at(-1) ? times[0] : `${times[0]}–${times.at(-1)}`, what);
    }
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
const SPANS: Record<TimeUnit, number[]> = { day: [1, 3, 7, 14], week: [15, 40, 112], month: [130, 400, 1100] };
const COUNTS = [1, 2, 7, 40, 300, 2000];

test('time: no two pile footprints overlap and every column runs in time-of-day order, for many random item sets', () => {
  let seed = 1, runs = 0;
  const seen = new Map<TimeUnit, number>();
  for (const [unit, spans] of Object.entries(SPANS) as [TimeUnit, number[]][]) {
    for (const span of spans) {
      for (const n of COUNTS) {
        for (const view of VIEWS) {
          const items = randomItems(n, span, seed++);
          const got = timeUnit(items.map(i => i.local_date));
          seen.set(got, (seen.get(got) ?? 0) + 1);
          assertReadable(items, view, `${unit} span ${span}, ${n} items, view ${view.width}x${view.height}, seed ${seed - 1}`);
          runs++;
        }
      }
    }
  }
  for (const unit of ['day', 'week', 'month'] as TimeUnit[]) assert.ok((seen.get(unit) ?? 0) >= 40, `${unit}: ${seen.get(unit)} runs`);
  // A further spread of counts from 1 to 2,000.
  const r = rng(99);
  for (let k = 0; k < 60; k++) {
    const n = 1 + Math.floor(r() * r() * 2000);
    const span = [2, 10, 30, 90, 500][k % 5];
    const view = VIEWS[k % VIEWS.length];
    assertReadable(randomItems(n, span, 1000 + k), view, `extra ${k}: span ${span}, ${n} items`);
    runs++;
  }
  assert.ok(runs > 300);
});

test('time: a column too full for its piles merges neighbours, and a merged pile is labelled with its time range', () => {
  // One day, an item every 40 minutes from 06:00 to 23:20: far more piles than a short view can hold one under another.
  const items = Array.from({ length: 27 }, (_, k) => {
    const m = 6 * 60 + k * 40;
    return item(k, { kind: 'screenshot', date: '2026-11-07', time: `${pad(Math.floor(m / 60))}:${pad(m % 60)}` });
  });
  const view = { width: 120.3, height: 60.9 };
  const r = assertReadable(items, view, 'one full day');
  assert.ok(r.piles.length >= 2 && r.piles.length < 27, `${r.piles.length} piles`);
  assert.ok(r.piles.some(p => p.count > 1 && /^\d\d:\d\d–\d\d:\d\d$/.test(p.label)), 'a merged pile shows its time range');
  // Morning far, night near.
  const ordered = [...r.piles].sort((a, b) => b.y - a.y);
  assert.ok(ordered[0].label.startsWith('06:00'));
  assert.ok(ordered.at(-1)!.label.endsWith('23:20'));
  // Everything still inside the view from top to bottom (only the label under the nearest pile reaches past it).
  for (const p of r.placements) {
    const hh = (7 * Math.abs(Math.sin(p.rot)) + 15 * Math.abs(Math.cos(p.rot))) / 2;
    assert.ok(Math.abs(p.y) + hh <= view.height / 2 + EPS, `${p.y}`);
  }
});

test('time: columns too narrow for a pile are widened rather than overlapped', () => {
  // Fourteen days in a view 90 wide: 6.4 units a column, narrower than any photo.
  const items = Array.from({ length: 14 }, (_, k) => item(k, { kind: 'photo', date: `2026-11-${pad(1 + k)}`, time: '10:00' }));
  const r = assertReadable(items, { width: 90, height: 45 }, 'fourteen days');
  assert.ok(r.backdrop?.type === 'columns');
  if (r.backdrop?.type !== 'columns') return;
  const cols = r.backdrop.columns;
  assert.equal(cols.length, 14);
  for (let k = 1; k < cols.length; k++) assert.ok(cols[k].x > cols[k - 1].x);
  assert.ok(Math.abs(cols[0].x + cols.at(-1)!.x) < EPS, 'the columns stay centred');
  for (const c of cols) assert.ok(c.width >= 15, `${c.width}`);
});
