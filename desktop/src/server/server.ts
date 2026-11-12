// The local HTTP server behind `hippo ui` (spec section 7, "The local server"; plan Task B9). The desk page talks only to it.
// It binds 127.0.0.1, and every request must carry the per-run token and come with this server's own Host (and Origin, when
// sent): any web page can send requests to localhost. Media is served only from paths the index recorded. node:http only.
import http from 'node:http';
import type net from 'node:net';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { loadConfig, saveConfig, thumbsDir } from '../core/paths.ts';
import type { Config } from '../core/paths.ts';
import { enrichFolder } from '../enrich/enrich.ts';
import type { EnrichReport } from '../enrich/enrich.ts';
import { buildIndex, markEnriched, status } from '../index/build.ts';
import type { IndexReport } from '../index/build.ts';
import { openIndex } from '../index/db.ts';
import { makeProvider, providerNames } from '../providers/index.ts';
import { ProviderError } from '../providers/types.ts';
import type { Provider } from '../providers/types.ts';
import { ask, LAYOUTS, localToday } from '../recall/ask.ts';
import type { AskInput } from '../recall/ask.ts';
import { facets, mediaOf, search } from '../recall/engine.ts';
import type { CaptureRecord } from '../core/record.ts';
import { validateSpec } from '../recall/spec.ts';
import type { LayoutName, SearchSpec } from '../recall/spec.ts';
import { inside, openInside, serveMedia, streamFile } from './media.ts';
import { toDeskItem, toDetail } from './wire.ts';
import type { DeskItem, WireMedia } from './wire.ts';

export type { DeskItem } from './wire.ts';

export const DEFAULT_PORT = 4477;
export const MAX_BODY = 1024 * 1024;
/** The one external image host the page may load from: OpenStreetMap's raster tiles (spec section 8, "By place"). */
export const MAP_TILE_ORIGIN = 'https://tile.openstreetmap.org';
const PORT_TRIES = 20;
const THEMES = ['desk'];
const SETTINGS = ['provider', 'askModel', 'enrichModel', 'mapTiles', 'theme'] as const;
const MODEL_NAME = /^[A-Za-z0-9][A-Za-z0-9._:/@[\]-]{0,99}$/;
const MAX_IDS = 5000;
const MAX_SENTENCE = 2000;
const MAX_HISTORY = 100;

export interface ServerOptions { folder: string; port?: number; provider: Provider; uiDir?: string; devOrigin?: string;
  /** Where the server's few log lines go (default stderr). The token is never in one. */
  log?: (line: string) => void }
export interface RunningServer { url: string; port: number; token: string; close(): Promise<void> }
export interface EnrichPass { enrich?: EnrichReport; index?: IndexReport; error?: string }
type Settings = Pick<Config, 'provider' | 'askModel' | 'enrichModel' | 'mapTiles' | 'theme'>;

class HttpError extends Error {
  status: number; code: string;
  constructor(status: number, code: string, message: string) { super(message); this.status = status; this.code = code; }
}

function isObject(v: unknown): v is Record<string, unknown> { return typeof v === 'object' && v !== null && !Array.isArray(v); }
const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** Constant-time comparison of two tokens of any length. */
function sameToken(given: string, token: string): boolean {
  const h = (s: string) => crypto.createHash('sha256').update(s).digest();
  return crypto.timingSafeEqual(h(given), h(token)) && given.length === token.length;
}

function cookieValues(header: string | undefined, name: string): string[] {
  if (!header) return [];
  return header.split(';').map(p => p.trim()).filter(p => p.startsWith(`${name}=`)).map(p => p.slice(name.length + 1));
}

const UI_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.map': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.woff2': 'font/woff2',
  '.wasm': 'application/wasm', '.glb': 'model/gltf-binary', '.hdr': 'image/vnd.radiance', '.ktx2': 'image/ktx2',
};

