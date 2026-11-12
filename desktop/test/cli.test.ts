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

test('hippo enrich runs the index step; hippo status reports it without the SQLite warning', () => {
  const folder = copyFixtures();
  const env = { HIPPO_DESK_HOME: home() };
  const r = hippo(['enrich', '--folder', folder, '--provider', 'fake'], env);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^Index: 7 captures · 7 added · 0 updated · 0 removed · 4 thumbnails$/m);
  assert.doesNotMatch(r.stderr, /ExperimentalWarning/);
  const s = hippo(['status'], env);
  assert.equal(s.status, 0, s.stderr);
  assert.equal(s.stderr, '');
  assert.match(s.stdout, /^Captures: 7 \(1 note · 1 link · 2 photo · 1 screenshot · 1 recording · 1 video · 0 file\)$/m);
  assert.match(s.stdout, /^Enriched: 5 of 7$/m);
  assert.match(s.stdout, /^Pending: 0$/m);
  assert.match(s.stdout, /^Failures: 0$/m);
  assert.match(s.stdout, /^Last enrich: \d{4}-\d\d-\d\dT[\d:.]+Z$/m);
  assert.match(s.stdout, /^Last index: \d{4}-\d\d-\d\dT[\d:.]+Z$/m);
});

test('hippo index builds, updates and rebuilds; nothing in the folder changes', () => {
  const folder = copyFixtures(); const before = snapshot(folder);
  const env = { HIPPO_DESK_HOME: home() };
  const first = hippo(['index', '--folder', folder], env);
  assert.equal(first.status, 0, first.stderr);
  assert.match(first.stdout, /^Index: 7 captures · 7 added · 0 updated · 0 removed · 4 thumbnails$/m);
  const second = hippo(['index'], env);
  assert.match(second.stdout, /^Index: 7 captures · 0 added · 0 updated · 0 removed · 0 thumbnails$/m);
  const rebuilt = hippo(['index', '--rebuild'], env);
  assert.match(rebuilt.stdout, /^Index: 7 captures · 7 added · 0 updated · 0 removed · 4 thumbnails$/m);
  const s = hippo(['status'], env);
  assert.match(s.stdout, /^Enriched: 0 of 7$/m);
  assert.match(s.stdout, /^Last enrich: never$/m);
  assert.deepEqual(snapshot(folder), before);
  assert.equal(hippo(['index', '--bogus'], env).status, 2);
});

test('hippo status before any index says so', () => {
  const r = hippo(['status', '--folder', copyFixtures()], { HIPPO_DESK_HOME: home() });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^No index yet: run hippo index\.$/m);
  assert.match(r.stdout, /^Captures: 0 /m);
});

test('hippo enrich --dry-run writes nothing', () => {
  const folder = copyFixtures();
  const h = home();
  const r = hippo(['enrich', '--folder', folder, '--dry-run', '--provider', 'fake'], { HIPPO_DESK_HOME: h });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /would call the model for 5 captures and write 5 documents/);
  assert.equal(fs.existsSync(path.join(folder, 'enrichments/server/2026/11/07/00000000-0000-4000-8000-000000000001')), false);
  assert.doesNotMatch(r.stdout, /^Index:/m);
  assert.ok(!fs.readdirSync(h).some(n => n.endsWith('.sqlite')), 'a dry run creates no index');
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
  assert.match(r.stdout, /^Index: 7 captures · 7 added/m, 'the index step still runs after a stop');
  assert.equal(fs.existsSync(path.join(folder, 'enrichments/server/2026/11/07/00000000-0000-4000-8000-000000000001')), false);
});

const posix = process.platform !== 'win32';

/** A PATH holding a `claude` stub that answers after `seconds` with a valid enrichment. When `marker` is given the stub
 *  creates that file as soon as it is called, so a test knows a model call is in flight. */
function slowClaude(seconds: number, marker?: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-slow-claude-'));
  const answer = JSON.stringify({ type: 'result', is_error: false, structured_output: { title: 'Slow answer', summary: 'Slow.',
    image_descriptions: [], tags: ['slow'], topic: 'slow', people: [], keywords: [] } });
  const touch = marker ? `: > '${marker}'\n` : '';
  fs.writeFileSync(path.join(dir, 'claude'), `#!/bin/sh\n${touch}cat > /dev/null\nsleep ${seconds}\nprintf '%s' '${answer}'\n`, { mode: 0o755 });
  return dir + path.delimiter + (process.env.PATH ?? '');
}

