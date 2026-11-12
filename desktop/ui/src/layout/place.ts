// By place: a map sheet over the left 80% of the view, at the Web Mercator integer zoom that fits the located items' bounds
// (padded 15% on each side) at MAP_PX_PER_UNIT; north is away from the viewer. Items within 6 units of a pile's centroid
// join it (leader clustering, in time order). Then no two piles may lie across each other: while any two piles' footprints
// (every member as stacked, turned and jittered, plus PILE_GAP) overlap, the closest such pairs merge, and a merged pile sits
// at its members' centre (so a member can end up more than 6 units from its pile). A pile is labelled with the sub-locality
// or locality most of its members share. Items with no location form one pile, "No location", in the right 20%. With no
// located item there is no map and everything is in "No location", at the centre. Nothing is ever put at 0,0 for want of a
// place, and nothing is dropped.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Backdrop, LayoutFn, SizeTable } from './types.ts';
import { byTime, collect, emptyResult, halfExtents, stackPile, viewRect } from './pile.ts';
import type { PileDraft, Rect } from './pile.ts';
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

export const placeLayout: LayoutFn = (items, view, sizes) => {
  if (!items.length) return emptyResult();
  const whole = viewRect(view);
  const here = items.filter(located), nowhere = items.filter(i => !located(i));
  if (!here.length) return collect([{ key: 'nowhere', label: NO_LOCATION, items, x: 0, y: 0 }], sizes, whole);

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
  const points = at0.map(p => ({ it: p.it, x: mapX + (p.x - cx) * scale, y: mapY - (p.y - cy) * scale }))
    .sort((a, b) => byTime(a.it, b.it));

  // Leader clusters over the points in time-then-id order: each joins the nearest pile whose centroid is within
  // CLUSTER_DISTANCE, provided every member stays within CLUSTER_DISTANCE of the moved centroid; else it starts a pile.
  // A dense trail therefore becomes a row of piles, never one pile with members far from its point.
  type Point = (typeof points)[number];
  const piles: { members: Point[]; x: number; y: number }[] = [];
  const near = (m: Point, x: number, y: number) => Math.hypot(m.x - x, m.y - y) <= CLUSTER_DISTANCE;
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
  const clusters = mergeOverlapping(piles.map(c => c.members), sizes, map);
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
  const avoid = drafts.filter(d => d.key !== 'nowhere').map(d => {
    const f = footprintOf(result.placements.filter(p => p.pile === d.key), d.items, sizes);
    return { x0: f.x0, x1: f.x1, y0: f.y0 - LABEL_ROOM, y1: f.y1 };
  });
  const backdrop: Backdrop = { type: 'map', x: mapX, y: mapY, width: mapW, height: mapH, zoom,
    centerLat: Math.max(-MAX_LAT, Math.min(MAX_LAT, center.lat)), centerLon: center.lon, labels, avoid };
  return { ...result, backdrop };
};

/** The box around a pile's members as placed: each turned by its rotation, from its kind's size. */
function footprintOf(placements: { id: string; x: number; y: number; rot: number }[], items: DeskItem[], sizes: SizeTable): Rect {
  const kind = new Map(items.map(i => [i.id, i.kind]));
  const r = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
  for (const p of placements) {
    const { hw, hh } = halfExtents(sizes[kind.get(p.id)!], p.rot);
    r.x0 = Math.min(r.x0, p.x - hw); r.x1 = Math.max(r.x1, p.x + hw);
    r.y0 = Math.min(r.y0, p.y - hh); r.y1 = Math.max(r.y1, p.y + hh);
  }
  return r;
}

/**
 * Merges clusters until no two piles' footprints (as `stackPile` would place them in `map`, PILE_GAP apart) overlap. Each round
 * merges the overlapping pairs closest first, each cluster at most once a round, so a dense trail halves round by round
 * into a row of piles instead of chaining into one. Every merge lowers the count, so it ends (at worst in one pile).
 */
function mergeOverlapping<P extends { it: DeskItem; x: number; y: number }>(clusters: P[][], sizes: SizeTable, map: Rect): P[][] {
  let list = clusters;
  for (;;) {
    const boxes = list.map(ms => {
      const x = ms.reduce((s, m) => s + m.x, 0) / ms.length, y = ms.reduce((s, m) => s + m.y, 0) / ms.length;
      const items = ms.map(m => m.it);
      const { placements, pile } = stackPile({ key: '', label: '', items, x, y }, sizes, map);
      return { ...footprintOf(placements, items, sizes), cx: pile.x, cy: pile.y };
    });
    const pairs: { a: number; b: number; d: number }[] = [];
    for (let a = 0; a < boxes.length; a++) {
      const p = boxes[a];
      for (let b = a + 1; b < boxes.length; b++) {
        const q = boxes[b];
        if (p.x0 < q.x1 + PILE_GAP && q.x0 < p.x1 + PILE_GAP && p.y0 < q.y1 + PILE_GAP && q.y0 < p.y1 + PILE_GAP)
          pairs.push({ a, b, d: Math.hypot(p.cx - q.cx, p.cy - q.cy) });
      }
    }
    if (!pairs.length) return list;
    pairs.sort((p, q) => p.d - q.d || p.a - q.a || p.b - q.b);
    const used = new Set<number>(), gone = new Set<number>();
    const next = list.map(ms => [...ms]);
    for (const { a, b } of pairs) {
      if (used.has(a) || used.has(b)) continue;
      used.add(a); used.add(b); gone.add(b);
      next[a].push(...next[b]);
    }
    list = next.filter((_, k) => !gone.has(k));
  }
}
