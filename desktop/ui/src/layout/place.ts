// By place: a map sheet over the left 80% of the view, at the Web Mercator integer zoom that fits the located items' bounds
// (padded 15% on each side) at MAP_PX_PER_UNIT; north is away from the viewer. Items within 6 units of a pile's centroid
// join it (leader clustering, in time order). Then no two piles may lie across each other. A pile's footprint is what is
// drawn of it: its top PILE_CAP sheets as stacked, turned and jittered, and the thickness block under them; two piles
// overlap when their footprints come within PILE_GAP. While any two overlap, the closest overlapping pair merges (one pair
// at a time, everything re-checked after each), and a merged pile sits at its members' centre (so a member can end up more
// than 6 units from its pile). Then each merged pile is split again into two whenever that can be done without an overlap,
// so a pile holds several places only when no split of it would fit. A pile is labelled with the sub-locality or locality
// most of its members share. Items with no location form one pile, "No location", in the right 20%. With no located item
// there is no map and everything is in "No location", at the centre. Nothing is ever put at 0,0 for want of a place, and
// nothing is dropped.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Backdrop, LayoutFn, SizeTable } from './types.ts';
import { blockSizeOf, byTime, clampPoint, collect, emptyResult, halfExtents, jitterOf, marginOf, PILE_CAP, viewRect } from './pile.ts';
import type { PileDraft, Rect } from './pile.ts';
import type { PileInfo, Placement, View } from './types.ts';
import { lonLatToWorld, MAP_PX_PER_UNIT, MAX_LAT, worldToLonLat } from './mercator.ts';

export const NO_LOCATION = 'No location';
export const MAP_SHARE = 0.8;
export const MAP_PADDING = 0.15;
export const CLUSTER_DISTANCE = 6;
export const MIN_ZOOM = 0;
export const MAX_ZOOM = 17;
/** Room kept between neighbouring piles' footprints on the map, in desk units. */
export const PILE_GAP = 1;
/** Room under a pile kept free of place names on the sheet: where its label goes. */
export const LABEL_ROOM = 4;
/** At most this many sub-locality names on the sheet. */
export const MINOR_NAMES = 16;
/** A merged pile is tried for a split only while it holds at most this many leader clusters (2^(n-1) - 1 ways to split). */
export const SPLIT_MAX = 10;

const located = (it: DeskItem): boolean => !!it.place && Number.isFinite(it.place.lat) && Number.isFinite(it.place.lon)
  && Math.abs(it.place.lat) <= 90 && Math.abs(it.place.lon) <= 180;

/** The commonest value, ties broken by code-unit order; undefined when there is none. */
function commonest(values: (string | undefined)[]): string | undefined {
  const counts = new Map<string, number>();
  for (const v of values) if (v && v.trim()) counts.set(v.trim(), (counts.get(v.trim()) ?? 0) + 1);
  let best: string | undefined, n = 0;
  for (const [v, c] of counts) if (c > n || (c === n && best !== undefined && v < best)) { best = v; n = c; }
  return best;
}

/** A located item's point on the map area, and its place in time order (0 the oldest). */
export interface PlacePoint { it: DeskItem; x: number; y: number; order: number }

/**
 * The stages before piles merge, exported so the tests can check the merging against them: the map area, the zoom and the
 * centre of the sheet, every located item's point (in time order), and the leader clusters (points, in time order).
 * Undefined when no item is located.
 */