function runUntil(args: string[], env: Record<string, string>, onOut: (child: ReturnType<typeof spawn>, out: string) => void,
  onSpawn?: (child: ReturnType<typeof spawn>) => void):
  Promise<{ code: number | null; stdout: string; stderr: string; ms: number; t0: number }> {
  return new Promise(resolve => {
    const t0 = Date.now();
    const child = spawn(process.execPath, [bin, ...args], { env: { ...process.env, ...env } });
    let stdout = '', stderr = '';
    child.stdout.on('data', d => { stdout += d; onOut(child, stdout); });
    child.stderr.on('data', d => { stderr += d; onOut(child, stdout); });
    child.on('close', code => resolve({ code, stdout, stderr, ms: Date.now() - t0, t0 }));
    onSpawn?.(child);
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
  // Signal once a model call is in flight (the stub has created the marker), never on whatever the child prints first.
  const marker = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-marker-')), 'called');
  let signalledAt = 0;
  const r = await runUntil(['enrich', '--folder', folder, '--provider', 'claude-cli'], { HIPPO_DESK_HOME: home(), PATH: slowClaude(5, marker) },
    () => {}, child => {
      const poll = setInterval(() => {
        if (!fs.existsSync(marker)) return;
        clearInterval(poll);
        signalledAt = Date.now();
        child.kill('SIGTERM');
        setTimeout(() => child.kill('SIGTERM'), 200);
      }, 20);
      child.on('close', () => clearInterval(poll));
    });
  assert.equal(r.code, 130, r.stderr);
  assert.ok(signalledAt > 0, 'the model was never called');
  assert.ok(r.ms - (signalledAt - r.t0) < 2000, `exited ${r.ms - (signalledAt - r.t0)} ms after the first signal`);
});

// ---- recall: search, show, facets (an indexed fixture copy, not enriched with the fake provider) ----

const recallId = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;

/** A fixture copy indexed under a fresh HIPPO_DESK_HOME, which remembers the folder. */
function indexedFixtures(): { folder: string; env: Record<string, string> } {
  const folder = copyFixtures();
  const env = { HIPPO_DESK_HOME: home() };
  const r = hippo(['index', '--folder', folder], env);
  assert.equal(r.status, 0, r.stderr);
  return { folder, env };
}

test('hippo search --kind screenshot --json prints {total, items} with capture 7', () => {
  const { env } = indexedFixtures();
  const r = hippo(['search', '--kind', 'screenshot', '--json'], env);
  assert.equal(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout);
  assert.equal(out.total, 1);
  assert.equal(out.items.length, 1);
  assert.equal(out.items[0].id, recallId(7));
});

test('hippo search prints a readable block per capture', () => {
  const { env } = indexedFixtures();
  const r = hippo(['search', '--site', 'example.com'], env);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /Example Domain \(server\)/);
  assert.match(r.stdout, /^2026-11-07 09:02 · link · Example Domain \(server\)$/m);
  assert.match(r.stdout, new RegExp(`^    id ${recallId(2)}$`, 'm'));
  const car = hippo(['search', '--circumstance', 'in_car'], env);
  assert.match(car.stdout, /^    Likely: in_car \(high\)/m);
  assert.match(car.stdout, /^    File: .*\.png$/m);
  const none = hippo(['search', '--kind', 'file'], env);
  assert.equal(none.status, 0, none.stderr);
  assert.match(none.stdout, /^No captures match\.$/m);
});

