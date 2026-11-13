import test from 'node:test';
import assert from 'node:assert/strict';
import { createStore, UNDO_DEPTH, SENTENCES_KEPT } from '../src/state.ts';
import type { Api, AskRequest, AskResponse, SearchRequest, SearchResponse } from '../src/api.ts';
import type { DeskItem } from '../../src/server/wire.ts';
import { item } from './items.ts';

interface Call { route: string; body?: unknown }

/** An Api whose search returns `searchItems` and whose ask answers with `answer` (or throws it). Every call is recorded. */
function stubApi() {
  const calls: Call[] = [];
  const s = {
    calls,
    searchItems: [item(1), item(2)] as DeskItem[],
    answer: (req: AskRequest): Promise<AskResponse> | AskResponse =>
      ({ spec: { kinds: ['link'] }, layout: 'time', reply: `1 found for ${req.sentence}`, total: 1, items: [item(3)] }),
    api: undefined as unknown as Api,
  };
  const unexpected = (route: string) => async (): Promise<never> => { calls.push({ route }); throw new Error(`unexpected ${route}`); };
  s.api = {
    boot: unexpected('boot'),
    search: async (req: SearchRequest): Promise<SearchResponse> => {
      calls.push({ route: 'search', body: structuredClone(req) });
      return { total: s.searchItems.length, items: s.searchItems };
    },
    ask: async (req: AskRequest) => { calls.push({ route: 'ask', body: structuredClone(req) }); return s.answer(req); },
    capture: unexpected('capture'),
    enrichPlan: unexpected('enrichPlan'),
    enrichStart: unexpected('enrichStart'),
    enrichStatus: unexpected('enrichStatus'),
    settings: unexpected('settings'),
  };
  return s;
}

const ids = (items: DeskItem[]) => items.map(i => i.id);
const lastBody = <T>(calls: Call[], route: string) => calls.filter(c => c.route === route).at(-1)!.body as T;

test('the store starts empty in the kind layout; refresh runs the current spec', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  assert.deepEqual(store.get(), { spec: {}, layout: 'kind', items: [], total: 0, reply: '', pinned: [], dismissed: [], history: [],
    sentences: [], thinking: false, resets: 0 });
  await store.refresh();
  assert.deepEqual(ids(store.get().items), ids(s.searchItems));
  assert.deepEqual(lastBody(s.calls, 'search'), { spec: {}, pinned: [], dismissed: [] });
});

test('ask replaces spec, layout, items and reply and records the turn; undo restores the earlier ones', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.refresh();
  const before = store.get();
  await store.ask('youtube videos');
  const after = store.get();
  assert.deepEqual(after.spec, { kinds: ['link'] });
  assert.equal(after.layout, 'time');
  assert.deepEqual(ids(after.items), ids([item(3)]));
  assert.equal(after.total, 1);
  assert.equal(after.reply, '1 found for youtube videos');
  assert.deepEqual(after.history, [{ sentence: 'youtube videos', reply: '1 found for youtube videos' }]);
  assert.deepEqual(after.sentences, ['youtube videos']);
  assert.deepEqual(lastBody(s.calls, 'ask'), { sentence: 'youtube videos', spec: {}, layout: 'kind', history: [], pinned: [], dismissed: [] });

  const callsBefore = s.calls.length;
  store.undo();
  const undone = store.get();
  assert.deepEqual(undone.spec, before.spec);
  assert.equal(undone.layout, before.layout);
  assert.deepEqual(ids(undone.items), ids(before.items));
  assert.equal(undone.total, before.total);
  assert.equal(undone.reply, before.reply);
  assert.equal(s.calls.length, callsBefore, 'undo needs no network when nothing was pinned or dismissed since');
  store.undo();   // nothing left to undo: no change
  assert.deepEqual(ids(store.get().items), ids(before.items));
});

test('"keep" leaves the layout as it is', async () => {
  const s = stubApi();
  s.answer = () => ({ spec: {}, layout: 'keep', reply: 'ok', total: 0, items: [] });
  const store = createStore(s.api);
  store.setLayout('person');
  await store.ask('anything');
  assert.equal(store.get().layout, 'person');
});

