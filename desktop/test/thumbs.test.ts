import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import sharp from 'sharp';
import { copyFixtures } from './helpers.ts';
import { ensureThumbs } from '../src/index/thumbs.ts';
import { thumbsDir } from '../src/core/paths.ts';

const png = (folder: string, cap: number) => {
  const dir = path.join(folder, 'captures/2026/11/07', `00000000-0000-4000-8000-00000000000${cap}`, 'content');
  return path.join(dir, fs.readdirSync(dir).find(f => f.endsWith('.png'))!);
};
const dims = async (p: string) => { const m = await sharp(p).metadata(); return { w: m.width!, h: m.height!, format: m.format }; };

test('capture 3 PNG yields two JPEGs within the size limits', async () => {
  const t = await ensureThumbs(png(copyFixtures(), 3), 'a'.repeat(64));
  assert.equal(path.dirname(t.display), thumbsDir());
  assert.ok(t.display.endsWith('-1024.jpg')); assert.ok(t.small.endsWith('-256.jpg'));
  const d = await dims(t.display), s = await dims(t.small);
  assert.equal(d.format, 'jpeg'); assert.equal(s.format, 'jpeg');
  assert.ok(Math.max(d.w, d.h) <= 1024); assert.ok(Math.max(s.w, s.h) <= 256);
});

test('capture 7 is 1170 x 2532 and scales to 473 x 1024 and 118 x 256', async () => {
  const t = await ensureThumbs(png(copyFixtures(), 7), 'b'.repeat(64));
  const d = await dims(t.display), s = await dims(t.small);
  assert.ok(Math.abs(d.w - 473) <= 1 && d.h === 1024, `${d.w}x${d.h}`);
  assert.ok(Math.abs(s.w - 118) <= 1 && s.h === 256, `${s.w}x${s.h}`);
});

test('a second call does not rewrite the files', async () => {
  const src = png(copyFixtures(), 3);
  const t = await ensureThumbs(src, 'c'.repeat(64));
  const before = [fs.statSync(t.display).mtimeMs, fs.statSync(t.small).mtimeMs];
  await new Promise(r => setTimeout(r, 20));
  const t2 = await ensureThumbs(src, 'c'.repeat(64));
  assert.deepEqual(t2, t);
  assert.deepEqual([fs.statSync(t2.display).mtimeMs, fs.statSync(t2.small).mtimeMs], before);
  assert.deepEqual(fs.readdirSync(thumbsDir()).sort(), [path.basename(t.display), path.basename(t.small)].sort());
});

test('random bytes named .heic reject with a message naming heic', async () => {
  copyFixtures();
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-bad-')), 'junk.heic');
  fs.writeFileSync(f, Buffer.from(Array.from({ length: 4096 }, (_, i) => (i * 7919 + 13) % 251)));
  await assert.rejects(ensureThumbs(f, 'd'.repeat(64)), (e: Error) => e instanceof Error && /heic/i.test(e.message));
});

test('a real HEIC yields both sizes', { skip: spawnSync('sips', ['--help']).error ? 'sips not available' : false }, async () => {
  const folder = copyFixtures();
  const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-heic-')), 'x.heic');
  const r = spawnSync('sips', ['-s', 'format', 'heic', png(folder, 7), '--out', out]);
  assert.equal(r.status, 0);
  const t = await ensureThumbs(out, 'e'.repeat(64));
  const d = await dims(t.display), s = await dims(t.small);
  assert.ok(Math.max(d.w, d.h) <= 1024 && Math.max(d.w, d.h) > 256);
  assert.ok(Math.max(s.w, s.h) <= 256);
});
