// The "Set aside" pile (spec section 8, "Handling", Dismiss): an item thrown toward an edge lands in a small pile in the
// lower right corner of the desk; the pile opens like any other, and clicking an item in it, or dragging one back onto the
// desk, takes it back. Dismissed items stay out through refinements until the person starts over (the store keeps the
// list; the server leaves them out of every result). Pure: the pile is worked out here, the scene draws it.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { PileInfo, PileStyle, Placement, SizeTable, View } from '../layout/types.ts';
import { halfExtents, jitterOf, marginOf } from '../layout/pile.ts';
import type { Rect } from '../layout/pile.ts';

export const ASIDE_KEY = 'aside';
export const ASIDE_LABEL = 'Set aside';
/** Room under a pile for its label, desk units (as the layouts leave it). */
export const LABEL_ROOM = 4;
/** A corner pile moves outward in steps this long until it covers no other pile. */
const STEP = 1.5, STEPS = 60;

/** The area each pile's members cover, with room for its label below it. */
export function bodiesOf(placements: readonly Placement[], sizes: SizeTable, kindOf: (id: string) => DeskItem['kind'] | undefined): Rect[] {
  const by = new Map<string, Rect>();
  for (const p of placements) {
    const kind = kindOf(p.id);
    if (!kind) continue;
    const { hw, hh } = halfExtents(sizes[kind], p.rot);
    const r = by.get(p.pile) ?? { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
    r.x0 = Math.min(r.x0, p.x - hw); r.x1 = Math.max(r.x1, p.x + hw);
    r.y0 = Math.min(r.y0, p.y - hh - LABEL_ROOM); r.y1 = Math.max(r.y1, p.y + hh);
    by.set(p.pile, r);
  }
  return [...by.values()];
}

const overlaps = (a: Rect, b: Rect) => a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1;

/**
 * The point of a corner pile holding `items`: in the view's near `corner`, inset so its members and its label lie inside;
 * moved outward (and toward the person) while it would cover one of `avoid`, so it never lies over a layout's pile.
 */
export function cornerPoint(corner: 'left' | 'right', items: DeskItem[], view: View, sizes: SizeTable, avoid: readonly Rect[]): { x: number; y: number } {
  const { mx, my } = marginOf(items, sizes);
  const sx = corner === 'right' ? 1 : -1;
  let x = sx * (view.width / 2 - mx), y = -view.height / 2 + my + LABEL_ROOM;
  for (let k = 0; k < STEPS; k++) {
    const r = { x0: x - mx, x1: x + mx, y0: y - my - LABEL_ROOM, y1: y + my };
    if (!avoid.some(a => overlaps(a, r))) break;
    x += sx * STEP; y -= STEP * 0.6;
  }
  return { x, y };
}

/**
 * A pile the handling keeps: `items` top first (the latest thrown or kept on top), stacked at x,y with each item's own small
 * jitter, labelled in the theme's `style`.
 */
export function extraPile(key: string, label: string, style: PileStyle, items: DeskItem[], at: { x: number; y: number },
  pin = false): { placements: Placement[]; pile: PileInfo } {
  const n = items.length;
  const placements = items.map((it, k) => {
    const j = jitterOf(it.id);
    return { id: it.id, x: at.x + j.dx, y: at.y + j.dy, order: n - 1 - k, rot: j.rot, pile: key, ...(pin ? { pin: true } : {}) };
  });
  return { placements, pile: { key, label, count: n, x: at.x, y: at.y, ids: items.map(i => i.id), style } };
}

/** The set-aside pile: the dismissed items the page knows, the latest on top; undefined when there are none. */
export function asidePile(dismissed: readonly string[], known: ReadonlyMap<string, DeskItem>, view: View, sizes: SizeTable,
  avoid: readonly Rect[]): { placements: Placement[]; pile: PileInfo } | undefined {
  const items = [...dismissed].reverse().map(id => known.get(id)).filter((i): i is DeskItem => !!i);
  if (!items.length) return undefined;
  return extraPile(ASIDE_KEY, ASIDE_LABEL, 'aside', items, cornerPoint('right', items, view, sizes, avoid));
}
