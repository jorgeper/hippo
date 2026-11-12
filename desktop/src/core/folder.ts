import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import type { CommentFile, EnrichmentDoc, FolderScan, RawCapture } from './types.ts';

export async function sha256File(p: string): Promise<string> {
  const h = crypto.createHash('sha256');
  for await (const chunk of createReadStream(p)) h.update(chunk as Buffer);
  return h.digest('hex');
}

function inside(base: string, rel: string): string | undefined {
  if (typeof rel !== 'string' || rel === '' || path.isAbsolute(rel)) return undefined;
  const full = path.resolve(base, rel);
  const r = path.relative(base, full);
  if (r === '' || r.startsWith('..') || path.isAbsolute(r)) return undefined;
  return full;
}

type Match = 'ok' | 'missing' | 'changed';

async function matches(base: string, ref: { relative_path: string; byte_count: number; sha256: string }): Promise<{ result: Match; full?: string }> {
  const full = inside(base, ref.relative_path);
  if (!full) return { result: 'changed' };
  let st;
  try { st = await fs.stat(full); } catch { return { result: 'missing' }; }
  if (!st.isFile() || st.size !== ref.byte_count) return { result: 'changed' };
  try {
    if ((await sha256File(full)) !== ref.sha256) return { result: 'changed' };
  } catch { return { result: 'missing' }; }
  return { result: 'ok', full };
}

async function readJson(p: string): Promise<{ value?: any; exists: boolean; error?: boolean }> {
  let text: string;
  try { text = await fs.readFile(p, 'utf8'); } catch { return { exists: false }; }
  try { return { exists: true, value: JSON.parse(text) }; } catch { return { exists: true, error: true }; }
}

function isObject(v: unknown): v is Record<string, any> { return typeof v === 'object' && v !== null && !Array.isArray(v); }

export async function readCapture(folder: string, datePath: string, id: string): Promise<RawCapture | { pending: string }> {
  const dir = path.resolve(folder, 'captures', ...datePath.split('/'), id);
  let completeBytes: Buffer;
  try { completeBytes = await fs.readFile(path.join(dir, 'complete.json')); } catch { return { pending: 'incomplete' }; }
  let complete: any;
  try { complete = JSON.parse(completeBytes.toString('utf8')); } catch { return { pending: 'incomplete' }; }
  if (!isObject(complete)) return { pending: 'incomplete' };
  if (complete.schema_version !== 1) return { pending: 'unsupported version' };
  if (!Array.isArray(complete.files)) return { pending: 'incomplete' };
  for (const f of complete.files) {
    const m = await matches(dir, f);
    if (m.result === 'missing') return { pending: 'incomplete' };
    if (m.result === 'changed') return { pending: 'changed' };
  }
  const packageDigest = crypto.createHash('sha256').update(completeBytes).digest('hex');

  const md = await readJson(path.join(dir, 'metadata.json'));
  if (!md.exists) return { pending: 'incomplete' };
  if (md.error || !isObject(md.value)) return { pending: 'unreadable metadata' };
  if (md.value.schema_version !== 1) return { pending: 'unsupported version' };
  const metadata = md.value;

  let noteBody: string | undefined;
  const textAtt = (Array.isArray(metadata.attachments) ? metadata.attachments : [])
    .find((a: any) => a && (a.uti === 'public.utf8-plain-text' || a.uti === 'public.plain-text'));
  if (textAtt) {
    const p = inside(dir, textAtt.relative_path);
    if (p) { try { noteBody = await fs.readFile(p, 'utf8'); } catch { /* leave unset */ } }
  }

  const comments: CommentFile[] = [];
  let names: string[] = [];
  try { names = (await fs.readdir(path.join(dir, 'comments'))).filter(n => n.endsWith('.json')).sort(); } catch { /* none */ }
  for (const n of names) {
    const j = await readJson(path.join(dir, 'comments', n));
    const c = j.value;
    if (j.error || !isObject(c) || c.schema_version !== 1 || typeof c.comment_id !== 'string' || typeof c.added_at !== 'string') continue;
    const out: CommentFile = { id: c.comment_id, added_at: c.added_at };
    if (typeof c.text === 'string' && c.text !== '') out.text = c.text;
    if (isObject(c.audio)) {
      const m = await matches(dir, c.audio as any);
      if (m.result === 'ok') out.audioPath = m.full;
    }
    if (out.text === undefined && out.audioPath === undefined) continue;
    comments.push(out);
  }
  comments.sort((a, b) => (a.added_at < b.added_at ? -1 : a.added_at > b.added_at ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const layerDir = (layer: string) => path.resolve(folder, 'enrichments', layer, ...datePath.split('/'), id);
  const result: RawCapture = { id, dir, datePath, metadata, packageDigest, comments, serverPath: path.join(layerDir('server'), 'enrichment.json') };
  if (noteBody !== undefined) result.noteBody = noteBody;

  const dj = await readJson(path.join(layerDir('device'), 'enrichment.json'));
  if (dj.exists && !dj.error && isObject(dj.value) && dj.value.schema_version === 1 && dj.value.package_digest === packageDigest) {
    result.device = dj.value as EnrichmentDoc;
    result.deviceDir = layerDir('device');
  }
  const sj = await readJson(result.serverPath);
  if (sj.exists) {
    if (sj.error || !isObject(sj.value)) result.serverUnreadable = 'not valid JSON';
    else if (sj.value.schema_version !== 1) result.serverUnreadable = 'unsupported version';
    else result.server = sj.value as EnrichmentDoc;
  }
  return result;
}

export async function assetPath(c: RawCapture, ref: { relative_path: string; byte_count: number; sha256: string }): Promise<string | undefined> {
  if (!c.deviceDir) return undefined;
  const m = await matches(c.deviceDir, ref);
  return m.result === 'ok' ? m.full : undefined;
}

async function dirs(p: string): Promise<string[]> {
  try {
    return (await fs.readdir(p, { withFileTypes: true })).filter(e => e.isDirectory()).map(e => e.name).sort();
  } catch { return []; }
}

export async function scanFolder(folder: string): Promise<FolderScan> {
  const root = path.resolve(folder, 'captures');
  const captures: RawCapture[] = [];
  const pending: FolderScan['pending'] = [];
  for (const y of (await dirs(root)).filter(n => /^\d{4}$/.test(n)))
    for (const m of (await dirs(path.join(root, y))).filter(n => /^\d{2}$/.test(n)))
      for (const d of (await dirs(path.join(root, y, m))).filter(n => /^\d{2}$/.test(n)))
        for (const id of await dirs(path.join(root, y, m, d))) {
          const r = await readCapture(folder, `${y}/${m}/${d}`, id);
          if ('pending' in r) pending.push({ id, reason: r.pending }); else captures.push(r);
        }
  const key = (c: RawCapture) => String(c.metadata.captured_at ?? '');
  captures.sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : a.id < b.id ? -1 : 1));
  return { captures, pending };
}
