// Serving one file the index recorded (spec section 7, "The local server"): only a path from the index's media table, only when
// its real path is inside the Hippo folder or the thumbnails directory, inline only for a fixed list of harmless types.
import fs from 'node:fs';
import path from 'node:path';
import type http from 'node:http';

/** Types sent inline, by declared type. Everything else (HTML, SVG, XML, scripts, whatever the manifest says) is an attachment. */
const INLINE: Record<string, string> = {
  'image/jpeg': 'image/jpeg', 'image/png': 'image/png', 'image/gif': 'image/gif', 'image/webp': 'image/webp',
  'image/heic': 'image/heic', 'image/heif': 'image/heif',
  'audio/mp4': 'audio/mp4', 'audio/x-m4a': 'audio/x-m4a', 'audio/mpeg': 'audio/mpeg', 'audio/wav': 'audio/wav', 'audio/x-wav': 'audio/x-wav',
  'audio/aiff': 'audio/aiff', 'audio/x-aiff': 'audio/x-aiff', 'audio/x-caf': 'audio/x-caf',
  'video/quicktime': 'video/quicktime', 'video/mp4': 'video/mp4', 'video/x-m4v': 'video/x-m4v', 'video/3gpp': 'video/3gpp',
  'application/pdf': 'application/pdf',
  'text/plain': 'text/plain; charset=utf-8',
};

export const MEDIA_CSP = "default-src 'none'; sandbox";
export const MEDIA_CACHE = 'private, max-age=3600';

/** The Content-Type a declared type is sent with, and whether it may be shown inline. */
export function servedType(mime: string): { type: string; inline: boolean } {
  const type = INLINE[mime.split(';')[0].trim().toLowerCase()];
  return type ? { type, inline: true } : { type: 'application/octet-stream', inline: false };
}

export type RangeResult = { start: number; end: number } | 'whole' | 'unsatisfiable';

/** One byte range of a `Range` header: `bytes=a-b`, `bytes=a-`, `bytes=-n`. Several ranges: the whole file. Malformed or out
 *  of the file: unsatisfiable. */
export function parseRange(header: string | undefined, size: number): RangeResult {
  if (header === undefined) return 'whole';
  const m = /^\s*bytes\s*=(.*)$/i.exec(header);
  if (!m) return 'unsatisfiable';
  if (m[1].includes(',')) return 'whole';
  const r = /^\s*(\d*)\s*-\s*(\d*)\s*$/.exec(m[1]);
  if (!r || (r[1] === '' && r[2] === '') || size === 0) return 'unsatisfiable';
  if (r[1] === '') {
    const n = Number(r[2]);
    return n > 0 ? { start: Math.max(0, size - n), end: size - 1 } : 'unsatisfiable';
  }
  const start = Number(r[1]);
  const end = r[2] === '' ? size - 1 : Number(r[2]);
  if (!Number.isSafeInteger(start) || start >= size || end < start) return 'unsatisfiable';
  return { start, end: Math.min(end, size - 1) };
}

export function inside(base: string, p: string): boolean {
  const r = path.relative(base, p);
  return r !== '' && !r.startsWith('..') && !path.isAbsolute(r);
}

function realRoots(roots: string[]): string[] {
  const out: string[] = [];
  for (const r of roots) { try { out.push(fs.realpathSync(r)); } catch { /* not there: nothing inside it is served */ } }
  return out;
}

/** Opens `file` when its real path lies inside one of `roots` (real paths too) and it is a regular file. */
export function openInside(file: string, roots: string[]): { fd: number; size: number; real: string } | undefined {
  let real: string;
  try { real = fs.realpathSync(file); } catch { return undefined; }
  if (!realRoots(roots).some(root => inside(root, real))) return undefined;
  let fd: number;
  try { fd = fs.openSync(real, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0)); } catch { return undefined; }
  try {
    const st = fs.fstatSync(fd);
    if (st.isFile()) return { fd, size: st.size, real };
  } catch { /* fall through */ }
  fs.closeSync(fd);
  return undefined;
}

/** Streams an open file (or one range of it) and closes it; the stream is destroyed when the client goes away. */
export function streamFile(req: http.IncomingMessage, res: http.ServerResponse, f: { fd: number; size: number },
  headers: Record<string, string>, ranged: boolean): void {
  const range = ranged ? parseRange(req.headers.range, f.size) : 'whole';
  if (range === 'unsatisfiable') {
    fs.closeSync(f.fd);
    res.writeHead(416, { ...headers, 'Content-Range': `bytes */${f.size}`, 'Content-Length': '0' });
    res.end();
    return;
  }
  const { start, end } = range === 'whole' ? { start: 0, end: f.size - 1 } : range;
  const length = Math.max(0, end - start + 1);
  const out: Record<string, string> = { ...headers, 'Content-Length': String(length) };
  if (ranged) out['Accept-Ranges'] = 'bytes';
  if (range !== 'whole') out['Content-Range'] = `bytes ${start}-${end}/${f.size}`;
  res.writeHead(range === 'whole' ? 200 : 206, out);
  if (length === 0) { fs.closeSync(f.fd); res.end(); return; }
  const stream = fs.createReadStream('', { fd: f.fd, start, end, autoClose: true });
  res.on('close', () => stream.destroy());
  stream.on('error', () => res.destroy());
  stream.pipe(res);
}

/** Sends one media file: false (nothing written) when it is missing or its real path is outside `roots`. */
export function serveMedia(req: http.IncomingMessage, res: http.ServerResponse, file: string, mime: string, roots: string[]): boolean {
  const f = openInside(file, roots);
  if (!f) return false;
  const { type, inline } = servedType(mime);
  const headers: Record<string, string> = { 'Content-Type': type, 'Content-Security-Policy': MEDIA_CSP, 'Cache-Control': MEDIA_CACHE };
  if (!inline) {
    const name = path.basename(f.real).replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 100) || 'file';
    headers['Content-Disposition'] = `attachment; filename="${name}"`;
  }
  streamFile(req, res, f, headers, true);
  return true;
}
