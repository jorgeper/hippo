// The person's hands on the desk (spec section 8, "Handling"): what each press, drag, release, wheel turn and key means,
// and the desk that results. Everything the handling changes (an open pile, a riffled pile, an item dropped somewhere, a
// pile dragged by its label, the set-aside and kept piles) is worked out as one layout over the store's arrangement and
// handed to the stage like any other, so the scene's bookkeeping (who arrives, glides, tucks, leaves) covers it. Only the
// drag itself and the lifted item are moved directly, through the stage's hand. A new arrangement (another question, a
// layout button, undo, start over) clears what the handling did; the pins and the set-aside list live in the store.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Api } from '../api.ts';
import type { Store, DeskState } from '../state.ts';
import type { Stage } from '../scene/stage.ts';
import type { Theme } from '../themes/types.ts';
import type { LayoutResult, PileInfo, Placement } from '../layout/types.ts';
import { layouts } from '../layout/index.ts';
import { createPointer, releaseVelocity } from './pointer.ts';
import type { Press } from './pointer.ts';
import { maxScroll, cellOf, openPile, pullOut, queueRiffle, restack, riffle, SPREAD_PREFIX, wheelSteps } from './pile.ts';
import { createLifter, isThrow } from './item.ts';
import { ASIDE_KEY, ASIDE_LABEL, asidePile, bodiesOf } from './setaside.ts';
import { KEPT_KEY, KEPT_LABEL, keptPile } from './keep.ts';
import { mountDetail } from '../overlay/detail.ts';
import { PILE_CAP } from '../layout/pile.ts';

/** Wheel travel (CSS pixels) for one row of an open pile, and for one card of a riffle. */
export const ROW_WHEEL = 70, RIFFLE_WHEEL = 50;
/** For this long (ms) after a pile opens, a click on its spread is the second half of a double click: ignored. */
export const OPEN_GUARD_MS = 400;
/** A dragged item rides this far (desk units) above where it lay. */
const CARRY_LIFT = 2.5;
const DROP_PREFIX = 'drop:';

/** What C5's browser test (and a person checking by hand) can read about the handling. */
export interface HandProbe {
  /** The key of the open pile, if one is open. */
  open(): string | undefined;
  /** The lifted item's id, and which side faces the person. */
  lifted(): { id: string; back: boolean; state: string } | undefined;
  /** Ids in the set-aside pile and in the kept pile, top first. */
  aside(): string[];
  kept(): string[];
  /** Ids dropped loose on the desk. */
  dropped(): string[];
  /** The piles on the desk now (as composed): key, label, count, ids top first. */
  piles(): { key: string; label: string; count: number; ids: string[]; x: number; y: number }[];
  /** The ids the scene draws now (its placements that are drawn). */
  slots(): string[];
  /** Where to point at, in window CSS pixels: an item's object (its middle), or a pile's top drawn item; undefined when not drawn. */
  pointOf(idOrPile: string): { x: number; y: number } | undefined;
}

export interface Hand {
  /** Lays the desk out again when the store or the handling changed (`force`: the view or a setting changed). */
  render(force?: boolean): void;
  probe: HandProbe;
  /** True while a gesture or a motion of the hand is under way (not settled for a test). */
  busy(): boolean;
}

export interface HandDeps { stage: Stage; store: Store; api: Pick<Api, 'capture'>; theme: Theme;
  /** Where the lifted item's overlay goes, and the open pile's title line. */
  overlayHost: HTMLElement; title: HTMLElement }

interface Target { type: 'item' | 'pile' | 'desk' | 'outside'; id?: string; pile?: string }

const isTyping = (t: EventTarget | null) => {
  const e = t as HTMLElement | null;
  if (!e || !e.tagName) return false;
  if (e.isContentEditable) return true;
  if (e.tagName === 'TEXTAREA' || e.tagName === 'SELECT') return true;
  if (e.tagName === 'INPUT') return !['checkbox', 'radio', 'button', 'submit', 'range'].includes((e as HTMLInputElement).type);
  return false;
};