const NOT_BUILT = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Hippo Desk</title></head>
<body style="font: 16px/1.5 system-ui, sans-serif; margin: 3em auto; max-width: 36em; padding: 0 1em">
<h1>Hippo Desk</h1>
<p>The desk page has not been built yet. In <code>desktop/</code>, run <code>npm run build</code>, then reload this page.</p>
<p>The server is running, and its API answers as usual.</p>
</body></html>
`;

/** Bodies are parsed without ever giving `__proto__` a meaning: such keys are dropped. */
const parseJson = (text: string): unknown => JSON.parse(text, (k, v) => (k === '__proto__' ? undefined : v));

async function readBody(req: http.IncomingMessage): Promise<unknown> {
  const type = (req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
  if (type !== 'application/json') { req.resume(); throw new HttpError(415, 'unsupported_media_type', 'POST bodies must be application/json'); }
  const chunks: Buffer[] = [];
  let size = 0, tooBig = false;
  // Read to the end even when too big (discarding), so the client always gets the 413 instead of a reset connection.
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY) { tooBig = true; chunks.length = 0; continue; }
    chunks.push(chunk as Buffer);
  }
  if (tooBig) throw new HttpError(413, 'too_large', `request bodies are limited to ${MAX_BODY} bytes`);
  const text = Buffer.concat(chunks).toString('utf8');
  if (text.trim() === '') return undefined;
  try { return parseJson(text); } catch { throw new HttpError(400, 'bad_json', 'the body is not valid JSON'); }
}

function bodyObject(v: unknown): Record<string, unknown> {
  if (v === undefined) return {};
  if (!isObject(v)) throw new HttpError(400, 'bad_request', 'expected a JSON object');
  return v;
}

function specFrom(v: unknown): SearchSpec {
  const checked = validateSpec(v ?? {});
  if (!checked.ok) throw new HttpError(400, 'bad_spec', checked.errors.join('; '));
  return checked.spec;
}

function idList(v: unknown, field: string): string[] {
  if (v === undefined) return [];
  if (!Array.isArray(v) || v.length > MAX_IDS || !v.every(x => typeof x === 'string' && x.length <= 64))
    throw new HttpError(400, 'bad_request', `${field}: expected a list of capture ids`);
  return v as string[];
}

function settingsOf(c: Config, provider: Provider): Settings {
  return { provider: provider.name, askModel: c.askModel, enrichModel: c.enrichModel, mapTiles: c.mapTiles, theme: c.theme };
}

async function listen(server: http.Server, port: number): Promise<number> {
  const tries = port === 0 ? 1 : PORT_TRIES;
  for (let i = 0; i < tries && port + i <= 65535; i++) {
    try {
      await new Promise<void>((resolve, reject) => {
        const onError = (e: Error) => { server.off('listening', onListening); reject(e); };
        const onListening = () => { server.off('error', onError); resolve(); };
        server.once('error', onError);
        server.once('listening', onListening);
        server.listen(port + i, '127.0.0.1');
      });
      return (server.address() as net.AddressInfo).port;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EADDRINUSE' || i === tries - 1) throw e;
    }
  }
  throw new Error(`no free port from ${port}`);
}

export async function startServer(opts: ServerOptions): Promise<RunningServer> {
  const folder = path.resolve(opts.folder);
  const thumbs = thumbsDir();
  const uiDir = opts.uiDir === undefined ? undefined : path.resolve(opts.uiDir);
  const devOrigin = opts.devOrigin === undefined ? undefined : new URL(opts.devOrigin).origin;
  const log = opts.log ?? ((line: string) => { process.stderr.write(`${line}\n`); });
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  const token = crypto.randomBytes(32).toString('hex');
  const scrub = (s: string) => s.split(token).join('…');
  let provider = opts.provider;
  let port = 0;

  const connect = ["'self'", ...(devOrigin ? [devOrigin.replace(/^http/, 'ws')] : [])].join(' ');
  const pageCsp = `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: ${MAP_TILE_ORIGIN}; `
    + `connect-src ${connect}; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`;

  // One connection for the server's lifetime: the engine registers its SQL functions once per connection, and later index runs
  // (by the enrich pass, or `hippo index` elsewhere) commit through their own connections, which this one then reads.
  const db = openIndex(folder);

  const pass: { running: boolean; done: number; total: number; report?: EnrichPass; promise?: Promise<void>; abort?: AbortController } =
    { running: false, done: 0, total: 0 };
  let closing: Promise<void> | undefined;

  // ---- responses ----

  const json = (res: http.ServerResponse, code: number, value: unknown) => {
    const body = JSON.stringify(value);
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': String(Buffer.byteLength(body)),
      'Cache-Control': 'no-store' });
    res.end(body);
  };
  const empty = (req: http.IncomingMessage, res: http.ServerResponse, code: number, extra: Record<string, string> = {}) => {
    req.resume();
    res.writeHead(code, { 'Content-Length': '0', ...extra });
    res.end();
  };

  const mediaFor = (ids: string[]): Map<string, WireMedia[]> => {
    const out = new Map<string, WireMedia[]>();
    if (!ids.length) return out;
    for (const row of db.raw.prepare('SELECT capture_id, ref, mime FROM media WHERE capture_id IN (SELECT value FROM json_each(?)) ORDER BY ref')
      .all(JSON.stringify(ids)) as { capture_id: string; ref: string; mime: string }[]) {
      let list = out.get(row.capture_id);
      if (!list) out.set(row.capture_id, list = []);
      list.push({ ref: row.ref, mime: row.mime });
    }
    return out;
  };

  /** The spec, with the pinned ids added to include_ids and the dismissed ones to exclude_ids. */
  const runSearch = (spec: SearchSpec, pinned: string[], dismissed: string[]): { total: number; items: DeskItem[] } => {
    const s: SearchSpec = { ...spec };
    if (pinned.length) s.include_ids = [...(spec.include_ids ?? []), ...pinned];
    if (dismissed.length) s.exclude_ids = [...(spec.exclude_ids ?? []), ...dismissed];
    const result = search(db, s);
    const media = mediaFor(result.items.map(r => r.id));
    return { total: result.total, items: result.items.map(r => toDeskItem(r, media.get(r.id) ?? [])) };
  };

  // ---- handlers ----

  const boot = (res: http.ServerResponse) => {
    const c = loadConfig();
    json(res, 200, { facets: facets(db), status: status(folder), settings: settingsOf(c, provider),
      today: localToday(new Date(), timezone).date, timezone });
  };

  const searchRoute = async (req: http.IncomingMessage, res: http.ServerResponse) => {
    const body = bodyObject(await readBody(req));
    json(res, 200, runSearch(specFrom(body.spec), idList(body.pinned, 'pinned'), idList(body.dismissed, 'dismissed')));
  };

  const askRoute = async (req: http.IncomingMessage, res: http.ServerResponse) => {
    const body = bodyObject(await readBody(req));
    const sentence = typeof body.sentence === 'string' ? body.sentence.trim() : '';
    if (sentence === '' || sentence.length > MAX_SENTENCE) throw new HttpError(400, 'bad_request', `sentence: expected 1 to ${MAX_SENTENCE} characters`);
    const spec = specFrom(body.spec);
    const layout = body.layout === undefined ? 'kind' : body.layout;
    if (typeof layout !== 'string' || !(LAYOUTS as string[]).includes(layout))
      throw new HttpError(400, 'bad_request', `layout: expected one of ${LAYOUTS.join(', ')}`);
    const h = body.history === undefined ? [] : body.history;
    if (!Array.isArray(h) || h.length > MAX_HISTORY || !h.every(t => isObject(t) && typeof t.sentence === 'string' && typeof t.reply === 'string'))
      throw new HttpError(400, 'bad_request', 'history: expected a list of {sentence, reply}');
    const history: AskInput['history'] = h.map(t => ({ sentence: String(t.sentence).slice(0, MAX_SENTENCE), reply: String(t.reply).slice(0, 500) }));
    const pinned = idList(body.pinned, 'pinned'), dismissed = idList(body.dismissed, 'dismissed');

    let out;
    const started = Date.now();
    try {
      out = await ask(provider, loadConfig().askModel, facets(db), { sentence, spec, layout: layout as LayoutName, history, now: new Date(), timezone });
    } catch (e) {
      const code = e instanceof ProviderError ? e.code : 'failed';
      log(`ask failed after ${Date.now() - started} ms: ${code}`);
      json(res, 502, { error: code, message: e instanceof ProviderError ? scrub(e.message) : 'the model call failed' });
      return;
    }
    const result = runSearch(out.spec, pinned, dismissed);
    json(res, 200, { spec: out.spec, layout: out.layout, reply: out.reply.split('{count}').join(String(result.total)), ...result });
  };

  const captureRoute = (res: http.ServerResponse, id: string) => {
    const row = db.raw.prepare('SELECT record FROM captures WHERE id = ?').get(id.toLowerCase()) as { record: string } | undefined;
    if (!row) throw new HttpError(404, 'not_found', 'no capture with that id');
    const r = JSON.parse(row.record) as CaptureRecord;
    const media = mediaOf(db, r.id);
    json(res, 200, { item: toDeskItem(r, media), detail: toDetail(r, media) });
  };

  const mediaRoute = (req: http.IncomingMessage, res: http.ServerResponse, id: string, ref: string) => {
    const row = db.raw.prepare('SELECT path, mime FROM media WHERE capture_id = ? AND ref = ?').get(id, ref) as { path: string; mime: string } | undefined;
    // The media table is the only source of servable paths; the request only names a row of it.
    if (!row || !serveMedia(req, res, row.path, row.mime, [folder, thumbs])) throw new HttpError(404, 'not_found', 'no such file');
  };

  const startPass = (res: http.ServerResponse) => {
    if (closing) throw new HttpError(503, 'closing', 'the server is stopping');
    if (pass.running) throw new HttpError(409, 'running', 'an update is already running');
    const c = loadConfig();
    const abort = new AbortController();
    const p = provider;
    pass.running = true; pass.done = 0; pass.total = 0; pass.report = undefined; pass.abort = abort;
    log('update started');
    pass.promise = (async () => {
      const report: EnrichPass = {};
      try {
        report.enrich = await enrichFolder({ folder, provider: p, model: c.enrichModel, concurrency: c.concurrency, signal: abort.signal,
          onProgress: e => { pass.done = e.done; pass.total = e.total; } });
        // As `hippo enrich` does: the index step runs even after a stop, so the desk shows what was written.
        markEnriched(folder);
        report.index = await buildIndex(folder);
      } catch (e) {
        report.error = scrub(errorText(e));
      }
      const e = report.enrich;
      log(report.error ? `update failed: ${report.error}`
        : `update finished: ${e?.written ?? 0} written, ${e?.failed.length ?? 0} failed${e?.stoppedBy ? `, stopped (${e.stoppedBy})` : ''}`);
      pass.report = report;
      pass.running = false;
    })();
    json(res, 202, { running: true, done: 0, total: 0 });
  };

  const passState = (res: http.ServerResponse) =>
    json(res, 200, { running: pass.running, done: pass.done, total: pass.total, ...(pass.report ? { report: pass.report } : {}) });

  const settingsRoute = async (req: http.IncomingMessage, res: http.ServerResponse) => {
    const body = await readBody(req);
    if (!isObject(body)) throw new HttpError(400, 'bad_settings', 'expected a JSON object of settings');
    const bad = (m: string) => new HttpError(400, 'bad_settings', m);
    for (const k of Object.keys(body))
      if (!(SETTINGS as readonly string[]).includes(k)) throw bad(`unknown setting ${JSON.stringify(k.slice(0, 40))} (accepted: ${SETTINGS.join(', ')})`);
    const next: Config = { ...loadConfig() };
    if (body.provider !== undefined) {
      if (typeof body.provider !== 'string' || !providerNames.includes(body.provider)) throw bad(`provider: expected one of ${providerNames.join(', ')}`);
      next.provider = body.provider;
    }
    for (const k of ['askModel', 'enrichModel'] as const) {
      const v = body[k];
      if (v === undefined) continue;
      if (typeof v !== 'string' || !MODEL_NAME.test(v)) throw bad(`${k}: expected a model name`);
      next[k] = v;
    }
    if (body.mapTiles !== undefined) {
      if (typeof body.mapTiles !== 'boolean') throw bad('mapTiles: expected true or false');
      next.mapTiles = body.mapTiles;
    }
    if (body.theme !== undefined) {
      if (typeof body.theme !== 'string' || !THEMES.includes(body.theme)) throw bad(`theme: expected one of ${THEMES.join(', ')}`);
      next.theme = body.theme;
    }
    saveConfig(next);
    if (body.provider !== undefined && body.provider !== provider.name) provider = makeProvider(next.provider);
    json(res, 200, { settings: settingsOf(next, provider) });
  };

  const sendUiFile = (req: http.IncomingMessage, res: http.ServerResponse, f: { fd: number; size: number; real: string }) =>
    streamFile(req, res, f, { 'Content-Type': UI_TYPES[path.extname(f.real).toLowerCase()] ?? 'application/octet-stream', 'Cache-Control': 'no-cache' }, false);

  const page = (req: http.IncomingMessage, res: http.ServerResponse, pathname: string) => {
    const acceptsHtml = /\btext\/html\b/i.test(String(req.headers.accept ?? ''));
    const index = uiDir === undefined ? undefined : openInside(path.join(uiDir, 'index.html'), [uiDir]);
    if (!index) {
      if (pathname !== '/' && !acceptsHtml) throw new HttpError(404, 'not_found', 'no such file');
      const body = Buffer.from(NOT_BUILT);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': String(body.length), 'Cache-Control': 'no-cache' });
      res.end(body);
      return;
    }
    if (pathname !== '/') {
      let segments: string[] | undefined;
      try { segments = pathname.slice(1).split('/').map(decodeURIComponent); } catch { segments = undefined; }
      const ok = segments?.every(s => s !== '' && s !== '.' && s !== '..' && !/[\\/\0]/.test(s));
      // uiDir files only from inside uiDir (real paths: a symlink out of it is not served).
      const f = ok ? openInside(path.join(uiDir!, ...segments!), [uiDir!]) : undefined;
      if (f) { fs.closeSync(index.fd); sendUiFile(req, res, f); return; }
      if (!acceptsHtml) { fs.closeSync(index.fd); throw new HttpError(404, 'not_found', 'no such file'); }
    }
    sendUiFile(req, res, index);
  };

  // ---- the gate and the routes ----

  const allowedHost = (host: string | undefined) => {
    const h = (host ?? '').toLowerCase();
    return h === `127.0.0.1:${port}` || h === `localhost:${port}`;
  };

  const handle = async (req: http.IncomingMessage, res: http.ServerResponse) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    res.setHeader('Content-Security-Policy', pageCsp);
    const forbid = () => empty(req, res, 403);

    const host = req.headers.host;
    if (!allowedHost(host)) return forbid();
    const origin = req.headers.origin;
    if (origin !== undefined && origin !== `http://${host!.toLowerCase()}` && origin !== devOrigin) return forbid();
    let url: URL;
    try { url = new URL(req.url ?? '/', 'http://127.0.0.1'); } catch { return forbid(); }
    const pathname = url.pathname;

    const header = req.headers['x-hippo-token'];
    const fromQuery = req.method === 'GET' && pathname === '/' ? url.searchParams.get('t') : null;
    const candidates = [...(typeof header === 'string' ? [header] : []), ...cookieValues(req.headers.cookie, 'hippo_t'),
      ...(fromQuery !== null ? [fromQuery] : [])];
    if (!candidates.some(t => sameToken(t, token))) return forbid();
    if (fromQuery !== null && sameToken(fromQuery, token)) res.setHeader('Set-Cookie', `hippo_t=${token}; HttpOnly; SameSite=Strict; Path=/`);

    const method = req.method ?? '';
    if (method !== 'GET' && method !== 'POST') return empty(req, res, 405, { Allow: 'GET, POST' });
    const only = (allowed: string) => {
      if (method === allowed) return;
      res.setHeader('Allow', allowed);
      throw new HttpError(405, 'method_not_allowed', `use ${allowed}`);
    };

    try {
      if (pathname.startsWith('/api/')) {
        const capture = /^\/api\/capture\/([^/]+)$/.exec(pathname);
        if (pathname === '/api/boot') { only('GET'); boot(res); }
        else if (pathname === '/api/search') { only('POST'); await searchRoute(req, res); }
        else if (pathname === '/api/ask') { only('POST'); await askRoute(req, res); }
        else if (pathname === '/api/settings') { only('POST'); await settingsRoute(req, res); }
        else if (pathname === '/api/enrich') {
          if (method === 'POST') { await readBody(req); startPass(res); } else passState(res);
        }
        else if (capture) {
          only('GET');
          let id: string;
          try { id = decodeURIComponent(capture[1]); } catch { throw new HttpError(404, 'not_found', 'no capture with that id'); }
          captureRoute(res, id);
        }
        else throw new HttpError(404, 'not_found', 'no such route');
      } else if (pathname === '/media' || pathname.startsWith('/media/')) {
        const parts = pathname.split('/');
        let id: string | undefined, ref: string | undefined;
        try { if (parts.length === 4) { id = decodeURIComponent(parts[2]); ref = decodeURIComponent(parts[3]); } } catch { /* 404 below */ }
        if (id === undefined || ref === undefined) throw new HttpError(404, 'not_found', 'no such file');
        only('GET');
        mediaRoute(req, res, id, ref);
      } else {
        if (method !== 'GET') throw new HttpError(404, 'not_found', 'no such route');
        page(req, res, pathname);
      }
    } catch (e) {
      if (res.headersSent) { res.destroy(); return; }
      req.resume();
      if (e instanceof HttpError) {
        json(res, e.status, { error: e.code, message: scrub(e.message) });
      } else {
        log(`request failed: ${method} ${pathname}: ${scrub(errorText(e))}`);
        json(res, 500, { error: 'internal', message: 'internal error' });
      }
    }
  };

  // A request without Host reaches the gate (and gets its 403) instead of Node's own 400.
  const server = http.createServer({ requireHostHeader: false }, (req, res) => {
    handle(req, res).catch(() => { if (!res.headersSent) { res.writeHead(500); res.end(); } else res.destroy(); });
  });
  try { port = await listen(server, opts.port ?? DEFAULT_PORT); }
  catch (e) { db.close(); throw e; }

  const close = () => closing ??= (async () => {
    // Cancel a running pass (no new model call or write starts) and wait for it, index step included.
    pass.abort?.abort();
    await pass.promise;
    await new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); });
    db.close();
  })();

  return { url: `http://127.0.0.1:${port}/?t=${token}`, port, token, close };
}
