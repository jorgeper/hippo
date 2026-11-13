import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import { copyFixtures, snapshot } from './helpers.ts';
import { enrichFolder } from '../src/enrich/enrich.ts';
import { fakeEnrichment, fakeProvider } from '../src/providers/fake.ts';
import { ProviderError } from '../src/providers/types.ts';
import type { ModelRequest } from '../src/providers/types.ts';
import { buildIndex } from '../src/index/build.ts';
import { loadConfig } from '../src/core/paths.ts';
import { startServer } from '../src/server/server.ts';
import type { DeskItem } from '../src/server/wire.ts';

const id = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;
const att = (capture: number, n: number) => `00000000-0000-4000-8000-000${capture}0000000${n}`;
const now = () => new Date('2026-11-12T10:00:00Z');
const sha = (b: Buffer) => crypto.createHash('sha256').update(b).digest('hex');

// Every server in this file shares one HIPPO_DESK_HOME (copyFixtures points it at a new one each time).
const home = { value: '' };
function fixtureCopy(): string {
  const folder = copyFixtures();
  if (home.value) process.env.HIPPO_DESK_HOME = home.value; else home.value = process.env.HIPPO_DESK_HOME!;
  return folder;
}

/** Rewrites one attachment's declared mime type in metadata.json and keeps complete.json consistent. */
function setMime(folder: string, capture: number, attachment: string, mime: string): void {
  const dir = path.join(folder, 'captures/2026/11/07', id(capture));
  const md = JSON.parse(fs.readFileSync(path.join(dir, 'metadata.json'), 'utf8'));
  for (const a of md.attachments) if (a.attachment_id === attachment) a.mime_type = mime;
  const bytes = Buffer.from(JSON.stringify(md, null, 2));
  fs.writeFileSync(path.join(dir, 'metadata.json'), bytes);
  const complete = JSON.parse(fs.readFileSync(path.join(dir, 'complete.json'), 'utf8'));
  for (const f of complete.files) if (f.relative_path === 'metadata.json') { f.byte_count = bytes.length; f.sha256 = sha(bytes); }
  fs.writeFileSync(path.join(dir, 'complete.json'), JSON.stringify(complete, null, 2));
}

interface Reply { status: number; headers: http.IncomingHttpHeaders; body: Buffer; text: string; json: any }

/** One request with full control of the headers (fetch cannot set Host). */
function request(port: number, method: string, urlPath: string, headers: Record<string, string | number> = {}, body?: string | Buffer): Promise<Reply> {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers, setHost: false }, res => {
      const chunks: Buffer[] = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const b = Buffer.concat(chunks);
        let json: any;
        try { json = JSON.parse(b.toString('utf8')); } catch { json = undefined; }
        resolve({ status: res.statusCode!, headers: res.headers, body: b, text: b.toString('utf8'), json });
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}

// ---- the main server: a fixture copy with two lying manifests, enriched with the fake provider and indexed ----

const folder = fixtureCopy();
setMime(folder, 1, att(1, 1), 'text/html');
setMime(folder, 3, att(3, 1), 'image/svg+xml');
await enrichFolder({ folder, provider: fakeProvider(), now });
await buildIndex(folder);
const uiDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-ui-'));
fs.writeFileSync(path.join(uiDir, 'index.html'), '<!doctype html><title>desk</title><p>the desk page</p>');
fs.writeFileSync(path.join(uiDir, 'app.js'), 'console.log(1);');
fs.mkdirSync(path.join(uiDir, 'assets'));
fs.writeFileSync(path.join(uiDir, 'assets', 'style.css'), 'body{}');
const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-outside-'));
fs.writeFileSync(path.join(outside, 'secret.txt'), 'not for the page');
fs.symlinkSync(path.join(outside, 'secret.txt'), path.join(uiDir, 'leak.txt'));

/** What the main server's provider answers; tests swap it and put the default back. */
let answer: (req: ModelRequest) => unknown;
const useDefaultAnswers = () => { answer = async req => (await fakeProvider().complete(req)).value; };
useDefaultAnswers();
const logs: string[] = [];
const srv = await startServer({ folder, port: 0, provider: fakeProvider(req => answer(req)), uiDir, log: line => logs.push(line) });
test.after(() => srv.close());

