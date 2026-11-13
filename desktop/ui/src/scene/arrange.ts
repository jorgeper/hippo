// Applying a layout to the desk (spec section 8, "Motion"): which ids each pile draws (at most a dozen, the rest become the
// pile's thickness), who arrives, who glides, who is swept off, from and to which edge, in what order; then the pile labels,
// thickness blocks, the backdrop and the empty-state line. The planning functions at the top are pure, and nothing here
// touches the DOM at import, so `node --test` can check them; `createArranger` below drives the scene with the theme's
// builders and motions.
import { Box3, Vector3 } from 'three';
import type { Group, Object3D } from 'three';
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Backdrop, LayoutResult, PileInfo, Placement, Size } from '../layout/types.ts';
import type { BackdropMotion, Edge, Scrim, Theme } from '../themes/types.ts';
import type { ObjectStore, Pose } from './objects.ts';
import { spring, step, settled, snap } from './spring.ts';
import { blockSizeOf, PILE_CAP } from '../layout/pile.ts';

// ---------------------------------------------------------------- pure planning

export { PILE_CAP };

export interface Rect { x0: number; x1: number; y0: number; y1: number }
/** A desk area and how high the tallest pile on it stands (desk units), for framing the camera. */
export interface Bounds extends Rect { top: number }

/** Which of a pile's ids are drawn (the top `cap`, `ids` being top first) and how many are left to the thickness block. */
export function planPile(ids: readonly string[], cap = PILE_CAP): { drawn: string[]; hidden: number } {
  return { drawn: ids.slice(0, cap), hidden: Math.max(0, ids.length - cap) };
}

/** The side of `r` closest to x,y and how far it is (0 when outside). Ties prefer the near edge, then left, right, far. */
export function nearestEdge(x: number, y: number, r: Rect): { edge: Edge; distance: number } {
  const options: [Edge, number][] = [['near', y - r.y0], ['left', x - r.x0], ['right', r.x1 - x], ['far', r.y1 - y]];
  let best = options[0];
  for (const o of options) if (o[1] < best[1]) best = o;
  return { edge: best[0], distance: Math.max(0, best[1]) };
}

