// One persistent object per capture id (spec section 8, "Motion"). An object is built from the theme the first time it has
// to be seen, with small textures; a full-size one replaces it while it covers a large part of the screen and is released
// when it no longer does. Its place is a set of springs, so a new target mid-flight carries on from where it is. A hidden
// object keeps only its small version, and only the most recently hidden few hundred are kept at all.
import { Group } from 'three';
import type { Material, Mesh, Object3D, PerspectiveCamera, Texture } from 'three';
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Easing, Edge, MotionSpec, Theme } from '../themes/types.ts';
import type { Rect } from './arrange.ts';
import { spring, step, snap } from './spring.ts';
import type { Spring } from './spring.ts';

export interface Pose { x: number; y: number; z: number; rot: number }

/** An object full-size above this many CSS pixels on screen, small again below the second. */
export const FULL_ABOVE_PX = 300;
export const SMALL_BELOW_PX = 240;
/** Full-size objects at once, the largest on screen first. */
export const MAX_FULL = 24;
/** Hidden objects kept for reuse (their small version only); older ones are disposed. */
export const HIDDEN_KEPT = 240;
/** New objects built per frame, so a big deal-in spreads its canvas work over frames. */
const BUILDS_PER_FRAME = 10;
/** The vertical spring that follows the arc and the stacking height. */
const Z_STIFFNESS = 380;
const POS_EPS = 0.01;
const ROT_EPS = 0.001;
/** Off-desk distance beyond the visible edge, besides the object's own size. */
const OFF_DESK = 6;

type Step = 'arrive' | 'move' | 'tuck' | 'leave';
interface Pending { at: number; kind: Step; target: Pose; spec: MotionSpec; from?: Pose }
interface Arc { t0: number; duration: number; from: Pose; to: Pose; height: number; spin: number; easing: Easing }

export interface Entry {
  id: string;
  item: DeskItem;
  sig: string;
  gen: number;
  slot?: Group;
  small?: Object3D;
  full?: Object3D;
  loadingFull?: Object3D;
  badge?: Object3D;
  badgeText?: string;
  x: Spring; y: Spring; rot: Spring; z: Spring;
  baseZ: number; lift: number; dist0: number; fade: -1 | 0 | 1; opacity: number;
  pending?: Pending;
  arc?: Arc;
  phase: 'shown' | 'leaving' | 'tucking' | 'hidden';
  /** Has appeared on the desk since it was last hidden. */
  onDesk: boolean;
  active: boolean;
  castShadow: boolean;
  pile?: string;
  screenPx: number;
}

export interface ShowOptions { castShadow: boolean; pile: string; badge?: string }

export interface StepResult { moving: boolean; shadowsMoved: boolean }

export interface ObjectStore {
  update(item: DeskItem): void;
  /** Forgets ids that are neither in the set nor on the desk. */
  prune(present: ReadonlySet<string>): void;
  arrive(item: DeskItem, target: Pose, from: Edge, edges: Rect, spec: MotionSpec, now: number, opts: ShowOptions): void;
  move(id: string, target: Pose, spec: MotionSpec, now: number, opts: ShowOptions): void;
  tuck(id: string, target: Pose, spec: MotionSpec, now: number, pile: string): void;
  leave(id: string, to: Edge, edges: Rect, spec: MotionSpec, now: number): void;
  onDesk(id: string): boolean;
  positionOf(id: string): { x: number; y: number } | undefined;
  step(dt: number, now: number): StepResult;
  /** Swaps small and full-size versions by how large each object is on screen. True when it changed anything. */
  updateLod(camera: PerspectiveCamera, viewHeightPx: number): boolean;
  objectOf(id: string): Object3D | undefined;
  idOf(obj: Object3D): string | undefined;
  pileOfId(id: string): string | undefined;
  pickables(): Object3D[];
  disposeObject(obj: Object3D): void;
  stats(): { entries: number; built: number; onDesk: number; full: number; hiddenKept: number; active: number };
}

export interface ObjectHooks {
  /** An object finished leaving or tucking and is hidden. */
  settled(id: string): void;
  /** Something changed outside a frame step (a full-size face arrived): draw again. */
  changed(): void;
}

const EASE: Record<Easing, (u: number) => number> = {
  linear: u => u,
  easeIn: u => u * u * u,
  easeOut: u => 1 - (1 - u) ** 3,
  easeInOut: u => (u < 0.5 ? 4 * u * u * u : 1 - (-2 * u + 2) ** 3 / 2),
};