const host = () => `127.0.0.1:${srv.port}`;
const auth = (extra: Record<string, string | number> = {}) => ({ Host: host(), 'X-Hippo-Token': srv.token, ...extra });
const get = (p: string, extra: Record<string, string | number> = {}) => request(srv.port, 'GET', p, auth(extra));
const post = (p: string, body: unknown, extra: Record<string, string | number> = {}) => {
  const b = typeof body === 'string' ? body : JSON.stringify(body);
  return request(srv.port, 'POST', p, auth({ 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b), ...extra }), b);
};
const mediaPath = (url: string) => { assert.match(url, /^\/media\//); return url; };

test('binds 127.0.0.1 only; the URL carries a 64-hex token', async () => {
  assert.match(srv.url, new RegExp(`^http://127\\.0\\.0\\.1:${srv.port}/\\?t=[0-9a-f]{64}$`));
  assert.equal(srv.token.length, 64);
  assert.ok(srv.url.endsWith(srv.token));
  const reached = await new Promise<boolean>(resolve => {
    const s = net.connect({ host: '::1', port: srv.port });
    s.on('connect', () => { s.destroy(); resolve(true); });
    s.on('error', () => resolve(false));
  });
  assert.equal(reached, false, 'nothing listens on the IPv6 loopback');
});

test('no token, a wrong token, a foreign Host or a foreign Origin: 403 with an empty body', async () => {
  for (const r of [
    await request(srv.port, 'GET', '/api/boot', { Host: host() }),
    await request(srv.port, 'GET', '/api/boot', { Host: host(), 'X-Hippo-Token': 'f'.repeat(64) }),
    await request(srv.port, 'GET', '/api/boot', { Host: host(), 'X-Hippo-Token': srv.token.slice(0, 10) }),
    await request(srv.port, 'GET', '/api/boot', { Host: host(), Cookie: `hippo_t=${'0'.repeat(64)}` }),
    await get('/api/boot', { Host: 'evil.example' }),
    await get('/api/boot', { Host: `127.0.0.1:${srv.port + 1}` }),
    await request(srv.port, 'GET', '/api/boot', { 'X-Hippo-Token': srv.token }),
    await get('/api/boot', { Origin: 'http://evil.example' }),
    await get('/api/boot', { Origin: 'null' }),
    await get(`/?t=${srv.token}`, { Host: 'evil.example' }),
    await request(srv.port, 'GET', '/no-such-thing', { Host: host() }),
    await request(srv.port, 'GET', `/media/${id(7)}/${att(7, 1)}`, { Host: host() }),
  ]) {
    assert.equal(r.status, 403);
    assert.equal(r.body.length, 0);
    assert.equal(r.headers['x-content-type-options'], 'nosniff');
  }
  assert.equal((await get('/api/boot', { Host: `localhost:${srv.port}` })).status, 200);
  assert.equal((await get('/api/boot', { Origin: `http://127.0.0.1:${srv.port}` })).status, 200);
  assert.equal((await get('/api/boot', { Host: `localhost:${srv.port}`, Origin: `http://localhost:${srv.port}` })).status, 200);
});

test('GET /?t= sets the cookie and returns the page; the cookie alone then opens the API', async () => {
  const page = await request(srv.port, 'GET', `/?t=${srv.token}`, { Host: host(), Accept: 'text/html' });
  assert.equal(page.status, 200);
  assert.match(page.text, /the desk page/);
  assert.match(String(page.headers['content-type']), /^text\/html/);
  const cookie = String(page.headers['set-cookie']);
  assert.equal(cookie, `hippo_t=${srv.token}; HttpOnly; SameSite=Strict; Path=/`);

  const boot = await request(srv.port, 'GET', '/api/boot', { Host: host(), Cookie: `other=1; hippo_t=${srv.token}` });
  assert.equal(boot.status, 200);
  assert.equal(boot.json.facets.total, 7);
  assert.equal(boot.json.status.total, 7);
  assert.deepEqual(Object.keys(boot.json.settings).sort(), ['askModel', 'enrichModel', 'mapTiles', 'provider', 'theme']);
  assert.match(boot.json.today, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(typeof boot.json.timezone, 'string');
  assert.ok(!boot.text.includes(srv.token), 'the token is never in /api/boot');

  // Files of the page are served with the cookie; the query token works only on the page itself.
  const js = await request(srv.port, 'GET', '/app.js', { Host: host(), Cookie: `hippo_t=${srv.token}` });
  assert.equal(js.status, 200);
  assert.match(String(js.headers['content-type']), /^text\/javascript/);
  assert.match(String((await get('/assets/style.css')).headers['content-type']), /^text\/css/);
  assert.equal((await request(srv.port, 'GET', `/api/boot?t=${srv.token}`, { Host: host() })).status, 403);
});

test('the page: unknown paths fall back to index.html only for GETs that accept HTML; nothing outside uiDir', async () => {
  const deep = await get('/some/desk/route', { Accept: 'text/html,application/xhtml+xml' });
  assert.equal(deep.status, 200);
  assert.match(deep.text, /the desk page/);
  assert.equal((await get('/missing.js', { Accept: '*/*' })).status, 404);
  assert.equal((await get('/leak.txt', { Accept: '*/*' })).status, 404, 'a symlink out of uiDir is not served');
  assert.equal((await get('/../../../etc/passwd', { Accept: '*/*' })).status, 404);
  assert.equal((await get('/%2e%2e/%2e%2e/etc/passwd', { Accept: '*/*' })).status, 404);
  assert.equal((await post('/', {})).status, 404);
});

test('unknown routes are 404 after the token check; only GET and POST', async () => {
  assert.equal((await get('/api/nope')).status, 404);
  assert.equal((await get('/media/x')).status, 404);
  const put = await request(srv.port, 'PUT', '/api/settings', auth({ 'Content-Type': 'application/json' }), '{}');
  assert.equal(put.status, 405);
  assert.equal((await request(srv.port, 'DELETE', '/api/boot', auth())).status, 405);
});

test('every response carries nosniff, no-referrer and, for pages and the API, the content security policy', async () => {
  for (const r of [await get('/api/boot'), await get(`/?t=${srv.token}`), await get('/api/nope'), await post('/api/search', { spec: { kinds: ['gif'] } })]) {
    assert.equal(r.headers['x-content-type-options'], 'nosniff');
    assert.equal(r.headers['referrer-policy'], 'no-referrer');
    const csp = String(r.headers['content-security-policy']);
    for (const part of ["default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob: https://tile.openstreetmap.org", "connect-src 'self'", "frame-ancestors 'none'", "base-uri 'none'",
      "form-action 'none'"]) assert.ok(csp.includes(part), `${part} in ${csp}`);
    assert.doesNotMatch(csp, /ws:/);
  }
});

test('POST needs Content-Type application/json; bodies over 1 MiB are 413; bad JSON is 400', async () => {
  const b = JSON.stringify({ spec: {} });
  for (const type of ['text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data; boundary=x', '']) {
    const r = await request(srv.port, 'POST', '/api/search', auth(type ? { 'Content-Type': type } : {}), b);
    assert.equal(r.status, 415, type);
  }
  assert.equal((await post('/api/search', b, { 'Content-Type': 'application/json; charset=utf-8' })).status, 200);
  const big = JSON.stringify({ spec: {}, pad: 'x'.repeat(1024 * 1024) });
  assert.equal((await post('/api/search', big)).status, 413);
  const chunked = await new Promise<number>((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: srv.port, method: 'POST', path: '/api/search', setHost: false,
      headers: auth({ 'Content-Type': 'application/json', 'Transfer-Encoding': 'chunked' }) }, res => { res.resume(); resolve(res.statusCode!); });
    req.on('error', reject);
    for (let i = 0; i < 20; i++) req.write('x'.repeat(64 * 1024));
    req.end();
  });
  assert.equal(chunked, 413);
  const bad = await post('/api/search', '{not json');
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error, 'bad_json');
});

