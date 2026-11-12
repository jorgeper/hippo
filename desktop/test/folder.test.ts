import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { copyFixtures } from './helpers.ts';
import { scanFolder, assetPath, sha256File } from '../src/core/folder.ts';
import { indexPath, homeDir } from '../src/core/paths.ts';

const cap = (folder: string, n: number) =>
  path.join(folder, 'captures/2026/11/07', `00000000-0000-4000-8000-00000000000${n}`);

test('reads the seven fixture captures in time order', async () => {
  const s = await scanFolder(copyFixtures());
  assert.equal(s.captures.length, 7); assert.equal(s.pending.length, 0);
  assert.deepEqual(s.captures.map(c => c.id.slice(-1)), ['1','2','3','4','5','6','7']);
  const c2 = s.captures[1];
  assert.equal(c2.packageDigest, 'dcb65caedf824a4442f61c2aba5495f3cf04eeac0a84af3796fa8491fae4c04f');
  assert.equal(c2.server?.producer.name, 'hippo-fixtures'); assert.ok(c2.device);
  assert.equal(s.captures[3].comments.length, 2);
  assert.equal(s.captures[3].comments[0].text, 'Bought this one.');
  assert.ok(s.captures[3].comments[1].audioPath?.endsWith('.m4a'));
  assert.ok(s.captures[0].noteBody && s.captures[0].noteBody.length > 0);
});

test('a folder path containing a space works', async () => {
  const src = copyFixtures();
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-space-'));
  const dst = path.join(parent, 'My Hippo Folder');
  fs.cpSync(src, dst, { recursive: true });
  const s = await scanFolder(dst);
  assert.equal(s.captures.length, 7); assert.equal(s.pending.length, 0);
});

test('a capture without complete.json is pending as incomplete', async () => {
  const f = copyFixtures();
  fs.rmSync(path.join(cap(f, 3), 'complete.json'));
  const s = await scanFolder(f);
  assert.equal(s.captures.length, 6);
  assert.deepEqual(s.pending, [{ id: '00000000-0000-4000-8000-000000000003', reason: 'incomplete' }]);
});

test('a manifest file with a different size is pending as changed', async () => {
  const f = copyFixtures();
  fs.appendFileSync(path.join(cap(f, 3), 'content/00000000-0000-4000-8000-000300000001.png'), Buffer.from([0]));
  const s = await scanFolder(f);
  assert.equal(s.captures.length, 6);
  assert.equal(s.pending[0].reason, 'changed');
});

test('a manifest file with the same size but different bytes is pending as changed', async () => {
  const f = copyFixtures();
  const p = path.join(cap(f, 3), 'content/00000000-0000-4000-8000-000300000001.png');
  const b = fs.readFileSync(p); b[b.length - 1] ^= 0xff; fs.writeFileSync(p, b);
  const s = await scanFolder(f);
  assert.equal(s.pending[0].reason, 'changed');
});

test('a missing manifest file is pending as incomplete', async () => {
  const f = copyFixtures();
  fs.rmSync(path.join(cap(f, 3), 'content/00000000-0000-4000-8000-000300000001.png'));
  const s = await scanFolder(f);
  assert.equal(s.pending[0].reason, 'incomplete');
});

test('schema_version 2 in complete.json is pending as unsupported version', async () => {
  const f = copyFixtures();
  const p = path.join(cap(f, 5), 'complete.json');
  const j = JSON.parse(fs.readFileSync(p, 'utf8')); j.schema_version = 2;
  fs.writeFileSync(p, JSON.stringify(j));
  const s = await scanFolder(f);
  assert.equal(s.captures.length, 6);
  assert.deepEqual(s.pending, [{ id: '00000000-0000-4000-8000-000000000005', reason: 'unsupported version' }]);
});

test('an unreadable server document sets serverUnreadable and keeps the capture', async () => {
  const f = copyFixtures();
  const p = path.join(f, 'enrichments/server/2026/11/07/00000000-0000-4000-8000-000000000002/enrichment.json');
  fs.writeFileSync(p, '{not json');
  const s = await scanFolder(f);
  assert.equal(s.captures.length, 7);
  const c2 = s.captures[1];
  assert.ok(c2.serverUnreadable); assert.equal(c2.server, undefined);
  assert.equal(c2.serverPath, p);
});

test('a device document with another package digest is ignored', async () => {
  const f = copyFixtures();
  const p = path.join(f, 'enrichments/device/2026/11/07/00000000-0000-4000-8000-000000000002/enrichment.json');
  const j = JSON.parse(fs.readFileSync(p, 'utf8')); j.package_digest = '0'.repeat(64);
  fs.writeFileSync(p, JSON.stringify(j));
  const c2 = (await scanFolder(f)).captures[1];
  assert.equal(c2.device, undefined); assert.equal(c2.deviceDir, undefined);
});

test('assetPath returns a verified path, undefined after truncation or outside deviceDir', async () => {
  const f = copyFixtures();
  const c2 = (await scanFolder(f)).captures[1];
  const ref = (c2.device!.facets.link_preview.data as any).items[0].thumbnail;
  const p = await assetPath(c2, ref);
  assert.ok(p && p.endsWith('.jpg')); assert.equal(await sha256File(p), ref.sha256);
  assert.equal(await assetPath(c2, { ...ref, relative_path: '../../../../../../captures/2026/11/07/x' }), undefined);
  fs.truncateSync(p, 10);
  assert.equal(await assetPath(c2, ref), undefined);
});

test('indexPath differs per folder and sits under HIPPO_DESK_HOME', () => {
  copyFixtures();
  const a = indexPath('/tmp/a'), b = indexPath('/tmp/b');
  assert.notEqual(a, b);
  assert.equal(path.dirname(a), homeDir());
  assert.equal(path.dirname(a), process.env.HIPPO_DESK_HOME);
  assert.match(path.basename(a), /^index-[0-9a-f]{12}\.sqlite$/);
});
