// The top left: what is on the desk ("83 on the desk · 4 set aside") and the small tools beside it: undo, reset view,
// update and settings (spec section 8, "Controls"). Update first asks the server what a pass would do (POST /api/enrich
// with dryRun: nothing written, no model called). When the pass would send captures to the model, the page asks the person
// first, with the numbers; otherwise, or on "Send and update", it starts the pass (POST /api/enrich), shows its progress from
// GET /api/enrich once a second, and when the pass ends has the page boot again (fresh facets) and run the current spec
// again, so what the pass wrote shows on the desk.
import type { Api, EnrichPlan, EnrichState } from '../api.ts';
import type { DeskState, Store } from '../state.ts';
import { el, icon } from './dom.ts';

export const POLL_MS = 1000;
/** How long the line saying how an update went stays up. */
export const DONE_LINE_MS = 8000;

export interface ToolbarDeps {
  store: Store;
  api: Pick<Api, 'enrichPlan' | 'enrichStart' | 'enrichStatus'>;
  /** The provider's name, for Update's label (setProvider changes it after a save). */
  provider: string;
  /** Where the question before an update goes (an empty, hidden element). */
  confirmHost: HTMLElement;
  resetView(): void;
  /** After an update pass: boot again and refill the desk. */
  afterUpdate(): Promise<void>;
  /** False until the desk's first fill has landed: the count shows nothing before then. */
  ready(): boolean;
}

export interface Toolbar { settingsButton: HTMLButtonElement; render(s: DeskState): void; setProvider(name: string): void }

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

/** The progress line while a pass runs. */
export function progressLine(st: Pick<EnrichState, 'done' | 'total'>): string {
  return st.total ? `Updating ${n(st.done)} of ${n(st.total)}` : 'Updating…';
}

/** Update's accessible name and tooltip. */
export const updateLabel = (provider: string) => `Update: describe new captures with ${provider}`;

/** The last part of a folder's path (either separator, a trailing one ignored). */
export function folderName(p: string): string {
  return p.split(/[\\/]+/).filter(Boolean).pop() ?? p;
}

/** What Update does with a dry run's answer: run at once when nothing would go to the model, else ask, in these words. */
export type UpdateDecision = { ask: false } | { ask: true; before: string; folderName: string; folderPath: string; after: string };

export function updateDecision(plan: EnrichPlan): UpdateDecision {
  if (plan.send <= 0) return { ask: false };
  const captures = plan.send === 1 ? `${n(1)} capture (its text and pictures)` : `${n(plan.send)} captures (their text and pictures)`;
  const files = plan.write === 1 ? `${n(1)} file` : `${n(plan.write)} files`;
  return { ask: true, before: `Update will send ${captures} to ${plan.provider} and write ${files} into `,
    folderName: folderName(plan.folder), folderPath: plan.folder, after: '. Go ahead?' };
}

/** The line while the server works out what a pass would do. */
export const CHECKING_LINE = 'Looking for new captures…';

/** What following an update pass needs: the pass's state, a pause, the line to write, and the refill after the pass. */
export interface UpdateFollow {
  status(): Promise<EnrichState>;
  wait(ms: number): Promise<void>;
  /** Writes the line under the count ('' clears it). */
  say(text: string, failed?: boolean): void;
  afterUpdate(): Promise<void>;
}

/**
 * Follows a running pass to its end: its progress every POLL_MS, then the line on how it went (which replaces the progress
 * line at once), then the refill; a line that is not a failure is cleared DONE_LINE_MS later. A failure (of the pass, of a
 * status request or of the refill) stays up until the next update.
 */
export async function followUpdate(f: UpdateFollow): Promise<void> {
  for (;;) {
    await f.wait(POLL_MS);
    let st: EnrichState;
    try { st = await f.status(); }
    catch (e) { f.say(e instanceof Error ? e.message : String(e), true); return; }
    if (st.running) { f.say(progressLine(st)); continue; }
    const line = updateLine(st);
    f.say(line.text, line.failed);
    try { await f.afterUpdate(); }
    catch (e) { f.say(e instanceof Error ? e.message : String(e), true); return; }
    if (line.failed) return;
    await f.wait(DONE_LINE_MS);
    f.say('');
    return;
  }
}

export interface UpdaterDeps {
  api: Pick<Api, 'enrichPlan' | 'enrichStart' | 'enrichStatus'>;
  /** Puts the question to the person; true for "Send and update". */
  confirm(d: Extract<UpdateDecision, { ask: true }>): Promise<boolean>;
  /** The button's look while a pass runs: disabled and turning (true), back to normal (false). */
  busy(on: boolean): void;
  /** Writes the line under the count ('' clears it). */
  say(text: string, failed?: boolean): void;
  wait(ms: number): Promise<void>;
  afterUpdate(): Promise<void>;
}

/**
 * Update's click, without the DOM. One click at a time; every click has its own generation, and a line or the button's
 * return from an older one (its summary clearing, its last step after a newer update started) is dropped.
 */