test('/api/search: one screenshot whose thumb is a JPEG; dismissed and pinned', async () => {
  const r = await post('/api/search', { spec: { kinds: ['screenshot'] } });
  assert.equal(r.status, 200);
  assert.equal(r.json.total, 1);
  const item: DeskItem = r.json.items[0];
  assert.equal(item.id, id(7));
  assert.equal(item.kind, 'screenshot');
  assert.ok(item.thumb && item.display && item.media);
  assert.equal(item.media_type, 'picture');
  assert.equal(item.more_count, 1);
  assert.ok(item.has.includes('picture'));
  assert.ok(item.circumstances.some(c => c.label === 'in_car'));
  const thumb = await get(mediaPath(item.thumb));
  assert.equal(thumb.status, 200);
  assert.equal(thumb.headers['content-type'], 'image/jpeg');
  assert.equal(thumb.body[0], 0xff); assert.equal(thumb.body[1], 0xd8);
  assert.equal(thumb.headers['cache-control'], 'private, max-age=3600');
  assert.equal(thumb.headers['content-security-policy'], "default-src 'none'; sandbox");
  assert.equal(thumb.headers['x-content-type-options'], 'nosniff');

  const gone = await post('/api/search', { spec: { kinds: ['screenshot'] }, dismissed: [id(7)] });
  assert.equal(gone.json.total, 0);
  const pinned = await post('/api/search', { spec: { kinds: ['screenshot'] }, pinned: [id(1)] });
  assert.deepEqual(pinned.json.items.map((x: DeskItem) => x.id).sort(), [id(1), id(7)]);
  assert.equal((await post('/api/search', { spec: {}, pinned: 'x' })).status, 400);
});