function eachMaterial(obj: Object3D, fn: (m: Material) => void): void {
  obj.traverse(o => {
    const mat = (o as Mesh).material as Material | Material[] | undefined;
    if (!mat) return;
    if (Array.isArray(mat)) mat.forEach(fn); else fn(mat);
  });
}

/** Disposes what a theme built for one object: its materials and textures and geometries, except those marked shared. */
export function disposeObject(obj: Object3D): void {
  obj.traverse(o => {
    (o.userData.dispose as (() => void) | undefined)?.();
    const g = (o as Mesh).geometry;
    if (g && !g.userData.shared) g.dispose();
  });
  eachMaterial(obj, m => {
    if (m.userData.shared) return;
    for (const v of Object.values(m)) {
      const t = v as Texture | null;
      if (t && (t as Texture).isTexture && !t.userData.shared) t.dispose();
    }
    m.dispose();
  });
}

function setOpacity(obj: Object3D, o: number): void {
  const transparent = o < 0.999;
  eachMaterial(obj, m => {
    if (m.transparent !== transparent) { m.transparent = transparent; m.needsUpdate = true; }
    m.opacity = transparent ? o : 1;
  });
}

function setShadow(obj: Object3D, cast: boolean): void {
  obj.traverse(o => { if ((o as Mesh).isMesh) o.castShadow = cast; });
}

const sigOf = (it: DeskItem) => JSON.stringify(it);

