// The page's only way to the local server (plan Task B9's routes). Same-origin fetch with JSON bodies; any non-2xx answer
// becomes an Error carrying the server's message. The token, when the page has one, goes in the X-Hippo-Token header on every
// call: in dev the page comes from Vite and has no cookie, and the header also keeps two desks on different ports apart.
import type { DeskItem, CaptureDetail } from '../../src/server/wire.ts';
import type { EnrichPass, EnrichPlan } from '../../src/server/server.ts';
import type { Facets } from '../../src/recall/engine.ts';
import type { LayoutName, SearchSpec } from '../../src/recall/spec.ts';
import type { Status } from '../../src/index/build.ts';
import type { Config } from '../../src/core/paths.ts';

export type { DeskItem, CaptureDetail } from '../../src/server/wire.ts';
export type { EnrichPlan } from '../../src/server/server.ts';

export interface Settings { provider: string; askModel: string; enrichModel: string; mapTiles: boolean; theme: string }
export interface BootResponse { facets: Facets; status: Status; settings: Settings; today: string; timezone: string }
export interface Turn { sentence: string; reply: string }
export interface SearchRequest { spec: SearchSpec; pinned: string[]; dismissed: string[] }
export interface SearchResponse { total: number; items: DeskItem[] }
export interface AskRequest { sentence: string; spec: SearchSpec; layout: LayoutName; history: Turn[]; pinned: string[]; dismissed: string[] }
export interface AskResponse extends SearchResponse { spec: SearchSpec; layout: LayoutName | 'keep'; reply: string }
export interface CaptureResponse { item: DeskItem; detail: CaptureDetail }
export interface EnrichState { running: boolean; done: number; total: number; report?: EnrichPass }
export type SettingsPatch = Partial<Pick<Config, 'provider' | 'askModel' | 'enrichModel' | 'mapTiles' | 'theme'>>;

export interface Api {
  boot(): Promise<BootResponse>;
  search(req: SearchRequest): Promise<SearchResponse>;
  ask(req: AskRequest): Promise<AskResponse>;
  capture(id: string): Promise<CaptureResponse>;
  /** What an update pass would do (a dry run: nothing is written, no model is called). */
  enrichPlan(): Promise<EnrichPlan>;
  enrichStart(): Promise<EnrichState>;
  enrichStatus(): Promise<EnrichState>;
  settings(patch: SettingsPatch): Promise<{ settings: Settings }>;
}

export interface ApiOptions { token?: string; fetch?: typeof fetch }

const FORBIDDEN = 'The desk lost its key. Open it again from the link `hippo ui` prints.';
const UNREACHABLE = 'Cannot reach Hippo. Is `hippo ui` still running?';

function messageOf(status: number, body: unknown): string {
  if (typeof body === 'object' && body !== null && typeof (body as { message?: unknown }).message === 'string')
    return (body as { message: string }).message;
  return status === 403 ? FORBIDDEN : `Hippo answered ${status}.`;
}

export function createApi(opts: ApiOptions = {}): Api {
  const doFetch = opts.fetch ?? ((input: RequestInfo | URL, init?: RequestInit) => fetch(input, init));

  async function call<T>(method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (opts.token) headers['X-Hippo-Token'] = opts.token;
    if (method === 'POST') headers['Content-Type'] = 'application/json';
    let res: Response;
    try {
      res = await doFetch(path, { method, headers, credentials: 'same-origin', cache: 'no-store',
        ...(method === 'POST' ? { body: JSON.stringify(body ?? {}) } : {}) });
    } catch {
      throw new Error(UNREACHABLE);
    }
    const text = await res.text();
    let data: unknown;
    try { data = text ? JSON.parse(text) : undefined; } catch { data = undefined; }
    if (!res.ok) throw new Error(messageOf(res.status, data));
    return data as T;
  }

  return {
    boot: () => call('GET', '/api/boot'),
    search: req => call('POST', '/api/search', req),
    ask: req => call('POST', '/api/ask', req),
    capture: id => call('GET', `/api/capture/${encodeURIComponent(id)}`),
    enrichPlan: () => call('POST', '/api/enrich', { dryRun: true }),
    enrichStart: () => call('POST', '/api/enrich', {}),
    enrichStatus: () => call('GET', '/api/enrich'),
    settings: patch => call('POST', '/api/settings', patch),
  };
}