test('an invalid spec is 400 naming the field', async () => {
  const r = await post('/api/search', { spec: { kinds: ['gif'], time: { from: 'yesterday' } } });
  assert.equal(r.status, 400);
  assert.equal(r.json.error, 'bad_spec');
  assert.match(r.json.message, /kinds/);
  assert.match(r.json.message, /time\.from/);
  const ask = await post('/api/ask', { sentence: 'x', spec: { limit: 0 }, layout: 'kind', history: [] });
  assert.equal(ask.status, 400);
  assert.match(ask.json.message, /limit/);
  assert.equal((await post('/api/ask', { sentence: 'x', spec: {}, layout: 'sideways', history: [] })).status, 400);
  assert.equal((await post('/api/ask', { sentence: '', spec: {}, layout: 'kind', history: [] })).status, 400);
});

test('/api/ask: one model call, then the search, with {count} filled in', async () => {
  let calls = 0;
  answer = async req => { calls++; return (await fakeProvider().complete(req)).value; };
  const r = await post('/api/ask', { sentence: 'show me the screenshots', spec: { kinds: ['link'] }, layout: 'kind', history: [] });
  assert.equal(r.status, 200, r.text);
  assert.equal(calls, 1);
  assert.deepEqual(r.json.spec.kinds, ['screenshot']);
  assert.equal(r.json.total, 1);
  assert.equal(r.json.reply, '1 found');
  assert.equal(r.json.layout, 'keep');
  assert.equal(r.json.items[0].id, id(7));
  const pinned = await post('/api/ask', { sentence: 'show me the screenshots', spec: {}, layout: 'kind', history: [], pinned: [id(2)],
    dismissed: [id(7)] });
  assert.deepEqual(pinned.json.items.map((x: DeskItem) => x.id), [id(2)]);
  assert.equal(pinned.json.reply, '1 found');
  assert.equal(pinned.json.spec.include_ids, undefined, 'pinned ids are added by the server, not put in the spec');
  useDefaultAnswers();
});

test('/api/ask failures are 502 {error, message} and never leak the token', async () => {
  answer = () => { throw new ProviderError('timeout', 'claude timed out after 60000 ms'); };
  const r = await post('/api/ask', { sentence: 'anything', spec: {}, layout: 'kind', history: [] });
  assert.equal(r.status, 502);
  assert.equal(r.json.error, 'timeout');
  assert.equal(typeof r.json.message, 'string');
  assert.deepEqual(Object.keys(r.json).sort(), ['error', 'message']);
  assert.ok(!r.text.includes(srv.token));
  answer = () => ({ spec: { kinds: ['spaceship'] }, layout: 'kind', reply: 'x' });
  const bad = await post('/api/ask', { sentence: 'anything', spec: {}, layout: 'kind', history: [] });
  assert.equal(bad.status, 502);
  assert.equal(bad.json.error, 'bad_output');
  answer = () => { throw new Error(`boom ${srv.token}`); };
  const other = await post('/api/ask', { sentence: 'anything', spec: {}, layout: 'kind', history: [] });
  assert.ok(other.status >= 500);
  assert.ok(!other.text.includes(srv.token));
  useDefaultAnswers();
});

test('/media: only what the index recorded; traversal and unknown refs are 404', async () => {
  for (const p of [`/media/${id(7)}/../../etc/passwd`, `/media/${id(7)}/nope`, `/media/${id(7)}/%2e%2e%2f%2e%2e%2fetc%2fpasswd`,
    `/media/${id(7)}/..%2f..%2f..%2fetc%2fpasswd`, `/media/../../etc/passwd`, `/media/${id(7)}`, `/media/${id(9)}/${att(7, 1)}`,
    `/media/${id(7)}/${att(7, 1)}/x`, `/media/${id(7)}/%E0%A4%A`]) {
    const r = await get(p);
    assert.equal(r.status, 404, p);
    assert.ok(!r.text.includes('root:'), p);
  }
  const png = await get(`/media/${id(7)}/${att(7, 1)}`);
  assert.equal(png.status, 200);
  assert.equal(png.headers['content-type'], 'image/png');
  assert.equal(png.headers['content-disposition'], undefined);
  const pdf = await get(`/media/${id(4)}/${att(4, 3)}`);
  assert.equal(pdf.headers['content-type'], 'application/pdf');
  const audio = await get(`/media/${id(7)}/${att(7, 2)}`);
  assert.equal(audio.headers['content-type'], 'audio/mp4');
});

