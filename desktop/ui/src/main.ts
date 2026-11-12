/// <reference types="vite/client" />
// The desk page's entry: boots, sets the stage with the theme the settings name, puts the controls over it (the count and
// tools, the layout buttons, the ask bar and reply line, the settings panel) and fills the desk with the whole folder in the
// `kind` layout. Text from captures and the model only ever reaches the page as text (textContent or canvas fillText).
import { createApi } from './api.ts';
import type { Api, BootResponse } from './api.ts';
import { createStore } from './state.ts';
import type { DeskState } from './state.ts';
import { layouts } from './layout/index.ts';
import type { LayoutName } from '../../src/recall/spec.ts';
import { themes } from './themes/index.ts';
import { createStage } from './scene/stage.ts';
import type { Theme } from './themes/types.ts';
import { mountAskBar } from './controls/askbar.ts';
import { mountLayoutBar } from './controls/layoutbar.ts';
import { mountToolbar } from './controls/toolbar.ts';
import { mountSettings } from './controls/settings.ts';

/** What browser tests read: the ids on the desk, the layout, and whether everything has come to rest. */
export interface DeskProbe { ids(): string[]; layout(): string; settled(): boolean }
declare global { interface Window { __desk?: DeskProbe } }

/** Quiet this long (no frame drawn, no request out, no question with the model) and the desk counts as settled. */
const SETTLED_MS = 250;

/** The per-run token from the opening URL, kept in memory and taken out of the address bar (the cookie is set by then). */
function takeToken(): string | undefined {
  const url = new URL(window.location.href);
  const token = url.searchParams.get('t') ?? undefined;
  if (token !== undefined) {
    url.searchParams.delete('t');
    window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
  }
  return token;
}

/** The api, counting the requests that are out (for `settled`). */
function counted(api: Api): { api: Api; inFlight(): number } {
  let out = 0;
  const wrap = <A extends unknown[], R>(fn: (...a: A) => Promise<R>) => async (...a: A): Promise<R> => {
    out++;
    try { return await fn(...a); } finally { out--; }
  };
  const wrapped = Object.fromEntries(Object.entries(api).map(([k, fn]) => [k, wrap(fn as (...a: unknown[]) => Promise<unknown>)])) as unknown as Api;
  return { api: wrapped, inFlight: () => out };
}

const el = (id: string) => document.getElementById(id) as HTMLElement;

async function start(): Promise<void> {
  const { api, inFlight } = counted(createApi({ token: takeToken() }));
  const reply = el('reply');
  let boot: BootResponse;
  let theme: Theme;
  try {
    boot = await api.boot();
    theme = await (themes[boot.settings.theme] ?? themes.desk)();
  } catch (e) {
    reply.textContent = e instanceof Error ? e.message : String(e);
    return;
  }
  for (const [name, value] of Object.entries(theme.chrome)) document.documentElement.style.setProperty(name, value);

  const stage = createStage(el('stage') as HTMLCanvasElement, theme, { mapTiles: boot.settings.mapTiles });
  const store = createStore(api);
  let ready = false;
  let lastChange = performance.now();
  let shown: { items: DeskState['items']; layout: LayoutName } | undefined;
  const arrange = (s: DeskState, force = false) => {
    if (!force && shown && shown.items === s.items && shown.layout === s.layout) return;
    shown = { items: s.items, layout: s.layout };
    lastChange = performance.now();
    stage.setItems(s.items, layouts[s.layout](s.items, stage.view(), theme.sizes));
  };

  const toolbar = mountToolbar(el('count'), el('tools'), el('progress'), {
    store, api,
    resetView: () => stage.resetView(),
    ready: () => ready,
    afterUpdate: async () => {
      boot = await api.boot();
      await store.refresh();
    },
  });
  mountLayoutBar(el('layouts'), store);
  const ask = mountAskBar(el('ask'), reply, store);
  mountSettings(el('settings'), toolbar.settingsButton, boot.settings, {
    api,
    themes: Object.keys(themes),
    saved: (now, before) => {
      boot = { ...boot, settings: now };
      if (now.mapTiles !== before.mapTiles) {
        stage.setMapTiles(now.mapTiles);
        arrange(store.get(), true);
      }
    },
  });

  store.subscribe(s => {
    stage.setThinking(s.thinking);
    arrange(s);
  });
  stage.on('view', () => arrange(store.get(), true));
  stage.on('frame', () => { lastChange = performance.now(); });

  window.__desk = {
    ids: () => store.get().items.map(i => i.id),
    layout: () => store.get().layout,
    settled: () => ready && !store.get().thinking && inFlight() === 0 && performance.now() - lastChange > SETTLED_MS,
  };
  if (import.meta.env.DEV) (window as unknown as Record<string, unknown>).hippoDesk = { stage, store, layouts, theme };

  ask.focus();
  await store.refresh();
  ready = true;
  toolbar.render(store.get());
}

void start();
