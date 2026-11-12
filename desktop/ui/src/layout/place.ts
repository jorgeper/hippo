// By place: a map sheet over the left 80% of the view, at the Web Mercator integer zoom that fits the located items' bounds
// (padded 15% on each side) at MAP_PX_PER_UNIT; north is away from the viewer. Items closer than 6 units (linked in a
// chain) form one pile at their centroid, labelled with the commonest sub-locality or locality. Items with no location form
// one pile, "No location", in the right 20%. With no located item there is no map and everything is in "No location", at
// the centre. Nothing is ever put at 0,0 for want of a place, and nothing is dropped.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Backdrop, LayoutFn } from './types.ts';
import { byTime, collect, emptyResult, viewRect } from './pile.ts';
import type { PileDraft, Rect } from './pile.ts';
import { lonLatToWorld, MAP_PX_PER_UNIT, MAX_LAT, worldToLonLat } from './mercator.ts';

export const NO_LOCATION = 'No location';
export const MAP_SHARE = 0.8;
export const MAP_PADDING = 0.15;
export const CLUSTER_DISTANCE = 6;
export const MIN_ZOOM = 0;
export const MAX_ZOOM = 17;

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

  // Single-linkage clusters: any two items closer than CLUSTER_DISTANCE end up in the same pile.
  const parent = points.map((_, k) => k);
  const root = (k: number): number => { while (parent[k] !== k) k = parent[k] = parent[parent[k]]; return k; };
  for (let a = 0; a < points.length; a++) for (let b = a + 1; b < points.length; b++) {
    if (Math.hypot(points[a].x - points[b].x, points[a].y - points[b].y) < CLUSTER_DISTANCE) {
      const ra = root(a), rb = root(b);
      if (ra !== rb) parent[Math.max(ra, rb)] = Math.min(ra, rb);
    }
  }
  const clusters = new Map<number, typeof points>();
  points.forEach((p, k) => { const r = root(k); let c = clusters.get(r); if (!c) clusters.set(r, c = []); c.push(p); });

  const drafts: PileDraft[] = [...clusters.values()].map(members => {
    const firstId = members.map(m => m.it.id).sort()[0];
    const label = commonest(members.map(m => m.it.place!.sub_locality ?? m.it.place!.locality ?? m.it.place!.nearby)) ?? '';
    return { key: `place:${firstId}`, label, items: members.map(m => m.it),
      x: members.reduce((s, m) => s + m.x, 0) / members.length, y: members.reduce((s, m) => s + m.y, 0) / members.length };
  }).sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

  const labels: { text: string; x: number; y: number }[] = [];
  const byLocality = new Map<string, { x: number; y: number }[]>();
  for (const p of points) {
    const name = p.it.place!.locality?.trim();
    if (!name) continue;
    let list = byLocality.get(name);
    if (!list) byLocality.set(name, list = []);
    list.push(p);
  }
  for (const [text, ps] of [...byLocality].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)))
    labels.push({ text, x: ps.reduce((s, p) => s + p.x, 0) / ps.length, y: ps.reduce((s, p) => s + p.y, 0) / ps.length });

  const side: Rect = { x0: map.x1, x1: whole.x1, y0: whole.y0, y1: whole.y1 };
  if (nowhere.length) drafts.push({ key: 'nowhere', label: NO_LOCATION, items: nowhere, x: (side.x0 + side.x1) / 2, y: 0 });
  const backdrop: Backdrop = { type: 'map', x: mapX, y: mapY, width: mapW, height: mapH, zoom,
    centerLat: Math.max(-MAX_LAT, Math.min(MAX_LAT, center.lat)), centerLon: center.lon, labels };
  return { ...collect(drafts, sizes, d => (d.key === 'nowhere' ? side : map)), backdrop };
};