test('/media: a manifest claiming text/html or image/svg+xml is sent as an octet-stream attachment', async () => {
  for (const [capture, a] of [[1, att(1, 1)], [3, att(3, 1)]] as const) {
    const r = await get(`/media/${id(capture)}/${a}`);
    assert.equal(r.status, 200);
    assert.equal(r.headers['content-type'], 'application/octet-stream');
    assert.match(String(r.headers['content-disposition']), /^attachment/);
    assert.equal(r.headers['content-security-policy'], "default-src 'none'; sandbox");
    assert.equal(r.headers['x-content-type-options'], 'nosniff');
  }
});

test('/media ranges: a-b, a-, -n; unsatisfiable or malformed is 416; several ranges get the whole file', async () => {
  const video = `/media/${id(5)}/${att(5, 1)}`;
  const whole = await get(video);
  assert.equal(whole.status, 200);
  assert.equal(whole.headers['content-type'], 'video/quicktime');
  assert.equal(whole.headers['accept-ranges'], 'bytes');
  const size = whole.body.length;
  assert.equal(size, 2357);
  const first = await get(video, { Range: 'bytes=0-99' });
  assert.equal(first.status, 206);
  assert.equal(first.body.length, 100);
  assert.equal(first.headers['content-range'], `bytes 0-99/${size}`);
  assert.deepEqual(first.body, whole.body.subarray(0, 100));
  const tail = await get(video, { Range: `bytes=${size - 7}-` });
  assert.equal(tail.status, 206);
  assert.deepEqual(tail.body, whole.body.subarray(size - 7));
  const last = await get(video, { Range: 'bytes=-10' });
  assert.equal(last.status, 206);
  assert.equal(last.headers['content-range'], `bytes ${size - 10}-${size - 1}/${size}`);
  const over = await get(video, { Range: 'bytes=100-999999' });
  assert.equal(over.status, 206);
  assert.equal(over.body.length, size - 100);
  for (const bad of [`bytes=${size}-`, 'bytes=50-10', 'bytes=-0', 'bytes=abc', 'items=0-5', 'bytes=-', 'bytes=1-2-3']) {
    const r = await get(video, { Range: bad });
    assert.equal(r.status, 416, bad);
    assert.equal(r.headers['content-range'], `bytes */${size}`, bad);
  }
  const multi = await get(video, { Range: 'bytes=0-1,5-6' });
  assert.equal(multi.status, 200);
  assert.equal(multi.body.length, size);
});

test('/api/capture/:id: the item and the detail with evidence, attachments, comments, paths and media URLs', async () => {
  const r = await get(`/api/capture/${id(7)}`);
  assert.equal(r.status, 200);
  assert.equal(r.json.item.id, id(7));
  assert.match(JSON.stringify(r.json.detail), /audio route was CarPlay/);
  const d = r.json.detail;
  assert.ok(d.attachments.every((a: { path: string }) => path.isAbsolute(a.path)));
  assert.ok(d.attachments.some((a: { url?: string }) => a.url === `/media/${id(7)}/${att(7, 1)}`));
  assert.equal(typeof d.method, 'string');
  const four = await get(`/api/capture/${id(4)}`);
  assert.ok(four.json.detail.comments.length >= 1);
  assert.ok(four.json.detail.comments.some((k: { audio?: string; audio_path?: string }) => k.audio?.startsWith('/media/') && k.audio_path));
  assert.equal((await get(`/api/capture/${id(9)}`)).status, 404);
  assert.equal((await get('/api/capture/00000000')).status, 404, 'no prefixes over HTTP');
});

test('/api/settings saves the five settings, refuses anything else, and never returns a key', async () => {
  const ok = await post('/api/settings', { mapTiles: false, askModel: 'sonnet' });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(loadConfig().mapTiles, false);
  assert.equal(loadConfig().askModel, 'sonnet');
  assert.equal(ok.json.settings.mapTiles, false);
  assert.equal((await get('/api/boot')).json.settings.mapTiles, false);
  const key = await post('/api/settings', { apiKey: 'x' });
  assert.equal(key.status, 400);
  assert.match(key.json.message, /apiKey/);
  for (const bad of [{ mapTiles: 'no' }, { provider: 'nobody' }, { theme: 'wood' }, { askModel: '' }, { askModel: 'a b' }, [], 'x'])
    assert.equal((await post('/api/settings', bad)).status, 400, JSON.stringify(bad));
  const proto = await post('/api/settings', '{"__proto__": {"polluted": true, "apiKey": "x"}, "theme": "desk"}');
  assert.equal(proto.status, 200, proto.text);
  assert.equal(({} as any).polluted, undefined);
  assert.equal((loadConfig() as any).apiKey, undefined);
  assert.equal(proto.json.settings.apiKey, undefined);
  const search = await post('/api/search', '{"spec": {"__proto__": {"kinds": ["file"]}}}');
  assert.equal(search.status, 200);
  assert.equal(search.json.total, 7);
  await post('/api/settings', { mapTiles: true, askModel: 'haiku' });
});

