import test from 'node:test';
import assert from 'node:assert/strict';
import { spring, step, settled } from '../src/scene/spring.ts';

const run = (s: ReturnType<typeof spring>, seconds: number, dt: number, each?: (v: number) => void) => {
  for (let t = 0; t < seconds - 1e-9; t += dt) { step(s, dt); each?.(s.value); }
};

test('a default spring from 0 to 1 is within 0.001 of 1 after 2 s of 1/60 steps, and never passes 1.05', () => {
  const s = spring(0);
  s.target = 1;
  let peak = 0;
  run(s, 2, 1 / 60, v => { peak = Math.max(peak, v); });
  assert.ok(Math.abs(s.value - 1) < 0.001, `value ${s.value}`);
  assert.ok(peak <= 1.05, `peak ${peak}`);
  assert.ok(settled(s));
});

test('the default spring is critically damped: it does not pass the target at all', () => {
  const s = spring(0);
  s.target = 1;
  let peak = 0;
  run(s, 3, 1 / 60, v => { peak = Math.max(peak, v); });
  assert.ok(peak <= 1 + 1e-9, `peak ${peak}`);
});

test('a spring does not blow up with dt 0.05, at any damping, and lands where 1/60 steps land', () => {
  for (const damping of [0.4, 0.72, 1, 1.6]) {
    const coarse = spring(0, { stiffness: 400, damping }), fine = spring(0, { stiffness: 400, damping });
    coarse.target = fine.target = 1;
    let peak = 0;
    run(coarse, 3, 0.05, v => { peak = Math.max(peak, Math.abs(v)); });
    run(fine, 3, 1 / 60);
    assert.ok(Number.isFinite(coarse.value) && peak < 2, `damping ${damping}: peak ${peak}`);
    assert.ok(Math.abs(coarse.value - 1) < 0.01 && Math.abs(fine.value - 1) < 0.01, `damping ${damping}: ${coarse.value} ${fine.value}`);
  }
});

test('an underdamped spring overshoots a little and settles; a redirect mid-flight starts from where it is', () => {
  const s = spring(0, { stiffness: 90, damping: 0.72 });
  s.target = 10;
  let peak = 0;
  run(s, 3, 1 / 60, v => { peak = Math.max(peak, v); });
  assert.ok(peak > 10 && peak < 10.6, `peak ${peak}`);

  const r = spring(0);
  r.target = 10;
  run(r, 0.1, 1 / 60);
  const mid = r.value;
  assert.ok(mid > 0 && mid < 10);
  r.target = -5;
  step(r, 1 / 60);
  assert.ok(Math.abs(r.value - mid) < 1, 'no jump on redirect');
  run(r, 3, 1 / 60);
  assert.ok(Math.abs(r.value + 5) < 0.001);
});

test('step with dt 0 or a negative dt changes nothing', () => {
  const s = spring(2);
  s.target = 5;
  step(s, 0);
  step(s, -1);
  assert.equal(s.value, 2);
  assert.equal(s.velocity, 0);
});
