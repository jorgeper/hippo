/// <reference types="vite/client" />
// The desk page's entry: boots, sets the stage with the theme the settings name, and puts the whole folder on the desk in
// the `kind` layout. Text from captures and the model only ever reaches the page as text (textContent or canvas fillText).
import { createApi } from './api.ts';
import { createStore } from './state.ts';
import type { DeskState } from './state.ts';
import { layouts } from './layout/index.ts';
import type { LayoutName } from '../../src/recall/spec.ts';
import { themes } from './themes/index.ts';
import { createStage } from './scene/stage.ts';
import type { Stage } from './scene/stage.ts';
import type { Theme } from './themes/types.ts';

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

const el = (id: string) => document.getElementById(id) as HTMLElement;
const plural = (n: number, one: string, many: string) => `${n.toLocaleString()} ${n === 1 ? one : many}`;

async function start(): Promise<void> {
  const api = createApi({ token: takeToken() });
  const count = el('count'), note = el('count-note'), reply = el('reply');
  try {
    const boot = await api.boot();
    const theme: Theme = await (themes[boot.settings.theme] ?? themes.desk)();
    const stage = createStage(el('stage') as HTMLCanvasElement, theme, { mapTiles: boot.settings.mapTiles });
    const store = createStore(api);
    let shown: { items: DeskState['items']; layout: LayoutName } | undefined;
    const arrange = (s: DeskState, force = false) => {
      if (!force && shown && shown.items === s.items && shown.layout === s.layout) return;
      shown = { items: s.items, layout: s.layout };
      stage.setItems(s.items, layouts[s.layout](s.items, stage.view(), theme.sizes));
    };
    store.subscribe(s => {
      count.textContent = s.items.length.toLocaleString();
      note.textContent = `${s.items.length === 1 ? 'capture' : 'captures'} on the desk, of ${plural(boot.status.total, 'capture', 'captures')}`;
      reply.textContent = s.reply;
      stage.setThinking(s.thinking);
      arrange(s);
    });
    stage.on('view', () => arrange(store.get(), true));
    temporaryKeys(stage, store);
    if (import.meta.env.DEV) (window as unknown as Record<string, unknown>).hippoDesk = { stage, store, layouts, theme };
    await store.refresh();
  } catch (e) {
    count.textContent = '–';
    note.textContent = e instanceof Error ? e.message : String(e);
  }
}

// TEMPORARY (Task C2, to see the layouts and motion before the controls exist): keys 1–5 switch the layout and `r` resets
// the view. The controls task replaces this with the layout buttons and the reset control.
function temporaryKeys(stage: Stage, store: ReturnType<typeof createStore>): void {
  const order: LayoutName[] = ['kind', 'time', 'place', 'topic', 'person'];
  window.addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey || e.altKey || (e.target as HTMLElement | null)?.closest?.('input, textarea')) return;
    const k = Number(e.key);
    if (k >= 1 && k <= order.length) store.setLayout(order[k - 1]);
    else if (e.key === 'r') stage.resetView();
  });
}

void start();
