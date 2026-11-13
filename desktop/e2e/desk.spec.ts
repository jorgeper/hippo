// The desk in a real browser, on a generated sample folder, with the fake provider (spec "Done means" steps 3 to 5).
import fs from 'node:fs';
import path from 'node:path';
import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';

// Type-only: brings in the `window.__desk` declaration the page's own code makes.
import type {} from '../ui/src/main.ts';

/** interact/hand.ts OPEN_GUARD_MS: a click on a spread item sooner than this after opening is ignored. */
const OPEN_GUARD_MS = 400;

const url = () => process.env.HIPPO_E2E_URL as string;
const settled = (page: Page) => page.waitForFunction(() => window.__desk?.settled() === true);
const ids = (page: Page): Promise<string[]> => page.evaluate(() => window.__desk!.ids());
async function ask(page: Page, sentence: string): Promise<void> {
  const box = page.getByTestId('ask');
  await box.fill(sentence);
  await box.press('Enter');
  await settled(page);
}

const consoleProblems: string[] = [];

/** The server's own answer for a spec: the ids the desk should hold (sorted). */
async function searchIds(page: Page, spec: object): Promise<string[]> {
  const res = await page.request.post(`${process.env.HIPPO_E2E_ORIGIN}/api/search`, { data: { spec, pinned: [], dismissed: [] } });
  expect(res.status()).toBe(200);
  return ((await res.json()).items as { id: string }[]).map(i => i.id).sort();
}
const sorted = (a: string[]) => [...a].sort();

// No test may reach a host other than this machine (map tiles are off in global-setup; nothing else goes out).
let external: string[] = [];
test.beforeEach(({ page }) => {
  external = [];
  page.on('request', r => {
    const u = new URL(r.url());
    if (/^(https?|wss?):$/.test(u.protocol) && u.hostname !== '127.0.0.1' && u.hostname !== 'localhost') external.push(r.url());
  });
});
test.afterEach(() => { expect(external).toEqual([]); });

test('ask, correct, refine', async ({ page }) => {
  // Software WebGL logs "GL Driver Message" performance warnings; they are the driver's, not the page's.
  page.on('console', m => { if ((m.type() === 'error' || m.type() === 'warning') && !m.text().includes('GL Driver Message')) consoleProblems.push(`${m.type()}: ${m.text()}`); });
  page.on('pageerror', e => consoleProblems.push(`pageerror: ${e.message}`));

  await page.goto(url());
  await settled(page);
  const all = await page.evaluate(() => window.__desk!.ids().length);
  expect(all).toBeGreaterThan(100);
  expect((await page.evaluate(() => window.__desk!.audit())).clean).toBe(true);

  await ask(page, 'show me the youtube videos');
  const videos = await ids(page);
  expect(videos.length).toBeGreaterThanOrEqual(8);
  expect(videos.length).toBeLessThan(all);
  // Which captures, not only how many: exactly the YouTube links.
  expect(sorted(videos)).toEqual(await searchIds(page, { kinds: ['link'], sites: ['youtube.com'] }));

  await ask(page, 'no, actually it was a screenshot');
  const shots = await ids(page);
  expect(shots.some(id => videos.includes(id))).toBe(false);
  expect(shots.length).toBeGreaterThan(0);
  expect(sorted(shots)).toEqual(await searchIds(page, { kinds: ['screenshot'] }));

  await ask(page, 'from last week');
  const recent = await ids(page);
  // The week filter must really narrow: some screenshots from last week, but not all of them. The sample is seeded (7), and for
  // every weekday of today it holds 3 to 4 of its 18 screenshots in the previous Monday-to-Sunday week.
  expect(recent.length).toBeGreaterThan(0);
  expect(recent.length).toBeLessThan(shots.length);
  expect(recent.every(id => shots.includes(id))).toBe(true);

  await page.getByTestId('layout-place').click();
  await settled(page);
  expect(await page.evaluate(() => window.__desk!.layout())).toBe('place');
  expect(await ids(page)).toEqual(recent);
  await expect(page.getByTestId('reply')).toContainText('found');
  expect((await page.evaluate(() => window.__desk!.audit())).clean).toBe(true);
  expect(consoleProblems).toEqual([]);
});

test('undo steps back through the questions, newest first', async ({ page }) => {
  await page.goto(url());
  await settled(page);
  const all = await ids(page);
  await ask(page, 'show me the youtube videos');
  const videos = await ids(page);
  await ask(page, 'no, actually it was a screenshot');
  await page.getByTestId('undo').click();
  await settled(page);
  expect(await ids(page)).toEqual(videos);
  await page.getByTestId('undo').click();
  await settled(page);
  expect(await ids(page)).toEqual(all);
  expect((await page.evaluate(() => window.__desk!.audit())).clean).toBe(true);
});

