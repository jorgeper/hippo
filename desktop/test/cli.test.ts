import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { copyFixtures, snapshot } from './helpers.ts';

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

const posix = process.platform !== 'win32';

/** A PATH holding a `claude` stub that answers after `seconds` with a valid enrichment. */
function slowClaude(seconds: number): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-slow-claude-'));
  const answer = JSON.stringify({ type: 'result', is_error: false, structured_output: { title: 'Slow answer', summary: 'Slow.',
    image_descriptions: [], tags: ['slow'], topic: 'slow', people: [], keywords: [] } });
  fs.writeFileSync(path.join(dir, 'claude'), `#!/bin/sh\ncat > /dev/null\nsleep ${seconds}\nprintf '%s' '${answer}'\n`, { mode: 0o755 });
  return dir + path.delimiter + (process.env.PATH ?? '');
}

function runUntil(args: string[], env: Record<string, string>, onOut: (child: ReturnType<typeof spawn>, out: string) => void):
  Promise<{ code: number | null; stdout: string; stderr: string; ms: number }> {
  return new Promise(resolve => {
    const t0 = Date.now();
    const child = spawn(process.execPath, [bin, ...args], { env: { ...process.env, ...env } });
    let stdout = '', stderr = '';
    child.stdout.on('data', d => { stdout += d; onOut(child, stdout); });
    child.stderr.on('data', d => { stderr += d; onOut(child, stdout); });
    child.on('close', code => resolve({ code, stdout, stderr, ms: Date.now() - t0 }));
  });
}

test('SIGINT stops after the calls in flight, prints the summary and exits 130', { skip: !posix }, async () => {
  const folder = copyFixtures();
  const h = home();
  let sent = false;
  const r = await runUntil(['enrich', '--folder', folder, '--provider', 'claude-cli'], { HIPPO_DESK_HOME: h, PATH: slowClaude(1) },
    (child, out) => { if (!sent && / written$/m.test(out)) { sent = true; child.kill('SIGINT'); } });
  assert.equal(r.code, 130, r.stderr);
  assert.match(r.stderr, /stopping after the calls in flight/);
  assert.match(r.stdout, /^7 captures · \d model calls · \d written · \d unchanged · 0 failed · \d left for the next run$/m);
  assert.ok(Object.keys(snapshot(folder)).every(p => !p.endsWith('.tmp')));
  const env = { ...process.env, HIPPO_DESK_HOME: h };
  const rows = spawnSync(process.execPath, ['-e', `const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync(process.argv[1]);console.log(d.prepare('SELECT COUNT(*) AS n FROM enrich_failures').get().n)`, path.join(h, fs.readdirSync(h).find(n => n.endsWith('.sqlite'))!)], { encoding: 'utf8', env });
  assert.equal(rows.stdout.trim(), '0');
});

test('a second signal exits at once', { skip: !posix }, async () => {
  const folder = copyFixtures();
  let sent = 0;
  const r = await runUntil(['enrich', '--folder', folder, '--provider', 'claude-cli'], { HIPPO_DESK_HOME: home(), PATH: slowClaude(5) },
    child => { if (sent++ === 0) setTimeout(() => { child.kill('SIGTERM'); setTimeout(() => child.kill('SIGTERM'), 200); }, 1000); });
  assert.equal(r.code, 130, r.stderr);
  assert.ok(r.ms < 4000, `took ${r.ms} ms`);
});