test('hippo search flags: repeatable, comma-separated, --text words, --phrase, --spec, --near', () => {
  const { env } = indexedFixtures();
  const ids = (args: string[]) => {
    const r = hippo(['search', ...args, '--json'], env);
    assert.equal(r.status, 0, r.stderr);
    return JSON.parse(r.stdout).items.map((x: { id: string }) => Number(x.id.slice(-1))).sort();
  };
  assert.deepEqual(ids(['--kind', 'screenshot,video']), [5, 7]);
  assert.deepEqual(ids(['--kind', 'screenshot', '--kind', 'video']), [5, 7]);
  assert.deepEqual(ids(['--text', 'plumber cafe']), [1, 7]);
  assert.deepEqual(ids(['--phrase', 'the corner']), [7]);
  assert.deepEqual(ids(['--phrase', 'corner the']), []);
  assert.deepEqual(ids(['--spec', '{"has":["comment"]}']), [4]);
  assert.deepEqual(ids(['--near', '37.7749,-122.4194,500']), [4, 7]);
  assert.deepEqual(ids(['--from', '2026-11-07', '--to', '2026-11-07', '--weekday', 'sat', '--part-of-day', 'morning', '--limit', '3']).length, 3);
  assert.deepEqual(ids(['--circumstance', 'in_car', '--min-confidence', 'high']), [7]);
  assert.deepEqual(ids(['--sort', 'oldest', '--limit', '1']), [1]);
});

test('hippo search with a bad value exits 2 naming the field', () => {
  const { env } = indexedFixtures();
  const r = hippo(['search', '--limit', '0'], env);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /limit/);
  assert.equal(hippo(['search', '--kind', 'gif'], env).status, 2);
  assert.equal(hippo(['search', '--near', '1,2'], env).status, 2);
  assert.equal(hippo(['search', '--spec', '{not json'], env).status, 2);
  assert.equal(hippo(['search', '--spec', '{}', '--kind', 'link'], env).status, 2);
  assert.match(hippo(['search', '--from', 'yesterday'], env).stderr, /time\.from: expected YYYY-MM-DD/);
});

test('hippo show prints every field, the evidence lines and absolute paths; --json prints the record', () => {
  const { env } = indexedFixtures();
  const r = hippo(['show', recallId(7)], env);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /audio route was CarPlay/);
  assert.match(r.stdout, /Menu from the cafe on the corner/);
  assert.match(r.stdout, /\/00000000-0000-4000-8000-000700000001\.png$/m);
  const j = hippo(['show', recallId(7), '--json'], env);
  assert.equal(JSON.parse(j.stdout).id, recallId(7));
  const ambiguous = hippo(['show', '00000000'], env);
  assert.equal(ambiguous.status, 1);
  assert.match(ambiguous.stderr, /7 captures/);
  assert.equal(hippo(['show', 'ffffffff'], env).status, 1);
  assert.equal(hippo(['show'], env).status, 2);
});

test('hippo facets --json parses; the readable form lists the vocabulary', () => {
  const { env } = indexedFixtures();
  const r = hippo(['facets', '--json'], env);
  assert.equal(r.status, 0, r.stderr);
  const f = JSON.parse(r.stdout);
  assert.equal(f.total, 7);
  assert.deepEqual(f.date_range, { from: '2026-11-07', to: '2026-11-07' });
  const t = hippo(['facets'], env);
  assert.match(t.stdout, /^Circumstances: .*in_car 1/m);
  assert.match(t.stdout, /^Sites: example\.com 2$/m);
});

test('search, show and facets need an index, never load a provider, and change nothing in the folder', () => {
  const env0 = { HIPPO_DESK_HOME: home() };
  const fresh = copyFixtures();
  const noIndex = hippo(['search', '--folder', fresh], env0);
  assert.equal(noIndex.status, 1);
  assert.match(noIndex.stderr, /hippo index/);

  const { folder, env } = indexedFixtures();
  const before = snapshot(folder);
  // A resolve hook that reports every module under src/ the process loads.
  const hook = `data:text/javascript,${encodeURIComponent(`import { registerHooks } from 'node:module';
registerHooks({ resolve(s, c, next) { const r = next(s, c); if (r.url.includes('/src/')) process.stderr.write('LOADED ' + r.url + '\\n'); return r; } });`)}`;
  for (const args of [['search', '--kind', 'link'], ['show', recallId(7)], ['facets']]) {
    const r = spawnSync(process.execPath, ['--import', hook, bin, ...args], { encoding: 'utf8', env: { ...process.env, ...env } });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stderr, /LOADED .*\/src\/recall\/engine\.ts/, 'the hook sees what loads');
    assert.doesNotMatch(r.stderr, /\/src\/providers\//, args[0]);
  }
  assert.deepEqual(snapshot(folder), before);
});
