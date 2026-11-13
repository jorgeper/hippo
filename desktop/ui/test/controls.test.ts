import test from 'node:test';
import assert from 'node:assert/strict';
import { CHECKING_LINE, countText, createUpdater, DONE_LINE_MS, folderName, followUpdate, POLL_MS, progressLine, updateDecision, updateLabel, updateLine } from '../src/controls/toolbar.ts';
import { settingsPatch } from '../src/controls/settings.ts';
import type { EnrichPlan, EnrichState, Settings } from '../src/api.ts';
import type { EnrichReport } from '../../src/enrich/enrich.ts';
import { item } from './items.ts';

const desk = (on: number, total: number, aside: number) => ({
  items: Array.from({ length: on }, (_, k) => item(k)), total, dismissed: Array.from({ length: aside }, (_, k) => `gone-${k}`),
});

test('countText: what is on the desk, the "N of T" form when the result was cut, and how many are set aside', () => {
  assert.deepEqual(countText(desk(83, 83, 4)), { main: '83 on the desk', aside: '4 set aside' });
  assert.deepEqual(countText(desk(83, 83, 0)), { main: '83 on the desk', aside: '' });
  assert.deepEqual(countText(desk(200, 412, 1)), { main: '200 of 412 on the desk', aside: '1 set aside' });
  assert.deepEqual(countText(desk(0, 0, 0)), { main: '0 on the desk', aside: '' });
  assert.deepEqual(countText(desk(1, 1, 0)), { main: '1 on the desk', aside: '' });
});

const report = (over: Partial<EnrichReport> = {}): EnrichReport => ({ captures: 300, pending: 0, modelCalls: 0, written: 0, unchanged: 300,
  failed: [], skippedAfterRetries: 0, wouldCall: [], wouldWrite: [], deferred: 0, tempFilesRemoved: 0, wouldRemove: [], warnings: [], ...over });
const finished = (r: EnrichState['report']): EnrichState => ({ running: false, done: 0, total: 0, ...(r ? { report: r } : {}) });

test('progressLine and updateLine: the progress, then one line on how the pass went', () => {
  assert.equal(progressLine({ done: 12, total: 40 }), 'Updating 12 of 40');
  assert.equal(progressLine({ done: 0, total: 0 }), 'Updating…');
  assert.deepEqual(updateLine(finished({ enrich: report() })), { text: 'Nothing new to update', failed: false });
  assert.deepEqual(updateLine(finished({ enrich: report({ written: 1 }) })), { text: '1 capture updated', failed: false });
  assert.deepEqual(updateLine(finished({ enrich: report({ written: 40 }) })), { text: '40 captures updated', failed: false });
  assert.deepEqual(updateLine(finished({ enrich: report({ written: 38, failed: [{ id: 'a', reason: 'x' }, { id: 'b', reason: 'y' }] }) })),
    { text: '38 captures updated, 2 failed', failed: true });
  assert.deepEqual(updateLine(finished({ enrich: report({ failed: [{ id: 'a', reason: 'x' }] }) })), { text: 'Nothing new to update, 1 failed', failed: true });
  assert.deepEqual(updateLine(finished({ enrich: report({ written: 3, stoppedBy: 'usage_limit', stopReason: 'usage limit reached' }) })),
    { text: 'Update stopped: usage limit reached', failed: true });
  assert.deepEqual(updateLine(finished({ enrich: report({ stoppedBy: 'interrupted' }) })), { text: 'Update stopped: interrupted', failed: true });
  assert.deepEqual(updateLine(finished({ error: 'the folder is gone' })), { text: 'Update failed: the folder is gone', failed: true });
  assert.deepEqual(updateLine(finished(undefined)), { text: 'Update finished', failed: false });
});

/** Runs followUpdate over a scripted sequence of states, recording every line written and every pause. */
async function follow(states: (EnrichState | Error)[], afterUpdate: () => Promise<void> = async () => {}) {
  const log: string[] = [];
  let k = 0;
  await followUpdate({
    status: async () => { const s = states[k++]; if (s instanceof Error) throw s; return s; },
    wait: async ms => { log.push(`wait ${ms}`); },
    say: (text, failed = false) => { log.push(`${failed ? 'FAILED ' : ''}"${text}"`); },
    afterUpdate: async () => { log.push('refill'); await afterUpdate(); },
  });
  return log;
}

test('followUpdate: progress gives way to the summary as soon as the pass ends, then the summary clears', async () => {
  const log = await follow([{ running: true, done: 12, total: 40 }, { running: true, done: 40, total: 40 },
    finished({ enrich: report({ written: 40 }) })]);
  assert.deepEqual(log, [`wait ${POLL_MS}`, '"Updating 12 of 40"', `wait ${POLL_MS}`, '"Updating 40 of 40"', `wait ${POLL_MS}`,
    '"40 captures updated"', 'refill', `wait ${DONE_LINE_MS}`, '""']);
});