test('/media refuses a file that became a symlink out of the folder', async () => {
  const jpg = path.join(folder, 'captures/2026/11/07', id(4), 'content', `${att(4, 2)}.jpg`);
  assert.equal((await get(`/media/${id(4)}/${att(4, 2)}`)).status, 200);
  fs.rmSync(jpg);
  fs.symlinkSync(path.join(outside, 'secret.txt'), jpg);
  const r = await get(`/media/${id(4)}/${att(4, 2)}`);
  assert.equal(r.status, 404);
  assert.ok(!r.text.includes('not for the page'));
});

test('no log line holds the token', () => {
  assert.ok(logs.every(l => !l.includes(srv.token)), logs.join('\n'));
});

// ---- enrichment from the page ----

test('POST /api/enrich runs one pass in the background (409 while running); later searches see the new rows', async () => {
  const f2 = fixtureCopy();
  await buildIndex(f2);
  let release!: () => void;
  const gate = new Promise<void>(r => { release = r; });
  const s = await startServer({ folder: f2, port: 0, provider: fakeProvider(async req => { await gate; return fakeEnrichment(req); }), log: () => {} });
  try {
    const h = { Host: `127.0.0.1:${s.port}`, 'X-Hippo-Token': s.token };
    const json = { ...h, 'Content-Type': 'application/json' };
    const searchFake = async () => (await request(s.port, 'POST', '/api/search', json, JSON.stringify({ spec: { topics: ['fake'] } }))).json.total;
    assert.equal(await searchFake(), 0);
    assert.deepEqual((await request(s.port, 'GET', '/api/enrich', h)).json, { running: false, done: 0, total: 0 });
    const plan = (await request(s.port, 'POST', '/api/enrich', json, '{"dryRun":true}')).json;
    const start = JSON.stringify({ expect: { provider: plan.provider, model: plan.model, send: plan.send } });
    const started = await request(s.port, 'POST', '/api/enrich', json, start);
    assert.equal(started.status, 202);
    assert.equal((await request(s.port, 'POST', '/api/enrich', json, start)).status, 409);
    const mid = (await request(s.port, 'GET', '/api/enrich', h)).json;
    assert.equal(mid.running, true);
    release();
    let state: any;
    for (let i = 0; i < 200; i++) {
      state = (await request(s.port, 'GET', '/api/enrich', h)).json;
      if (!state.running) break;
      await new Promise(r => setTimeout(r, 25));
    }
    assert.equal(state.running, false);
    assert.equal(state.report.enrich.written, 5);
    assert.equal(state.report.index.updated, 5);
    assert.equal(state.done, state.total);
    assert.equal(await searchFake(), 5);
    const boot = (await request(s.port, 'GET', '/api/boot', h)).json;
    assert.equal(boot.status.enriched, 5);
    assert.ok(boot.status.lastEnrichAt);
  } finally { await s.close(); }
});

test('POST /api/enrich {dryRun: true} says what a pass would do, writes nothing and calls no model; same gate', async () => {
  const f4 = fixtureCopy();
  await buildIndex(f4);
  let calls = 0;
  const s = await startServer({ folder: f4, port: 0, log: () => {}, provider: fakeProvider(req => { calls++; return fakeEnrichment(req); }) });
  try {
    const h = { Host: `127.0.0.1:${s.port}`, 'X-Hippo-Token': s.token, 'Content-Type': 'application/json' };
    const before = snapshot(f4);
    const plan = await request(s.port, 'POST', '/api/enrich', h, JSON.stringify({ dryRun: true }));
    assert.equal(plan.status, 200);
    assert.deepEqual(plan.json, { dryRun: true, send: 5, write: 5, captures: 7, provider: 'fake', model: loadConfig().enrichModel, folder: path.resolve(f4) });
    assert.deepEqual(snapshot(f4), before);
    assert.equal(calls, 0);
    // It started nothing.
    assert.deepEqual((await request(s.port, 'GET', '/api/enrich', h)).json, { running: false, done: 0, total: 0 });
    // The same gate as every route: no token, a foreign Host or a foreign Origin is 403.
    for (const r of [
      await request(s.port, 'POST', '/api/enrich', { Host: h.Host, 'Content-Type': 'application/json' }, '{"dryRun":true}'),
      await request(s.port, 'POST', '/api/enrich', { ...h, Host: 'evil.example' }, '{"dryRun":true}'),
      await request(s.port, 'POST', '/api/enrich', { ...h, Origin: 'http://evil.example' }, '{"dryRun":true}'),
    ]) assert.equal(r.status, 403);
    assert.equal((await request(s.port, 'POST', '/api/enrich', h, '{"dryRun":"yes"}')).status, 400);
    assert.deepEqual(snapshot(f4), before);
    assert.equal(calls, 0);
  } finally { await s.close(); }
});

