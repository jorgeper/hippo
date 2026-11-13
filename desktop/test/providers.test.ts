import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeProvider, fakeProvider, ProviderError } from '../src/providers/index.ts';
import { loadEnv, parseEnv } from '../src/core/env.ts';
import { childEnv } from '../src/providers/spawn.ts';

const schema = { type: 'object', properties: { fruit: { type: 'string' } }, required: ['fruit'] };
const base = { system: 'Reply in JSON.', prompt: 'Name one fruit.', schema, model: 'haiku' };
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const posix = process.platform !== 'win32';

const STUB = `#!/usr/bin/env node
const fs = require('node:fs');
let stdin = '';
if (process.env.STUB_PID) fs.writeFileSync(process.env.STUB_PID, String(process.pid));
process.stdin.on('data', d => { stdin += d; });
process.stdin.on('end', () => {
  const rec = { argv: process.argv.slice(2), cwd: process.cwd(), entries: fs.readdirSync(process.cwd()), stdin, pid: process.pid, hasAnthropicKey: process.env.ANTHROPIC_API_KEY !== undefined, hasOpenaiKey: process.env.OPENAI_API_KEY !== undefined };
  if (process.env.STUB_OUT) fs.writeFileSync(process.env.STUB_OUT, JSON.stringify(rec));
  const mode = process.env.STUB_MODE || 'ok';
  if (mode === 'ok') console.log(JSON.stringify({ is_error: false, result: '', structured_output: { fruit: 'pear' } }));
  else if (mode === 'limit') console.log(JSON.stringify({ is_error: true, result: "You've hit your usage limit" }));
  else if (mode === 'login') console.log(JSON.stringify({ is_error: true, result: 'Not logged in. Please run /login' }));
  else if (mode === 'junk') console.log('not json at all');
  else if (mode === 'crash') { console.log('garbage'); process.exitCode = 1; }
  else if (mode === 'nostruct') console.log(JSON.stringify({ is_error: false, result: 'hello' }));
  else if (mode === 'sleep') setTimeout(() => {}, 60000);
});
`;

function stubEnv(mode: string): { env: Record<string, string>; out: string; pidFile: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-stub-'));
  const exe = path.join(dir, 'claude');
  fs.writeFileSync(exe, STUB, { mode: 0o755 });
  const out = path.join(dir, 'record.json');
  const pidFile = path.join(dir, 'pid');
  // Only PATH reaches a child from the provider env, so the stub reads its settings from the process environment.
  Object.assign(process.env, { STUB_PID: pidFile, STUB_MODE: mode, STUB_OUT: out });
  return { env: { PATH: dir + path.delimiter + (process.env.PATH ?? '') }, out, pidFile };
}

test('claude-cli passes every spec flag, never --bare, runs in an empty temp dir', { skip: !posix }, async () => {
  const { env, out } = stubEnv('ok');
  const r = await makeProvider('claude-cli', env).complete(base);
  assert.deepEqual(r.value, { fruit: 'pear' });
  assert.equal(r.model, 'haiku');
  const rec = JSON.parse(fs.readFileSync(out, 'utf8'));
  const a: string[] = rec.argv;
  assert.ok(!a.includes('--bare'));
  for (const f of ['-p', '--strict-mcp-config', '--disable-slash-commands', '--no-session-persistence']) assert.ok(a.includes(f), f);
  const val = (f: string) => a[a.indexOf(f) + 1];
  assert.equal(val('--output-format'), 'json');
  assert.deepEqual(JSON.parse(val('--json-schema')), schema);
  assert.equal(val('--model'), 'haiku');
  assert.equal(val('--system-prompt'), 'Reply in JSON.');
  assert.equal(val('--tools'), '');
  assert.equal(val('--setting-sources'), '');
  assert.ok(!a.includes('--add-dir') && !a.includes('--permission-mode'));
  assert.equal(rec.stdin, 'Name one fruit.');
  assert.deepEqual(rec.entries, []);
  assert.ok(!path.resolve(rec.cwd).startsWith(repoRoot + path.sep));
  assert.ok(!fs.existsSync(rec.cwd), 'temp dir removed afterwards');
});

test('claude-cli with images adds the three image flags and names the path', { skip: !posix }, async () => {
  const { env, out } = stubEnv('ok');
  const imgDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-img-'));
  const img = path.join(imgDir, 'a b.jpg');
  await makeProvider('claude-cli', env).complete({ ...base, images: [img] });
  const rec = JSON.parse(fs.readFileSync(out, 'utf8'));
  const a: string[] = rec.argv;
  assert.equal(a[a.indexOf('--tools') + 1], 'Read');
  assert.equal(a.filter(x => x === '--tools').length, 1);
  assert.equal(a[a.indexOf('--add-dir') + 1], imgDir);
  assert.equal(a[a.indexOf('--permission-mode') + 1], 'dontAsk');
  assert.ok(rec.stdin.includes(img));
});

test('claude-cli error mapping', { skip: !posix }, async () => {
  const cases: [string, string][] = [['limit', 'usage_limit'], ['login', 'not_signed_in'], ['junk', 'bad_output'], ['nostruct', 'bad_output'], ['crash', 'failed']];
  for (const [mode, code] of cases) {
    const { env } = stubEnv(mode);
    await assert.rejects(makeProvider('claude-cli', env).complete(base), (e: any) => e instanceof ProviderError && e.code === code, mode);
  }
});

