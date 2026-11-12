// The desk's state: what is asked (the spec), how it is arranged (the layout), what came back, and what the person has
// pinned and dismissed (spec sections 7 "For the desk: ask" and 8 "Handling"). Asking goes to the model through /api/ask;
// everything else that changes the set goes to /api/search with the current spec; switching layout never calls the network.
// Pure: no DOM, no three.js. A newer question or search always wins over an older answer that arrives late.
import type { DeskItem } from '../../src/server/wire.ts';
import type { LayoutName, SearchSpec } from '../../src/recall/spec.ts';
import type { Api, AskRequest, SearchRequest, Turn } from './api.ts';

export const UNDO_DEPTH = 30;
export const SENTENCES_KEPT = 50;
/** Turns kept for the model's context (the server uses the last few). */
export const HISTORY_KEPT = 20;

export interface DeskState { spec: SearchSpec; layout: LayoutName; items: DeskItem[]; total: number; reply: string;
  pinned: string[]; dismissed: string[]; history: Turn[]; sentences: string[];
  /** A question is with the model. */
  thinking: boolean }

export interface Store {
  get(): DeskState;
  /** Called after every change with the new state; returns the unsubscribe function. */
  subscribe(fn: (s: DeskState) => void): () => void;
  /** Runs the current spec again (the first fill after boot, and after an update pass). */
  refresh(): Promise<void>;
  ask(sentence: string): Promise<void>;
  setLayout(name: LayoutName): void;
  dismiss(id: string): Promise<void>;
  restore(id: string): Promise<void>;
  pin(ids: string[]): Promise<void>;
  unpin(id: string): Promise<void>;
  /** Steps back to the previous question's spec, layout, items, reply and conversation (and, after start over, its lists). */
  undo(): void;
  canUndo(): boolean;
  /** Clears the spec, pinned, dismissed and the conversation, and fills the desk with everything. */
  startOver(): Promise<void>;
}

/** One undo step. `applied` is the result key its items were fetched for; `lists` is kept only by start over, which clears them. */
interface Snapshot { spec: SearchSpec; layout: LayoutName; items: DeskItem[]; total: number; reply: string; history: Turn[];
  applied: string | undefined; lists?: { pinned: string[]; dismissed: string[] } }

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));
/** What a result was fetched for: the spec and both lists. */
const resultKey = (r: { spec: SearchSpec; pinned: string[]; dismissed: string[] }) => JSON.stringify([r.spec, r.pinned, r.dismissed]);
const without = (list: string[], ids: string[]) => list.filter(x => !ids.includes(x));

export function createStore(api: Api): Store {
  let state: DeskState = { spec: {}, layout: 'kind', items: [], total: 0, reply: '', pinned: [], dismissed: [], history: [],
    sentences: [], thinking: false };
  const listeners = new Set<(s: DeskState) => void>();
  const undoStack: Snapshot[] = [];
  let ticket = 0;            // every request takes the next number
  let askTicket = 0;         // the newest question; older answers are dropped
  let searchTicket = 0;      // the newest search; older results are dropped
  let applied: string | undefined;   // the result key of the items on the desk; undefined until a result has landed

  /** The new state, then every subscriber; one that throws is reported and touches neither the state nor the others. */
  const set = (patch: Partial<DeskState>) => {
    state = { ...state, ...patch };
    for (const fn of [...listeners]) {
      try { fn(state); } catch (e) { console.error('hippo desk: a state subscriber failed', e); }
    }
  };

  async function runSearch(): Promise<void> {
    const t = searchTicket = ++ticket;
    const sent: SearchRequest = { spec: state.spec, pinned: state.pinned, dismissed: state.dismissed };
    try {
      const r = await api.search(sent);
      // A newer search, or a question asked since, brings a fresher set.
      if (t !== searchTicket || askTicket > t) return;
      applied = resultKey(sent);
      set({ items: r.items, total: r.total });
    } catch (e) {
      if (t !== searchTicket || askTicket > t) return;
      set({ reply: errorText(e) });
    }
  }

  /**
   * After a question settles (or an undo): search again when the items on the desk were not fetched for the current spec and
   * lists, because pins or dismissals changed meanwhile, or a first fill was dropped for a question that then failed.
   */
  const settle = () => { if (resultKey(state) !== applied) void runSearch(); };

  const pushUndo = (withLists = false) => {
    undoStack.push({ spec: state.spec, layout: state.layout, items: state.items, total: state.total, reply: state.reply,
      history: state.history, applied, ...(withLists ? { lists: { pinned: state.pinned, dismissed: state.dismissed } } : {}) });
    if (undoStack.length > UNDO_DEPTH) undoStack.shift();
  };

  return {
    get: () => state,
    subscribe(fn) { listeners.add(fn); return () => { listeners.delete(fn); }; },
    refresh: runSearch,

    async ask(input) {
      const sentence = input.trim();
      if (!sentence) return;
      const sentences = state.sentences.at(-1) === sentence ? state.sentences : [...state.sentences, sentence].slice(-SENTENCES_KEPT);
      const t = askTicket = ++ticket;
      const sent: AskRequest = { sentence, spec: state.spec, layout: state.layout, history: state.history,
        pinned: state.pinned, dismissed: state.dismissed };
      set({ sentences, thinking: true });
      try {
        const r = await api.ask(sent);
        if (t !== askTicket) return;
        pushUndo();
        searchTicket = ++ticket;   // a search sent before this answer would bring back the old set
        applied = resultKey({ spec: r.spec, pinned: sent.pinned, dismissed: sent.dismissed });
        set({ spec: r.spec, layout: r.layout === 'keep' ? state.layout : r.layout, items: r.items, total: r.total, reply: r.reply,
          history: [...state.history, { sentence, reply: r.reply }].slice(-HISTORY_KEPT), thinking: false });
      } catch (e) {
        if (t !== askTicket) return;
        set({ reply: errorText(e), thinking: false });
      }
      settle();
    },

    setLayout(name) { if (name !== state.layout) set({ layout: name }); },

    async dismiss(id) {
      set({ dismissed: state.dismissed.includes(id) ? state.dismissed : [...state.dismissed, id], pinned: without(state.pinned, [id]) });
      await runSearch();
    },
    async restore(id) {
      set({ dismissed: without(state.dismissed, [id]) });
      await runSearch();
    },
    async pin(ids) {
      const pinned = [...state.pinned];
      for (const id of ids) if (!pinned.includes(id)) pinned.push(id);
      set({ pinned, dismissed: without(state.dismissed, ids) });
      await runSearch();
    },
    async unpin(id) {
      set({ pinned: without(state.pinned, [id]) });
      await runSearch();
    },

    undo() {
      const s = undoStack.pop();
      if (!s) return;
      askTicket = ++ticket;      // a question still with the model is dropped
      searchTicket = ++ticket;
      applied = s.applied;
      set({ spec: s.spec, layout: s.layout, items: s.items, total: s.total, reply: s.reply, history: s.history, thinking: false,
        ...(s.lists ?? {}) });
      settle();
    },
    canUndo: () => undoStack.length > 0,

    async startOver() {
      pushUndo(true);
      askTicket = ++ticket;
      set({ spec: {}, pinned: [], dismissed: [], history: [], reply: '', thinking: false });
      await runSearch();
    },
  };
}