test('followUpdate: a failure stays up; a status request or refill that fails says why', async () => {
  assert.deepEqual(await follow([finished({ error: 'boom' })]), [`wait ${POLL_MS}`, 'FAILED "Update failed: boom"', 'refill']);
  assert.deepEqual(await follow([{ running: true, done: 1, total: 4 }, new Error('Cannot reach Hippo.')]),
    [`wait ${POLL_MS}`, '"Updating 1 of 4"', `wait ${POLL_MS}`, 'FAILED "Cannot reach Hippo."']);
  assert.deepEqual(await follow([finished({ enrich: report({ written: 2 }) })], async () => { throw new Error('no boot'); }),
    [`wait ${POLL_MS}`, '"2 captures updated"', 'refill', 'FAILED "no boot"']);
});

const BASE: Settings = { provider: 'claude-cli', askModel: 'sonnet', enrichModel: 'haiku', mapTiles: true, theme: 'desk' };

test('settingsPatch: only the fields that changed, among theme, provider, the two models and map tiles', () => {
  assert.deepEqual(settingsPatch(BASE, { ...BASE }), {});
  assert.deepEqual(settingsPatch(BASE, { ...BASE, provider: 'fake' }), { provider: 'fake' });
  assert.deepEqual(settingsPatch(BASE, { ...BASE, askModel: 'opus' }), { askModel: 'opus' });
  assert.deepEqual(settingsPatch(BASE, { ...BASE, enrichModel: '' }), { enrichModel: '' });
  assert.deepEqual(settingsPatch(BASE, { ...BASE, mapTiles: false }), { mapTiles: false });
  assert.deepEqual(settingsPatch(BASE, { ...BASE, theme: 'other' }), { theme: 'other' });
  assert.deepEqual(settingsPatch(BASE, { provider: 'fake', askModel: 'a', enrichModel: 'b', mapTiles: false, theme: 'x' }),
    { provider: 'fake', askModel: 'a', enrichModel: 'b', mapTiles: false, theme: 'x' });
  // Anything else on the objects (a key, a folder, a stray field) never goes into the patch, changed or not.
  const extra = { ...BASE, apiKey: 'placeholder-1', folder: '/x' } as Settings;
  const changed = { ...BASE, provider: 'fake', apiKey: 'placeholder-2', folder: '/y', concurrency: 9 } as Settings;
  const patch = settingsPatch(extra, changed);
  assert.deepEqual(patch, { provider: 'fake' });
  assert.deepEqual(Object.keys(settingsPatch({} as Settings, changed)).sort(), ['askModel', 'enrichModel', 'mapTiles', 'provider', 'theme']);
});

const plan = (over: Partial<EnrichPlan> = {}): EnrichPlan =>
  ({ dryRun: true, send: 0, write: 0, captures: 300, provider: 'claude-cli', folder: '/Volumes/Data/Dropbox/H1ppo', ...over });

test('updateDecision: nothing for the model runs at once; anything for the model asks first, with the real numbers', () => {
  assert.deepEqual(updateDecision(plan()), { ask: false });
  // Rule-made changes only (no model call): runs as before.
  assert.deepEqual(updateDecision(plan({ write: 4 })), { ask: false });
  const d = updateDecision(plan({ send: 51, write: 51 }));
  assert.equal(d.ask, true);
  if (!d.ask) return;
  assert.equal(`${d.before}${d.folderName}${d.after}`,
    'Update will send 51 captures (their text and pictures) to claude-cli and write 51 files into H1ppo. Go ahead?');
  assert.equal(d.folderName, 'H1ppo');
  assert.equal(d.folderPath, '/Volumes/Data/Dropbox/H1ppo');
  const one = updateDecision(plan({ send: 1, write: 3, provider: 'fake', folder: 'C:\\data\\hippo-sample\\' }));
  assert.ok(one.ask);
  if (!one.ask) return;
  assert.equal(`${one.before}${one.folderName}${one.after}`,
    'Update will send 1 capture (its text and pictures) to fake and write 3 files into hippo-sample. Go ahead?');
  const big = updateDecision(plan({ send: 1200, write: 1201 }));
  assert.ok(big.ask && big.before.startsWith(`Update will send ${(1200).toLocaleString()} captures`));
});

test('folderName: the last part of the path, whatever the separator or a trailing one', () => {
  assert.equal(folderName('/a/b/H1ppo'), 'H1ppo');
  assert.equal(folderName('/a/b/H1ppo/'), 'H1ppo');
  assert.equal(folderName('C:\\x\\H1ppo'), 'H1ppo');
  assert.equal(folderName('/'), '/');
});