test('claude-cli timeout kills the child', { skip: !posix }, async () => {
  const { env, pidFile } = stubEnv('sleep');
  await assert.rejects(makeProvider('claude-cli', env).complete({ ...base, timeoutMs: 1500 }), (e: any) => e.code === 'timeout');
  let pid = NaN;
  for (let i = 0; i < 30 && !fs.existsSync(pidFile); i++) await new Promise(r => setTimeout(r, 100));
  pid = Number(fs.readFileSync(pidFile, 'utf8'));
  let alive = true;
  for (let i = 0; i < 30 && alive; i++) {
    try { process.kill(pid, 0); await new Promise(r => setTimeout(r, 100)); } catch { alive = false; }
  }
  assert.ok(!alive, 'child is gone');
});

test('children do not inherit keys from the provider env, only PATH', { skip: !posix }, async () => {
  const saved = { a: process.env.ANTHROPIC_API_KEY, o: process.env.OPENAI_API_KEY };
  delete process.env.ANTHROPIC_API_KEY; delete process.env.OPENAI_API_KEY;
  try {
    const { env, out } = stubEnv('ok');
    await makeProvider('claude-cli', { ...env, ANTHROPIC_API_KEY: 'sentinel-not-a-real-key', OPENAI_API_KEY: 'sentinel-not-a-real-key' }).complete(base);
    const rec = JSON.parse(fs.readFileSync(out, 'utf8'));
    assert.equal(rec.hasAnthropicKey, false);
    assert.equal(rec.hasOpenaiKey, false);
    const ce = childEnv({ PATH: '/x', OPENAI_API_KEY: 'sentinel-not-a-real-key', OPENAI_BASE_URL: 'u' });
    assert.equal(ce.PATH, '/x');
    assert.equal(ce.OPENAI_API_KEY, undefined);
    assert.equal(ce.OPENAI_BASE_URL, undefined);
    assert.equal(childEnv({}).PATH, process.env.PATH);
  } finally {
    if (saved.a !== undefined) process.env.ANTHROPIC_API_KEY = saved.a;
    if (saved.o !== undefined) process.env.OPENAI_API_KEY = saved.o;
  }
});

test('an unreadable image fails before any network call, naming the basename only', async () => {
  const realFetch = globalThis.fetch;
  let called = false;
  globalThis.fetch = (async () => { called = true; throw new Error('no network in tests'); }) as typeof fetch;
  try {
    const missing = path.join(os.tmpdir(), 'hippo-no-such-dir', 'gone.jpg');
    const env = { ANTHROPIC_API_KEY: 'sentinel-not-a-real-key', OPENAI_API_KEY: 'sentinel-not-a-real-key', OPENAI_BASE_URL: 'http://localhost:1' };
    for (const [name, model] of [['anthropic-api', 'haiku'], ['openai-compatible', 'some-model']]) {
      await assert.rejects(makeProvider(name, env).complete({ ...base, model, images: [missing] }), (e: any) =>
        e instanceof ProviderError && e.code === 'failed' && e.message === 'could not read image gone.jpg' && !e.message.includes('hippo-no-such-dir'), name);
    }
    assert.equal(called, false);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('claude-cli without a claude on PATH is unavailable', async () => {
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-nopath-'));
  await assert.rejects(makeProvider('claude-cli', { PATH: empty }).complete(base), (e: any) => e.code === 'unavailable');
  await assert.rejects(makeProvider('codex-cli', { PATH: empty }).complete(base), (e: any) => e.code === 'unavailable');
});

test('API providers without keys are unavailable and name only the variable', async () => {
  await assert.rejects(makeProvider('anthropic-api', {}).complete(base), (e: any) => e.code === 'unavailable' && e.message.includes('ANTHROPIC_API_KEY'));
  const secret = 'sk-test-SECRETVALUE-1234';
  await assert.rejects(makeProvider('anthropic-api', { OPENAI_API_KEY: secret }).complete(base), (e: any) => !e.message.includes(secret));
  await assert.rejects(makeProvider('openai-compatible', { OPENAI_API_KEY: secret }).complete({ ...base, model: 'haiku' }), (e: any) =>
    e.code === 'unavailable' && e.message.includes('OPENAI_BASE_URL') && e.message.includes('model') && !e.message.includes(secret));
});

test('unknown provider name is unavailable', () => {
  assert.throws(() => makeProvider('nope', {}), (e: any) => e instanceof ProviderError && e.code === 'unavailable');
});

test('fakeProvider returns the handler value, or {} by default', async () => {
  const req = { ...base };
  assert.deepEqual(await fakeProvider(r => ({ echo: r.prompt })).complete(req), { value: { echo: 'Name one fruit.' }, model: 'fake' });
  assert.deepEqual(await fakeProvider().complete(req), { value: {}, model: 'fake' });
  assert.equal(makeProvider('fake', {}).name, 'fake');
});

test('parseEnv handles values, quotes and comments', () => {
  const e = parseEnv('# top\nA=1\nB="two words" # c\nC=\'x#y\'\nexport D=four # tail\n\nbad line\nE=\n');
  assert.deepEqual(e, { A: '1', B: 'two words', C: 'x#y', D: 'four', E: '' });
});

test('loadEnv: process environment wins over the file; missing file is fine', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-env-'));
  const file = path.join(dir, '.env');
  fs.writeFileSync(file, 'ONE=file\nTWO=file\nEMPTY=\n');
  assert.deepEqual(loadEnv(file, { TWO: 'proc', THREE: 'proc' }), { ONE: 'file', TWO: 'proc', THREE: 'proc' });
  assert.deepEqual(loadEnv(path.join(dir, 'missing'), { X: 'y' }), { X: 'y' });
});