test('a rejected ask keeps the desk as it was and shows the error in the reply line', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.refresh();
  s.answer = () => Promise.reject(new Error('The model is not signed in.'));
  const seen: boolean[] = [];
  store.subscribe(st => seen.push(st.thinking));
  await store.ask('bananas');
  const st = store.get();
  assert.deepEqual(ids(st.items), ids(s.searchItems));
  assert.deepEqual(st.spec, {});
  assert.equal(st.reply, 'The model is not signed in.');
  assert.equal(st.thinking, false);
  assert.deepEqual(seen, [true, false], 'thinking while the question is with the model');
  assert.deepEqual(st.history, []);
  assert.deepEqual(st.sentences, ['bananas'], 'the sentence can still be recalled with Up');
  store.undo();
  assert.deepEqual(store.get().reply, 'The model is not signed in.', 'a failed ask leaves nothing to undo');
});

test('setLayout changes the arrangement without any network call', () => {
  const s = stubApi();
  const store = createStore(s.api);
  let notified = 0;
  store.subscribe(() => notified++);
  store.setLayout('place');
  assert.equal(store.get().layout, 'place');
  assert.equal(s.calls.length, 0);
  assert.equal(notified, 1);
});

test('dismiss sends the id as dismissed on this and the next search; restore and startOver take it back', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.ask('first');
  await store.dismiss('d1');
  assert.deepEqual(lastBody(s.calls, 'search'), { spec: { kinds: ['link'] }, pinned: [], dismissed: ['d1'] });
  await store.pin(['p1']);
  assert.deepEqual(lastBody(s.calls, 'search'), { spec: { kinds: ['link'] }, pinned: ['p1'], dismissed: ['d1'] });
  await store.ask('second');
  assert.deepEqual((lastBody(s.calls, 'ask') as AskRequest).dismissed, ['d1']);
  await store.restore('d1');
  assert.deepEqual(store.get().dismissed, []);
  await store.dismiss('d2');
  await store.startOver();
  const st = store.get();
  assert.deepEqual([st.spec, st.pinned, st.dismissed, st.history], [{}, [], [], []]);
  assert.deepEqual(lastBody(s.calls, 'search'), { spec: {}, pinned: [], dismissed: [] });
  assert.deepEqual(ids(st.items), ids(s.searchItems));
});

test('dismissing a pinned item unpins it; pinning a dismissed one restores it', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.pin(['a', 'b', 'a']);
  assert.deepEqual(store.get().pinned, ['a', 'b']);
  await store.dismiss('a');
  assert.deepEqual([store.get().pinned, store.get().dismissed], [['b'], ['a']]);
  await store.pin(['a']);
  assert.deepEqual([store.get().pinned, store.get().dismissed], [['b', 'a'], []]);
  await store.unpin('b');
  assert.deepEqual(lastBody(s.calls, 'search'), { spec: {}, pinned: ['a'], dismissed: [] });
});

test('pinned ids are sent with every ask', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.pin(['p1', 'p2']);
  await store.ask('one');
  assert.deepEqual((lastBody(s.calls, 'ask') as AskRequest).pinned, ['p1', 'p2']);
  await store.ask('two');
  const req = lastBody<AskRequest>(s.calls, 'ask');
  assert.deepEqual(req.pinned, ['p1', 'p2']);
  assert.deepEqual(req.spec, { kinds: ['link'] }, 'the current spec goes with the sentence');
  assert.deepEqual(req.history, [{ sentence: 'one', reply: '1 found for one' }]);
});

test('an answer that arrives after a newer one is dropped', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  let releaseSlow!: () => void;
  s.answer = req => req.sentence === 'slow'
    ? new Promise(resolve => { releaseSlow = () => resolve({ spec: { kinds: ['note'] }, layout: 'kind', reply: 'slow', total: 1, items: [item(8)] }); })
    : { spec: { kinds: ['photo'] }, layout: 'kind', reply: 'fast', total: 1, items: [item(9)] };
  const slow = store.ask('slow');
  await store.ask('fast');
  releaseSlow();
  await slow;
  assert.equal(store.get().reply, 'fast');
  assert.deepEqual(store.get().spec, { kinds: ['photo'] });
  assert.equal(store.get().thinking, false);
});

