// Canvas helpers for the faces of desk objects: fitting text (measured, wrapped, ellipsised by grapheme, never by UTF-16
// unit), drawing pictures without stretching them, and loading pictures and first video frames from the same-origin /media
// URLs with a cache, a limit of six loads at once, and no retry storm: a failed URL is not tried again for a minute.
// Text from captures only ever reaches the screen through fillText here. Nothing touches the DOM until a function is called,
// so `node --test` can import the pure parts.
import { CanvasTexture, LinearFilter, LinearMipmapLinearFilter, SRGBColorSpace } from 'three';

// ---------------------------------------------------------------- text

type Measure = (s: string) => number;

const segmenter: { segment(s: string): Iterable<{ segment: string }> } | undefined =
  typeof Intl !== 'undefined' && 'Segmenter' in Intl ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : undefined;

/** The user-perceived characters of `s` (grapheme clusters; code points where Intl.Segmenter is missing). */
export function graphemes(s: string): string[] {
  return segmenter ? Array.from(segmenter.segment(s), g => g.segment) : Array.from(s);
}

/** The longest prefix of `units` (joined) that measures within `max`; at least one unit, so a line always makes progress. */
function longestFit(units: string[], max: number, measure: Measure, suffix = ''): number {
  let lo = 0, hi = units.length;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (measure(units.slice(0, mid).join('') + suffix) <= max) lo = mid; else hi = mid - 1;
  }
  return lo;
}

/** Breaks one word wider than the line into pieces that fit: by grapheme, and by code point inside a too-wide grapheme. */
function breakWord(word: string, max: number, measure: Measure): string[] {
  const out: string[] = [];
  let units = graphemes(word);
  while (units.length) {
    let n = longestFit(units, max, measure);
    if (n === 0) {
      // One grapheme wider than the line (a long emoji sequence on a tiny line): split it by code point, at least one.
      const cps = Array.from(units[0]);
      const k = Math.max(1, longestFit(cps, max, measure));
      out.push(cps.slice(0, k).join(''));
      const rest = cps.slice(k).join('');
      units = rest ? [rest, ...units.slice(1)] : units.slice(1);
      continue;
    }
    out.push(units.slice(0, n).join(''));
    units = units.slice(n);
  }
  return out;
}

/** `s` as is when it fits in `max`, else cut (by grapheme) so that it and an ellipsis fit; `always` adds the ellipsis anyway. */
export function ellipsise(s: string, max: number, measure: Measure, always = false): string {
  if (!always && measure(s) <= max) return s;
  const units = graphemes(s.trimEnd());
  const n = longestFit(units, max, measure, '…');
  const cut = units.slice(0, n).join('').trimEnd();
  return measure(cut + '…') <= max || !cut ? `${cut}…` : cut;
}

/**
 * Wraps `text` into at most `maxLines` lines no wider than `maxWidth` (as `measure` says): on spaces, on the text's own line
 * breaks, and inside a word that is wider than a line. When the text does not fit, the last line ends with an ellipsis.
 */
export function fitLines(text: string, maxWidth: number, maxLines: number, measure: Measure): string[] {
  if (!(maxLines >= 1) || !(maxWidth > 0)) return [];
  const lines: string[] = [];
  let overflow = false;
  outer: for (const para of text.split(/\r\n|\r|\n/)) {
    const words = para.split(/\s+/).filter(Boolean);
    if (!words.length) continue;
    let line = '';
    for (const word of words) {
      const candidate = line ? `${line} ${word}` : word;
      if (measure(candidate) <= maxWidth) { line = candidate; continue; }
      if (line) { lines.push(line); line = ''; if (lines.length > maxLines) { overflow = true; break outer; } }
      if (measure(word) <= maxWidth) { line = word; continue; }
      const pieces = breakWord(word, maxWidth, measure);
      for (let k = 0; k < pieces.length - 1; k++) {
        lines.push(pieces[k]);
        if (lines.length > maxLines) { overflow = true; break outer; }
      }
      line = pieces[pieces.length - 1] ?? '';
    }
    if (line) lines.push(line);
    if (lines.length > maxLines) { overflow = true; break; }
  }
  if (lines.length > maxLines) overflow = true;
  if (!overflow) return lines;
  const kept = lines.slice(0, maxLines);
  // The text goes on past this line: the ellipsis shows even when the line itself fits.
  kept[maxLines - 1] = ellipsise(kept[maxLines - 1], maxWidth, measure, true);
  return kept;
}

const RTL = /[\p{Script=Hebrew}\p{Script=Arabic}\p{Script=Syriac}\p{Script=Thaana}\p{Script=Nko}]/u;
/** True when the first letter of `text` belongs to a right-to-left script. */
export function isRtl(text: string): boolean {
  const first = text.match(/\p{L}/u)?.[0];
  return first !== undefined && RTL.test(first);
}

// ---------------------------------------------------------------- canvas

export interface Face { canvas: HTMLCanvasElement; ctx: CanvasRenderingContext2D; scale: number; w: number; h: number }

/**
 * A canvas for a face `w` × `h` desk units, `longSide` pixels on its longer side. The context is scaled so that drawing
 * code works in desk units.
 */
