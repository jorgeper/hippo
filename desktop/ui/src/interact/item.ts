// One item in the hand (spec section 8, "Handling"): thrown or dropped when let go of, and lifted toward the person, turned
// over, and put back. `isThrow` is pure; the lifter drives a held object's pose through the stage's hand every frame, with
// the theme's `lift` and `flip` motions (short fades under reduced motion: the theme's motions say so).
import { Quaternion, Vector3 } from 'three';
import type { Size, View } from '../layout/types.ts';
import type { ArcMotion, Theme } from '../themes/types.ts';
import type { FreePose, Hand } from '../scene/stage.ts';
import { EASE } from '../scene/objects.ts';

/** A release faster than this (desk units per second), heading outward, is a throw. */
export const THROW_SPEED = 60;
/** A release this close to the edge of what the window shows (desk units) is a throw, however slow. */
export const THROW_EDGE = 4;
/** A lifted item fills about this share of the window's height. */
export const LIFT_SHARE = 0.7;

/**
 * Whether letting go of a dragged item throws it away: released within THROW_EDGE of an edge of `view` (what the window
 * shows, centred on 0,0, with `pos` in the same frame), or moving faster than THROW_SPEED toward the edges rather than back
 * toward the middle.
 */
export function isThrow(velocity: { x: number; y: number }, pos: { x: number; y: number }, view: View): boolean {
  const hw = view.width / 2, hh = view.height / 2;
  const edge = Math.min(hw - pos.x, pos.x + hw, hh - pos.y, pos.y + hh);
  if (edge <= THROW_EDGE) return true;
  if (Math.hypot(velocity.x, velocity.y) <= THROW_SPEED) return false;
  return velocity.x * pos.x + velocity.y * pos.y >= 0;
}

export interface LifterHooks {
  /** The item has risen and is facing the person (also after it moved because the window changed). */
  arrived(id: string): void;
  /** It has finished turning over; `back` says which side faces the person. */
  turned(id: string, back: boolean): void;
  /** It is back where it was on the desk and has been let go. */
  landed(id: string): void;
}

export interface Lifter {
  lift(id: string, size: Size, thick?: number): boolean;
  flip(): void;
  putBack(): void;
  /** The window or the camera changed: follow it. */
  refresh(): void;
  current(): { id: string; back: boolean; state: 'rising' | 'up' | 'turning' | 'falling' } | undefined;
}

const Y = new Vector3(0, 1, 0), Z = new Vector3(0, 0, 1);

export function createLifter(hand: Hand, theme: Theme, hooks: LifterHooks): Lifter {
  interface State { id: string; size: Size; thick: number; back: boolean; state: 'rising' | 'up' | 'turning' | 'falling';
    t0: number; from: FreePose; spec: ArcMotion; turnFrom: number; turnTo: number; turn: number; last?: FreePose }
  let s: State | undefined;
  let running = false;

  const turnQ = new Quaternion();
  /** The pose facing the person with the item turned `turn` radians about its own up axis. */
  function upPose(st: State): FreePose {
    const p = hand.liftPose(st.size, LIFT_SHARE, st.thick);
    turnQ.setFromAxisAngle(Y, st.turn);
    p.quaternion.multiply(turnQ);
    return p;
  }

  function blend(a: FreePose, b: FreePose, k: number, bump: number): FreePose {
    const position = a.position.clone().lerp(b.position, k).addScaledVector(Z, bump);
    return { position, quaternion: a.quaternion.clone().slerp(b.quaternion, k) };
  }

  const same = (a: FreePose | undefined, b: FreePose) =>
    !!a && a.position.distanceToSquared(b.position) < 1e-8 && Math.abs(a.quaternion.dot(b.quaternion)) > 1 - 1e-10;

  function step(now: number): boolean {
    if (!s) return false;
    const st = s;
    const u = st.spec.duration > 0 ? Math.min(1, (now - st.t0) / st.spec.duration) : 1;
    const k = EASE[st.spec.easing](u), bump = st.spec.height * 4 * u * (1 - u);
    if (st.state === 'rising') {
      const pose = blend(st.from, upPose(st), k, bump);
      hand.place(st.id, pose);
      if (u >= 1) { st.state = 'up'; st.last = pose; hooks.arrived(st.id); }
      return true;
    }
    if (st.state === 'turning') {
      st.turn = st.turnFrom + (st.turnTo - st.turnFrom) * k;
      const pose = upPose(st);
      // It comes a little toward the person as it turns.
      const toward = Z.clone().applyQuaternion(hand.liftPose(st.size, LIFT_SHARE, st.thick).quaternion);
      pose.position.addScaledVector(toward, bump);
      hand.place(st.id, pose);
      if (u >= 1) { st.state = 'up'; st.last = pose; hooks.turned(st.id, st.back); }
      return true;
    }
    if (st.state === 'falling') {
      const home = hand.homeOf(st.id);
      if (!home) { finish(); return false; }
      hand.place(st.id, blend(st.from, home, k, bump));
      if (u >= 1) { finish(); return false; }
      return true;
    }
    // Up: follow the camera (it may still be easing, or the window changed size).
    const pose = upPose(st);
    if (same(st.last, pose)) return false;
    hand.place(st.id, pose);
    st.last = pose;
    hooks.arrived(st.id);
    return true;
  }

  function run(): void {
    if (running) return;
    running = true;
    hand.animate((now) => {
      const more = step(now);
      if (!more) running = false;
      return more;
    });
  }

  function finish(): void {
    if (!s) return;
    const id = s.id;
    s = undefined;
    hand.release(id);
    hand.setLifting(false);
    hooks.landed(id);
  }

  return {
    lift(id, size, thick = 0) {
      if (s) return false;
      if (!hand.hold(id)) return false;
      const from = hand.poseOf(id);
      if (!from) { hand.release(id); return false; }
      s = { id, size, thick, back: false, state: 'rising', t0: performance.now(), from, spec: theme.motions.lift, turnFrom: 0, turnTo: 0, turn: 0 };
      hand.setLifting(true);
      run();
      return true;
    },
    flip() {
      if (!s || s.state !== 'up') return;
      s.back = !s.back;
      s.spec = theme.motions.flip;
      s.state = 'turning';
      s.t0 = performance.now();
      s.turnFrom = s.turn;
      // A reduced-motion flip does not turn: the overlay just shows the other side.
      s.turnTo = s.spec.spin ? s.turn + s.spec.spin : s.turn;
      run();
    },
    putBack() {
      if (!s || s.state === 'falling') return;
      const from = hand.poseOf(s.id);
      if (!from) { finish(); return; }
      s.state = 'falling';
      s.spec = theme.motions.lift;
      s.t0 = performance.now();
      s.from = from;
      run();
    },
    refresh() { if (s?.state === 'up') run(); },
    current: () => (s ? { id: s.id, back: s.back, state: s.state } : undefined),
  };
}