/** Arrivals in dealing order: each from the edge nearest its place, the ones closest to their edge first; ties by id. */
export function dealOrder(targets: readonly { id: string; x: number; y: number }[], r: Rect): { id: string; edge: Edge; distance: number }[] {
  return targets.map(t => ({ id: t.id, ...nearestEdge(t.x, t.y, r) }))
    .sort((a, b) => a.distance - b.distance || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/**
 * Where each object stands in the animation. `shown`: on the desk or on its way there. `leaving`: being swept off.
 * `tucking`: still in the set but under its pile's cap, gliding into the pile before it hides. Hidden ids are absent.
 */
export type Phase = 'shown' | 'leaving' | 'tucking';

export interface ChangePlan {
  /** Dealt in from an edge (not on the desk, or nowhere yet), in the order of `drawn`. */
  arrive: string[];
  /** Already visible (shown, or partway in or out): glide from where they are to their new place. */
  move: string[];
  /** Visible, still in the set, but no longer drawn: glide into the pile, then hide. */
  tuck: string[];
  /** Newly swept off. Ids already leaving keep going and are not listed again. */
  leave: string[];
  phases: Map<string, Phase>;
}

/**
 * The bookkeeping for one change of the set. `prev` is where everything stood when the change came (possibly mid-flight),
 * `drawn` the ids to draw now, `present` every id in the new set (drawn or under a pile's cap).
 */
export function planChange(prev: ReadonlyMap<string, Phase>, drawn: readonly string[], present: ReadonlySet<string>): ChangePlan {
  const plan: ChangePlan = { arrive: [], move: [], tuck: [], leave: [], phases: new Map() };
  const drawnSet = new Set(drawn);
  for (const id of drawn) {
    if (plan.phases.has(id)) continue;
    (prev.has(id) ? plan.move : plan.arrive).push(id);
    plan.phases.set(id, 'shown');
  }
  for (const [id, phase] of prev) {
    if (drawnSet.has(id)) continue;
    if (phase === 'leaving') { plan.phases.set(id, 'leaving'); continue; }
    if (present.has(id)) { plan.tuck.push(id); plan.phases.set(id, 'tucking'); }
    else { plan.leave.push(id); plan.phases.set(id, 'leaving'); }
  }
  return plan;
}

/** An object finished leaving or tucking: it is hidden and no longer tracked. A shown object stays shown. */
export function settle(phases: ReadonlyMap<string, Phase>, id: string): Map<string, Phase> {
  const next = new Map(phases);
  if (next.get(id) !== 'shown') next.delete(id);
  return next;
}

export interface PileBody extends Rect { key: string; weight: number }

/** Where a pile's label lies: its centre, its size as a share of its full size, and whether it lies on top of the pile. */
export interface LabelSpot { x: number; y: number; scale: number; onPile: boolean }

/** A label with no room beside its pile at full size tries again at these shares of its size. */
export const LABEL_SHRINK = [0.8, 0.62];
/** A label on its pile's near edge: this share of its size, inset this far from the edge. */
const ON_PILE_SCALE = 0.62, ON_PILE_INSET = 0.3;

/**
 * Places each pile's label beside its pile without covering another pile or label and inside `bounds`: below, else above,
 * else right, else left; the heaviest piles choose first. A label with no such spot tries the same spots smaller; failing
 * that it lies on its own pile's near edge, smaller, on top of the pile. Every pile with a size gets a spot.
 */
export function placeLabels(piles: readonly PileBody[], sizes: Readonly<Record<string, Size>>, bounds: Rect, gap: number): Map<string, LabelSpot> {
  const out = new Map<string, LabelSpot>();
  const taken: Rect[] = [];
  const overlaps = (a: Rect, b: Rect) => a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1;
  const order = [...piles].sort((a, b) => b.weight - a.weight || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  for (const p of order) {
    const full = sizes[p.key];
    if (!full) continue;
    const cx = (p.x0 + p.x1) / 2, cy = (p.y0 + p.y1) / 2;
    let chosen: LabelSpot | undefined;
    for (const scale of [1, ...LABEL_SHRINK]) {
      const w = full.w * scale, h = full.h * scale;
      const spots = [
        { x: cx, y: p.y0 - gap - h / 2 }, { x: cx, y: p.y1 + gap + h / 2 },
        { x: p.x1 + gap + w / 2, y: cy }, { x: p.x0 - gap - w / 2, y: cy },
      ];
      for (const c of spots) {
        const r = { x0: c.x - w / 2, x1: c.x + w / 2, y0: c.y - h / 2, y1: c.y + h / 2 };
        if (r.x0 < bounds.x0 || r.x1 > bounds.x1 || r.y0 < bounds.y0 || r.y1 > bounds.y1) continue;
        if (piles.some(o => o.key !== p.key && overlaps(r, o)) || taken.some(t => overlaps(r, t))) continue;
        chosen = { ...c, scale, onPile: false };
        taken.push(r);
        break;
      }
      if (chosen) break;
    }
    if (!chosen) {
      const h = full.h * ON_PILE_SCALE, w = full.w * ON_PILE_SCALE;
      const y = Math.min(cy, p.y0 + ON_PILE_INSET + h / 2);
      chosen = { x: cx, y, scale: ON_PILE_SCALE, onPile: true };
      taken.push({ x0: cx - w / 2, x1: cx + w / 2, y0: y - h / 2, y1: y + h / 2 });
    }
    out.set(p.key, chosen);
  }
  return out;
}

/** The axis-aligned half extents of a `size` object turned by `rot` about the vertical. */
export function halfExtents(size: Size, rot: number): { hw: number; hh: number } {
  const c = Math.abs(Math.cos(rot)), s = Math.abs(Math.sin(rot));
  return { hw: (size.w * c + size.h * s) / 2, hh: (size.w * s + size.h * c) / 2 };
}

// ---------------------------------------------------------------- applying a layout to the scene

/** Room between a pile and its label, and between stacked sheets (so nothing shares a depth). */
const LABEL_GAP = 1.2;
const SHEET_GAP = 0.025;
/** How many of a pile's top objects cast shadows. */
const SHADOW_CASTERS = 3;
/**
 * Only objects lying lower than this (desk units) cast shadows: in a tall pile (a dozen cassettes) the casters are the top
 * three of the part near the desk, so its shadow stays a short one at its foot instead of a box thrown far off by its top.
 */
const SHADOW_MAX_Z = 2.5;
/** Labels grow in after the arrivals have started. */
const LABEL_DELAY_MS = 220;
const LABEL_STIFFNESS = 140;
/** Blocks grow a little slower than labels, about as long as a card takes to land. */
const BLOCK_STIFFNESS = 110;
/** A block starts growing when its pile's first card comes within this distance (desk units), so it rises as that card lands. */
const BLOCK_NEAR = 14;
/** ... or this long after that card was dealt, whichever is first. */
const BLOCK_LATEST_MS = 900;
/** Room above a time layout's columns for their labels, in desk units. */
const COLUMN_LABEL_ROOM = 3.6;
/** The veil lies this far above the highest thing it dims; an open pile's spread lies this far above the veil. */
const SCRIM_GAP = 0.3, RAISED_GAP = 0.25;
/** Positions closer than this (desk units) are the same place. */
const SAME_PLACE = 1e-6;

interface PileParts { key: string; label?: Object3D; labelSize?: Size; block?: Object3D; blockTop: number;
  /** What the label says and what the block stands for: either changing builds that part again. */
  labelSig: string; blockSig: string;
  /** Where the label and block stand: a pile moved by the hand keeps them, a pile the layout moved elsewhere builds them again. */
  at: { x: number; y: number };
  scale: ReturnType<typeof spring>; startAt: number; labelPos?: LabelSpot;
  /** A new block grows up from the desk as its pile's first card comes in, rather than standing there bare. */
  grow?: ReturnType<typeof spring>; growAt: number; dealt?: string[] }

export interface Arranger {
  /**
   * Applies a layout. `frame` is called once the piles are built, with the area they (and their labels, backdrop or the
   * empty-state line) take; it answers with the desk area the camera will show, for dealing in and sweeping off.
   */
  apply(items: DeskItem[], layout: LayoutResult, frame: (b: Bounds) => Rect, now: number): void;
  /** The area the placed piles, labels and backdrop (or the empty-state line) take, in desk units, to frame the camera. */
  measure(items: DeskItem[], layout: LayoutResult): Rect;
  /** Grows labels and thickness blocks in and moves the backdrop; says whether anything moved, and whether a shadow caster did. */
  step(dt: number, now: number): { moving: boolean; shadows: boolean };
  /** The pile key under an object hit by a pick (labels and blocks carry it). */
  pileOf(obj: Object3D): string | undefined;
  pickables(): Object3D[];
  /** Called by the object store when an object finished leaving or tucking. */
  settled(id: string): void;
  phases(): ReadonlyMap<string, Phase>;
  setMapTiles(on: boolean): void;
  /** While an item is lifted: the veil also covers an open pile's spread. */
  setLifting(on: boolean, now: number): void;
  /** Moves a pile (its label, block and drawn objects) by dx,dy at once: the person is dragging it by its label. */
  shiftPile(key: string, dx: number, dy: number): void;
  /** The ids a pile draws, top last. */
  drawnOf(key: string): readonly string[];
}

const tmpBox = new Box3();
const tmpSize = new Vector3();

/** The size of a built object's footprint and its height, in its own (unrotated) frame. */
function footprint(obj: Object3D): { w: number; h: number; top: number } {
  const r = obj.rotation.z;
  obj.rotation.z = 0;
  obj.updateMatrixWorld(true);
  tmpBox.setFromObject(obj, true);
  obj.rotation.z = r;
  obj.updateMatrixWorld(true);
  if (tmpBox.isEmpty()) return { w: 0, h: 0, top: 0 };
  tmpBox.getSize(tmpSize);
  return { w: tmpSize.x, h: tmpSize.y, top: tmpBox.max.z };
}

function backdropSig(b: Backdrop | undefined): string { return b ? JSON.stringify(b) : ''; }

export function createArranger(scene: Group, theme: Theme, objects: ObjectStore): Arranger {
  let phases: Map<string, Phase> = new Map();
  let piles = new Map<string, PileParts>();
  let backdrop: { obj: Object3D; sig: string; floor: number; type: Backdrop['type'] } | undefined;
  /** Backdrops on their way out (a map sheet folding away), dropped once their motion says they are gone. */
  let goingAway: Object3D[] = [];
  let empty: { obj: Object3D; text: string } | undefined;
  let mapTiles = false;
  const pileByObject = new WeakMap<Object3D, string>();
  /** The last layout's piles by key, the ids each draws, and where members not drawn tuck in. */
  let pileInfo = new Map<string, PileInfo>();
  const drawnBy = new Map<string, string[]>();
  const tuckZ = new Map<string, number>();
  // The veil: under an open pile's spread, or over everything while an item is lifted.
  let scrim: Scrim | undefined;
  let raisedNow = false, lifting = false, scrimLow = 0, scrimHigh = 0;
  function placeScrim(now: number): void {
    const on = raisedNow || lifting;
    if (!scrim) {
      if (!on) return;
      scrim = theme.buildScrim();
      scene.add(scrim.object);
    }
    scrim.object.position.set(0, 0, lifting ? scrimHigh : scrimLow);
    scrim.set(on, now);
  }

  const dispose = (o: Object3D | undefined) => { if (o) { o.removeFromParent(); objects.disposeObject(o); } };
  const motionOf = (o: Object3D) => o.userData.motion as BackdropMotion | undefined;

  /**
   * Puts up the layout's backdrop. One of a new type arrives (the map unfolds) while the old one leaves by its own motion;
   * one that replaces a backdrop of the same type (the set changed, or map tiles were turned on or off) swaps in place.
   */
  function setBackdrop(b: Backdrop | undefined, now: number): number {
    const sig = backdropSig(b) + (b?.type === 'map' ? `|${mapTiles}` : '');
    if (backdrop?.sig === sig) return backdrop.floor;
    const sameType = !!b && backdrop?.type === b.type;
    if (backdrop) {
      const motion = motionOf(backdrop.obj);
      if (motion && !sameType) { motion.leave(now); goingAway.push(backdrop.obj); }
      else dispose(backdrop.obj);
    }
    backdrop = undefined;
    if (!b) return 0;
    const obj = theme.buildBackdrop(b, { mapTiles, arrive: !sameType });
    scene.add(obj);
    const floor = Math.max(0, Math.min(0.5, footprint(obj).top));
    backdrop = { obj, sig, floor, type: b.type };
    return floor;
  }

  /** The rectangle the members of each pile cover, from their placements and sizes. */
  function bodyOf(ps: Placement[], items: Map<string, DeskItem>): Rect {
    const r = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
    for (const p of ps) {
      const it = items.get(p.id);
      if (!it) continue;
      const { hw, hh } = halfExtents(theme.sizes[it.kind], p.rot);
      r.x0 = Math.min(r.x0, p.x - hw); r.x1 = Math.max(r.x1, p.x + hw);
      r.y0 = Math.min(r.y0, p.y - hh); r.y1 = Math.max(r.y1, p.y + hh);
    }
    return r;
  }

  /** The area to frame: while a pile is open, only its spread. */
  function measure(items: DeskItem[], layout: LayoutResult): Rect { return measureOf(items, layout, true); }

  function measureOf(items: DeskItem[], layout: LayoutResult, framing: boolean): Rect {
    if (layout.empty !== undefined) {
      const f = empty ? footprint(empty.obj) : { w: 40, h: 4 };
      return { x0: -f.w / 2 - 4, x1: f.w / 2 + 4, y0: -f.h / 2 - 4, y1: f.h / 2 + 4 };
    }
    const byId = new Map(items.map(i => [i.id, i]));
    // What is drawn: not a pile that draws none of its members; while a pile is open, only its spread (the camera frames it).
    const info = new Map(layout.piles.map(p => [p.key, p]));
    if (framing && layout.frame) return { ...layout.frame };
    const raised = framing && layout.piles.some(p => p.raised);
    const counted = layout.placements.filter(pl => {
      const p = info.get(pl.pile);
      return p?.cap !== 0 && (!raised || !!p?.raised);
    });
    const r = bodyOf(counted, byId);
    if (raised) { if (Number.isFinite(r.y0)) r.y0 -= 4; return r; }
    if (layout.backdrop?.type === 'columns') {
      const b = layout.backdrop;
      for (const c of b.columns) { r.x0 = Math.min(r.x0, c.x - c.width / 2); r.x1 = Math.max(r.x1, c.x + c.width / 2); }
      // The day labels are written just above the columns.
      r.y0 = Math.min(r.y0, b.bottom); r.y1 = Math.max(r.y1, b.top + COLUMN_LABEL_ROOM);
    } else if (layout.backdrop?.type === 'map') {
      const b = layout.backdrop;
      r.x0 = Math.min(r.x0, b.x - b.width / 2); r.x1 = Math.max(r.x1, b.x + b.width / 2);
      r.y0 = Math.min(r.y0, b.y - b.height / 2); r.y1 = Math.max(r.y1, b.y + b.height / 2);
    }
    // Room for the labels under the lowest piles.
    if (Number.isFinite(r.y0)) r.y0 -= 4;
    return r;
  }

  function apply(items: DeskItem[], layout: LayoutResult, frame: (b: Bounds) => Rect, now: number): void {
    const byId = new Map(items.map(i => [i.id, i]));
    drawnBy.clear();
    tuckZ.clear();
    const byPile = new Map<string, Placement[]>();
    const placementOf = new Map<string, Placement>();
    for (const p of layout.placements) {
      if (!byId.has(p.id)) continue;
      placementOf.set(p.id, p);
      let list = byPile.get(p.pile);
      if (!list) byPile.set(p.pile, list = []);
      list.push(p);
    }
    for (const it of items) objects.update(it);

    const floor = setBackdrop(layout.backdrop, now);

    // Empty-state line.
    if (layout.empty !== undefined) {
      if (empty?.text !== layout.empty) {
        dispose(empty?.obj);
        const obj = theme.buildPileLabel(layout.empty, 0);
        obj.position.set(0, 0, 0);
        scene.add(obj);
        empty = { obj, text: layout.empty };
      }
    } else if (empty) { dispose(empty.obj); empty = undefined; }

    // Which ids each pile draws, their targets and stacking. Piles on the desk first, then items dropped loose on top of
    // them, then (above the veil) an open pile's spread.
    const drawn: string[] = [];
    const targets = new Map<string, Pose & { cast: boolean; pile: string; badge?: string; pin?: boolean }>();
    const nextPiles = new Map<string, PileParts>();
    const bodies: PileBody[] = [];
    const labelSizes: Record<string, Size> = {};
    /** How high each pile's top sheet lies, for a label that has to lie on it. */
    const pileTops = new Map<string, number>();
    const rank = (p: PileInfo) => (p.raised ? 2 : p.loose ? 1 : 0);
    const ordered = layout.piles.map((p, k) => ({ p, k })).sort((a, b) => rank(a.p) - rank(b.p) || a.k - b.k).map(x => x.p);
    let lowTop = floor, raisedFloor = floor;
    let raisedReady = false;
    for (const pile of ordered) {
      const members = (byPile.get(pile.key) ?? []).slice().sort((a, b) => a.order - b.order);
      if (!members.length) continue;
      if (pile.raised && !raisedReady) { raisedReady = true; raisedFloor = lowTop + SCRIM_GAP + RAISED_GAP; }
      const plan = planPile(pile.ids, pile.cap ?? PILE_CAP);
      const drawnIds = new Set(plan.drawn);
      const shown = members.filter(m => drawnIds.has(m.id));
      // Where the pile's bottom lies: the desk (or the backdrop sheet), on top of the piles under a loose item, or above the veil.
      let base = floor;
      if (pile.raised) base = raisedFloor;
      else if (pile.loose && shown.length) {
        const own = bodyOf(shown, byId);
        for (const b of bodies) {
          if (own.x0 < b.x1 && b.x0 < own.x1 && own.y0 < b.y1 && b.y0 < own.y1) base = Math.max(base, (pileTops.get(b.key) ?? floor) + SHEET_GAP);
        }
      }
      // The block under the pile has the middle footprint of the drawn sheets, so it reads as more of the same underneath.
      const blockSize = blockSizeOf(shown.map(m => theme.sizes[byId.get(m.id)!.kind]));
      const wantsBlock = !pile.bare && plan.hidden > 0;
      const labelSig = pile.bare ? '' : `${pile.label}|${pile.count}|${pile.style ?? ''}`;
      const blockSig = wantsBlock ? `${plan.hidden}|${blockSize.w}x${blockSize.h}|${base}` : '';
      const old = piles.get(pile.key);
      piles.delete(pile.key);
      const samePlace = !!old && Math.abs(old.at.x - pile.x) < SAME_PLACE && Math.abs(old.at.y - pile.y) < SAME_PLACE;
      const parts: PileParts = old && samePlace ? old
        : { key: pile.key, labelSig: '', blockSig: '', at: { x: pile.x, y: pile.y }, blockTop: base,
          scale: spring(0, { stiffness: LABEL_STIFFNESS, damping: 0.8 }), startAt: now + LABEL_DELAY_MS, growAt: now };
      if (old && !samePlace) { dispose(old.label); dispose(old.block); }
      // The block: kept while it stands for the same; one that only changes height where it stands swaps in place;
      // anywhere else it grows in.
      if (parts.blockSig !== blockSig || !wantsBlock) {
        const standing = !!parts.block && !parts.grow;
        if (parts.block) { dispose(parts.block); parts.block = undefined; }
        parts.grow = undefined;
        parts.blockTop = base;
        if (wantsBlock) {
          const block = theme.buildThickness(plan.hidden, blockSize);
          if (block) {
            block.position.set(pile.x, pile.y, base);
            scene.add(block);
            parts.block = block;
            parts.blockTop = footprint(block).top;
            block.traverse(o => pileByObject.set(o, pile.key));
            if (!standing) {
              parts.grow = spring(0, { stiffness: BLOCK_STIFFNESS, damping: 1 });
              parts.grow.target = 1;
              block.scale.z = 0.001;
              block.visible = false;
              parts.growAt = now;
            }
          }
        }
        parts.blockSig = blockSig;
      }
      if (!parts.block) parts.blockTop = base;
      // The label: kept while it says the same.
      if (parts.labelSig !== labelSig) {
        if (parts.label) { dispose(parts.label); parts.label = undefined; parts.labelSize = undefined; }
        parts.scale = spring(0, { stiffness: LABEL_STIFFNESS, damping: 0.8 });
        parts.startAt = now + LABEL_DELAY_MS;
        if (!pile.bare) {
          const label = theme.buildPileLabel(pile.label, pile.count, pile.style);
          const f = footprint(label);
          parts.labelSize = { w: f.w, h: f.h };
          label.scale.setScalar(0.001);
          label.visible = false;
          scene.add(label);
          label.traverse(o => pileByObject.set(o, pile.key));
          parts.label = label;
        }
        parts.labelSig = labelSig;
      }
      nextPiles.set(pile.key, parts);
      let z = parts.blockTop;
      const zs = shown.map(m => { const at = z; z += theme.depths[byId.get(m.id)!.kind] + SHEET_GAP; return at; });
      // The highest objects that still lie near the desk cast the pile's shadow (shown is bottom first); nothing above the
      // veil casts one.
      let lastLow = -1;
      zs.forEach((at, k) => { if (at - base < SHADOW_MAX_Z || k === 0) lastLow = k; });
      shown.forEach((m, k) => {
        const cast = !pile.raised && k <= lastLow && k > lastLow - SHADOW_CASTERS;
        targets.set(m.id, { x: m.x, y: m.y, z: zs[k], rot: m.rot, cast, pile: pile.key, ...(m.badge ? { badge: m.badge } : {}), ...(m.pin ? { pin: true } : {}) });
        drawn.push(m.id);
      });
      // Members not drawn tuck into the pile at its foot.
      for (const m of members) if (!drawnIds.has(m.id)) tuckZ.set(m.id, base);
      pileTops.set(pile.key, z);
      if (!pile.raised) lowTop = Math.max(lowTop, z, parts.blockTop);
      drawnBy.set(pile.key, shown.map(m => m.id));
      if (shown.length) {
        const body = bodyOf(shown, byId);
        bodies.push({ key: pile.key, weight: pile.count, ...body });
      }
      if (parts.labelSize) labelSizes[pile.key] = parts.labelSize;
    }
    for (const old of piles.values()) { dispose(old.label); dispose(old.block); }
    piles = nextPiles;
    pileInfo = new Map(layout.piles.map(p => [p.key, p]));
    raisedNow = raisedReady;
    scrimLow = lowTop + SCRIM_GAP;
    scrimHigh = Math.max(lowTop, ...[...targets.values()].map(t => t.z + 0.7)) + SCRIM_GAP;
    placeScrim(now);

    // Labels beside their piles, never over another pile or label; smaller, or on the pile itself, when there is no room.
    const view = measureOf(items, layout, false);
    const bounds = { x0: view.x0 - 6, x1: view.x1 + 6, y0: view.y0 - 4, y1: view.y1 + 4 };
    const spots = placeLabels(bodies, labelSizes, bounds, LABEL_GAP);
    for (const parts of piles.values()) {
      if (!parts.label) continue;
      const spot = spots.get(parts.key);
      parts.labelPos = spot;
      if (spot) parts.label.position.set(spot.x, spot.y, spot.onPile ? (pileTops.get(parts.key) ?? floor) + SHEET_GAP : floor);
      parts.label.visible = !!spot && parts.label.scale.x > 0.01;
    }

    // Who arrives, glides, tucks and leaves.
    const present = new Set(placementOf.keys());
    const change = planChange(phases, drawn, present);
    phases = change.phases;
    let top = 0;
    for (const [id, t] of targets) top = Math.max(top, t.z + theme.depths[byId.get(id)!.kind]);
    const edges = frame({ ...measure(items, layout), top });

    // An object still waiting for its turn to be dealt in is not on the desk yet: it is dealt in again, not glided.
    const move: string[] = [], arrive: string[] = [...change.arrive];
    for (const id of change.move) (objects.onDesk(id) ? move : arrive).push(id);
    const arriveSet = new Set(arrive);
    const order = dealOrder(drawn.filter(id => arriveSet.has(id)).map(id => ({ id, x: targets.get(id)!.x, y: targets.get(id)!.y })), edges);

    const firstDeal = new Map<string, number>(), dealt = new Map<string, string[]>();
    // Out of a pile (it opens, it is scrolled, a card is pulled from under it): quickly, from that point, in order.
    let outOf = 0;
    order.forEach((o, k) => {
      const t = targets.get(o.id)!;
      const from = pileInfo.get(t.pile)?.from;
      const spec = from ? theme.motions.spread(outOf++) : theme.motions.arrive(k, o.edge);
      if (!from) {
        firstDeal.set(t.pile, Math.min(firstDeal.get(t.pile) ?? Infinity, spec.delay));
        dealt.set(t.pile, [...(dealt.get(t.pile) ?? []), o.id]);
      }
      objects.arrive(byId.get(o.id)!, t, o.edge, edges, spec, now,
        { castShadow: t.cast, pile: t.pile, badge: t.badge, pin: t.pin, ...(from ? { start: from } : {}) });
    });
    // Only what goes somewhere new takes its turn in the stagger; what stays put (a gesture moved one thing) starts at once.
    let quick = 0, stagger = 0;
    move.forEach(id => {
      const t = targets.get(id)!;
      const info = pileInfo.get(t.pile);
      const was = objects.homeOf(id);
      const goes = !was || Math.hypot(was.x - t.x, was.y - t.y) > 0.01 || Math.abs(was.rot - t.rot) > 0.001;
      const spec = info?.quick || info?.raised ? theme.motions.spread(goes ? quick++ : 0) : theme.motions.move(goes ? stagger++ : 0);
      objects.move(id, t, spec, now, { castShadow: t.cast, pile: t.pile, badge: t.badge, pin: t.pin });
    });
    change.tuck.forEach((id, k) => {
      const p = placementOf.get(id)!;
      const pile = pileInfo.get(p.pile);
      const spec = pile?.quick || pile?.raised || pile?.cap === 0 ? theme.motions.spread(k) : theme.motions.move(k);
      objects.tuck(id, { x: pile?.x ?? p.x, y: pile?.y ?? p.y, z: tuckZ.get(id) ?? floor, rot: p.rot }, spec, now, p.pile);
    });
    const leaving = change.leave.map(id => ({ id, at: objects.positionOf(id) }))
      .map(l => ({ ...l, ...(l.at ? nearestEdge(l.at.x, l.at.y, edges) : { edge: 'near' as Edge, distance: 0 }) }))
      .sort((a, b) => a.distance - b.distance);
    leaving.forEach((l, k) => objects.leave(l.id, l.edge, edges, theme.motions.leave(k, l.edge), now));
    for (const p of piles.values()) {
      if (!p.grow || p.grow.value !== 0) continue;
      p.dealt = dealt.get(p.key);
      p.growAt = now + (firstDeal.has(p.key) ? firstDeal.get(p.key)! + BLOCK_LATEST_MS : 0);
    }
    objects.prune(present);
  }

  function stepLabels(dt: number, now: number): { moving: boolean; shadows: boolean } {
    let moving = false, shadows = false;
    if (backdrop && motionOf(backdrop.obj)?.step(now)) moving = true;
    if (scrim?.step(now)) moving = true;
    if (goingAway.length) {
      goingAway = goingAway.filter(o => {
        if (motionOf(o)?.step(now)) return true;
        dispose(o);
        return false;
      });
      moving = true;
    }
    for (const p of piles.values()) {
      if (!p.grow || !p.block) continue;
      if (p.grow.value === 0 && now < p.growAt) {
        const { x, y } = p.block.position;
        const near = p.dealt?.some(id => { const at = objects.positionOf(id); return !!at && Math.hypot(at.x - x, at.y - y) < BLOCK_NEAR; });
        if (!near) { moving = true; continue; }
        p.growAt = now;
      }
      step(p.grow, dt);
      if (settled(p.grow, 1e-3)) { snap(p.grow, 1); p.grow = undefined; }
      const s = Math.max(0.001, p.grow?.value ?? 1);
      p.block.scale.z = s;
      p.block.visible = s > 0.01;
      moving = shadows = true;
    }
    for (const p of piles.values()) {
      if (!p.label) continue;
      if (now < p.startAt) { moving = true; continue; }
      p.scale.target = p.labelPos?.scale ?? 0;
      if (settled(p.scale, 1e-3)) { if (p.scale.value !== p.scale.target) snap(p.scale, p.scale.target); else continue; }
      step(p.scale, dt);
      const s = Math.max(0.001, p.scale.value);
      p.label.scale.setScalar(s);
      p.label.visible = !!p.labelPos && s > 0.01;
      moving = true;
    }
    return { moving, shadows };
  }

  return {
    apply,
    measure,
    step: stepLabels,
    pileOf: obj => {
      for (let o: Object3D | null = obj; o; o = o.parent) { const k = pileByObject.get(o); if (k) return k; }
      return undefined;
    },
    pickables: () => {
      const out: Object3D[] = [];
      // Only what is drawn: three's raycaster does not look at `visible`, and a block waiting to grow in is hidden.
      for (const p of piles.values()) { if (p.label?.visible) out.push(p.label); if (p.block?.visible) out.push(p.block); }
      return out;
    },
    settled: id => { phases = settle(phases, id); },
    phases: () => phases,
    setMapTiles: on => { mapTiles = on; },
    setLifting(on, now) { lifting = on; placeScrim(now); },
    shiftPile(key, dx, dy) {
      const parts = piles.get(key);
      if (parts) {
        parts.at = { x: parts.at.x + dx, y: parts.at.y + dy };
        for (const o of [parts.label, parts.block]) if (o) { o.position.x += dx; o.position.y += dy; }
      }
      for (const id of drawnBy.get(key) ?? []) objects.nudge(id, dx, dy);
    },
    drawnOf: key => drawnBy.get(key) ?? [],
  };
}
