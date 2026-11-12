import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { copyFixtures, enrichmentDoc, syntheticCapture } from './helpers.ts';
import { scanFolder } from '../src/core/folder.ts';
import { deriveCircumstances } from '../src/core/circumstance.ts';
import type { RawCapture } from '../src/core/types.ts';

const route = (...outputs: { port_type: string; port_name?: string }[]) =>
  ({ key: 'context.audio_route', provenance: 'av_audio_session', value: { outputs } });
const burst = (seconds: number) =>
  ({ key: 'context.burst', provenance: 'last_saved', value: { previous_capture_id: '00000000-0000-4000-8000-000000000006', seconds_since_previous: seconds } });
const motion = (activities: string[], confidence: string) =>
  ({ motion_activity: { provenance: 'core_motion', data: { window_start: '2026-11-07T16:50:00.000Z', window_end: '2026-11-07T17:10:00.000Z',
    at_capture: { started_at: '2026-11-07T16:58:00.000Z', activities, confidence }, segments: [] } } });
const at = (lat: number, lon: number, speed?: number) =>
  ({ latitude: lat, longitude: lon, horizontal_accuracy_meters: 10, observed_at: '2026-11-07T17:00:00.000Z', provenance: 'core_location_request',
    ...(speed === undefined ? {} : { speed_meters_per_second: speed }) });

function cap(md: Record<string, any>, device?: Record<string, any>): RawCapture {
  return syntheticCapture(md, device ? { device: enrichmentDoc('device', device) } : {});
}
const labels = (c: RawCapture) => deriveCircumstances(c).map(x => x.label);
const one = (c: RawCapture, label: string) => deriveCircumstances(c).find(x => x.label === label);

test('fixture capture 7 reproduces the server fixture circumstance facet exactly', async () => {
  const folder = copyFixtures();
  const s = await scanFolder(folder);
  const c7 = s.captures[6];
  const got = deriveCircumstances(c7);
  const inCar = got.find(x => x.label === 'in_car');
  assert.equal(inCar?.confidence, 'high');
  assert.ok(inCar?.evidence.includes('audio route was CarPlay'));
  assert.ok(inCar?.evidence.includes('speed was 11.2 m/s'));
  assert.deepEqual(got.find(x => x.label === 'in_a_burst'), { label: 'in_a_burst', confidence: 'medium', evidence: ['previous capture was 60 s earlier'] });
  assert.equal(got.find(x => x.label === 'daylight')?.confidence, 'high');
  assert.equal(got.find(x => x.label === 'on_headphones'), undefined);
  const doc = JSON.parse(fs.readFileSync(path.join(folder,
    'enrichments/server/2026/11/07/00000000-0000-4000-8000-000000000007/enrichment.json'), 'utf8'));
  assert.deepEqual(got, doc.facets.circumstance.data.items);
});

test('the server circumstance facet is never read', async () => {
  const s = await scanFolder(copyFixtures());
  const c7 = s.captures[6];
  const before = deriveCircumstances(c7);
  const server = structuredClone(c7.server!);
  server.facets.circumstance = { ...server.facets.circumstance, data: { items: [{ label: 'walking', confidence: 'high', evidence: ['x'] }] } };
  assert.deepEqual(deriveCircumstances({ ...c7, server }), before);
});

test('fixture capture 1 yields nothing', async () => {
  const s = await scanFolder(copyFixtures());
  assert.deepEqual(deriveCircumstances(s.captures[0]), []);
});

test('in_car from car audio alone is high, naming the port', () => {
  assert.deepEqual(one(cap({ metadata_observations: [route({ port_type: 'car_audio', port_name: 'CarPlay' })] }), 'in_car'),
    { label: 'in_car', confidence: 'high', evidence: ['audio route was CarPlay'] });
  assert.deepEqual(one(cap({ metadata_observations: [route({ port_type: 'car_audio' })] }), 'in_car')?.evidence, ['audio route was car audio']);
});

test('in_car from automotive motion alone follows the motion confidence', () => {
  assert.deepEqual(one(cap({}, motion(['automotive'], 'medium')), 'in_car'),
    { label: 'in_car', confidence: 'medium', evidence: ['motion at capture was automotive'] });
  assert.equal(one(cap({}, motion(['automotive', 'stationary'], 'high')), 'in_car')?.confidence, 'high');
});

test('in_car from speed alone is low; two signals are high', () => {
  assert.deepEqual(one(cap({ capture_location: at(37.7, -122.4, 8) }), 'in_car'),
    { label: 'in_car', confidence: 'low', evidence: ['speed was 8.0 m/s'] });
  assert.deepEqual(one(cap({ capture_location: at(37.7, -122.4, 12.34) }, motion(['automotive'], 'low')), 'in_car'),
    { label: 'in_car', confidence: 'high', evidence: ['motion at capture was automotive', 'speed was 12.3 m/s'] });
  assert.equal(one(cap({ capture_location: at(37.7, -122.4, 3) }), 'in_car'), undefined);
  assert.equal(one(cap({ capture_location: at(37.7, -122.4) }), 'in_car'), undefined);
});