export function createUpdater(d: UpdaterDeps): { click(): Promise<void>; running(): boolean } {
  let running = false, generation = 0;
  const alreadyRunning = (e: unknown) => /already running/i.test(e instanceof Error ? e.message : String(e));
  const click = async () => {
    if (running) return;
    running = true;
    const g = ++generation;
    const mine = () => g === generation;
    const say = (text: string, failed = false) => { if (mine()) d.say(text, failed); };
    let busy = false;
    const done = () => {
      if (!mine()) return;
      running = false;
      if (busy) { busy = false; d.busy(false); }
    };
    const fail = (e: unknown) => say(e instanceof Error ? e.message : String(e), true);
    try {
      say(CHECKING_LINE);
      let plan: EnrichPlan | undefined;
      try { plan = await d.api.enrichPlan(); }
      catch (e) {
        // One already running (started elsewhere) is followed like our own.
        if (!alreadyRunning(e)) { fail(e); return; }
      }
      if (plan) {
        const decision = updateDecision(plan);
        if (decision.ask) {
          say('');
          // "Not now": nothing is sent and nothing written. (The server has no way to read the folder again without the pass.)
          if (!await d.confirm(decision)) return;
        }
        busy = true; d.busy(true);
        say(progressLine({ done: 0, total: 0 }));
        try { say(progressLine(await d.api.enrichStart())); }
        catch (e) { if (!alreadyRunning(e)) { fail(e); return; } }
      }
      if (!busy) { busy = true; d.busy(true); }
      // The button comes back as soon as the pass has ended and the desk is refilled; the summary clears on its own.
      await followUpdate({ status: () => d.api.enrichStatus(), wait: d.wait, say, afterUpdate: async () => {
        await d.afterUpdate();
        done();
      } });
    } finally {
      done();
    }
  };
  return { click, running: () => running };
}

export function mountToolbar(count: HTMLElement, tools: HTMLElement, progress: HTMLElement, deps: ToolbarDeps): Toolbar {
  const { store, api } = deps;
  const tool = (testid: string, label: string, ...paths: string[]) => {
    const b = el('button', { class: 'tool', attrs: { type: 'button', 'data-testid': testid, 'aria-label': label, title: label } }, icon(...paths));
    tools.append(b);
    return b;
  };
  const undo = tool('undo', 'Undo the last step: a throw, a pin, or the question', 'M9 14 4 9l5-5', 'M4 9h10.5a5.5 5.5 0 0 1 0 11H11');
  const reset = tool('reset-view', 'Reset view', 'M3 8V5a2 2 0 0 1 2-2h3', 'M16 3h3a2 2 0 0 1 2 2v3', 'M21 16v3a2 2 0 0 1-2 2h-3', 'M8 21H5a2 2 0 0 1-2-2v-3');
  const update = tool('update', updateLabel(deps.provider), 'M20.5 12a8.5 8.5 0 1 1-2.5-6', 'M20.5 3.5V9H15');
  const settings = tool('settings', 'Settings', 'M4 7h9', 'M17 7h3', 'M15 5a2 2 0 1 0 0 4a2 2 0 1 0 0-4', 'M4 17h3', 'M11 17h9',
    'M9 15a2 2 0 1 0 0 4a2 2 0 1 0 0-4');
  settings.setAttribute('aria-haspopup', 'dialog');
  settings.setAttribute('aria-expanded', 'false');

  undo.addEventListener('click', () => store.undo());
  reset.addEventListener('click', () => deps.resetView());

  // ---------------------------------------------------------------- update

  const setProvider = (name: string) => {
    update.setAttribute('aria-label', updateLabel(name));
    update.title = updateLabel(name);
  };
  setProvider(deps.provider);

  const say = (text: string, failed = false) => {
    progress.textContent = text;
    progress.classList.toggle('failed', failed);
    progress.title = text;
  };
  const updater = createUpdater({
    api, say,
    confirm: q => askFirst(deps.confirmHost, q, update),
    busy: on => { update.disabled = on; update.classList.toggle('busy', on); },
    wait: ms => new Promise<void>(r => setTimeout(r, ms)),
    afterUpdate: () => deps.afterUpdate(),
  });
  update.addEventListener('click', () => { void updater.click(); });

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

  return { settingsButton: settings, render, setProvider };
}

/**
 * The question before an update that would call the model, in the page's own panel. Focus starts on "Not now", so Enter
 * alone does not send; Escape is "Not now"; either way focus goes back to the Update button.
 */
function askFirst(host: HTMLElement, q: Extract<UpdateDecision, { ask: true }>, button: HTMLButtonElement): Promise<boolean> {
  return new Promise(resolve => {
    const text = el('p', { class: 'question', attrs: { id: 'confirm-update-text' } }, document.createTextNode(q.before),
      el('span', { class: 'folder', text: q.folderName, attrs: { title: q.folderPath } }), document.createTextNode(q.after));
    const no = el('button', { text: 'Not now', attrs: { type: 'button', 'data-testid': 'update-not-now' } });
    const yes = el('button', { class: 'primary', text: 'Send and update', attrs: { type: 'button', 'data-testid': 'update-send' } });
    host.replaceChildren(text, el('div', { class: 'actions' }, no, yes));
    host.setAttribute('aria-describedby', text.id);
    const finish = (answer: boolean) => {
      host.removeEventListener('keydown', onKey);
      host.hidden = true;
      host.replaceChildren();
      button.focus();
      resolve(answer);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(false); }
    };
    host.addEventListener('keydown', onKey);
    no.addEventListener('click', () => finish(false), { once: true });
    yes.addEventListener('click', () => finish(true), { once: true });
    host.hidden = false;
    no.focus();
  });
}
