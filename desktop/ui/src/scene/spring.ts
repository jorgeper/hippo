// A damped spring for one number, stepped with the exact solution of the damped oscillator, so any step size is stable (a
// slow frame of 1/20 s lands where three 1/60 s frames would). Every motion on the desk is a spring target: changing
// `target` mid-flight carries on from the current value and velocity. Pure: no DOM, no three.js.

export interface Spring {
  value: number;
  velocity: number;
  target: number;
  /** k in 1/s²: how hard the spring pulls (the natural frequency is √k radians per second). */
  stiffness: number;
  /** The damping ratio: 1 is critical (no overshoot), below 1 overshoots a little, above 1 creeps in. */
  damping: number;
}

export const DEFAULT_STIFFNESS = 170;
export const DEFAULT_DAMPING = 1;

export function spring(value = 0, opts: { stiffness?: number; damping?: number } = {}): Spring {
  return { value, velocity: 0, target: value, stiffness: opts.stiffness ?? DEFAULT_STIFFNESS, damping: opts.damping ?? DEFAULT_DAMPING };
}

/** Advances `s` by `dt` seconds in place. */
export function step(s: Spring, dt: number): void {
  if (!(dt > 0)) return;
  const w = Math.sqrt(Math.max(s.stiffness, 1e-6)), z = Math.max(s.damping, 0);
  const x0 = s.value - s.target, v0 = s.velocity;
  let x: number, v: number;
  if (Math.abs(z - 1) < 1e-4) {
    const e = Math.exp(-w * dt), c = v0 + w * x0;
    x = (x0 + c * dt) * e;
    v = (v0 - w * c * dt) * e;
  } else if (z < 1) {
    const wd = w * Math.sqrt(1 - z * z), e = Math.exp(-z * w * dt), cos = Math.cos(wd * dt), sin = Math.sin(wd * dt);
    x = e * (x0 * cos + ((v0 + z * w * x0) / wd) * sin);
    v = e * (v0 * cos - ((z * w * v0 + w * w * x0) / wd) * sin);
  } else {
    const r = w * Math.sqrt(z * z - 1), r1 = -z * w + r, r2 = -z * w - r;
    const c1 = (v0 - r2 * x0) / (r1 - r2), c2 = x0 - c1, e1 = Math.exp(r1 * dt), e2 = Math.exp(r2 * dt);
    x = c1 * e1 + c2 * e2;
    v = c1 * r1 * e1 + c2 * r2 * e2;
  }
  s.value = s.target + x;
  s.velocity = v;
}

/** At rest: within `eps` of the target and barely moving. */
export function settled(s: Spring, eps = 1e-3): boolean {
  return Math.abs(s.value - s.target) < eps && Math.abs(s.velocity) < eps * 10;
}

/** Puts the spring at rest on `value`. */
export function snap(s: Spring, value: number): void {
  s.value = s.target = value;
  s.velocity = 0;
}