/** A server on a fresh, indexed fixture copy whose fake provider counts its calls. */
async function countingServer() {
  const f = fixtureCopy();
  await buildIndex(f);
  const counter = { calls: 0 };
  const s = await startServer({ folder: f, port: 0, log: () => {}, provider: fakeProvider(req => { counter.calls++; return fakeEnrichment(req); }) });
  const h = { Host: `127.0.0.1:${s.port}`, 'X-Hippo-Token': s.token, 'Content-Type': 'application/json' };
  const post = (body: unknown) => request(s.port, 'POST', '/api/enrich', h, typeof body === 'string' ? body : JSON.stringify(body));
  const plan = (await post({ dryRun: true })).json;
  const finish = async () => {
    for (let i = 0; i < 400; i++) {
      const st = (await request(s.port, 'GET', '/api/enrich', h)).json;
      if (!st.running) return st;
      await new Promise(r => setTimeout(r, 25));
    }
    throw new Error('the pass did not finish');
  };
  return { f, s, counter, post, plan, finish };
}

test('a start refused: the provider, the model or more to send than the question showed is 409 "changed" with the new plan', async () => {
  const { f, s, counter, post, plan } = await countingServer();
  try {
    assert.equal(plan.send, 5);
    const before = snapshot(f);
    for (const expect of [
      { provider: 'claude-cli', model: plan.model, send: 5 },          // provider changed since the question
      { provider: plan.provider, model: `${plan.model}-other`, send: 5 }, // model changed
      { provider: plan.provider, model: plan.model, send: 4 },          // a capture synced in since: more to send
      { provider: plan.provider, model: plan.model, send: 0 },          // the page saw nothing to send
    ]) {
      const r = await post({ expect });
      assert.equal(r.status, 409, JSON.stringify(expect));
      assert.equal(r.json.error, 'changed');
      assert.deepEqual(r.json.plan, plan);
      assert.equal(typeof r.json.message, 'string');
    }
    assert.equal(counter.calls, 0);
    assert.deepEqual(snapshot(f), before);
    assert.deepEqual((await request(s.port, 'GET', '/api/enrich', { Host: `127.0.0.1:${s.port}`, 'X-Hippo-Token': s.token })).json,
      { running: false, done: 0, total: 0 });
  } finally { await s.close(); }
});

test('a start without expect, or with a malformed one, is 400 and sends nothing', async () => {
  const { f, s, counter, post, plan } = await countingServer();
  try {
    const before = snapshot(f);
    const ok = { provider: plan.provider, model: plan.model, send: plan.send };
    for (const body of ['', '{}', { dryRun: false }, { expect: null }, { expect: [] }, { expect: 'yes' },
      { expect: { ...ok, provider: 3 } }, { expect: { ...ok, model: undefined } }, { expect: { ...ok, send: -1 } },
      { expect: { ...ok, send: 1.5 } }, { expect: { ...ok, send: '5' } }, { expect: { ...ok, send: 1e20 } }]) {
      const r = await post(body);
      assert.equal(r.status, 400, JSON.stringify(body));
    }
    assert.equal(counter.calls, 0);
    assert.deepEqual(snapshot(f), before);
  } finally { await s.close(); }
});

test('a start that matches the question, or finds fewer to send, runs', async () => {
  for (const extra of [0, 3]) {
    const { s, counter, post, plan, finish } = await countingServer();
    try {
      const r = await post({ expect: { provider: plan.provider, model: plan.model, send: plan.send + extra } });
      assert.equal(r.status, 202);
      const st = await finish();
      assert.equal(st.report.enrich.written, 5);
      assert.equal(counter.calls, 5);
    } finally { await s.close(); }
  }
});