export function placeStages(items: DeskItem[], view: View): { map: Rect; zoom: number; center: { lon: number; lat: number };
  points: PlacePoint[]; leaders: PlacePoint[][] } | undefined {
  const here = items.filter(located);
  if (!here.length) return undefined;
  const whole = viewRect(view);
  const map: Rect = { x0: whole.x0, x1: whole.x0 + MAP_SHARE * view.width, y0: whole.y0, y1: whole.y1 };
  const mapW = map.x1 - map.x0, mapH = map.y1 - map.y0, mapX = (map.x0 + map.x1) / 2, mapY = (map.y0 + map.y1) / 2;

  // Bounds in world pixels at zoom 0, then the highest zoom at which the padded bounds fit the sheet.
  const at0 = here.map(it => ({ it, ...lonLatToWorld(it.place!.lon, it.place!.lat, 0) }));
  const xs = at0.map(p => p.x), ys = at0.map(p => p.y);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const grow = 1 + 2 * MAP_PADDING;
  let zoom = MIN_ZOOM;
  for (let z = MAX_ZOOM; z >= MIN_ZOOM; z--) {
    const scale = 2 ** z / MAP_PX_PER_UNIT;
    if ((maxX - minX) * grow * scale <= mapW && (maxY - minY) * grow * scale <= mapH) { zoom = z; break; }
  }
  const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  const center = worldToLonLat(cx, cy, 0);
  const scale = 2 ** zoom / MAP_PX_PER_UNIT;
  const points: PlacePoint[] = at0.map(p => ({ it: p.it, x: mapX + (p.x - cx) * scale, y: mapY - (p.y - cy) * scale, order: 0 }))
    .sort((a, b) => byTime(a.it, b.it));
  points.forEach((p, k) => { p.order = k; });

  // Leader clusters over the points in time-then-id order: each joins the nearest pile whose centroid is within
  // CLUSTER_DISTANCE, provided every member stays within CLUSTER_DISTANCE of the moved centroid; else it starts a pile.
  // A dense trail therefore becomes a row of piles, never one pile with members far from its point.
  const piles: { members: PlacePoint[]; x: number; y: number }[] = [];
  const near = (m: PlacePoint, x: number, y: number) => Math.hypot(m.x - x, m.y - y) <= CLUSTER_DISTANCE;
  for (const p of points) {
    const candidates = piles.map(c => ({ c, d: Math.hypot(p.x - c.x, p.y - c.y) })).filter(e => e.d < CLUSTER_DISTANCE)
      .sort((a, b) => a.d - b.d);
    let joined = false;
    for (const { c } of candidates) {
      const n = c.members.length + 1, x = (c.x * (n - 1) + p.x) / n, y = (c.y * (n - 1) + p.y) / n;
      if (near(p, x, y) && c.members.every(m => near(m, x, y))) { c.members.push(p); c.x = x; c.y = y; joined = true; break; }
    }
    if (!joined) piles.push({ members: [p], x: p.x, y: p.y });
  }
  return { map, zoom, center, points, leaders: piles.map(c => c.members) };
}

export const placeLayout: LayoutFn = (items, view, sizes) => {
  if (!items.length) return emptyResult();
  const whole = viewRect(view);
  const nowhere = items.filter(i => !located(i));
  const stages = placeStages(items, view);
  if (!stages) return collect([{ key: 'nowhere', label: NO_LOCATION, items, x: 0, y: 0 }], sizes, whole);
  const { map, zoom, center, points } = stages;
  const mapW = map.x1 - map.x0, mapH = map.y1 - map.y0, mapX = (map.x0 + map.x1) / 2, mapY = (map.y0 + map.y1) / 2;
  type Point = PlacePoint;
  const clusters = settlePiles(stages.leaders, sizes, map);
  const centre = (ms: Point[]) => ({ x: ms.reduce((s, m) => s + m.x, 0) / ms.length, y: ms.reduce((s, m) => s + m.y, 0) / ms.length });

  const drafts: PileDraft[] = clusters.map(members => {
    const firstId = members.map(m => m.it.id).sort()[0];
    const label = commonest(members.map(m => m.it.place!.sub_locality ?? m.it.place!.locality ?? m.it.place!.nearby)) ?? '';
    return { key: `place:${firstId}`, label, items: members.map(m => m.it), ...centre(members) };
  }).sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

  // Place names for the sheet: each locality at the middle of its items, then (smaller, `minor`) each sub-locality, at most
  // MINOR_NAMES of them, the ones with the most items first.
  const labels: { text: string; x: number; y: number; minor?: boolean }[] = [];
  const named = (nameOf: (p: (typeof points)[number]) => string | undefined) => {
    const groups = new Map<string, { x: number; y: number }[]>();
    for (const p of points) {
      const name = nameOf(p)?.trim();
      if (!name) continue;
      let list = groups.get(name);
      if (!list) groups.set(name, list = []);
      list.push(p);
    }
    return [...groups].map(([text, ps]) => ({ text, n: ps.length, x: ps.reduce((s, p) => s + p.x, 0) / ps.length, y: ps.reduce((s, p) => s + p.y, 0) / ps.length }));
  };
  const byName = (a: { text: string }, b: { text: string }) => (a.text < b.text ? -1 : a.text > b.text ? 1 : 0);
  const localities = named(p => p.it.place!.locality).sort(byName);
  for (const l of localities) labels.push({ text: l.text, x: l.x, y: l.y });
  const major = new Set(localities.map(l => l.text));
  for (const l of named(p => p.it.place!.sub_locality).filter(l => !major.has(l.text)).sort((a, b) => b.n - a.n || byName(a, b)).slice(0, MINOR_NAMES))
    labels.push({ text: l.text, x: l.x, y: l.y, minor: true });

  const side: Rect = { x0: map.x1, x1: whole.x1, y0: whole.y0, y1: whole.y1 };
  if (nowhere.length) drafts.push({ key: 'nowhere', label: NO_LOCATION, items: nowhere, x: (side.x0 + side.x1) / 2, y: 0 });
  const result = collect(drafts, sizes, d => (d.key === 'nowhere' ? side : map));
  // Where the piles and their labels lie, so the sheet writes its place names elsewhere.
  const avoid = result.piles.filter(p => p.key !== 'nowhere').map(p => {
    const f = drawnFootprint(p, result.placements, items, sizes);
    return { x0: f.x0, x1: f.x1, y0: f.y0 - LABEL_ROOM, y1: f.y1 };
  });
  const backdrop: Backdrop = { type: 'map', x: mapX, y: mapY, width: mapW, height: mapH, zoom,
    centerLat: Math.max(-MAX_LAT, Math.min(MAX_LAT, center.lat)), centerLon: center.lon, labels, avoid };
  return { ...result, backdrop };
};