export function makeFace(w: number, h: number, longSide: number): Face {
  const scale = longSide / Math.max(w, h);
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(w * scale));
  canvas.height = Math.max(1, Math.round(h * scale));
  const ctx = canvas.getContext('2d')!;
  ctx.setTransform(canvas.width / w, 0, 0, canvas.height / h, 0, 0);
  return { canvas, ctx, scale, w, h };
}

let anisotropy = 1;
/** The renderer's anisotropic filtering, set once by the stage, for faces seen at a slant. */
export function setAnisotropy(n: number): void { anisotropy = Math.max(1, Math.min(8, n)); }

export function faceTexture(canvas: HTMLCanvasElement): CanvasTexture {
  const t = new CanvasTexture(canvas);
  t.colorSpace = SRGBColorSpace;
  t.minFilter = LinearMipmapLinearFilter;
  t.magFilter = LinearFilter;
  t.anisotropy = anisotropy;
  t.generateMipmaps = true;
  return t;
}

export function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
  const rr = Math.max(0, Math.min(r, w / 2, h / 2));
  ctx.beginPath();
  ctx.moveTo(x + rr, y);
  ctx.arcTo(x + w, y, x + w, y + h, rr);
  ctx.arcTo(x + w, y + h, x, y + h, rr);
  ctx.arcTo(x, y + h, x, y, rr);
  ctx.arcTo(x, y, x + w, y, rr);
  ctx.closePath();
}

export type Picture = HTMLImageElement | HTMLCanvasElement;
const sizeOf = (p: Picture) => (p instanceof HTMLImageElement ? { w: p.naturalWidth, h: p.naturalHeight } : { w: p.width, h: p.height });

/** Draws `pic` to fill the box, cropping the overflow evenly (never stretched). */
export function drawCover(ctx: CanvasRenderingContext2D, pic: Picture, x: number, y: number, w: number, h: number): void {
  const { w: pw, h: ph } = sizeOf(pic);
  if (!pw || !ph) return;
  const s = Math.max(w / pw, h / ph), sw = w / s, sh = h / s;
  ctx.drawImage(pic, (pw - sw) / 2, (ph - sh) / 2, sw, sh, x, y, w, h);
}

/** Draws `pic` whole inside the box, centred (never stretched). Returns the rectangle it took. */
export function drawContain(ctx: CanvasRenderingContext2D, pic: Picture, x: number, y: number, w: number, h: number): { x: number; y: number; w: number; h: number } {
  const { w: pw, h: ph } = sizeOf(pic);
  if (!pw || !ph) return { x, y, w: 0, h: 0 };
  const s = Math.min(w / pw, h / ph), dw = pw * s, dh = ph * s;
  const r = { x: x + (w - dw) / 2, y: y + (h - dh) / 2, w: dw, h: dh };
  ctx.drawImage(pic, r.x, r.y, r.w, r.h);
  return r;
}

/** How far the picture's shape is from the box's: 1 is the same shape. */
export function aspectMismatch(pic: Picture, w: number, h: number): number {
  const { w: pw, h: ph } = sizeOf(pic);
  if (!pw || !ph) return 1;
  const a = pw / ph, b = w / h;
  return Math.max(a, b) / Math.min(a, b);
}

export interface TextStyle { font: string; color: string; lineHeight: number; align?: 'start' | 'center' }

/**
 * Writes `text` wrapped into the box (x, y, width; at most `maxLines`), top down, right-aligned for right-to-left text.
 * Returns the height it used.
 */
export function drawText(ctx: CanvasRenderingContext2D, text: string, x: number, y: number, width: number, maxLines: number, style: TextStyle): number {
  ctx.save();
  ctx.font = style.font;
  ctx.fillStyle = style.color;
  ctx.textBaseline = 'top';
  const rtl = isRtl(text);
  ctx.direction = rtl ? 'rtl' : 'ltr';
  const lines = fitLines(text, width, maxLines, s => ctx.measureText(s).width);
  const centre = style.align === 'center';
  ctx.textAlign = centre ? 'center' : rtl ? 'right' : 'left';
  const tx = centre ? x + width / 2 : rtl ? x + width : x;
  lines.forEach((l, k) => ctx.fillText(l, tx, y + k * style.lineHeight));
  ctx.restore();
  return lines.length * style.lineHeight;
}

/** One line, ellipsised to `width`. */
export function drawLine(ctx: CanvasRenderingContext2D, text: string, x: number, y: number, width: number, style: TextStyle): void {
  drawText(ctx, text.replace(/\s+/g, ' ').trim(), x, y, width, 1, style);
}

// ---------------------------------------------------------------- loading

export const MAX_LOADS = 6;
/** A URL that failed is not asked for again for this long. */
export const RETRY_AFTER_MS = 60_000;
/** Decoded pictures kept, by pixel count (about 700 small thumbnails, or 45 full ones). */
const CACHE_PIXELS = 48_000_000;
const VIDEO_TIMEOUT_MS = 8000;
const IMAGE_TIMEOUT_MS = 20000;