export function mountHand(canvas: HTMLElement, deps: HandDeps): Hand {
  const { stage, store, api, theme, title } = deps;
  const hand = stage.hand;
  const overlay = mountDetail(deps.overlayHost, { flip: () => flip(), close: () => putBack() });

  // ---------------------------------------------------------------- what the handling has done in this arrangement
  let arrangement = '';
  let open: { key: string; scroll: number; shown?: number; at: number } | undefined;
  const riffled = new Map<string, number>();
  const dropped = new Map<string, { x: number; y: number; rot: number }>();
  const shifted = new Map<string, { dx: number; dy: number }>();
  let pulled: { key: string; id: string; under: boolean } | undefined;
  /** Every item the page has seen, for the set-aside pile (dismissed ids are no longer in any result). */
  const known = new Map<string, DeskItem>();
  /** Taken back from the set-aside pile and not yet in a result: shown on the desk meanwhile. */
  const restoring = new Map<string, DeskItem>();
  let restoringSince: DeskItem[] | undefined;
  let version = 0;
  let lastSig = '';
  let itemsShown: DeskItem[] | undefined;
  /** The last layout handed to the stage, and the one before the open pile and the pulled card were applied. */
  let composed: LayoutResult = { placements: [], piles: [] };
  let stacked: LayoutResult = composed;

  const changed = () => { version++; render(); };

  function newArrangement(): void {
    open = undefined;
    riffled.clear();
    dropped.clear();
    shifted.clear();
    pulled = undefined;
    riffleQueue = undefined;
    riffleGen++;
    if (lifter.current()) putBack();
  }

  // ---------------------------------------------------------------- composing the desk

  const sizeOf = (id: string) => theme.sizes[(known.get(id) ?? restoring.get(id))?.kind ?? 'file'];
  const kindOf = (id: string) => (known.get(id) ?? restoring.get(id))?.kind;

  function without(layout: LayoutResult, ids: ReadonlySet<string>): LayoutResult {
    if (!ids.size) return layout;
    const piles: PileInfo[] = [];
    for (const p of layout.piles) {
      const left = p.ids.filter(id => !ids.has(id));
      if (!left.length) continue;
      piles.push(left.length === p.ids.length ? p : { ...p, ids: left, count: left.length });
    }
    return { ...layout, piles, placements: layout.placements.filter(p => !ids.has(p.id)) };
  }

  function compose(s: DeskState): { items: DeskItem[]; layout: LayoutResult } {
    const dismissed = new Set(s.dismissed);
    const onDesk = s.items.filter(i => !dismissed.has(i.id));
    const ids = new Set(onDesk.map(i => i.id));
    for (const [id, it] of restoring) if (!ids.has(id) && !dismissed.has(id)) { onDesk.push(it); ids.add(id); }
    const byId = new Map(onDesk.map(i => [i.id, i]));
    const pinned = s.pinned.filter(id => byId.has(id));
    const pinSet = new Set(pinned);
    for (const id of [...dropped.keys()]) if (!byId.has(id) && !dismissed.has(id)) dropped.delete(id);
    const view = stage.view();

    // The arrangement, without what is kept (it lies in its own pile) and without what was dropped elsewhere.
    let layout = layouts[s.layout](onDesk.filter(i => !pinSet.has(i.id)), view, theme.sizes);
    layout = without(layout, new Set(dropped.keys()));
    const avoid = bodiesOf(layout.placements, theme.sizes, kindOf);
    const kept = keptPile(pinned.filter(id => !dropped.has(id)), byId, view, theme.sizes, avoid);
    const aside = asidePile(s.dismissed.filter(id => !dropped.has(id)), known, view, theme.sizes, avoid);
    const piles = [...layout.piles], placements = [...layout.placements];
    for (const x of [kept, aside]) if (x) { piles.push(x.pile); placements.push(...x.placements); }
    layout = { ...layout, piles, placements };
    // Piles moved by their labels.
    if (shifted.size) {
      layout = {
        ...layout,
        piles: layout.piles.map(p => { const d = shifted.get(p.key); return d ? { ...p, x: p.x + d.dx, y: p.y + d.dy } : p; }),
        placements: layout.placements.map(p => { const d = shifted.get(p.pile); return d ? { ...p, x: p.x + d.dx, y: p.y + d.dy } : p; }),
      };
    }
    for (const [key, steps] of riffled) {
      const p = layout.piles.find(x => x.key === key);
      if (p) layout = restack(layout, key, riffle(p.ids, steps));
    }
    // Items dropped loose, each lying on whatever is under it.
    for (const [id, at] of dropped) {
      const key = `${DROP_PREFIX}${id}`;
      layout.piles.push({ key, label: '', count: 1, x: at.x, y: at.y, ids: [id], bare: true, loose: true });
      layout.placements.push({ id, x: at.x, y: at.y, order: 0, rot: at.rot, pile: key });
    }
    // Pins on whatever is kept, wherever it lies.
    if (pinSet.size) layout = { ...layout, placements: layout.placements.map(p => (pinSet.has(p.id) ? { ...p, pin: true } : p)) };
    // Within one arrangement every change answers a gesture: quick, and what comes into view comes out of its pile.
    if (lastSig.startsWith(`${arrangement}|`)) layout = { ...layout, piles: layout.piles.map(p => ({ ...p, quick: true, from: p.from ?? { x: p.x, y: p.y } })) };
    if (layout.placements.length && layout.empty !== undefined) { const { empty: _gone, ...rest } = layout; void _gone; layout = rest; }
    stacked = layout;
    if (pulled) {
      const p = layout.piles.find(x => x.key === pulled!.key);
      if (p && p.ids.includes(pulled.id)) layout = pullOut(layout, pulled.key, pulled.id, sizeOf(pulled.id), pulled.under);
    }
    if (open) {
      const p = layout.piles.find(x => x.key === open!.key);
      if (!p) { open = undefined; }
      else {
        open.scroll = Math.max(0, Math.min(open.scroll, maxScroll(p.ids.length, view, cellOf(p.ids.map(sizeOf)))));
        layout = openPile(layout, open.key, open.scroll, view, sizeOf, open.shown);
        open.shown = open.scroll;
      }
    }
    const items = [...onDesk];
    for (const id of s.dismissed) { const it = known.get(id); if (it && !ids.has(id)) items.push(it); }
    return { items, layout };
  }

  function render(force = false): void {
    const s = store.get();
    // Another question, layout, undo or start over (counted, so even one on an empty desk) is a new arrangement.
    const key = JSON.stringify([s.spec, s.layout, s.history.length, s.resets]);
    if (key !== arrangement) { arrangement = key; newArrangement(); }
    for (const it of s.items) known.set(it.id, it);
    if (restoringSince && s.items !== restoringSince) { restoring.clear(); restoringSince = undefined; }
    const v = stage.view();
    const sig = `${arrangement}|${version}|${s.pinned.join(',')}|${s.dismissed.join(',')}|${v.width.toFixed(3)}x${v.height.toFixed(3)}`;
    if (!force && sig === lastSig && itemsShown === s.items) return;
    const { items, layout } = compose(s);
    lastSig = sig;
    itemsShown = s.items;
    composed = layout;
    stage.setItems(items, layout);
    showTitle();
    // A pile whose aside list needs an item the page has never seen: fetch it, then lay out again.
    for (const id of s.dismissed) if (!known.has(id)) fetchKnown(id);
  }

  const fetching = new Set<string>();
  function fetchKnown(id: string): void {
    if (fetching.has(id)) return;
    fetching.add(id);
    api.capture(id).then(r => { known.set(id, r.item); changed(); }, () => undefined).finally(() => fetching.delete(id));
  }

  function showTitle(): void {
    const p = open && stacked.piles.find(x => x.key === open!.key);
    if (!p) { title.hidden = true; title.replaceChildren(); return; }
    const label = p.style === 'aside' ? ASIDE_LABEL : p.style === 'kept' ? KEPT_LABEL : p.label;
    const n = p.ids.length;
    const gather = `Esc gathers ${n === 1 ? 'it' : 'them'}.`;
    const more = maxScroll(n, stage.view(), cellOf(p.ids.map(sizeOf))) > 0 ? 'Scroll for more. ' : '';
    const hint = p.style === 'aside' ? `Click one to take it back. ${more}${gather}` : `${more}${gather}`;
    const b = document.createElement('b');
    b.textContent = label;
    const span = document.createElement('span');
    span.textContent = `${n.toLocaleString()} ${n === 1 ? 'item' : 'items'}. ${hint}`;
    title.replaceChildren(b, span);
    title.hidden = false;
  }

  // ---------------------------------------------------------------- piles

  const pileOf = (key: string | undefined) => (key ? stacked.piles.find(p => p.key === key) : undefined);
  const placementOf = (id: string): Placement | undefined => composed.placements.find(p => p.id === id);
  const isSpread = (pile: string | undefined) => !!pile && pile.startsWith(SPREAD_PREFIX);
  /** A pile one can open: more than one item, not an item lying loose. */
  const openable = (p: PileInfo | undefined) => !!p && p.ids.length > 1 && !p.bare;

  function openOne(key: string): void {
    if (!openable(pileOf(key))) return;
    open = { key, scroll: 0, at: performance.now() };
    pulled = undefined; riffleQueue = undefined; riffleGen++;
    stage.resetView();
    changed();
  }
  function gather(): void {
    if (!open) return;
    open = undefined;
    stage.resetView();
    changed();
  }

  // Riffling: one card at a time, pulled out to the side, then slid under (or, backward, out from under and on top).
  let riffleQueue: { key: string; steps: number } | undefined;
  let riffleGen = 0, riffleTimer = 0;
  function riffleBy(key: string, steps: number): void {
    if (!riffleQueue || riffleQueue.key !== key) riffleQueue = { key, steps: 0 };
    riffleQueue.steps = queueRiffle(riffleQueue.steps, steps);
    if (!riffleTimer) riffleStep();
  }
  function riffleStep(): void {
    riffleTimer = 0;
    const q = riffleQueue;
    if (!q || !q.steps) { riffleQueue = undefined; return; }
    const p = pileOf(q.key);
    if (!p || p.ids.length < 2) { riffleQueue = undefined; return; }
    const dir = Math.sign(q.steps);
    q.steps -= dir;
    const gen = riffleGen;
    const pace = theme.motions.riffle.pace;
    pulled = { key: q.key, id: dir > 0 ? p.ids[0] : p.ids[p.ids.length - 1], under: dir > 0 };
    changed();
    riffleTimer = window.setTimeout(() => {
      if (gen !== riffleGen) { riffleTimer = 0; return; }
      pulled = undefined;
      riffled.set(q.key, (riffled.get(q.key) ?? 0) + dir);
      changed();
      riffleTimer = window.setTimeout(riffleStep, pace / 2);
    }, pace / 2);
  }

  // ---------------------------------------------------------------- lifting

  const faceOf = (id: string) => {
    const kind = (known.get(id) ?? restoring.get(id))?.kind ?? 'file';
    return hand.screenRect(id, theme.sizes[kind], theme.depths[kind]);
  };
  const lifter = createLifter(hand, theme, {
    arrived: id => {
      const r = faceOf(id);
      if (!r) return;
      if (overlay.isOpen()) overlay.place(r); else overlay.show(r, lifter.current()?.back ?? false);
    },
    turned: id => { const r = faceOf(id); if (r) overlay.show(r, lifter.current()?.back ?? false); },
    landed: () => { changed(); },
  });

  function lift(id: string): void {
    const it = known.get(id) ?? restoring.get(id);
    if (!it || lifter.current()) return;
    if (!lifter.lift(id, theme.sizes[it.kind], theme.depths[it.kind])) return;
    overlay.prepare(it, api.capture(id));
  }
  function putBack(): void {
    if (!lifter.current()) return;
    overlay.close();
    lifter.putBack();
  }
  function flip(): void {
    const c = lifter.current();
    if (!c || c.state !== 'up') return;
    overlay.conceal();
    lifter.flip();
  }
  stage.on('frame', () => lifter.refresh());
  stage.on('view', () => lifter.refresh());

  // ---------------------------------------------------------------- the pointer

  /** What a drag is doing: carrying an item (`grab` is where it was taken hold of), moving a pile, or panning. */
  let drag: { type: 'item'; id: string; z: number; rot: number; grab: { x: number; y: number }; from?: string; at: { x: number; y: number } }
    | { type: 'pile'; key: string; last: { x: number; y: number }; moved: { dx: number; dy: number } }
    | { type: 'pan' } | undefined;

  function targetAt(x: number, y: number): Target {
    if (lifter.current()) return { type: 'outside' };
    const hit = stage.pick(x, y);
    if (open) {
      if (hit?.id && isSpread(hit.pile)) return { type: 'item', id: hit.id, pile: hit.pile };
      return { type: 'outside' };
    }
    if (hit?.id) return { type: 'item', id: hit.id, pile: hit.pile };
    if (hit?.pile) return { type: 'pile', pile: hit.pile };
    return { type: 'desk' };
  }

  function startPan(p: Press): void {
    drag = stage.panStart(p.x0, p.y0) ? { type: 'pan' } : undefined;
    if (drag) stage.panTo(p.x, p.y);
  }

  createPointer(canvas, {
    down(p) {
      p.target = targetAt(p.x, p.y);
      return true;
    },
    dragStart(p) {
      const t = p.target as Target;
      if (t.type === 'outside' && lifter.current()) { drag = undefined; return; }
      if (t.type === 'item' && t.id && hand.hold(t.id)) {
        const home = hand.homeOf(t.id), now = hand.poseOf(t.id);
        const z = (now?.position.z ?? 0) + CARRY_LIFT;
        const g = stage.groundAt(p.x0, p.y0, z);
        const pos = now?.position ?? home?.position;
        const rot = placementOf(t.id)?.rot ?? 0;
        drag = { type: 'item', id: t.id, z, rot, grab: g && pos ? { x: g.x - pos.x, y: g.y - pos.y } : { x: 0, y: 0 }, from: t.pile, at: { x: pos?.x ?? 0, y: pos?.y ?? 0 } };
        return;
      }
      if (t.type === 'pile' && t.pile) {
        const g = stage.groundAt(p.x0, p.y0);
        if (g) { drag = { type: 'pile', key: t.pile, last: g, moved: { dx: 0, dy: 0 } }; return; }
      }
      startPan(p);
    },
    drag(p) {
      if (!drag) return;
      if (drag.type === 'pan') { stage.panTo(p.x, p.y); return; }
      if (drag.type === 'item') {
        const g = stage.groundAt(p.x, p.y, drag.z);
        if (!g) return;
        drag.at = { x: g.x - drag.grab.x, y: g.y - drag.grab.y };
        hand.carry(drag.id, { x: drag.at.x, y: drag.at.y, z: drag.z, rot: drag.rot });
        return;
      }
      const g = stage.groundAt(p.x, p.y);
      if (!g) return;
      const dx = g.x - drag.last.x, dy = g.y - drag.last.y;
      drag.last = g;
      drag.moved.dx += dx; drag.moved.dy += dy;
      hand.shiftPile(drag.key, dx, dy);
    },
    up(p) {
      const d = drag;
      drag = undefined;
      if (!p.dragging) { click(p.target as Target); return; }
      if (d?.type === 'item') drop(d, p);
      else if (d?.type === 'pile') commitPile(d.key, d.moved);
    },
    cancel() {
      const d = drag;
      drag = undefined;
      if (d?.type === 'item') { hand.release(d.id); changed(); }
      else if (d?.type === 'pile') commitPile(d.key, d.moved);
    },
    pinch(cx, cy, f) { if (!lifter.current()) stage.zoomAt(cx, cy, f); },
  });

  function commitPile(key: string, moved: { dx: number; dy: number }): void {
    // A pile in a spread, or a loose item's own pile, is not moved this way.
    if (key.startsWith(DROP_PREFIX)) {
      const id = key.slice(DROP_PREFIX.length), at = dropped.get(id);
      if (at) dropped.set(id, { ...at, x: at.x + moved.dx, y: at.y + moved.dy });
    } else {
      const s = shifted.get(key) ?? { dx: 0, dy: 0 };
      shifted.set(key, { dx: s.dx + moved.dx, dy: s.dy + moved.dy });
    }
    changed();
  }

  function click(t: Target): void {
    // The second click of a double click on a closed pile lands on its spread as it opens: it neither lifts nor gathers.
    if (open && performance.now() - open.at < OPEN_GUARD_MS) return;
    if (t.type === 'outside') {
      if (lifter.current()) putBack(); else gather();
      return;
    }
    if (t.type === 'item' && t.id) {
      if (open && isSpread(t.pile)) {
        if (open.key === ASIDE_KEY) { restore(t.id); return; }
        lift(t.id);
        return;
      }
      const p = pileOf(t.pile);
      if (openable(p)) openOne(p!.key); else lift(t.id);
      return;
    }
    if (t.type === 'pile' && t.pile) {
      const p = pileOf(t.pile);
      if (openable(p)) openOne(t.pile);
      else if (p?.ids.length === 1) lift(p.ids[0]);
    }
  }

  function restore(id: string): void {
    const it = known.get(id);
    if (it) { restoring.set(id, it); restoringSince = store.get().items; }
    version++;
    void store.restore(id);
    render();
  }

  /** Letting go of a carried item: thrown, kept, taken back, or simply put down there. */
  function drop(d: { id: string; z: number; rot: number; from?: string; at: { x: number; y: number } }, p: Press): void {
    const s = store.get();
    const id = d.id;
    const wasAside = s.dismissed.includes(id), wasKept = s.pinned.includes(id);
    const fromSpread = isSpread(d.from);
    // The pile under the pointer (the carried item itself is not pickable while held).
    const hit = stage.pick(p.x, p.y);
    const under = hit?.pile && hit.pile.startsWith(SPREAD_PREFIX) ? undefined : hit?.pile;
    // How fast it was going, on the desk, over the last moments of the drag.
    const desk = p.samples.map(sm => { const g = stage.groundAt(sm.x, sm.y, d.z); return g ? { t: sm.t, x: g.x, y: g.y } : undefined; })
      .filter((x): x is { t: number; x: number; y: number } => !!x);
    const v = releaseVelocity(desk);
    const vis = stage.visible();
    const rel = { x: d.at.x - (vis.x0 + vis.x1) / 2, y: d.at.y - (vis.y0 + vis.y1) / 2 };
    version++;
    if (under === ASIDE_KEY || isThrow(v, rel, { width: vis.x1 - vis.x0, height: vis.y1 - vis.y0 })) {
      hand.release(id, v);
      dropped.delete(id);
      restoring.delete(id);
      if (!wasAside) void store.dismiss(id);
    } else if (under === KEPT_KEY || p.shift) {
      hand.release(id);
      dropped.delete(id);
      if (!wasKept) void store.pin([id]);
    } else {
      hand.release(id);
      dropped.set(id, { x: d.at.x, y: d.at.y, rot: d.rot });
      // Taken out of an open pile onto the desk: the pile gathers and it lies where it was put.
      if (open && fromSpread) { open = undefined; stage.resetView(); }
      if (wasAside) { restore(id); return; }
    }
    render();
  }

  // ---------------------------------------------------------------- the wheel and the keys

  let rowWheel = 0, riffleWheel = 0;
  canvas.addEventListener('wheel', e => {
    e.preventDefault();
    if (lifter.current()) return;
    if (e.ctrlKey) { stage.wheelZoom(e); return; }
    const dy = e.deltaY * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? window.innerHeight : 1);
    if (open) {
      const { steps: rows, rest } = wheelSteps(rowWheel + dy, ROW_WHEEL);
      rowWheel = rest;
      if (rows) { open.scroll = Math.max(0, open.scroll + rows); changed(); }
      return;
    }
    const hit = stage.pick(e.clientX, e.clientY);
    const p = pileOf(hit?.pile);
    if (openable(p)) {
      const { steps, rest } = wheelSteps(riffleWheel + dy, RIFFLE_WHEEL);
      riffleWheel = rest;
      if (steps) riffleBy(p!.key, steps);
      return;
    }
    riffleWheel = 0;
    stage.wheelZoom(e);
  }, { passive: false });

  window.addEventListener('keydown', e => {
    if (e.defaultPrevented || e.isComposing || isTyping(e.target) || isTyping(document.activeElement)) return;
    const mod = e.metaKey || e.ctrlKey;
    if (e.key === 'Escape' && !mod) {
      if (lifter.current()) { e.preventDefault(); putBack(); }
      else if (open) { e.preventDefault(); gather(); }
    } else if ((e.key === 'f' || e.key === 'F') && !mod && !e.altKey) {
      if (lifter.current()) { e.preventDefault(); flip(); }
    } else if (mod && !e.shiftKey && !e.altKey && e.key.toLowerCase() === 'z') {
      e.preventDefault();
      store.undo();
    }
  });


  return {
    render,
    busy: () => !!drag || !!pulled || !!riffleQueue || (lifter.current()?.state !== undefined && lifter.current()?.state !== 'up'),
    probe: {
      open: () => open?.key,
      lifted: () => lifter.current(),
      aside: () => stacked.piles.find(p => p.key === ASIDE_KEY)?.ids ?? [],
      kept: () => stacked.piles.find(p => p.key === KEPT_KEY)?.ids ?? [],
      dropped: () => [...dropped.keys()],
      piles: () => composed.piles.filter(p => p.cap !== 0).map(p => ({ key: p.key, label: p.label, count: p.count, ids: [...p.ids], x: p.x, y: p.y })),
      slots: () => composed.piles.flatMap(p => p.ids.slice(0, p.cap ?? PILE_CAP)),
      pointOf(key) {
        const pile = composed.piles.find(p => p.key === key);
        const id = pile ? pile.ids.slice(0, pile.cap ?? PILE_CAP)[0] : key;
        const o = id ? stage.objectOf(id) : undefined;
        if (!o || !o.parent || !o.visible) return undefined;
        return stage.toWindow(o.position.x, o.position.y, o.position.z);
      },
    },
  };
}