test('close() cancels a running pass and waits for it', async () => {
  const f3 = fixtureCopy();
  await buildIndex(f3);
  let inFlight = 0, finished = 0;
  const s = await startServer({ folder: f3, port: 0, log: () => {}, provider: fakeProvider(async req => {
    inFlight++;
    await new Promise(r => setTimeout(r, 300));
    finished++;
    return fakeEnrichment(req);
  }) });
  const h = { Host: `127.0.0.1:${s.port}`, 'X-Hippo-Token': s.token, 'Content-Type': 'application/json' };
  const plan = (await request(s.port, 'POST', '/api/enrich', h, '{"dryRun":true}')).json;
  assert.equal((await request(s.port, 'POST', '/api/enrich', h,
    JSON.stringify({ expect: { provider: plan.provider, model: plan.model, send: plan.send } }))).status, 202);
  for (let i = 0; i < 100 && inFlight === 0; i++) await new Promise(r => setTimeout(r, 10));
  assert.ok(inFlight > 0);
  await s.close();
  assert.equal(finished, inFlight, 'close waited for the calls in flight');
  assert.ok(inFlight < 5, 'no new call started after close');
  const count = inFlight;
  await new Promise(r => setTimeout(r, 400));
  assert.equal(inFlight, count);
  await assert.rejects(request(s.port, 'GET', '/api/boot', h));
});

test('no desk page built yet: the server starts and / says how to build it', async () => {
  const s = await startServer({ folder, port: 0, provider: fakeProvider(), uiDir: path.join(outside, 'no-dist'), log: () => {} });
  try {
    const r = await request(s.port, 'GET', `/?t=${s.token}`, { Host: `127.0.0.1:${s.port}`, Accept: 'text/html' });
    assert.equal(r.status, 200);
    assert.match(r.text, /has not been built/);
    assert.match(r.text, /npm run build/);
    assert.ok(!r.text.includes(s.token));
    assert.equal((await request(s.port, 'GET', '/api/boot', { Host: `127.0.0.1:${s.port}`, Cookie: `hippo_t=${s.token}` })).status, 200);
  } finally { await s.close(); }
});

test('with devOrigin, that origin is allowed and its websocket is in connect-src', async () => {
  const s = await startServer({ folder, port: 0, provider: fakeProvider(), uiDir, devOrigin: 'http://localhost:5177', log: () => {} });
  try {
    const r = await request(s.port, 'GET', '/api/boot', { Host: `127.0.0.1:${s.port}`, 'X-Hippo-Token': s.token, Origin: 'http://localhost:5177' });
    assert.equal(r.status, 200);
    assert.match(String(r.headers['content-security-policy']), /connect-src 'self' ws:\/\/localhost:5177/);
    assert.equal((await request(s.port, 'GET', '/api/boot', { Host: `127.0.0.1:${s.port}`, 'X-Hippo-Token': s.token,
      Origin: 'http://localhost:5178' })).status, 403);
  } finally { await s.close(); }
});

test('with devOrigin, /api/boot authenticated by the header also sets the cookie, so proxied media requests carry it', async () => {
  const s = await startServer({ folder, port: 0, provider: fakeProvider(), uiDir, devOrigin: 'http://localhost:5177', log: () => {} });
  try {
    const h = { Host: `127.0.0.1:${s.port}` };
    const boot = await request(s.port, 'GET', '/api/boot', { ...h, 'X-Hippo-Token': s.token, Origin: 'http://localhost:5177' });
    assert.equal(boot.status, 200);
    assert.equal(String(boot.headers['set-cookie']), `hippo_t=${s.token}; HttpOnly; SameSite=Strict; Path=/`);
    // Only /api/boot, only by the header: a cookie-authenticated boot and other routes set nothing.
    const byCookie = await request(s.port, 'GET', '/api/boot', { ...h, Cookie: `hippo_t=${s.token}` });
    assert.equal(byCookie.status, 200);
    assert.equal(byCookie.headers['set-cookie'], undefined);
    const search = await request(s.port, 'POST', '/api/search', { ...h, 'X-Hippo-Token': s.token, 'Content-Type': 'application/json' }, '{}');
    assert.equal(search.status, 200);
    assert.equal(search.headers['set-cookie'], undefined);
    const thumb = (search.json.items as DeskItem[]).find(i => i.thumb)!.thumb!;
    const media = await request(s.port, 'GET', thumb, { ...h, Cookie: `hippo_t=${s.token}` });
    assert.equal(media.status, 200);
    assert.equal(media.headers['content-type'], 'image/jpeg');
  } finally { await s.close(); }
});

test('without devOrigin, /api/boot sets no cookie', async () => {
  const boot = await get('/api/boot');
  assert.equal(boot.status, 200);
  assert.equal(boot.headers['set-cookie'], undefined);
});

test('a taken port moves to the next free one', async () => {
  const blocker = net.createServer();
  await new Promise<void>(r => blocker.listen(0, '127.0.0.1', r));
  const taken = (blocker.address() as net.AddressInfo).port;
  const s = await startServer({ folder, port: taken, provider: fakeProvider(), uiDir, log: () => {} });
  try {
    assert.notEqual(s.port, taken);
    assert.ok(s.port > taken && s.port <= taken + 20);
  } finally { await s.close(); blocker.close(); }
});
