import test from 'node:test';
import assert from 'node:assert/strict';
import { queueRiffle, riffle, RIFFLE_QUEUE, spreadPositions, wheelSteps } from '../src/interact/pile.ts';
import { isThrow } from '../src/interact/item.ts';
import { deviceLines, duration } from '../src/overlay/detail.ts';

const view = { width: 120, height: 70 };

test('spreadPositions lays 30 prints out in the view without any two overlapping', () => {
  const size = { w: 15, h: 10 };
  const at = spreadPositions(30, view, size);
  assert.equal(at.length, 30);
  for (const p of at) {
    assert.ok(p.x - size.w / 2 >= -view.width / 2 && p.x + size.w / 2 <= view.width / 2, `x ${p.x} inside`);
    assert.ok(p.y - size.h / 2 >= -view.height / 2 && p.y + size.h / 2 <= view.height / 2, `y ${p.y} inside`);
  }
  for (let a = 0; a < at.length; a++) for (let b = a + 1; b < at.length; b++) {
    const apart = Math.abs(at[a].x - at[b].x) >= size.w || Math.abs(at[a].y - at[b].y) >= size.h;
    assert.ok(apart, `${a} and ${b} overlap`);
  }
});

test('spreadPositions: first item top left, reading order, a few items centred, more than fit run on in rows below', () => {
  const size = { w: 15, h: 10 };
  const few = spreadPositions(3, view, size);
  const cx = few.reduce((s, p) => s + p.x, 0) / few.length, cy = few.reduce((s, p) => s + p.y, 0) / few.length;
  assert.ok(Math.abs(cx) < 1e-9 && Math.abs(cy) < 1e-9, 'a few are centred');
  const many = spreadPositions(200, view, size);
  assert.equal(many.length, 200);
  assert.ok(many[0].x < many[1].x && many[0].y === many[1].y, 'reading order along a row');
  const top = many[0].y;
  assert.ok(top + size.h / 2 <= view.height / 2, 'the first row is inside the view');
  assert.ok(many[199].y < -view.height / 2, 'the last rows are below the view, to scroll to');
  // No overlap there either.
  for (let a = 0; a < many.length; a++) for (let b = a + 1; b < many.length; b++)
    assert.ok(Math.abs(many[a].x - many[b].x) >= size.w || Math.abs(many[a].y - many[b].y) >= size.h);
  assert.deepEqual(spreadPositions(0, view, size), []);
});

test('isThrow: fast toward an edge, or let go right at one; a slow release in the middle is a drop', () => {
  assert.equal(isThrow({ x: 90, y: 0 }, { x: 10, y: 0 }, view), true);
  assert.equal(isThrow({ x: 10, y: 0 }, { x: 0, y: 0 }, view), false);
  // Slow, 2 units from the right edge.
  assert.equal(isThrow({ x: 1, y: 0 }, { x: view.width / 2 - 2, y: 0 }, view), true);
  // Fast but back toward the middle, from well inside: brought back, not thrown.
  assert.equal(isThrow({ x: -90, y: 0 }, { x: 20, y: 0 }, view), false);
  // Fast toward the near edge.
  assert.equal(isThrow({ x: 0, y: -80 }, { x: 0, y: -5 }, view), true);
  // "Moving outward": from (40, 0), fast straight toward the far edge is moving along the desk, neither out nor back in: a
  // drop. Turned a little outward it is a throw; turned a little inward it is not.
  assert.equal(isThrow({ x: 0, y: 90 }, { x: 40, y: 0 }, view), false);
  assert.equal(isThrow({ x: 25, y: 90 }, { x: 40, y: 0 }, view), true);
  assert.equal(isThrow({ x: -25, y: 90 }, { x: 40, y: 0 }, view), false);
  // From the very middle every fast direction leads out.
  assert.equal(isThrow({ x: 0, y: 90 }, { x: 0, y: 0 }, view), true);
});