export interface LoadOptions {
  /** Asked when the load reaches the front of the queue: false skips it (the object went away meanwhile). */
  wanted?: () => boolean;
  /** Jumps the queue (a full-size picture for an object close to the camera). */
  urgent?: boolean;
}

interface Job { key: string; run: () => Promise<Picture | null>; wanted: (() => boolean)[]; urgent: boolean;
  settle: (p: Picture | null) => void }

const cache = new Map<string, { picture: Picture; pixels: number }>();
let cachedPixels = 0;
const pending = new Map<string, Job>();
const failed = new Map<string, number>();
const queue: Job[] = [];
let inFlight = 0;

function remember(key: string, picture: Picture): void {
  const { w, h } = sizeOf(picture);
  cache.set(key, { picture, pixels: w * h });
  cachedPixels += w * h;
  for (const [k, v] of cache) {
    if (cachedPixels <= CACHE_PIXELS || k === key) break;
    cache.delete(k);
    cachedPixels -= v.pixels;
  }
}

function pump(): void {
  while (inFlight < MAX_LOADS && queue.length) {
    const job = queue.shift()!;
    if (!job.wanted.some(w => w())) { pending.delete(job.key); job.settle(null); continue; }
    inFlight++;
    job.run().catch(() => null).then(p => {
      inFlight--;
      pending.delete(job.key);
      if (p) remember(job.key, p); else failed.set(job.key, performance.now());
      job.settle(p);
      pump();
    });
  }
}

function request(key: string, run: () => Promise<Picture | null>, opts: LoadOptions): Promise<Picture | null> {
  const hit = cache.get(key);
  if (hit) { cache.delete(key); cache.set(key, hit); return Promise.resolve(hit.picture); }
  const failedAt = failed.get(key);
  if (failedAt !== undefined) {
    if (performance.now() - failedAt < RETRY_AFTER_MS) return Promise.resolve(null);
    failed.delete(key);
  }
  const wanted = opts.wanted ?? (() => true);
  const existing = pending.get(key);
  if (existing) {
    existing.wanted.push(wanted);
    const at = queue.indexOf(existing);
    if (opts.urgent && !existing.urgent && at >= 0) {
      existing.urgent = true;
      queue.splice(at, 1);
      queue.unshift(existing);
    }
    return new Promise(resolve => { const prev = existing.settle; existing.settle = p => { prev(p); resolve(p); }; });
  }
  return new Promise(resolve => {
    const job: Job = { key, run, wanted: [wanted], urgent: !!opts.urgent, settle: resolve };
    pending.set(key, job);
    if (job.urgent) queue.unshift(job); else queue.push(job);
    pump();
  });
}

/** The picture at a same-origin URL, decoded; null when it cannot be had (the caller draws its placeholder). */
export function loadPicture(url: string, opts: LoadOptions = {}): Promise<Picture | null> {
  return request(url, () => new Promise<Picture | null>(resolve => {
    const img = new Image();
    img.decoding = 'async';
    const timer = setTimeout(() => resolve(null), IMAGE_TIMEOUT_MS);
    img.onload = () => {
      img.decode().catch(() => undefined).then(() => { clearTimeout(timer); resolve(img.naturalWidth > 0 ? img : null); });
    };
    img.onerror = () => { clearTimeout(timer); resolve(null); };
    img.src = url;
  }), opts);
}

/** A picture of a video at 0.1 s (a <video> seeked there and drawn to a canvas, at most 1024 px); null when it cannot be read. */
export function loadVideoFrame(url: string, opts: LoadOptions = {}): Promise<Picture | null> {
  return request(`${url}#frame`, () => new Promise<Picture | null>(resolve => {
    const video = document.createElement('video');
    let done = false;
    const finish = (p: Picture | null) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      video.removeAttribute('src');
      video.load();
      resolve(p);
    };
    const timer = setTimeout(() => finish(null), VIDEO_TIMEOUT_MS);
    video.muted = true;
    video.playsInline = true;
    video.preload = 'auto';
    video.onerror = () => finish(null);
    video.onloadeddata = () => {
      const d = Number.isFinite(video.duration) ? video.duration : 1;
      video.currentTime = Math.min(0.1, d / 2);
    };
    video.onseeked = () => {
      const vw = video.videoWidth, vh = video.videoHeight;
      if (!vw || !vh) { finish(null); return; }
      const s = Math.min(1, 1024 / Math.max(vw, vh));
      const c = document.createElement('canvas');
      c.width = Math.max(1, Math.round(vw * s));
      c.height = Math.max(1, Math.round(vh * s));
      try { c.getContext('2d')!.drawImage(video, 0, 0, c.width, c.height); finish(c); }
      catch { finish(null); }
    };
    video.src = url;
  }), opts);
}

/** A loaded picture, if it is already in the cache (to draw a full-size face at once from the small picture). */
export function cachedPicture(url: string): Picture | undefined {
  return cache.get(url)?.picture;
}

/** Loads waiting and in flight, for the scale checks. */
export function loadStats(): { queued: number; inFlight: number; cached: number; cachedPixels: number; failed: number } {
  return { queued: queue.length, inFlight, cached: cache.size, cachedPixels, failed: failed.size };
}
