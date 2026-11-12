import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { copyFixtures } from './helpers.ts';

const bin = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../bin/hippo.mjs');
const home = () => fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-home-'));
const hippo = (args: string[], env: Record<string, string>) =>
  spawnSync(process.execPath, [bin, ...args], { encoding: 'utf8', env: { ...process.env, ...env } });

test('an inherited name such as constructor is not a command', () => {
  const r = hippo(['constructor'], { HIPPO_DESK_HOME: home() });
  assert.equal(r.status, 2); assert.match(r.stderr, /Usage: hippo/);
  assert.equal(hippo(['toString'], { HIPPO_DESK_HOME: home() }).status, 2);
  assert.equal(hippo([], { HIPPO_DESK_HOME: home() }).status, 2);
});

test('hippo enrich with the fake provider prints one line per capture acted on and the summary', () => {
  const folder = copyFixtures();
  const env = { HIPPO_DESK_HOME: home() };
  const r = hippo(['enrich', '--folder', folder, '--provider', 'fake'], env);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^7 captures · 5 model calls · 5 written · 2 unchanged · 0 failed$/m);
  assert.equal(r.stdout.split('\n').filter(l => / written$/.test(l)).length, 5);
  const again = hippo(['enrich', '--provider', 'fake'], env);        // the folder is remembered
  assert.equal(again.status, 0, again.stderr);
  assert.match(again.stdout, /^7 captures · 0 model calls · 0 written · 7 unchanged · 0 failed$/m);
});

test('hippo enrich --dry-run writes nothing', () => {
  const folder = copyFixtures();
  const r = hippo(['enrich', '--folder', folder, '--dry-run', '--provider', 'fake'], { HIPPO_DESK_HOME: home() });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /would call the model for 5 captures and write 5 documents/);
  assert.equal(fs.existsSync(path.join(folder, 'enrichments/server/2026/11/07/00000000-0000-4000-8000-000000000001')), false);
});

test('hippo enrich with a bad --limit exits 2', () => {
  const r = hippo(['enrich', '--folder', copyFixtures(), '--limit', 'x', '--provider', 'fake'], { HIPPO_DESK_HOME: home() });
  assert.equal(r.status, 2);
});

test('hippo enrich exits 3 and says how far it got when the provider is unavailable', () => {
  const folder = copyFixtures();
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-nopath-'));
  const r = hippo(['enrich', '--folder', folder, '--provider', 'claude-cli'], { HIPPO_DESK_HOME: home(), PATH: empty });
  assert.equal(r.status, 3, r.stderr);
  assert.match(r.stderr, /Stopped early \(unavailable\): the claude command was not found on PATH/);
  assert.match(r.stderr, /Got through \d+ of 7 captures/);
  assert.equal(fs.existsSync(path.join(folder, 'enrichments/server/2026/11/07/00000000-0000-4000-8000-000000000001')), false);
});
