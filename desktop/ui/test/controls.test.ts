import test from 'node:test';
import assert from 'node:assert/strict';
import { countText, DONE_LINE_MS, followUpdate, POLL_MS, progressLine, updateLine } from '../src/controls/toolbar.ts';
import { settingsPatch } from '../src/controls/settings.ts';
import type { EnrichState, Settings } from '../src/api.ts';
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