test('a dismissal made while a question is with the model is applied to its answer by one more search', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  let release!: () => void;
  s.answer = () => new Promise(resolve => { release = () => resolve({ spec: { kinds: ['note'] }, layout: 'kind', reply: 'notes', total: 1, items: [item(8)] }); });
  const asking = store.ask('notes');
  await store.dismiss('x');
  const searches = s.calls.filter(c => c.route === 'search').length;
  release();
  await asking;
  await new Promise(r => setImmediate(r));
  assert.equal(s.calls.filter(c => c.route === 'search').length, searches + 1);
  assert.deepEqual(lastBody(s.calls, 'search'), { spec: { kinds: ['note'] }, pinned: [], dismissed: ['x'] });
  assert.deepEqual(ids(store.get().items), ids(s.searchItems));
  assert.equal(store.get().reply, 'notes');
});

test('undo keeps at most 30 steps; Up recall keeps the last 50 sentences', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  assert.equal(UNDO_DEPTH, 30);
  assert.equal(SENTENCES_KEPT, 50);
  s.answer = req => ({ spec: { text: [req.sentence] }, layout: 'kind', reply: req.sentence, total: 0, items: [] });
  for (let k = 0; k < 60; k++) await store.ask(`q${k}`);
  assert.equal(store.get().sentences.length, 50);
  assert.equal(store.get().sentences[0], 'q10');
  assert.equal(store.get().sentences.at(-1), 'q59');
  for (let k = 0; k < 40; k++) store.undo();
  assert.deepEqual(store.get().spec, { text: ['q29'] }, 'thirty steps back from q59, and no further');
});

test('undo restores the conversation too: an undone turn is not sent to the model again', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.ask('one');
  await store.ask('two');
  store.undo();
  assert.deepEqual(store.get().history, [{ sentence: 'one', reply: '1 found for one' }]);
  await store.ask('three');
  assert.deepEqual(lastBody<AskRequest>(s.calls, 'ask').history, [{ sentence: 'one', reply: '1 found for one' }]);
});

test('undoing start over brings back the pinned and dismissed lists and the conversation', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.ask('one');
  await store.pin(['p1']);
  await store.dismiss('d1');
  const before = ids(store.get().items);
  await store.startOver();
  assert.deepEqual([store.get().pinned, store.get().dismissed], [[], []]);
  const searches = s.calls.filter(c => c.route === 'search').length;
  store.undo();
  const st = store.get();
  assert.deepEqual([st.pinned, st.dismissed], [['p1'], ['d1']]);
  assert.deepEqual(st.spec, { kinds: ['link'] });
  assert.deepEqual(st.history, [{ sentence: 'one', reply: '1 found for one' }]);
  assert.deepEqual(ids(st.items), before);
  await new Promise(r => setImmediate(r));
  assert.equal(s.calls.filter(c => c.route === 'search').length, searches, 'the restored items were fetched for these lists');
  // The restored lists go with the next question.
  await store.ask('two');
  assert.deepEqual([lastBody<AskRequest>(s.calls, 'ask').pinned, lastBody<AskRequest>(s.calls, 'ask').dismissed], [['p1'], ['d1']]);
});

test('a first fill dropped for a question that then fails is run again: the desk is not left empty', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  const search = s.api.search;
  let releaseSearch!: () => void;
  s.api.search = req => new Promise(resolve => { releaseSearch = () => resolve(search(req)); });
  const refreshing = store.refresh();
  s.answer = () => Promise.reject(new Error('The model is busy.'));
  s.api.search = search;            // later searches answer at once
  await store.ask('bananas');
  releaseSearch();
  await refreshing;
  await new Promise(r => setImmediate(r));
  assert.deepEqual(ids(store.get().items), ids(s.searchItems));
  assert.equal(store.get().reply, 'The model is busy.');
});