/** The footprint of what is drawn of `pile` as laid out: its top PILE_CAP sheets, and the block under them at its point. */
function drawnFootprint(pile: PileInfo, placements: Placement[], items: DeskItem[], sizes: SizeTable): Rect {
  const kind = new Map(items.map(i => [i.id, i.kind]));
  const at = new Map(placements.map(p => [p.id, p]));
  const top = pile.ids.slice(0, PILE_CAP).map(id => at.get(id)!);
  const r = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
  for (const p of top) {
    const { hw, hh } = halfExtents(sizes[kind.get(p.id)!], p.rot);
    r.x0 = Math.min(r.x0, p.x - hw); r.x1 = Math.max(r.x1, p.x + hw);
    r.y0 = Math.min(r.y0, p.y - hh); r.y1 = Math.max(r.y1, p.y + hh);
  }
  if (pile.ids.length > PILE_CAP) {
    const b = blockSizeOf(top.map(p => sizes[kind.get(p.id)!]));
    r.x0 = Math.min(r.x0, pile.x - b.w / 2); r.x1 = Math.max(r.x1, pile.x + b.w / 2);
    r.y0 = Math.min(r.y0, pile.y - b.h / 2); r.y1 = Math.max(r.y1, pile.y + b.h / 2);
  }
  return r;
}

/** A leader cluster, summed up once: what the footprint of any union of clusters needs. */
interface Part<P> { members: P[]; n: number; sx: number; sy: number; mx: number; my: number; top: P[]; first: string }
/** A pile in the making: its leader clusters, where it stands and the footprint of what is drawn of it. */
interface Heap<P> extends Rect { parts: Part<P>[]; cx: number; cy: number; first: string }

function partOf<P extends PlacePoint>(members: P[], sizes: SizeTable): Part<P> {
  const { mx, my } = marginOf(members.map(m => m.it), sizes);
  const top = [...members].sort((a, b) => b.order - a.order).slice(0, PILE_CAP);
  return { members, n: members.length, sx: members.reduce((s, m) => s + m.x, 0), sy: members.reduce((s, m) => s + m.y, 0),
    mx, my, top, first: members.map(m => m.it.id).sort()[0] };
}

/** The pile the union of `parts` makes: at its members' centre kept inside `map` (as stackPile keeps it), with its footprint. */
function heapOf<P extends PlacePoint>(parts: Part<P>[], sizes: SizeTable, map: Rect): Heap<P> {
  let n = 0, sx = 0, sy = 0, mx = 0, my = 0, count = 0;
  for (const p of parts) { n += p.n; sx += p.sx; sy += p.sy; mx = Math.max(mx, p.mx); my = Math.max(my, p.my); }
  const { x, y } = clampPoint(sx / n, sy / n, { mx, my }, map);
  const top = parts.flatMap(p => p.top).sort((a, b) => b.order - a.order).slice(0, PILE_CAP);
  const r = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
  for (const m of top) {
    const j = jitterOf(m.it.id);
    const { hw, hh } = halfExtents(sizes[m.it.kind], j.rot);
    r.x0 = Math.min(r.x0, x + j.dx - hw); r.x1 = Math.max(r.x1, x + j.dx + hw);
    r.y0 = Math.min(r.y0, y + j.dy - hh); r.y1 = Math.max(r.y1, y + j.dy + hh);
    count++;
  }
  if (n > count) {
    const b = blockSizeOf(top.map(m => sizes[m.it.kind]));
    r.x0 = Math.min(r.x0, x - b.w / 2); r.x1 = Math.max(r.x1, x + b.w / 2);
    r.y0 = Math.min(r.y0, y - b.h / 2); r.y1 = Math.max(r.y1, y + b.h / 2);
  }
  return { ...r, parts, cx: x, cy: y, first: parts.map(p => p.first).sort()[0] };
}

