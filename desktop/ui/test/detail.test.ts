import test from 'node:test';
import assert from 'node:assert/strict';
import { circumstanceWords, deviceLines, gapWords, methodWords, safeLink, whenLine } from '../src/overlay/detail.ts';

const INHERITED = ['constructor', '__proto__', 'toString', 'hasOwnProperty', 'valueOf'];

test('values that name an inherited property never print one: ports, battery, orientation, network', () => {
  for (const v of INHERITED) {
    const lines = deviceLines({
      'context.audio_route': { outputs: [{ port_type: v }] },
      'context.device': { battery_state: v, orientation: v },
      'context.network': { interface: v },
    });
    assert.deepEqual(lines, [], `${v}: ${JSON.stringify(lines)}`);
    // A named port keeps its own name.
    assert.deepEqual(deviceLines({ 'context.audio_route': { outputs: [{ port_type: v, port_name: 'Car Stereo' }] } }), ['Sound going to Car Stereo']);
  }
});

test('circumstance labels, methods and weekdays that name an inherited property are shown as written', () => {
  for (const v of INHERITED) {
    assert.equal(circumstanceWords(v), v);
    assert.equal(methodWords(v), v === '__proto__' ? 'Proto' : v.charAt(0).toUpperCase() + v.slice(1).replace(/_/g, ' '));
    assert.doesNotMatch(methodWords(v), /function|\[native code\]|\{/);
    assert.equal(whenLine({ local_date: '2026-11-10', local_time: '14:32', weekday: v }), `${v} 10 November 2026, 14:32`);
  }
  assert.equal(circumstanceWords('in_car'), 'In a car');
  assert.equal(methodWords('camera'), 'Taken with the camera');
});

test('the battery level is kept between 0 and 100 %', () => {
  assert.deepEqual(deviceLines({ 'context.device': { battery_level: 7.5 } }), ['Battery at 100%']);
  assert.deepEqual(deviceLines({ 'context.device': { battery_level: -1 } }), ['Battery at 0%']);
  assert.deepEqual(deviceLines({ 'context.device': { battery_level: 0.5 } }), ['Battery at 50%']);
});

test('a huge gap since the previous capture reads as days at most, then "more than a month"', () => {
  assert.deepEqual(deviceLines({ 'context.burst': { seconds_since_previous: 1e9 } }), ['More than a month after the previous capture']);
  assert.equal(gapWords(30 * 86400), '30 days');
  assert.equal(gapWords(31 * 86400), 'More than a month');
  assert.equal(gapWords(Number.MAX_VALUE), 'More than a month');
  assert.equal(gapWords(100000), '1 day 4 h');
});

test('safeLink: only http and https; javascript, data, file and vbscript in any case or after spaces give nothing', () => {
  for (const u of ['javascript:alert(1)', 'JavaScript:alert(1)', '  javascript:alert(1)', '\tjavascript:alert(1)', 'data:text/html,<b>x</b>',
    'DATA:text/html,x', 'file:///etc/passwd', ' File:///etc/passwd', 'vbscript:msgbox(1)', 'VBScript:msgbox(1)', 'ftp://example.com/', '', undefined])
    assert.equal(safeLink(u), undefined, String(u));
  assert.equal(safeLink('http://example.com/a?b=1'), 'http://example.com/a?b=1');
  assert.equal(safeLink('https://www.youtube.com/watch?v=x'), 'https://www.youtube.com/watch?v=x');
  assert.equal(safeLink('HTTPS://example.com/'), 'HTTPS://example.com/');
});
