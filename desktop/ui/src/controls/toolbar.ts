// The top left: what is on the desk ("83 on the desk · 4 set aside") and the small tools beside it: undo, reset view,
// update and settings (spec section 8, "Controls"). Update starts an enrich pass on the server (POST /api/enrich), shows
// its progress from GET /api/enrich once a second, and when the pass ends has the page boot again (fresh facets) and run
// the current spec again, so what the pass wrote shows on the desk.
import type { Api, EnrichState } from '../api.ts';
import type { DeskState, Store } from '../state.ts';
import { el, icon } from './dom.ts';

export const POLL_MS = 1000;
/** How long the line saying how an update went stays up. */
const DONE_LINE_MS = 8000;

export interface ToolbarDeps {
  store: Store;
  api: Pick<Api, 'enrichStart' | 'enrichStatus'>;
  resetView(): void;
  /** After an update pass: boot again and refill the desk. */
  afterUpdate(): Promise<void>;
  /** False until the desk's first fill has landed: the count shows nothing before then. */
  ready(): boolean;
}

export interface Toolbar { settingsButton: HTMLButtonElement; render(s: DeskState): void }

const n = (v: number) => v.toLocaleString();

/** The count line's parts: the number on the desk (and found, when the result was cut), and how many are set aside. */
export function countText(s: Pick<DeskState, 'items' | 'total' | 'dismissed'>): { main: string; aside: string } {
  const on = s.items.length;
  const main = s.total > on ? `${n(on)} of ${n(s.total)} on the desk` : `${n(on)} on the desk`;
  return { main, aside: s.dismissed.length ? `${n(s.dismissed.length)} set aside` : '' };
}

/** One line on how an update pass went. */
export function updateLine(st: EnrichState): { text: string; failed: boolean } {
  const r = st.report;
  if (!r) return { text: 'Update finished', failed: false };
  if (r.error) return { text: `Update failed: ${r.error}`, failed: true };
  const e = r.enrich;
  if (e?.stoppedBy) return { text: `Update stopped: ${e.stopReason ?? e.stoppedBy}`, failed: true };
  const written = e?.written ?? 0, failed = e?.failed.length ?? 0;
  const parts = [written ? `${n(written)} ${written === 1 ? 'capture' : 'captures'} updated` : 'Nothing new to update'];
  if (failed) parts.push(`${n(failed)} failed`);
  return { text: parts.join(', '), failed: failed > 0 };
}

export function mountToolbar(count: HTMLElement, tools: HTMLElement, progress: HTMLElement, deps: ToolbarDeps): Toolbar {
  const { store, api } = deps;
  const tool = (testid: string, label: string, ...paths: string[]) => {
    const b = el('button', { class: 'tool', attrs: { type: 'button', 'data-testid': testid, 'aria-label': label, title: label } }, icon(...paths));
    tools.append(b);
    return b;
  };
  const undo = tool('undo', 'Undo: back to the previous question', 'M9 14 4 9l5-5', 'M4 9h10.5a5.5 5.5 0 0 1 0 11H11');
  const reset = tool('reset-view', 'Reset view', 'M3 8V5a2 2 0 0 1 2-2h3', 'M16 3h3a2 2 0 0 1 2 2v3', 'M21 16v3a2 2 0 0 1-2 2h-3', 'M8 21H5a2 2 0 0 1-2-2v-3');
  const update = tool('update', 'Update: read new captures', 'M20.5 12a8.5 8.5 0 1 1-2.5-6', 'M20.5 3.5V9H15');
  const settings = tool('settings', 'Settings', 'M4 7h9', 'M17 7h3', 'M15 5a2 2 0 1 0 0 4a2 2 0 1 0 0-4', 'M4 17h3', 'M11 17h9',
    'M9 15a2 2 0 1 0 0 4a2 2 0 1 0 0-4');
  settings.setAttribute('aria-haspopup', 'dialog');
  settings.setAttribute('aria-expanded', 'false');

  undo.addEventListener('click', () => store.undo());
  reset.addEventListener('click', () => deps.resetView());

  // ---------------------------------------------------------------- update

  let running = false, clearTimer: ReturnType<typeof setTimeout> | undefined;
  const say = (text: string, failed = false) => {
    clearTimeout(clearTimer);
    progress.textContent = text;
    progress.classList.toggle('failed', failed);
    progress.title = text;
  };
  const sayProgress = (st: EnrichState) => say(st.total ? `Updating ${n(st.done)} of ${n(st.total)}` : 'Updating…');

  async function poll(): Promise<void> {
    for (;;) {
      await new Promise(r => setTimeout(r, POLL_MS));
      let st: EnrichState;
      try { st = await api.enrichStatus(); }
      catch (e) { say(e instanceof Error ? e.message : String(e), true); return; }
      if (st.running) { sayProgress(st); continue; }
      const line = updateLine(st);
      say(line.text, line.failed);
      try { await deps.afterUpdate(); }
      catch (e) { say(e instanceof Error ? e.message : String(e), true); return; }
      if (!line.failed) clearTimer = setTimeout(() => say(''), DONE_LINE_MS);
      return;
    }
  }

  update.addEventListener('click', async () => {
    if (running) return;
    running = true;
    update.disabled = true;
    update.classList.add('busy');
    say('Updating…');
    try {
      try { sayProgress(await api.enrichStart()); }
      catch (e) {
        // One already running (started elsewhere) is followed like our own.
        const msg = e instanceof Error ? e.message : String(e);
        if (!/already running/i.test(msg)) { say(msg, true); return; }
      }
      await poll();
    } finally {
      running = false;
      update.disabled = false;
      update.classList.remove('busy');
    }
  });

  // ---------------------------------------------------------------- the count

  const render = (s: DeskState) => {
    undo.disabled = !store.canUndo();
    if (!deps.ready()) { count.textContent = ''; return; }
    const { main, aside } = countText(s);
    const parts: Node[] = [el('b', { text: main.replace(/ on the desk$/, '') }), document.createTextNode(' on the desk')];
    if (aside) parts.push(el('span', { class: 'aside', text: ` · ${aside}` }));
    count.replaceChildren(...parts);
  };
  store.subscribe(render);
  render(store.get());

  return { settingsButton: settings, render };
}