test('an item lifts, turns over and goes back', async ({ page }) => {
  await page.goto(url());
  await settled(page);
  await ask(page, 'show me the youtube videos');
  // Items sit in piles: click the pile open, wait out the open guard, then click one spread item.
  const pile = (await page.evaluate(() => window.__desk!.piles())).find((q: { count: number }) => q.count > 1);
  expect(pile).toBeTruthy();
  const at = await page.evaluate(k => window.__desk!.pointOf(k), pile!.key);
  await page.mouse.click(at!.x, at!.y);
  await settled(page);
  await page.waitForFunction(() => window.__desk!.open() !== undefined);
  await settled(page);
  // `settled` needs 250 ms of quiet and the spread to be built; the click guard (OPEN_GUARD_MS, 400 ms) is measured from the
  // open, so wait for a spread item to exist, then for the guard.
  await page.waitForFunction(() => window.__desk!.piles().some(q => q.key.startsWith('spread:')));
  await page.waitForTimeout(OPEN_GUARD_MS + 50);
  const first = (await page.evaluate(() => window.__desk!.piles())).find((q: { key: string }) => q.key.startsWith('spread:'));
  const p = await page.evaluate(k => window.__desk!.pointOf(k), first!.key);
  await page.mouse.click(p!.x, p!.y);
  await expect(page.getByTestId('detail')).toHaveAttribute('data-side', 'front');
  await page.getByTestId('flip').click();
  await expect(page.getByTestId('detail')).toHaveAttribute('data-side', 'back');
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('detail')).toBeHidden();
  await settled(page);
  expect((await page.evaluate(() => window.__desk!.audit())).clean).toBe(true);
});

test('a request without the cookie or token is refused', async ({ request }) => {
  const res = await request.get(`${process.env.HIPPO_E2E_ORIGIN}/api/boot`);
  expect(res.status()).toBe(403);
});

/** Every server enrichment document in the sample folder, by capture id. */
function serverDocs(): Map<string, string> {
  const root = path.join(process.env.HIPPO_E2E_FOLDER as string, 'enrichments', 'server');
  const out = new Map<string, string>();
  const walk = (dir: string) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (e.name === 'enrichment.json') out.set(path.basename(dir), full);
    }
  };
  walk(root);
  return out;
}
const providerCalls = () => Number(fs.readFileSync(process.env.HIPPO_E2E_CALLS as string, 'utf8'));

// Last: it changes the sample folder (three captures lose their server enrichment, then get it back).
test('Update asks before it sends captures to the model; "Not now" sends nothing, "Send and update" runs the pass', async ({ page }) => {
  await page.goto(url());
  await settled(page);
  const update = page.getByTestId('update');
  await expect(update).toHaveAttribute('aria-label', 'Update: describe new captures with fake');
  await expect(update).toHaveAttribute('title', 'Update: describe new captures with fake');

  // Three notes the model has not described yet.
  const notes = (await searchIds(page, { kinds: ['note'] })).slice(0, 3);
  expect(notes.length).toBe(3);
  const docs = serverDocs();
  for (const id of notes) fs.rmSync(docs.get(id)!);
  const before = serverDocs().size, calls = providerCalls();

  const question = page.getByTestId('confirm-update');
  await update.click();
  await expect(question).toBeVisible();
  await expect(question).toContainText('Update will send 3 captures (their text and pictures) to fake and write 3 files into sample. Go ahead?');
  await expect(question.locator('.folder')).toHaveAttribute('title', process.env.HIPPO_E2E_FOLDER as string);
  // Focus starts on "Not now": Enter alone does not send.
  await expect(page.getByTestId('update-not-now')).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(question).toBeHidden();
  await expect(update).toBeFocused();

  await update.click();
  await page.getByTestId('update-not-now').click();
  await expect(question).toBeHidden();
  await expect(update).toBeFocused();
  await settled(page);
  expect(providerCalls()).toBe(calls);
  expect(serverDocs().size).toBe(before);

  await update.click();
  await page.getByTestId('update-send').click();
  await expect(page.locator('#progress')).toHaveText('3 captures updated', { timeout: 30_000 });
  expect(providerCalls()).toBe(calls + 3);
  const after = serverDocs();
  expect(after.size).toBe(before + 3);
  for (const id of notes) expect(after.has(id)).toBe(true);
  await settled(page);

  // A question left open while the settings change is closed; the next Update asks afresh, naming the new provider. The
  // provider is switched to claude-cli only to read its name: "Not now" means it is never called.
  fs.rmSync(serverDocs().get(notes[0])!);
  const callsNow = providerCalls();
  await update.click();
  await expect(question).toContainText('Update will send 1 capture (its text and pictures) to fake');
  await page.getByTestId('settings').click();
  await expect(question).toBeHidden();
  await page.locator('#settings-provider').selectOption('claude-cli');
  await page.locator('#settings').getByRole('button', { name: 'Save' }).click();
  await expect(page.locator('#settings')).toBeHidden();
  await expect(update).toHaveAttribute('aria-label', 'Update: describe new captures with claude-cli');
  await update.click();
  await expect(question).toContainText('Update will send 1 capture (its text and pictures) to claude-cli and write 1 file into sample. Go ahead?');
  await page.getByTestId('update-not-now').click();
  await expect(question).toBeHidden();
  await expect(update).toBeFocused();
  expect(providerCalls()).toBe(callsNow);
  expect(serverDocs().has(notes[0])).toBe(false);
});