/** Whether two piles' footprints come within PILE_GAP of each other. */
const clash = (p: Rect, q: Rect) => p.x0 < q.x1 + PILE_GAP && q.x0 < p.x1 + PILE_GAP && p.y0 < q.y1 + PILE_GAP && q.y0 < p.y1 + PILE_GAP;
const byFirst = (a: { first: string }, b: { first: string }) => (a.first < b.first ? -1 : a.first > b.first ? 1 : 0);

/**
 * The piles: the leader clusters, merged only as far as needed for no two to overlap. First, while any two overlap, the
 * closest overlapping pair (by their points) merges, and only the new pile is checked again. Greedy merging can still merge
 * more than it must (a merged pile lands between others and takes them in), so then every pile of 2 to SPLIT_MAX clusters
 * is tried for a split into two that overlap nothing (the most even such split, by item count), until none splits.
 */
function settlePiles<P extends PlacePoint>(leaders: P[][], sizes: SizeTable, map: Rect): P[][] {
  let heaps = leaders.map(ms => heapOf([partOf(ms, sizes)], sizes, map)).sort(byFirst);
  const alive = new Set(heaps);
  const pairs = new Map<Heap<P>, Set<Heap<P>>>();
  const link = (a: Heap<P>, b: Heap<P>) => { pairs.get(a)!.add(b); pairs.get(b)!.add(a); };
  for (const h of heaps) pairs.set(h, new Set());
  for (let a = 0; a < heaps.length; a++) for (let b = a + 1; b < heaps.length; b++) if (clash(heaps[a], heaps[b])) link(heaps[a], heaps[b]);
  for (;;) {
    let best: { a: Heap<P>; b: Heap<P>; d: number } | undefined;
    for (const a of alive) {
      for (const b of pairs.get(a)!) {
        if (byFirst(a, b) >= 0) continue;
        const d = Math.hypot(a.cx - b.cx, a.cy - b.cy);
        if (!best || d < best.d || (d === best.d && (byFirst(a, best.a) || byFirst(b, best.b)) < 0)) best = { a, b, d };
      }
    }
    if (!best) break;
    const merged = heapOf([...best.a.parts, ...best.b.parts], sizes, map);
    for (const old of [best.a, best.b]) {
      alive.delete(old);
      for (const o of pairs.get(old)!) pairs.get(o)!.delete(old);
      pairs.delete(old);
    }
    pairs.set(merged, new Set());
    for (const o of alive) if (clash(merged, o)) link(merged, o);
    alive.add(merged);
  }

  heaps = [...alive].sort(byFirst);
  for (let k = 0; k < heaps.length;) {
    const h = heaps[k];
    const split = h.parts.length >= 2 && h.parts.length <= SPLIT_MAX ? splitOf(h, heaps, sizes, map) : undefined;
    if (!split) { k++; continue; }
    // A split changes what the others stand beside: start the round again.
    heaps = [...heaps.slice(0, k), ...split, ...heaps.slice(k + 1)].sort(byFirst);
    k = 0;
  }
  return heaps.map(h => h.parts.flatMap(p => p.members));
}

/** The most even split of `h` into two piles that overlap neither each other nor any other pile; undefined when none does. */
function splitOf<P extends PlacePoint>(h: Heap<P>, all: Heap<P>[], sizes: SizeTable, map: Rect): [Heap<P>, Heap<P>] | undefined {
  const others = all.filter(o => o !== h);
  const k = h.parts.length, total = h.parts.reduce((s, p) => s + p.n, 0);
  let best: { pair: [Heap<P>, Heap<P>]; uneven: number } | undefined;
  // The last part always stays in the second half, so each split is tried once.
  for (let mask = 1; mask < 2 ** (k - 1); mask++) {
    const one = h.parts.filter((_, i) => mask & (1 << i)), two = h.parts.filter((_, i) => !(mask & (1 << i)));
    const n1 = one.reduce((s, p) => s + p.n, 0);
    const uneven = Math.abs(total - 2 * n1);
    if (best && uneven >= best.uneven) continue;
    const a = heapOf(one, sizes, map), b = heapOf(two, sizes, map);
    if (clash(a, b) || others.some(o => clash(a, o) || clash(b, o))) continue;
    best = { pair: [a, b], uneven };
  }
  return best?.pair;
}
