// What every layout shares: a pile's stacking (oldest at the bottom, a small jitter from a hash of the capture id), keeping
// everything inside the usable area, and the grid of piles that `topic` and `person` use. Pure: no DOM, no three.js.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { LayoutResult, PileInfo, Placement, Size, SizeTable, View } from './types.ts';

export const EMPTY_LINE = 'Nothing matches. Try fewer words, or say "start over".';
/** Largest offset of an item from its pile's point, in desk units, on each axis. */
export const JITTER = 0.4;
/** Largest rotation of an item in a pile, in radians (4°). */
export const MAX_ROT = (4 * Math.PI) / 180;
/** At most this many of a pile's top sheets are drawn; the rest are the block of thickness under them. */
export const PILE_CAP = 12;
/** Room between neighbouring piles of the grid, for their labels. */
export const GRID_GAP = 6;

export interface Rect { x0: number; x1: number; y0: number; y1: number }
/** A group of items about to become one pile at `x`,`y`. */
export interface PileDraft { key: string; label: string; items: DeskItem[]; x: number; y: number }

export const viewRect = (v: View): Rect => ({ x0: -v.width / 2, x1: v.width / 2, y0: -v.height / 2, y1: v.height / 2 });
export const emptyResult = (): LayoutResult => ({ placements: [], piles: [], empty: EMPTY_LINE });

/** FNV-1a over the UTF-16 code units: a stable 32-bit hash. */
export function hash32(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return h >>> 0;
}

/** Three numbers in [-1, 1) from a seed (mulberry32), so the jitter is the same on every run and every machine. */
function unitTriple(seed: number): [number, number, number] {
  let a = seed;
  const next = () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return (((t ^ (t >>> 14)) >>> 0) / 4294967296) * 2 - 1;
  };
  return [next(), next(), next()];
}

export function jitterOf(id: string): { dx: number; dy: number; rot: number } {
  const [a, b, c] = unitTriple(hash32(id));
  return { dx: a * JITTER, dy: b * JITTER, rot: c * MAX_ROT };
}

/** Oldest first; the id breaks ties, so the order never depends on the input's. */
export const byTime = (a: DeskItem, b: DeskItem) =>
  a.captured_at < b.captured_at ? -1 : a.captured_at > b.captured_at ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0;

/** Half the width and height of the axis-aligned box around an object turned by `rot`. */
export function halfExtents(size: Size, rot: number): { hw: number; hh: number } {
  const c = Math.abs(Math.cos(rot)), s = Math.abs(Math.sin(rot));
  return { hw: (size.w * c + size.h * s) / 2, hh: (size.w * s + size.h * c) / 2 };
}

/** How far a pile's point must stay from the area's edges so that every member, jitter and rotation included, stays inside. */
export function marginOf(items: DeskItem[], sizes: SizeTable): { mx: number; my: number } {
  let mx = 0, my = 0;
  for (const it of items) {
    const { hw, hh } = halfExtents(sizes[it.kind], MAX_ROT);
    mx = Math.max(mx, hw + JITTER); my = Math.max(my, hh + JITTER);
  }
  return { mx, my };
}

/** The thickness block's size: the middle width and the middle height of the drawn sheets' sizes. */
export function blockSizeOf(drawn: Size[]): Size {
  const median = (xs: number[]) => xs.sort((a, b) => a - b)[xs.length >> 1] ?? 0;
  return { w: median(drawn.map(s => s.w)), h: median(drawn.map(s => s.h)) };
}

/** Moves a point into `r` shrunk by the margins; centred on an axis where the area is narrower than that. */
export function clampPoint(x: number, y: number, m: { mx: number; my: number }, r: Rect): { x: number; y: number } {
  const clamp = (v: number, lo: number, hi: number) => (lo > hi ? (lo + hi) / 2 : Math.min(hi, Math.max(lo, v)));
  return { x: clamp(x, r.x0 + m.mx, r.x1 - m.mx), y: clamp(y, r.y0 + m.my, r.y1 - m.my) };
}

/** One pile: its point kept inside `bounds`, its items stacked oldest at the bottom (order 0), ids listed top first. */
export function stackPile(d: PileDraft, sizes: SizeTable, bounds: Rect): { placements: Placement[]; pile: PileInfo } {
  const items = [...d.items].sort(byTime);
  const { x, y } = clampPoint(d.x, d.y, marginOf(items, sizes), bounds);
  const placements = items.map((it, order) => {
    const j = jitterOf(it.id);
    return { id: it.id, x: x + j.dx, y: y + j.dy, order, rot: j.rot, pile: d.key };
  });
  return { placements, pile: { key: d.key, label: d.label, count: items.length, x, y, ids: items.map(i => i.id).reverse() } };
}

/** Every draft stacked, in the drafts' order. */
export function collect(drafts: PileDraft[], sizes: SizeTable, bounds: Rect | ((d: PileDraft) => Rect)): Pick<LayoutResult, 'placements' | 'piles'> {
  const placements: Placement[] = [], piles: PileInfo[] = [];
  for (const d of drafts) {
    const s = stackPile(d, sizes, typeof bounds === 'function' ? bounds(d) : bounds);
    placements.push(...s.placements);
    piles.push(s.pile);
  }
  return { placements, piles };
}

/** Groups items by a key, keeping the first label seen for each key. */
export function groupBy(items: DeskItem[], keyOf: (it: DeskItem) => { key: string; label: string }): Map<string, { label: string; items: DeskItem[] }> {
  const groups = new Map<string, { label: string; items: DeskItem[] }>();
  for (const it of [...items].sort(byTime)) {
    const { key, label } = keyOf(it);
    let g = groups.get(key);
    if (!g) groups.set(key, g = { label, items: [] });
    g.items.push(it);
  }
  return groups;
}

/** Largest group first; equal sizes by label, then key (plain code-unit order, the same on every machine). */
export const largestFirst = (a: { key: string; label: string; items: unknown[] }, b: { key: string; label: string; items: unknown[] }) =>
  b.items.length - a.items.length || (a.label < b.label ? -1 : a.label > b.label ? 1 : a.key < b.key ? -1 : a.key > b.key ? 1 : 0);

/** The grid of piles: each cell is the largest object plus a gap; how many cells fit in the view (at least one). */
export function gridCells(view: View, sizes: SizeTable): { cellW: number; cellH: number; cols: number; rows: number; capacity: number } {
  const all = Object.values(sizes);
  const cellW = Math.max(...all.map(s => s.w)) + GRID_GAP, cellH = Math.max(...all.map(s => s.h)) + GRID_GAP;
  const cols = Math.max(1, Math.floor(view.width / cellW)), rows = Math.max(1, Math.floor(view.height / cellH));
  return { cellW, cellH, cols, rows, capacity: cols * rows };
}

/** Points for `n` piles, row-major from the far left, the used part of the grid centred in the view. */
export function gridPoints(n: number, view: View, sizes: SizeTable): { x: number; y: number }[] {
  const { cellW, cellH, cols } = gridCells(view, sizes);
  const used = Math.max(1, Math.min(cols, n)), rows = Math.ceil(n / used);
  return Array.from({ length: n }, (_, k) => {
    const c = k % used, r = Math.floor(k / used);
    return { x: (c - (used - 1) / 2) * cellW, y: ((rows - 1) / 2 - r) * cellH };
  });
}
