import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import sharp from 'sharp';
import type { Sharp } from 'sharp';
import decodeHeic from 'heic-decode';
import { thumbsDir } from '../core/paths.ts';

const QUALITY = 82;

function exists(p: string): boolean { try { return fs.statSync(p).isFile(); } catch { return false; } }

/** Writes `bytes` to a temp name in the same directory, then renames, so a killed run never leaves a half file. */
function writeAtomic(dest: string, bytes: Buffer): void {
  const tmp = `${dest}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  try { fs.writeFileSync(tmp, bytes); fs.renameSync(tmp, dest); }
  catch (e) { fs.rmSync(tmp, { force: true }); throw e; }
}

async function decoder(srcPath: string): Promise<Sharp> {
  const ext = path.extname(srcPath).toLowerCase();
  if (ext === '.heic' || ext === '.heif') {
    let img;
    try { img = await decodeHeic({ buffer: fs.readFileSync(srcPath) }); }
    catch (e) { throw new Error(`Cannot decode ${ext.slice(1)} file ${path.basename(srcPath)}: ${(e as Error).message}`); }
    return sharp(Buffer.from(img.data.buffer, img.data.byteOffset, img.data.byteLength), { raw: { width: img.width, height: img.height, channels: 4 } });
  }
  return sharp(srcPath);
}

async function render(srcPath: string, side: number): Promise<Buffer> {
  const ext = path.extname(srcPath).toLowerCase() || 'unknown';
  try {
    return await (await decoder(srcPath)).rotate()
      .resize({ width: side, height: side, fit: 'inside', withoutEnlargement: true })
      .flatten({ background: '#ffffff' }).jpeg({ quality: QUALITY }).toBuffer();
  } catch (e) {
    if (/^Cannot decode/.test((e as Error).message)) throw e;
    throw new Error(`Cannot decode ${ext.replace('.', '') || 'unknown'} file ${path.basename(srcPath)}: ${(e as Error).message}`);
  }
}

export async function ensureThumbs(srcPath: string, sha256: string): Promise<{ display: string; small: string }> {
  const dir = thumbsDir();
  const display = path.join(dir, `${sha256}-1024.jpg`);
  const small = path.join(dir, `${sha256}-256.jpg`);
  if (exists(display) && exists(small)) return { display, small };
  fs.mkdirSync(dir, { recursive: true });
  const [d, s] = [await render(srcPath, 1024), await render(srcPath, 256)];
  writeAtomic(display, d);
  writeAtomic(small, s);
  return { display, small };
}