export function createObjects(world: Group, theme: Theme, hooks: ObjectHooks): ObjectStore {
  const pendingBadges = new Map<string, string | undefined>();
  const entries = new Map<string, Entry>();
  const active: Entry[] = [];
  const hidden = new Map<string, Entry>();   // hidden with a built object, oldest first
  const owner = new WeakMap<Object3D, Entry>();
  let gen = 0;
  let builds = 0;
  let fullCount = 0;

  function entryFor(item: DeskItem): Entry {
    let e = entries.get(item.id);
    if (!e) {
      e = { id: item.id, item, sig: sigOf(item), gen, x: spring(0), y: spring(0), rot: spring(0), z: spring(0, { stiffness: Z_STIFFNESS }),
        baseZ: 0, lift: 0, dist0: 0, fade: 0, opacity: 1, phase: 'hidden', onDesk: false, active: false, castShadow: false, screenPx: 0 };
      entries.set(item.id, e);
    }
    return e;
  }

  function activate(e: Entry): void { if (!e.active) { e.active = true; active.push(e); } }

  function dropFull(e: Entry): void {
    if (e.loadingFull) { disposeObject(e.loadingFull); e.loadingFull = undefined; }
    if (e.full) {
      e.full.removeFromParent();
      disposeObject(e.full);
      e.full = undefined;
      fullCount--;
      if (e.small && e.slot) { e.slot.add(e.small); setShadow(e.small, e.castShadow); setOpacity(e.small, e.opacity); }
    }
  }

  function unbuild(e: Entry): void {
    dropFull(e);
    if (e.small) { disposeObject(e.small); e.small = undefined; }
    if (e.badge) { disposeObject(e.badge); e.badge = undefined; e.badgeText = undefined; }
    e.slot?.removeFromParent();
    e.slot = undefined;
    hidden.delete(e.id);
  }

  function build(e: Entry): void {
    if (e.slot && e.small) return;
    const slot = e.slot ?? new Group();
    slot.name = 'desk-object';
    slot.rotation.order = 'ZYX';   // turn about the vertical last, so a flip turns about the object's own long axis
    const small = theme.buildObject(e.item, 'small');
    slot.add(small);
    owner.set(slot, e);
    e.slot = slot;
    e.small = small;
    builds++;
  }

  function current(e: Entry): Object3D | undefined { return e.full ?? e.small; }

  function setBadge(e: Entry, text: string | undefined): void {
    if (e.badgeText === text) return;
    if (e.badge) { e.badge.removeFromParent(); disposeObject(e.badge); e.badge = undefined; }
    e.badgeText = text;
    if (!text || !e.slot) return;
    const size = theme.sizes[e.item.kind];
    const b = theme.buildBadge(text);
    b.position.set(-size.w / 2 + 1.2, size.h / 2 - 1.2, theme.depths[e.item.kind] + 0.01);
    e.slot.add(b);
    e.badge = b;
  }

  function show(e: Entry): void {
    build(e);
    hidden.delete(e.id);
    if (e.slot && !e.slot.parent) world.add(e.slot);
    if (e.slot) e.slot.visible = true;
    e.onDesk = true;
  }

  function hide(e: Entry): void {
    e.phase = 'hidden';
    e.onDesk = false;
    e.pending = undefined;
    e.arc = undefined;
    dropFull(e);
    if (e.slot) {
      e.slot.removeFromParent();
      hidden.delete(e.id);
      hidden.set(e.id, e);
      while (hidden.size > HIDDEN_KEPT) {
        const oldest = hidden.values().next().value as Entry;
        unbuild(oldest);
        if (oldest.gen < gen) entries.delete(oldest.id);
      }
    }
    hooks.settled(e.id);
  }

  function writePose(e: Entry): void {
    const s = e.slot;
    if (!s) return;
    s.position.set(e.x.value, e.y.value, e.z.value);
    s.rotation.z = e.rot.value;
  }

  function offDesk(item: DeskItem, edge: Edge, edges: Rect, near: { x: number; y: number }): { x: number; y: number } {
    const size = theme.sizes[item.kind];
    const m = Math.hypot(size.w, size.h) / 2 + OFF_DESK;
    const cy = Math.min(edges.y1, Math.max(edges.y0, near.y)), cx = Math.min(edges.x1, Math.max(edges.x0, near.x));
    if (edge === 'left') return { x: edges.x0 - m, y: cy };
    if (edge === 'right') return { x: edges.x1 + m, y: cy };
    if (edge === 'far') return { x: cx, y: edges.y1 + m };
    return { x: cx, y: edges.y0 - m };
  }

  function toward(edge: Edge): { dx: number; dy: number } {
    return edge === 'left' ? { dx: -1, dy: 0 } : edge === 'right' ? { dx: 1, dy: 0 } : edge === 'far' ? { dx: 0, dy: 1 } : { dx: 0, dy: -1 };
  }

  function schedule(e: Entry, kind: Step, target: Pose, spec: MotionSpec, now: number, from?: Pose): void {
    e.pending = { at: now + spec.delay, kind, target, spec, ...(from ? { from } : {}) };
    activate(e);
  }

  /** Starts a scheduled motion: springs or a scripted arc toward the target, from where the object is (or `from`). */
  function begin(e: Entry, p: Pending, now: number): void {
    e.pending = undefined;
    const spec = p.spec;
    if (p.from) {
      snap(e.x, p.from.x); snap(e.y, p.from.y); snap(e.rot, p.from.rot); snap(e.z, p.from.z);
    }
    if (p.kind === 'arrive') {
      show(e);
      if (e.slot) { setShadow(current(e)!, e.castShadow); }
    }
    e.fade = spec.type === 'spring' && spec.fade ? (p.kind === 'leave' ? -1 : p.kind === 'arrive' ? 1 : 0) : 0;
    if (e.fade === 0 && e.opacity !== 1) { e.opacity = 1; const c = current(e); if (c) setOpacity(c, 1); }
    // Unwind the turn the shortest way.
    const turn = p.target.rot - e.rot.value;
    const wrapped = turn - 2 * Math.PI * Math.round(turn / (2 * Math.PI));
    const rotTarget = e.rot.value + wrapped;
    if (spec.type === 'arc') {
      e.arc = { t0: now, duration: Math.max(1, spec.duration), from: { x: e.x.value, y: e.y.value, z: e.z.value, rot: e.rot.value },
        to: { ...p.target, rot: rotTarget }, height: spec.height, spin: spec.spin, easing: spec.easing };
      e.baseZ = p.target.z;
      return;
    }
    e.arc = undefined;
    for (const s of [e.x, e.y, e.rot]) { s.stiffness = spec.stiffness; s.damping = spec.damping; }
    e.x.target = p.target.x; e.y.target = p.target.y; e.rot.target = rotTarget;
    e.baseZ = p.target.z;
    e.lift = spec.lift;
    e.dist0 = Math.hypot(e.x.target - e.x.value, e.y.target - e.y.value);
  }

  function progress(e: Entry): number {
    if (e.dist0 < 0.05) return 1;
    const d = Math.hypot(e.x.target - e.x.value, e.y.target - e.y.value);
    return Math.min(1, Math.max(0, 1 - d / e.dist0));
  }

  function finish(e: Entry): void {
    if (e.phase === 'leaving' || e.phase === 'tucking') hide(e);
  }

  function stepOne(e: Entry, dt: number, now: number): boolean {
    if (e.pending && now >= e.pending.at) {
      if (e.pending.kind === 'arrive' && !e.slot && builds >= BUILDS_PER_FRAME) return true; // build next frame
      begin(e, e.pending, now);
    }
    if (!e.onDesk) return !!e.pending;
    const px = e.x.value, py = e.y.value, pz = e.z.value, pr = e.rot.value;
    let busy: boolean;
    if (e.arc) {
      const a = e.arc, u = Math.min(1, (now - a.t0) / a.duration), k = EASE[a.easing](u);
      e.x.value = a.from.x + (a.to.x - a.from.x) * k;
      e.y.value = a.from.y + (a.to.y - a.from.y) * k;
      e.rot.value = a.from.rot + (a.to.rot - a.from.rot) * k;
      e.z.value = a.from.z + (a.to.z - a.from.z) * k + a.height * 4 * u * (1 - u);
      if (e.slot) e.slot.rotation.x = a.spin * k;
      if (u >= 1) {
        e.arc = undefined;
        snap(e.x, a.to.x); snap(e.y, a.to.y); snap(e.rot, a.to.rot); snap(e.z, a.to.z);
        if (e.slot) e.slot.rotation.x = 0;
      }
      busy = !!e.arc;
    } else {
      step(e.x, dt); step(e.y, dt); step(e.rot, dt);
      const p = progress(e);
      e.z.target = e.baseZ + e.lift * 4 * p * (1 - p);
      step(e.z, dt);
      if (e.fade !== 0) {
        e.opacity = e.fade > 0 ? p : 1 - p;
        const c = current(e);
        if (c) setOpacity(c, e.opacity);
      }
      busy = Math.abs(e.x.value - e.x.target) > POS_EPS || Math.abs(e.y.value - e.y.target) > POS_EPS
        || Math.abs(e.z.value - e.z.target) > POS_EPS || Math.abs(e.rot.value - e.rot.target) > ROT_EPS
        || Math.abs(e.x.velocity) + Math.abs(e.y.velocity) > POS_EPS * 10;
      // Off the desk (or faded out): hidden now, without waiting for the spring to come to rest out of sight.
      if (e.phase === 'leaving' && !e.pending && (p > 0.98 || (e.fade < 0 && e.opacity < 0.02))) { writePose(e); finish(e); return false; }
      if (!busy) {
        snap(e.x, e.x.target); snap(e.y, e.y.target); snap(e.rot, e.rot.target); snap(e.z, e.z.target);
        if (e.fade !== 0) { e.fade = 0; e.opacity = 1; const c = current(e); if (c) setOpacity(c, 1); }
      }
    }
    writePose(e);
    const moved = px !== e.x.value || py !== e.y.value || pz !== e.z.value || pr !== e.rot.value;
    if (moved && e.castShadow) shadowsMoved = true;
    if (!busy && !e.pending) { finish(e); return false; }
    return true;
  }

  let shadowsMoved = false;
  const result: StepResult = { moving: false, shadowsMoved: false };

  function stepAll(dt: number, now: number): StepResult {
    builds = 0;
    shadowsMoved = false;
    let k = 0;
    while (k < active.length) {
      const e = active[k];
      const still = e.phase !== 'hidden' && stepOne(e, dt, now);
      if (still) { k++; continue; }
      e.active = false;
      active[k] = active[active.length - 1];
      active.pop();
    }
    result.moving = active.length > 0;
    result.shadowsMoved = shadowsMoved;
    return result;
  }

  function setCaster(e: Entry, cast: boolean): boolean {
    if (e.castShadow === cast) return false;
    e.castShadow = cast;
    const c = current(e);
    if (c) setShadow(c, cast);
    return true;
  }

  const candidates: Entry[] = [];

  return {
    update(item) {
      const e = entryFor(item);
      e.gen = gen + 1;
      if (e.item === item) return;
      const sig = sigOf(item);
      e.item = item;
      if (sig === e.sig) return;
      e.sig = sig;
      if (!e.small) return;
      // The capture changed (say, a new enrichment): build it again in place.
      dropFull(e);
      const fresh = theme.buildObject(item, 'small');
      e.small.removeFromParent();
      disposeObject(e.small);
      e.small = fresh;
      e.slot?.add(fresh);
      setShadow(fresh, e.castShadow);
    },
    prune(present) {
      gen++;
      for (const [id, e] of entries) {
        if (present.has(id) || e.phase !== 'hidden' || e.slot) continue;
        entries.delete(id);
      }
    },
    arrive(item, target, from, edges, spec, now, opts) {
      const e = entryFor(item);
      e.phase = 'shown';
      e.pile = opts.pile;
      e.castShadow = opts.castShadow;
      const spin = spec.type === 'spring' ? spec.spin ?? 0 : 0;
      const reach = spec.type === 'spring' ? spec.reach : undefined;
      let start: { x: number; y: number };
      if (reach !== undefined) { const d = toward(from); start = { x: target.x + d.dx * reach, y: target.y + d.dy * reach }; }
      else start = offDesk(item, from, edges, target);
      schedule(e, 'arrive', target, spec, now, { x: start.x, y: start.y, z: target.z, rot: target.rot + spin });
      if (e.slot) setBadge(e, opts.badge); else e.badgeText = undefined;
      pendingBadges.set(e.id, opts.badge);
    },
    move(id, target, spec, now, opts) {
      const e = entries.get(id);
      if (!e) return;
      e.phase = 'shown';
      e.pile = opts.pile;
      setCaster(e, opts.castShadow);
      setBadge(e, opts.badge);
      schedule(e, 'move', target, spec, now);
    },
    tuck(id, target, spec, now, pile) {
      const e = entries.get(id);
      if (!e) return;
      e.phase = 'tucking';
      e.pile = pile;
      if (!e.onDesk) { hide(e); return; }
      setCaster(e, false);
      schedule(e, 'tuck', target, spec, now);
    },
    leave(id, to, edges, spec, now) {
      const e = entries.get(id);
      if (!e) return;
      e.phase = 'leaving';
      if (!e.onDesk) { hide(e); return; }   // never got onto the desk: nothing to sweep
      const reach = spec.type === 'spring' ? spec.reach : undefined;
      const here = { x: e.x.value, y: e.y.value };
      let end: { x: number; y: number };
      if (reach !== undefined) { const d = toward(to); end = { x: here.x + d.dx * reach, y: here.y + d.dy * reach }; }
      else end = offDesk(e.item, to, edges, here);
      schedule(e, 'leave', { x: end.x, y: end.y, z: e.baseZ, rot: e.rot.value }, spec, now);
    },
    onDesk: id => entries.get(id)?.onDesk ?? false,
    positionOf(id) {
      const e = entries.get(id);
      return e?.onDesk ? { x: e.x.value, y: e.y.value } : undefined;
    },
    step(dt, now) {
      const r = stepAll(dt, now);
      // Badges wait for the object to be built.
      if (pendingBadges.size) for (const [id, text] of pendingBadges) {
        const e = entries.get(id);
        if (!e) { pendingBadges.delete(id); continue; }
        if (e.slot) { setBadge(e, text); pendingBadges.delete(id); }
      }
      return r;
    },
    updateLod(camera, viewHeightPx) {
      const f = viewHeightPx / (2 * Math.tan((camera.fov * Math.PI) / 360));
      candidates.length = 0;
      for (const e of entries.values()) {
        if (!e.onDesk || !e.slot || e.phase !== 'shown') { e.screenPx = 0; continue; }
        const size = theme.sizes[e.item.kind];
        const d = camera.position.distanceTo(e.slot.position);
        e.screenPx = (Math.max(size.w, size.h) * f) / Math.max(d, 1e-3);
        candidates.push(e);
      }
      candidates.sort((a, b) => b.screenPx - a.screenPx);
      let changed = false, kept = 0;
      for (const e of candidates) {
        const has = !!(e.full || e.loadingFull);
        const want = kept < MAX_FULL && (has ? e.screenPx >= SMALL_BELOW_PX : e.screenPx > FULL_ABOVE_PX);
        if (want) kept++;
        if (want && !has) {
          const full = theme.buildObject(e.item, 'full');
          e.loadingFull = full;
          const ready = (full.userData.ready as Promise<void> | undefined) ?? Promise.resolve();
          ready.then(() => {
            if (e.loadingFull !== full || !e.slot || !e.small) return;
            e.loadingFull = undefined;
            e.small.removeFromParent();
            e.slot.add(full);
            setShadow(full, e.castShadow);
            setOpacity(full, e.opacity);
            e.full = full;
            fullCount++;
            hooks.changed();
          }, () => undefined);
          changed = true;
        } else if (!want && has) { dropFull(e); changed = true; }
      }
      for (const e of entries.values()) if (e.screenPx === 0 && (e.full || e.loadingFull)) { dropFull(e); changed = true; }
      return changed;
    },
    objectOf: id => entries.get(id)?.slot,
    idOf(obj) {
      for (let o: Object3D | null = obj; o; o = o.parent) { const e = owner.get(o); if (e) return e.id; }
      return undefined;
    },
    pileOfId: id => entries.get(id)?.pile,
    pickables() {
      const out: Object3D[] = [];
      for (const e of entries.values()) if (e.onDesk && e.phase === 'shown' && e.slot) out.push(e.slot);
      return out;
    },
    disposeObject,
    stats() {
      let built = 0, onDesk = 0;
      for (const e of entries.values()) { if (e.small) built++; if (e.onDesk) onDesk++; }
      return { entries: entries.size, built, onDesk, full: fullCount, hiddenKept: hidden.size, active: active.length };
    },
  };
}
