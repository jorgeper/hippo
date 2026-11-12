import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeProvider, fakeProvider, ProviderError } from '../src/providers/index.ts';
import { loadEnv, parseEnv } from '../src/core/env.ts';

const schema = { type: 'object', properties: { fruit: { type: 'string' } }, required: ['fruit'] };
const base = { system: 'Reply in JSON.', prompt: 'Name one fruit.', schema, model: 'haiku' };
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const posix = process.platform !== 'win32';

const STUB = `#!/usr/bin/env node
const fs = require('node:fs');
let stdin = '';
process.stdin.on('data', d => { stdin += d; });
process.stdin.on('end', () => {
  const rec = { argv: process.argv.slice(2), cwd: process.cwd(), entries: fs.readdirSync(process.cwd()), stdin, pid: process.pid };
  if (process.env.STUB_OUT) fs.writeFileSync(process.env.STUB_OUT, JSON.stringify(rec));
  const mode = process.env.STUB_MODE || 'ok';
  if (mode === 'ok') console.log(JSON.stringify({ is_error: false, result: '', structured_output: { fruit: 'pear' } }));
  else if (mode === 'limit') console.log(JSON.stringify({ is_error: true, result: "You've hit your usage limit" }));
  else if (mode === 'login') console.log(JSON.stringify({ is_error: true, result: 'Not logged in. Please run /login' }));
  else if (mode === 'junk') console.log('not json at all');
  else if (mode === 'nostruct') console.log(JSON.stringify({ is_error: false, result: 'hello' }));
  else if (mode === 'sleep') setTimeout(() => {}, 60000);
});
`;

function stubEnv(mode: string): { env: Record<string, string>; out: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-stub-'));
  const exe = path.join(dir, 'claude');
  fs.writeFileSync(exe, STUB, { mode: 0o755 });
  const out = path.join(dir, 'record.json');
  return { env: { PATH: dir + path.delimiter + (process.env.PATH ?? ''), STUB_MODE: mode, STUB_OUT: out }, out };
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
  const cases: [string, string][] = [['limit', 'usage_limit'], ['login', 'not_signed_in'], ['junk', 'failed'], ['nostruct', 'bad_output']];
  for (const [mode, code] of cases) {
    const { env } = stubEnv(mode);
    await assert.rejects(makeProvider('claude-cli', env).complete(base), (e: any) => {
      assert.ok(e instanceof ProviderError);
      if (mode === 'junk') return e.code === 'bad_output' || e.code === 'failed';
      return e.code === code;
    }, mode);
  }
});

test('claude-cli timeout kills the child', { skip: !posix }, async () => {
  const { env, out } = stubEnv('sleep');
  await assert.rejects(makeProvider('claude-cli', env).complete({ ...base, timeoutMs: 400 }), (e: any) => e.code === 'timeout');
  const pid = JSON.parse(fs.readFileSync(out, 'utf8')).pid;
  await new Promise(r => setTimeout(r, 200));
  assert.throws(() => process.kill(pid, 0), 'child is gone');
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