test('updateLabel: says what Update does, with the provider', () => {
  assert.equal(updateLabel('claude-cli'), 'Update: describe new captures with claude-cli');
  assert.equal(updateLabel('fake'), 'Update: describe new captures with fake');
});

/** An updater over scripted answers, recording what it does; `waits` lets a test hold a pause open. */
function updater(o: { plan: EnrichPlan | Error; answer?: boolean; states?: EnrichState[]; hold?: (ms: number) => Promise<void> | undefined }) {
  const log: string[] = [];
  let k = 0;
  const states = o.states ?? [finished({ enrich: report({ written: 2 }) })];
  const u = createUpdater({
    api: {
      enrichPlan: async () => { log.push('plan'); if (o.plan instanceof Error) throw o.plan; return o.plan; },
      enrichStart: async () => { log.push('start'); return { running: true, done: 0, total: 0 }; },
      enrichStatus: async () => states[Math.min(k++, states.length - 1)],
    },
    confirm: async q => { log.push(`ask "${q.before}${q.folderName}${q.after}"`); return o.answer ?? false; },
    busy: on => log.push(on ? 'busy' : 'free'),
    say: (text, failed = false) => log.push(`${failed ? 'FAILED ' : ''}"${text}"`),
    wait: async ms => { await o.hold?.(ms); },
    afterUpdate: async () => { log.push('refill'); },
  });
  return { u, log };
}

test('createUpdater: nothing for the model runs straight away, as before', async () => {
  const { u, log } = updater({ plan: plan({ write: 3 }) });
  await u.click();
  assert.deepEqual(log, ['"' + CHECKING_LINE + '"', 'plan', 'busy', '"Updating…"', 'start', '"Updating…"', '"2 captures updated"', 'refill', 'free', '""']);
  assert.equal(u.running(), false);
});

test('createUpdater: captures for the model ask first; "Not now" sends nothing, starts nothing and frees the button', async () => {
  const { u, log } = updater({ plan: plan({ send: 51, write: 51 }), answer: false });
  await u.click();
  assert.deepEqual(log, ['"' + CHECKING_LINE + '"', 'plan', '""',
    'ask "Update will send 51 captures (their text and pictures) to claude-cli and write 51 files into H1ppo. Go ahead?"']);
  assert.equal(u.running(), false);
});

test('createUpdater: "Send and update" starts the pass and follows it', async () => {
  const { u, log } = updater({ plan: plan({ send: 2, write: 2 }), answer: true });
  await u.click();
  assert.deepEqual(log.slice(4), ['busy', '"Updating…"', 'start', '"Updating…"', '"2 captures updated"', 'refill', 'free', '""']);
});

test('createUpdater: a pass already running elsewhere is followed; another failure of the dry run says why', async () => {
  const running = updater({ plan: new Error('an update is already running') });
  await running.u.click();
  assert.deepEqual(running.log, ['"' + CHECKING_LINE + '"', 'plan', 'busy', '"2 captures updated"', 'refill', 'free', '""']);
  const broken = updater({ plan: new Error('Cannot reach Hippo.') });
  await broken.u.click();
  assert.deepEqual(broken.log, ['"' + CHECKING_LINE + '"', 'plan', 'FAILED "Cannot reach Hippo."']);
});

test('createUpdater: an older click that ends while a newer pass runs leaves the button and the line alone (C3)', async () => {
  // The first click's summary pause (DONE_LINE_MS) is held open; meanwhile a second click starts a pass and is held in its poll.
  let releaseFirst!: () => void, releaseSecond!: () => void;
  const firstLine = new Promise<void>(r => { releaseFirst = r; });
  const secondPoll = new Promise<void>(r => { releaseSecond = r; });
  let clicks = 0;
  const { u, log } = updater({ plan: plan(), hold: ms => (ms === DONE_LINE_MS && clicks === 1 ? firstLine : ms === POLL_MS && clicks === 2 ? secondPoll : undefined) });
  clicks = 1;
  const first = u.click();
  for (let i = 0; i < 20 && !log.includes('free'); i++) await new Promise(r => setImmediate(r));
  assert.equal(u.running(), false, 'the first pass has ended and the button is back');
  clicks = 2;
  const second = u.click();
  for (let i = 0; i < 20 && log.filter(l => l === 'busy').length < 2; i++) await new Promise(r => setImmediate(r));
  const mark = log.length;
  releaseFirst();
  await first;
  assert.deepEqual(log.slice(mark), [], 'the first click neither freed the button nor cleared the line');
  assert.equal(u.running(), true);
  releaseSecond();
  await second;
  assert.equal(log.at(-2), 'free');
  assert.equal(u.running(), false);
});
