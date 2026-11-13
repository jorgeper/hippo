// One pointer state machine for the desk (spec section 8, "Handling"): a press, which becomes a drag once it has moved
// DRAG_PX, and a release with the pointer's recent path for its velocity. The pointer is captured on press so a release
// outside the canvas still arrives, and every way a press can end (up, cancel, lost capture) clears it: nothing is left
// behind. A second finger turns the press into a pinch. What a press means (an item, a pile, empty desk) is the caller's.

/** A press must move this far (CSS pixels) before it is a drag; less is a click. */
export const DRAG_PX = 4;
/** The velocity at release is measured over this much of the pointer's path (ms). */
export const VELOCITY_MS = 90;
const SAMPLES_KEPT = 24;

export interface Sample { t: number; x: number; y: number }

export interface Press {
  pointerId: number;
  /** Where it went down and where it is now, in window CSS pixels. */
  x0: number; y0: number; x: number; y: number;
  shift: boolean;
  /** It has moved DRAG_PX: a drag, not a click. */
  dragging: boolean;
  /** The recent path, oldest first (window CSS pixels, ms). */
  samples: Sample[];
  /** Whatever the caller decided the press is about. */
  target?: unknown;
}

export interface PointerHandlers {
  /** A press began; set `p.target`. Answer false to ignore this press (it is not captured). */
  down(p: Press, e: PointerEvent): boolean;
  dragStart(p: Press): void;
  drag(p: Press): void;
  /** Released: a click when `p.dragging` is false. */
  up(p: Press): void;
  /** Ended without a release (cancelled, capture lost, a second finger came): undo what the drag did. */
  cancel(p: Press): void;
  /** Two fingers: zoom by `factor` (below 1 is closer) toward cx,cy. */
  pinch(cx: number, cy: number, factor: number): void;
}

/**
 * The velocity at the end of a path: from the earliest sample within `windowMs` of the last one to the last one, in the
 * samples' units per second; zero for a path with one sample or no time.
 */
export function releaseVelocity(samples: readonly Sample[], windowMs = VELOCITY_MS): { x: number; y: number } {
  if (samples.length < 2) return { x: 0, y: 0 };
  const last = samples[samples.length - 1];
  let first = samples[samples.length - 2];
  for (let k = samples.length - 2; k >= 0; k--) {
    if (last.t - samples[k].t > windowMs) break;
    first = samples[k];
  }
  const dt = (last.t - first.t) / 1000;
  if (dt <= 0) return { x: 0, y: 0 };
  return { x: (last.x - first.x) / dt, y: (last.y - first.y) / dt };
}

export function createPointer(el: HTMLElement, h: PointerHandlers): { active(): Press | undefined; dispose(): void } {
  let press: Press | undefined;
  /** Two fingers down: where each is. */
  const fingers = new Map<number, { x: number; y: number }>();
  let pinchDist = 0;

  const release = (id: number) => { if (el.hasPointerCapture(id)) el.releasePointerCapture(id); };
  const record = (p: Press, e: PointerEvent) => {
    p.x = e.clientX; p.y = e.clientY; p.shift = e.shiftKey;
    p.samples.push({ t: e.timeStamp, x: e.clientX, y: e.clientY });
    if (p.samples.length > SAMPLES_KEPT) p.samples.shift();
  };

  function end(e: PointerEvent, how: 'up' | 'cancel'): void {
    fingers.delete(e.pointerId);
    if (fingers.size < 2) pinchDist = 0;
    release(e.pointerId);
    if (!press || press.pointerId !== e.pointerId) return;
    const p = press;
    press = undefined;
    if (how === 'up') { record(p, e); h.up(p); } else h.cancel(p);
  }

  function onDown(e: PointerEvent): void {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    if (press && e.pointerId !== press.pointerId && e.pointerType === 'touch') {
      // A second finger: the first press becomes a pinch.
      const p = press;
      press = undefined;
      h.cancel(p);
      fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      el.setPointerCapture(e.pointerId);
      const [a, b] = [...fingers.values()];
      if (a && b) pinchDist = Math.hypot(a.x - b.x, a.y - b.y);
      return;
    }
    if (press) return;
    const p: Press = { pointerId: e.pointerId, x0: e.clientX, y0: e.clientY, x: e.clientX, y: e.clientY, shift: e.shiftKey,
      dragging: false, samples: [{ t: e.timeStamp, x: e.clientX, y: e.clientY }] };
    if (!h.down(p, e)) return;
    press = p;
    if (e.pointerType === 'touch') fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    el.setPointerCapture(e.pointerId);
  }

  function onMove(e: PointerEvent): void {
    if (fingers.size === 2 && fingers.has(e.pointerId)) {
      fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      const [a, b] = [...fingers.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y);
      if (d > 0 && pinchDist > 0) h.pinch((a.x + b.x) / 2, (a.y + b.y) / 2, pinchDist / d);
      pinchDist = d;
      return;
    }
    if (!press || press.pointerId !== e.pointerId) return;
    record(press, e);
    if (!press.dragging) {
      if (Math.hypot(press.x - press.x0, press.y - press.y0) < DRAG_PX) return;
      press.dragging = true;
      h.dragStart(press);
    }
    h.drag(press);
  }

  const onUp = (e: PointerEvent) => end(e, 'up');
  const onCancel = (e: PointerEvent) => end(e, 'cancel');
  // A capture lost without an up (the window lost focus, an element took the pointer) ends the press as a cancel.
  const onLost = (e: PointerEvent) => { if (press?.pointerId === e.pointerId || fingers.has(e.pointerId)) end(e, 'cancel'); };

  el.addEventListener('pointerdown', onDown);
  el.addEventListener('pointermove', onMove);
  el.addEventListener('pointerup', onUp);
  el.addEventListener('pointercancel', onCancel);
  el.addEventListener('lostpointercapture', onLost);
  return {
    active: () => press,
    dispose() {
      el.removeEventListener('pointerdown', onDown);
      el.removeEventListener('pointermove', onMove);
      el.removeEventListener('pointerup', onUp);
      el.removeEventListener('pointercancel', onCancel);
      el.removeEventListener('lostpointercapture', onLost);
    },
  };
}
