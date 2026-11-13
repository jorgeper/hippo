// Piles in the hand (spec section 8, "Handling"): a click spreads a pile out so every item shows, the rest of the desk
// dimmed and moved aside; the wheel scrolls an open pile's rows, and riffles a closed one (its top card to the bottom);
// Escape or a click outside gathers it. Pure: what the desk shows is worked out here as a layout, and the scene animates
// the change like any other (ui/src/scene/arrange.ts).
import type { LayoutResult, PileInfo, Placement, Size, View } from '../layout/types.ts';
import { jitterOf } from '../layout/pile.ts';

/** Room between spread items, desk units. */
export const SPREAD_GAP = 2.4;
/** The spread keeps this share of the view on each axis, so nothing touches the edge of the window. */
export const SPREAD_FILL = { x: 0.94, y: 0.9 };
/** The rest of the desk moves this share of its distance from the middle outward while a pile is open. */
export const ASIDE_SHARE = 0.16;
/** A spread item keeps this share of its turn in the pile, so the grid still looks laid down by hand. */
const SPREAD_TURN = 0.5;

/** The grid an open pile spreads into: columns, rows that fit, and the pitch between cells. */
export function spreadGrid(count: number, view: View, size: Size): { cols: number; rowsFit: number; rows: number; pitchX: number; pitchY: number } {
  const pitchX = size.w + SPREAD_GAP, pitchY = size.h + SPREAD_GAP;
  const colsFit = Math.max(1, Math.floor((view.width + SPREAD_GAP) / pitchX));
  const rowsFit = Math.max(1, Math.floor((view.height + SPREAD_GAP) / pitchY));
  if (count <= colsFit * rowsFit) {
    // As square as the view allows: the fewest rows, then the fewest columns that still hold them.
    const rows = Math.max(1, Math.ceil(count / colsFit));
    return { cols: Math.max(1, Math.ceil(count / rows)), rowsFit, rows, pitchX, pitchY };
  }
  return { cols: colsFit, rowsFit, rows: Math.ceil(count / colsFit), pitchX, pitchY };
}

/**
 * Where each of `count` items of `size` lies when its pile is spread over `view` (centred on 0,0), in reading order: a grid
 * that fits the view, centred when everything fits; when more than fit, the rows that fit fill the view from its top and
 * the rest run on below it, to be scrolled to.
 */
export function spreadPositions(count: number, view: View, size: Size): { x: number; y: number }[] {
  if (count <= 0) return [];
  const g = spreadGrid(count, view, size);
  const shownRows = Math.min(g.rows, g.rowsFit);
  const top = ((shownRows - 1) / 2) * g.pitchY;
  return Array.from({ length: count }, (_, k) => {
    const r = Math.floor(k / g.cols), c = k % g.cols;
    const inRow = Math.min(g.cols, count - r * g.cols);
    // A short last row is centred under the others.
    return { x: (c - (inRow - 1) / 2) * g.pitchX, y: top - r * g.pitchY };
  });
}

/** A pile riffled `steps` times: each step sends its top (the first id) to the bottom; negative steps bring the bottom up. */
export function riffle(ids: readonly string[], steps: number): string[] {
  const n = ids.length;
  if (!n) return [];
  const k = ((steps % n) + n) % n;
  return [...ids.slice(k), ...ids.slice(0, k)];
}

/** The pile's members restacked in a new order (top first): its ids and each member's place in the stack. */
export function restack(layout: LayoutResult, key: string, ids: string[]): LayoutResult {
  const pile = layout.piles.find(p => p.key === key);
  if (!pile) return layout;
  const order = new Map(ids.map((id, k) => [id, ids.length - 1 - k]));
  return {
    ...layout,
    piles: layout.piles.map(p => (p.key === key ? { ...p, ids } : p)),
    placements: layout.placements.map(pl => (pl.pile === key && order.has(pl.id) ? { ...pl, order: order.get(pl.id)! } : pl)),
  };
}

/** The view an open pile spreads over: the layout's view, kept a little off the window's edges. */
export const spreadView = (view: View): View => ({ width: view.width * SPREAD_FILL.x, height: view.height * SPREAD_FILL.y });

