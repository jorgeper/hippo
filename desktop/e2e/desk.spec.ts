// The desk in a real browser, on a generated sample folder, with the fake provider (spec "Done means" steps 3 to 5).
import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';

// Type-only: brings in the `window.__desk` declaration the page's own code makes.
import type {} from '../ui/src/main.ts';

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

  await ask(page, 'no, actually it was a screenshot');
  const shots = await ids(page);
  expect(shots.some(id => videos.includes(id))).toBe(false);
  expect(shots.length).toBeGreaterThan(0);

  await ask(page, 'from last week');
  const recent = await ids(page);
  expect(recent.length).toBeLessThanOrEqual(shots.length);
  expect(recent.every(id => shots.includes(id))).toBe(true);

  await page.getByTestId('layout-place').click();
  await settled(page);
  expect(await page.evaluate(() => window.__desk!.layout())).toBe('place');
  expect(await ids(page)).toEqual(recent);
  await expect(page.getByTestId('reply')).toContainText('found');
  expect((await page.evaluate(() => window.__desk!.audit())).clean).toBe(true);
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
  await page.waitForTimeout(500);
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

test('no console errors during the first test', () => {
  expect(consoleProblems).toEqual([]);
});