test('the wheel riffles by its size: a big turn is several cards, the rest carries over, and the queue is capped', () => {
  assert.deepEqual(wheelSteps(600, 50), { steps: 12, rest: 0 });
  assert.deepEqual(wheelSteps(130, 50), { steps: 2, rest: 30 });
  assert.deepEqual(wheelSteps(-130, 50), { steps: -2, rest: -30 });
  assert.deepEqual(wheelSteps(49, 50), { steps: 0, rest: 49 });
  assert.equal(queueRiffle(0, 12), RIFFLE_QUEUE);
  assert.equal(queueRiffle(2, 3), 5);
  assert.equal(queueRiffle(-1, -12), -RIFFLE_QUEUE);
  assert.equal(queueRiffle(4, -6), -2);
});

test('riffle sends the top of a pile to the bottom, one per step; back again with negative steps', () => {
  assert.deepEqual(riffle(['a', 'b', 'c'], 1), ['b', 'c', 'a']);
  assert.deepEqual(riffle(['a', 'b', 'c'], 2), ['c', 'a', 'b']);
  assert.deepEqual(riffle(['a', 'b', 'c'], 3), ['a', 'b', 'c']);
  assert.deepEqual(riffle(['a', 'b', 'c'], -1), ['c', 'a', 'b']);
  assert.deepEqual(riffle([], 4), []);
});

test('the back of the card says the device facts in plain words, one short line each, with no ids', () => {
  const lines = deviceLines({
    'context.audio_route': { inputs: [{ port_name: 'Microphone', port_type: 'built_in_mic' }], outputs: [{ port_name: 'Sport Earbuds', port_type: 'bluetooth_le' }] },
    'context.device': { battery_level: 0.39, battery_state: 'unplugged', interface_style: 'light', locale: 'en_GB', low_power_mode: false,
      orientation: 'portrait', thermal_state: 'nominal', uses_24_hour_clock: true },
    'context.network': { constrained: false, expensive: false, interface: 'wifi' },
    'context.enabled': { groups: ['device_context', 'location'] },
    'context.burst': { previous_capture_id: 'ea76e8ff-9b32-439e-98e8-5ee90c733e03', seconds_since_previous: 7421.4 },
    capture_location: { altitude_meters: 54.2, vertical_accuracy_meters: 12.3 },
  });
  assert.deepEqual(lines, [
    'Sound going to Sport Earbuds',
    'Battery at 39%, not charging',
    'Held upright',
    'On Wi-Fi',
    '2 h 4 min after the previous capture',
    '54 m above sea level',
  ]);
  const text = lines.join(' ');
  assert.doesNotMatch(text, /[0-9a-f]{8}-[0-9a-f]{4}/, 'no ids');
  assert.doesNotMatch(text, /true|false|device_context/, 'no raw values');
  assert.deepEqual(deviceLines({ 'context.device': { low_power_mode: true, interface_style: 'dark', thermal_state: 'serious', battery_state: 'charging', battery_level: 1 } }),
    ['Battery at 100%, charging', 'Low power mode on', 'Dark appearance', 'Running hot']);
  assert.deepEqual(deviceLines({ 'context.network': { interface: 'cellular', expensive: true, constrained: true } }), ['On mobile data, metered, low data mode']);
  assert.deepEqual(deviceLines({ 'context.burst': { seconds_since_previous: 9.2 } }), ['9 s after the previous capture']);
  assert.deepEqual(deviceLines({ 'context.burst': { seconds_since_previous: 2675.5 } }), ['45 min after the previous capture']);
  assert.deepEqual(deviceLines({ 'context.burst': { seconds_since_previous: 100000 } }), ['1 day 4 h after the previous capture']);
  assert.deepEqual(deviceLines({ 'context.audio_route': { outputs: [{ port_type: 'built_in_speaker', port_name: 'Speaker' }] } }), ['Sound going to the speaker']);
  assert.deepEqual(deviceLines({}), []);
});

test('lengths count whole seconds, as the browser\'s players do', () => {
  assert.equal(duration(2.6), '0:02');
  assert.equal(duration(61.9), '1:01');
  assert.equal(duration(undefined), '');
});