test('speed 9 while cycling gives cycling and no in_car', () => {
  const c = cap({ capture_location: at(37.7, -122.4, 9) }, motion(['cycling'], 'high'));
  assert.deepEqual(deriveCircumstances(c), [{ label: 'cycling', confidence: 'high', evidence: ['motion at capture was cycling'] }]);
});

test('walking and running take the motion sample confidence', () => {
  assert.deepEqual(deriveCircumstances(cap({}, motion(['walking'], 'medium'))),
    [{ label: 'walking', confidence: 'medium', evidence: ['motion at capture was walking'] }]);
  assert.deepEqual(deriveCircumstances(cap({}, motion(['running'], 'low'))),
    [{ label: 'running', confidence: 'low', evidence: ['motion at capture was running'] }]);
  assert.deepEqual(labels(cap({}, motion(['stationary'], 'high'))), []);
  assert.deepEqual(labels(cap({}, { motion_activity: { status: 'empty', provenance: 'core_motion' } })), []);
});

test('on_headphones: wired and LE are high, A2DP and HFP medium, none beside car audio', () => {
  assert.deepEqual(one(cap({ metadata_observations: [route({ port_type: 'headphones', port_name: 'Headphones' })] }), 'on_headphones'),
    { label: 'on_headphones', confidence: 'high', evidence: ['audio route was Headphones'] });
  assert.equal(one(cap({ metadata_observations: [route({ port_type: 'bluetooth_le', port_name: 'Buds' })] }), 'on_headphones')?.confidence, 'high');
  assert.deepEqual(one(cap({ metadata_observations: [route({ port_type: 'bluetooth_a2dp', port_name: 'Buds' })] }), 'on_headphones'),
    { label: 'on_headphones', confidence: 'medium', evidence: ['audio route was Buds'] });
  assert.equal(one(cap({ metadata_observations: [route({ port_type: 'bluetooth_hfp', port_name: 'Buds' })] }), 'on_headphones')?.confidence, 'medium');
  assert.equal(one(cap({ metadata_observations: [route({ port_type: 'car_audio', port_name: 'CarPlay' }, { port_type: 'bluetooth_a2dp', port_name: 'Car' })] }), 'on_headphones'), undefined);
  assert.deepEqual(labels(cap({ metadata_observations: [route({ port_type: 'built_in_speaker', port_name: 'Speaker' })] })), []);
});

test('in_a_burst: under 60 s high, under 180 s medium, otherwise none', () => {
  assert.deepEqual(deriveCircumstances(cap({ metadata_observations: [burst(12.5)] })),
    [{ label: 'in_a_burst', confidence: 'high', evidence: ['previous capture was 12.5 s earlier'] }]);
  assert.equal(one(cap({ metadata_observations: [burst(179.9)] }), 'in_a_burst')?.confidence, 'medium');
  assert.deepEqual(labels(cap({ metadata_observations: [burst(180)] })), []);
});

test('daylight and dark come from an ok weather facet; failed weather says nothing', () => {
  const weather = (f: Record<string, any>) => ({ weather: { provenance: 'open_meteo', ...f } });
  assert.deepEqual(deriveCircumstances(cap({}, weather({ data: { observed_hour: '2026-11-07T17:00:00.000Z', source: 'open-meteo.com', is_day: true } }))),
    [{ label: 'daylight', confidence: 'high', evidence: ['weather lookup says daytime'] }]);
  assert.deepEqual(deriveCircumstances(cap({}, weather({ data: { observed_hour: '2026-11-07T17:00:00.000Z', source: 'open-meteo.com', is_day: false } }))),
    [{ label: 'dark', confidence: 'high', evidence: ['weather lookup says night'] }]);
  assert.deepEqual(labels(cap({}, weather({ status: 'failed', provenance: 'weather_http_400' }))), []);
  assert.deepEqual(labels(cap({}, weather({ data: { observed_hour: '2026-11-07T17:00:00.000Z', source: 'open-meteo.com' } }))), []);
});

test('labels come out in table order', () => {
  const c = cap({ metadata_observations: [route({ port_type: 'headphones', port_name: 'H' }), burst(5)], capture_location: at(1, 1, 1) },
    { ...motion(['walking'], 'high'), weather: { data: { is_day: false } } });
  assert.deepEqual(labels(c), ['walking', 'on_headphones', 'in_a_burst', 'dark']);
});
