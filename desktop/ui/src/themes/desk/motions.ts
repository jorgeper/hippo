// How things move on the desk (spec section 8, "Motion"): arrivals are dealt in from the nearest edge on an arc with a
// little spin and settle with a small overshoot; leavers are swept off the nearest edge; stayers glide with a slight lift.
// Every timing the desk uses lives here. With prefers-reduced-motion, arrivals and leavers become a short quick slide with
// a fade, no spin and no overshoot.
import type { Edge, MotionSpec, Motions } from '../types.ts';

const ARRIVE_STAGGER = 28, LEAVE_STAGGER = 14, MOVE_STAGGER = 6;
/** Staggers stop growing past this, so a big deal still lands within about two seconds. */
const STAGGER_CAP = 1500;

let query: MediaQueryList | undefined;
function reduced(): boolean {
  if (typeof matchMedia !== 'function') return false;
  query ??= matchMedia('(prefers-reduced-motion: reduce)');
  return query.matches;
}

/** The index-th delay: `each` ms apart at first, then closer together so the whole deal stays short. */
function stagger(index: number, each: number): number {
  const linear = index * each, knee = 30 * each;
  return Math.min(STAGGER_CAP, linear <= knee ? linear : knee + (linear - knee) * 0.25);
}

/** Dealt from the left, a card turns one way; from the right, the other. */
const spinFrom = (from: Edge) => (from === 'left' || from === 'far' ? 0.55 : -0.55);

export const motions: Motions = {
  arrive(index, from): MotionSpec {
    if (reduced()) return { type: 'spring', delay: Math.min(index * 4, 160), stiffness: 520, damping: 1, lift: 0, spin: 0, reach: 1.5, fade: true };
    return { type: 'spring', delay: stagger(index, ARRIVE_STAGGER), stiffness: 95, damping: 0.74, lift: 4, spin: spinFrom(from) };
  },
  leave(index, to): MotionSpec {
    void to;
    if (reduced()) return { type: 'spring', delay: Math.min(index * 2, 80), stiffness: 520, damping: 1, lift: 0, reach: 1.5, fade: true };
    return { type: 'spring', delay: stagger(index, LEAVE_STAGGER), stiffness: 70, damping: 1, lift: 1.2 };
  },
  move(index): MotionSpec {
    if (reduced()) return { type: 'spring', delay: 0, stiffness: 420, damping: 1, lift: 0 };
    return { type: 'spring', delay: stagger(index, MOVE_STAGGER), stiffness: 85, damping: 1, lift: 1.5 };
  },
  lift: { type: 'arc', delay: 0, duration: 380, height: 12, spin: 0, easing: 'easeOut' },
  flip: { type: 'arc', delay: 0, duration: 520, height: 3, spin: Math.PI, easing: 'easeInOut' },
  thinking: { period: 2600, amplitude: 0.28 },
};