test('a subscriber that throws breaks neither the store nor the other subscribers', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  const errors: unknown[][] = [];
  const consoleError = console.error;
  console.error = (...args: unknown[]) => { errors.push(args); };
  try {
    const seen: boolean[] = [];
    // Throws on the first change of the ask (thinking true).
    const off = store.subscribe(st => { if (st.thinking) throw new Error('render failed'); });
    store.subscribe(st => seen.push(st.thinking));
    await store.ask('one');
    assert.equal(store.get().thinking, false);
    assert.equal(store.get().reply, '1 found for one');
    assert.deepEqual(seen, [true, false], 'the other subscriber saw every change');
    off();
    // Throws on the success change: the answer still lands, and the error is not the reply.
    store.subscribe(st => { if (st.reply === '1 found for two') throw new Error('draw failed'); });
    await store.ask('two');
    assert.equal(store.get().reply, '1 found for two');
    assert.deepEqual(store.get().spec, { kinds: ['link'] });
    assert.equal(store.get().history.length, 2);
    assert.equal(errors.length, 2);
  } finally { console.error = consoleError; }
});

test('undo takes back a throw first: the item is back on the desk and the question is kept', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.ask('first');
  const shown = ids(store.get().items);
  s.searchItems = [item(4)];
  await store.dismiss('d1');
  assert.deepEqual(store.get().dismissed, ['d1']);
  assert.equal(store.canUndo(), true);
  store.undo();
  const st = store.get();
  assert.deepEqual(st.dismissed, []);
  assert.deepEqual(st.spec, { kinds: ['link'] }, 'the question stays');
  assert.deepEqual(st.history, [{ sentence: 'first', reply: '1 found for first' }]);
  assert.deepEqual(ids(st.items), shown, 'the items from before the throw, at once');
  store.undo();
  assert.deepEqual(store.get().spec, {}, 'a second undo goes to the previous question');
});

test('undo takes back a pin, an unpin and a take-back, most recent first', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.pin(['p1']);
  await store.dismiss('d1');
  await store.restore('d1');
  await store.unpin('p1');
  store.undo();
  assert.deepEqual([store.get().pinned, store.get().dismissed], [['p1'], []]);
  store.undo();
  assert.deepEqual([store.get().pinned, store.get().dismissed], [['p1'], ['d1']]);
  store.undo();
  assert.deepEqual([store.get().pinned, store.get().dismissed], [['p1'], []]);
  store.undo();
  assert.deepEqual([store.get().pinned, store.get().dismissed], [[], []]);
  assert.equal(store.canUndo(), false);
});

test('a throw, then a new question: undo goes back to the earlier question with the throw still made; undo again takes it back', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.ask('first');
  await store.dismiss('d1');
  await store.ask('second');
  store.undo();
  assert.deepEqual(store.get().history.map(t => t.sentence), ['first']);
  assert.deepEqual(store.get().dismissed, ['d1'], 'the lists as they were when the second question was asked');
  store.undo();
  assert.deepEqual(store.get().dismissed, []);
  assert.deepEqual(store.get().history.map(t => t.sentence), ['first']);
});

test('undo with nothing to undo changes nothing and sends nothing; a pin or throw that changes nothing is no step', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.refresh();
  const before = store.get(), calls = s.calls.length;
  store.undo();
  assert.equal(store.get(), before);
  assert.equal(s.calls.length, calls);
  await store.pin(['p1']);
  await store.pin(['p1']);
  store.undo();
  assert.deepEqual(store.get().pinned, []);
  assert.equal(store.canUndo(), false);
});

test('every start over is counted, even on an empty desk, so the handling can clear what it did', async () => {
  const s = stubApi();
  const store = createStore(s.api);
  await store.startOver();
  assert.equal(store.get().resets, 1);
  await store.startOver();
  assert.equal(store.get().resets, 2);
  store.undo();
  assert.equal(store.get().resets, 2, 'undo does not count back');
});
