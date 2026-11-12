// The desk page's entry. For now it boots, fills the store with the current spec, and shows how many captures are on the
// desk; the three.js desk arrives with the theme (Task C2). Text from captures and the model only ever goes in as text.
import { createApi } from './api.ts';
import { createStore } from './state.ts';

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
    const store = createStore(api);
    store.subscribe(s => {
      count.textContent = s.items.length.toLocaleString();
      note.textContent = `${s.items.length === 1 ? 'capture' : 'captures'} on the desk, of ${plural(boot.status.total, 'capture', 'captures')} in the index`;
      reply.textContent = s.reply;
    });
    await store.refresh();
  } catch (e) {
    count.textContent = '–';
    note.textContent = e instanceof Error ? e.message : String(e);
  }
}

void start();