/** How many rows an open pile can scroll by, at most. */
export function maxScroll(count: number, view: View, size: Size): number {
  const g = spreadGrid(count, spreadView(view), size);
  return Math.max(0, g.rows - g.rowsFit);
}

/** The cell an open pile's grid uses: wide enough and tall enough for each of its members. */
export function cellOf(sizes: Size[]): Size {
  return { w: Math.max(1, ...sizes.map(s => s.w)), h: Math.max(1, ...sizes.map(s => s.h)) };
}

export const SPREAD_PREFIX = 'spread:';

/**
 * The desk with one pile open: its members spread over the view in their pile's order (top first), `scroll` rows down,
 * above the dimmed desk; members in rows out of view are present but not drawn; every other pile moved aside. Members
 * coming into view come out of the pile (on opening) or from where they were before the scroll (`prevScroll`).
 */
export function openPile(layout: LayoutResult, key: string, scroll: number, view: View, sizeOf: (id: string) => Size,
  prevScroll?: number): LayoutResult {
  const pile = layout.piles.find(p => p.key === key);
  if (!pile) return layout;
  const members = pile.ids;
  const cell = cellOf(members.map(sizeOf));
  const sv = spreadView(view);
  const g = spreadGrid(members.length, sv, cell);
  const at = spreadPositions(members.length, sv, cell);
  const shift = (s: number) => s * g.pitchY;
  const inView = (y: number) => y + cell.h / 2 <= sv.height / 2 + 1e-6 && y - cell.h / 2 >= -sv.height / 2 - 1e-6;
  const pinned = new Map(layout.placements.filter(p => p.pile === key).map(p => [p.id, !!p.pin]));

  const placements: Placement[] = [], piles: PileInfo[] = [];
  for (const p of layout.piles) {
    if (p.key === key) continue;
    const dx = p.x * ASIDE_SHARE, dy = p.y * ASIDE_SHARE;
    piles.push({ ...p, x: p.x + dx, y: p.y + dy });
    for (const pl of layout.placements) if (pl.pile === p.key) placements.push({ ...pl, x: pl.x + dx, y: pl.y + dy });
  }
  members.forEach((id, k) => {
    const x = at[k].x, y = at[k].y + shift(scroll);
    const visible = inView(y);
    const from = prevScroll === undefined ? { x: pile.x, y: pile.y } : { x, y: at[k].y + shift(prevScroll) };
    const own = `${SPREAD_PREFIX}${id}`;
    placements.push({ id, x, y, order: 0, rot: jitterOf(id).rot * SPREAD_TURN, pile: own, ...(pinned.get(id) ? { pin: true } : {}) });
    piles.push({ key: own, label: '', count: 1, x, y, ids: [id], bare: true, raised: true, cap: visible ? 1 : 0, from });
  });
  // The camera frames the whole view, so a pile of two opens at its own size rather than zooming the desk around it.
  return { ...layout, placements, piles, frame: { x0: -view.width / 2, x1: view.width / 2, y0: -view.height / 2, y1: view.height / 2 } };
}

/**
 * The desk while a riffle step pulls card `id` out of its pile to the side: the pile keeps its label and count, the card
 * lies beside it (on top of the pile's height when it is going under, at the desk when it is coming up from the bottom).
 */
export function pullOut(layout: LayoutResult, key: string, id: string, size: Size, goingUnder: boolean): LayoutResult {
  const pile = layout.piles.find(p => p.key === key);
  const pl = layout.placements.find(p => p.id === id);
  if (!pile || !pl) return layout;
  const x = pile.x + size.w * 0.85, y = pile.y + size.h * 0.12;
  const own = `pull:${id}`;
  return {
    ...layout,
    piles: [...layout.piles.map(p => (p.key === key ? { ...p, ids: p.ids.filter(i => i !== id), quick: true } : p)),
      { key: own, label: '', count: 1, x, y, ids: [id], bare: true, loose: goingUnder, quick: true, from: { x: pile.x, y: pile.y } }],
    placements: layout.placements.map(p => (p.id === id ? { ...p, x, y, order: 0, pile: own } : p)),
  };
}
