// `hippo sample`: writes a seeded Hippo folder of invented captures (design section 5, "Commands"), with device enrichment and
// the server enrichment `hippo enrich` would write, so the folder needs no model call. Used for demos, for developing the desk and
// in its tests. Every random choice comes from one seeded generator and every timestamp from `end` and the seed, so the same
// seed, count and end give a byte-identical folder.
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { scanFolder } from '../core/folder.ts';
import { deriveCircumstances } from '../core/circumstance.ts';
import type { Kind } from '../core/types.ts';
import { inputDigest } from '../enrich/digest.ts';
import { normalize } from '../enrich/normalize.ts';
import { picturesToSend } from '../enrich/prompt.ts';
import { composeServerDoc, stableJson, writeServerDoc } from '../enrich/serverdoc.ts';
import { CLIPS, FILES, LINK_NOTES, LOCALITY, NAMES, NOTES, ONE_NAME, PAGES, PHOTOS, PLACES, SCREENS, STOPWORDS, TEXT_COMMENTS,
  TOPIC_COLORS, TRANSCRIPTS, TWO_NAMES, VOICE_COMMENTS, YOUTUBE_SHORTS, YOUTUBE_VIDEOS, ZONE } from './sample-data.ts';
import type { ClipItem, FileItem, PageItem, PhotoItem, ScreenItem, TextItem, VideoItem } from './sample-data.ts';

export interface SampleOptions { out: string; count?: number; seed?: number; end?: string }

const here = path.dirname(fileURLToPath(import.meta.url));
const CLIP = path.resolve(here, '../../assets/sample/clip.mov');
const REPO_FIXTURES = path.resolve(here, '../../../fixtures');
const DAYS = 42;
const MAX_COUNT = 5000;
const PRODUCER = { app_version: '0.1.0', build: '1', os_version: 'sample' };
const DEVICE_PRODUCER = { name: 'hippo-sample', version: '1', build: '1' };

// ---- seeded randomness ----

/** mulberry32: a small, fast, seeded generator of numbers in [0, 1). */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
type Rng = () => number;
const int = (r: Rng, lo: number, hi: number) => lo + Math.floor(r() * (hi - lo + 1));
const between = (r: Rng, lo: number, hi: number) => lo + r() * (hi - lo);
const pick = <T>(r: Rng, xs: readonly T[]): T => xs[Math.floor(r() * xs.length)];
const chance = (r: Rng, p: number) => r() < p;
const round = (x: number, places: number) => { const f = 10 ** places; return Math.round(x * f) / f; };
function weighted<T>(r: Rng, items: readonly (readonly [T, number])[]): T {
  const total = items.reduce((s, [, w]) => s + w, 0);
  let x = r() * total;
  for (const [v, w] of items) { x -= w; if (x < 0) return v; }
  return items[items.length - 1][0];
}
function shuffle<T>(r: Rng, xs: readonly T[]): T[] {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}
/** A lowercase UUID v4 made from the generator. */
function uuid(r: Rng): string {
  const b = Array.from({ length: 16 }, () => Math.floor(r() * 256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
/** Cycles through a shuffled copy, reshuffling each round, so every item is used before any repeats. */
function deck<T>(r: Rng, xs: readonly T[]): () => T {
  let order: T[] = [];
  return () => { if (order.length === 0) order = shuffle(r, xs); return order.pop()!; };
}

// ---- time in Europe/Lisbon ----

const ZONE_FORMAT = new Intl.DateTimeFormat('en-US', { timeZone: ZONE, year: 'numeric', month: 'numeric', day: 'numeric',
  hour: 'numeric', minute: 'numeric', second: 'numeric', hourCycle: 'h23' });
const pad = (n: number, w = 2) => String(n).padStart(w, '0');

/** Seconds east of UTC in the zone at the instant `ms`. */
function zoneOffset(ms: number): number {
  const parts = ZONE_FORMAT.formatToParts(new Date(ms));
  const get = (t: string) => Number(parts.find(p => p.type === t)!.value);
  const asUtc = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour') % 24, get('minute'), get('second'));
  return Math.round((asUtc - Math.floor(ms / 1000) * 1000) / 1000);
}
/** The UTC instant of a wall-clock time in the zone. */
function zoneToUtc(date: string, h: number, mi: number, s: number): number {
  const [y, mo, d] = date.split('-').map(Number);
  const local = Date.UTC(y, mo - 1, d, h, mi, s);
  return local - zoneOffset(local - zoneOffset(local) * 1000) * 1000;
}
interface Local { datetime: string; offset: number; date: string; hour: number; minute: number }
function local(ms: number): Local {
  const offset = zoneOffset(ms);
  const iso = new Date(Math.floor(ms / 1000) * 1000 + offset * 1000).toISOString().slice(0, 19);
  const a = Math.abs(offset);
  const datetime = `${iso}${offset < 0 ? '-' : '+'}${pad(Math.floor(a / 3600))}:${pad(Math.floor(a / 60) % 60)}`;
  return { datetime, offset, date: iso.slice(0, 10), hour: Number(iso.slice(11, 13)), minute: Number(iso.slice(14, 16)) };
}
const stamp = (ms: number) => new Date(ms).toISOString();
const addDays = (date: string, n: number) => {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
};
function todayLocal(): string {
  const d = new Date();
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// ---- stable files ----

/** The server writer's stable JSON (sorted keys, two-space indent), for every JSON file in the sample. */
const json = (v: unknown) => Buffer.from(stableJson(v), 'utf8');
const sha256 = (b: Buffer) => crypto.createHash('sha256').update(b).digest('hex');

// ---- the plan ----

type Ctx = 'car' | 'walk' | 'still';
type Content =
  | { kind: 'link'; video?: VideoItem; short?: boolean; mobile?: boolean; page?: PageItem }
  | { kind: 'photo'; item: PhotoItem }
  | { kind: 'screenshot'; item: ScreenItem }
  | { kind: 'note'; item: TextItem }
  | { kind: 'recording'; item: TextItem }
  | { kind: 'video'; item: ClipItem }
  | { kind: 'file'; item: FileItem };

interface Plan {
  id: string; kind: Kind; content: Content; seed: number;
  t: number;                               // captured_at, UTC milliseconds
  ctx: Ctx; headphones: boolean; motion: boolean; located: boolean; cluster: number;
  names: string[];                         // people mentioned in its text
  textComment: boolean; audioComment: boolean;
  prev?: { id: string; seconds: number };
}

const SHARES: [Kind, number][] = [['link', 0.30], ['photo', 0.20], ['screenshot', 0.15], ['note', 0.17], ['recording', 0.12],
  ['video', 0.03], ['file', 0.03]];
const HOURS: [number, number][] = [[7, 1], [8, 3], [9, 3], [10, 2], [11, 2], [12, 3], [13, 3], [14, 2], [15, 2], [16, 2], [17, 3],
  [18, 4], [19, 4], [20, 3], [21, 3], [22, 2], [23, 1]];
const CAR_HOURS: [number, number][] = [[8, 3], [9, 2], [13, 1], [17, 2], [18, 3], [19, 3], [20, 2], [21, 1]];
const WALK_HOURS: [number, number][] = [[9, 1], [10, 2], [11, 2], [12, 2], [13, 2], [14, 2], [15, 2], [16, 2], [17, 2], [18, 2], [19, 1]];

/** Counts per kind: shares of `count`, every kind at least once when there is room, links take the rest. */
function kindCounts(count: number): Map<Kind, number> {
  const m = new Map<Kind, number>();
  for (const [k, s] of SHARES) m.set(k, Math.round(count * s));
  if (count >= SHARES.length) for (const [k] of SHARES) if (m.get(k)! < 1) m.set(k, 1);
  let rest = count - [...m.values()].reduce((a, b) => a + b, 0);
  m.set('link', m.get('link')! + rest);
  for (const [k] of [...SHARES].reverse()) {          // a very small count: take back from the others until it fits
    while (m.get('link')! < 0 && m.get(k)! > 0 && k !== 'link') { m.set(k, m.get(k)! - 1); m.set('link', m.get('link')! + 1); }
  }
  rest = count - [...m.values()].reduce((a, b) => a + b, 0);
  m.set('photo', m.get('photo')! + rest);
  return m;
}

function plan(count: number, seed: number, end: string): Plan[] {
  const r = mulberry32(seed);
  const counts = kindCounts(count);
  const plans: Plan[] = [];
  const add = (kind: Kind, content: Content) => plans.push({ id: uuid(r), kind, content, seed: Math.floor(r() * 2 ** 32), t: 0,
    ctx: 'still', headphones: false, motion: false, located: true, cluster: 0, names: [], textComment: false, audioComment: false });

  // Links: a third YouTube (at least 8 within the last 7 days, some of them shorts), the rest news, recipes, shops, maps and pages.
  const nLinks = counts.get('link')!;
  const nYouTube = Math.min(nLinks, Math.max(Math.round(nLinks / 3), 8));
  const nRecent = Math.min(nYouTube, Math.max(8, Math.round(nYouTube * 0.3)));
  const videos = deck(r, YOUTUBE_VIDEOS), shorts = deck(r, YOUTUBE_SHORTS), pages = deck(r, PAGES);
  const recent: Plan[] = [];
  for (let i = 0; i < nYouTube; i++) {
    const isRecent = i < nRecent;
    const short = isRecent ? i % 2 === 0 : chance(r, 0.3);
    add('link', { kind: 'link', video: short ? shorts() : videos(), short, mobile: !isRecent && chance(r, 0.2) });
    if (isRecent) recent.push(plans[plans.length - 1]);
  }
  for (let i = nYouTube; i < nLinks; i++) add('link', { kind: 'link', page: pages() });
  const photos = deck(r, PHOTOS), screens = deck(r, SCREENS), notes = deck(r, NOTES), talks = deck(r, TRANSCRIPTS),
    clips = deck(r, CLIPS), files = deck(r, FILES);
  for (let i = 0; i < counts.get('photo')!; i++) add('photo', { kind: 'photo', item: photos() });
  for (let i = 0; i < counts.get('screenshot')!; i++) add('screenshot', { kind: 'screenshot', item: screens() });
  for (let i = 0; i < counts.get('note')!; i++) add('note', { kind: 'note', item: notes() });
  for (let i = 0; i < counts.get('recording')!; i++) add('recording', { kind: 'recording', item: talks() });
  for (let i = 0; i < counts.get('video')!; i++) add('video', { kind: 'video', item: clips() });
  for (let i = 0; i < counts.get('file')!; i++) add('file', { kind: 'file', item: files() });

  // Circumstances: about 12% in a car (three of the recent YouTube captures among them), 12% walking, 8% on headphones.
  const eligible = plans.filter(p => p.kind !== 'file');
  for (const i of [1, 2, 5]) if (recent[i]) recent[i].ctx = 'car';
  const take = (n: number, from: Plan[], set: (p: Plan) => void) => { for (const p of shuffle(r, from).slice(0, Math.max(0, n))) set(p); };
  const forcedCars = plans.filter(p => p.ctx === 'car').length;
  take(Math.round(count * 0.12) - forcedCars, eligible.filter(p => p.ctx === 'still' && !recent.includes(p)), p => { p.ctx = 'car'; });
  take(Math.round(count * 0.12), eligible.filter(p => p.ctx === 'still' && !recent.includes(p)), p => { p.ctx = 'walk'; });
  take(Math.round(count * 0.08), eligible.filter(p => p.ctx !== 'car'), p => { p.headphones = true; });
  for (const p of plans) p.motion = p.ctx !== 'still' || chance(r, 0.4);

  // Places: five clusters; about 15% have no location (never one in a car or walking: those carry a speed).
  const clusterOf = () => weighted(r, PLACES.map((pl, i) => [i, pl.weight] as const));
  for (const p of plans) p.cluster = clusterOf();
  take(Math.round(count * 0.15), plans.filter(p => p.ctx === 'still'), p => { p.located = false; });

  // People: about 25% mention one or two of six names; the first six mentions name each once, so all six occur.
  for (const p of plans) if (p.content.kind === 'screenshot' && p.content.item.style === 'chat') p.names = ['?'];
  const mentioning = shuffle(r, plans.filter(p => p.names.length === 0))
    .slice(0, Math.max(0, Math.round(count * 0.25) - plans.filter(p => p.names.length).length));
  const mentioned = shuffle(r, [...mentioning, ...plans.filter(p => p.names.length)]);
  mentioned.forEach((p, i) => {
    const a = i < NAMES.length ? NAMES[i] : pick(r, NAMES);
    const chat = p.content.kind === 'screenshot' && p.content.item.style === 'chat';
    p.names = !chat && chance(r, 0.25) ? [a, pick(r, NAMES.filter(n => n !== a))] : [a];
  });
  for (const p of plans) { p.textComment = p.kind === 'file' ? p.names.length > 0 : chance(r, 0.1); p.audioComment = chance(r, 0.03); }

  // Times: 42 days ending at `end`, some days busier, plausible hours. The recent YouTube captures fall in the last 7 days.
  const days = Array.from({ length: DAYS }, (_, i) => addDays(end, i - (DAYS - 1)));
  const dayWeights = days.map(() => (chance(r, 0.2) ? between(r, 2, 3.5) : between(r, 0.4, 1.4)));
  const at = (p: Plan, date: string) => {
    const hour = weighted(r, p.ctx === 'car' ? CAR_HOURS : p.ctx === 'walk' ? WALK_HOURS : HOURS);
    p.t = zoneToUtc(date, hour, int(r, 0, 59), int(r, 0, 59)) + int(r, 0, 999);
  };
  recent.forEach((p, i) => at(p, days[DAYS - 1 - (i * 3) % 7]));
  for (const p of plans) if (!recent.includes(p)) at(p, weighted(r, days.map((d, i) => [d, dayWeights[i]] as const)));

  // Bursts: runs of 3 to 5 captures within a minute, at the place of the first.
  const burstable = shuffle(r, plans.filter(p => p.ctx === 'still' && !recent.includes(p) && ['photo', 'screenshot', 'note', 'link'].includes(p.kind)));
  for (let b = 0; b < Math.max(1, Math.round(count / 50)) && burstable.length >= 3; b++) {
    const run = burstable.splice(0, int(r, 3, Math.min(5, burstable.length)));
    const lead = run[0];
    if (local(lead.t).hour >= 23) lead.t -= 3_600_000;
    let t = lead.t;
    for (const p of run.slice(1)) {
      t += int(r, 6, 14) * 1000 + int(r, 0, 999);
      Object.assign(p, { t, located: lead.located, cluster: lead.cluster, headphones: lead.headphones });
    }
  }

  plans.sort((a, b) => a.t - b.t || (a.id < b.id ? -1 : 1));
  for (let i = 1; i < plans.length; i++) plans[i].prev = { id: plans[i - 1].id, seconds: round((plans[i].t - plans[i - 1].t) / 1000, 1) };
  return plans;
}

// ---- drawing ----

const FONT = 'Helvetica, Arial, sans-serif';
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const n1 = (x: number) => round(x, 1);
function hsl(h: number, s: number, l: number): string {
  h = ((h % 360) + 360) % 360; s /= 100; l /= 100;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => { const k = (n + h / 30) % 12; return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)); };
  return '#' + [f(0), f(8), f(4)].map(x => Math.round(x * 255).toString(16).padStart(2, '0')).join('');
}
const grad = (id: string, stops: [number, string][], horizontal = false) =>
  `<linearGradient id="${id}" x1="0" y1="0" x2="${horizontal ? 1 : 0}" y2="${horizontal ? 0 : 1}">`
  + stops.map(([o, c]) => `<stop offset="${o}" stop-color="${c}"/>`).join('') + '</linearGradient>';
const svg = (w: number, h: number, body: string, defs = '') =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><defs>${defs}</defs>${body}</svg>`;
function text(x: number, y: number, size: number, fill: string, s: string, o: { weight?: number; anchor?: string; opacity?: number } = {}) {
  return `<text x="${n1(x)}" y="${n1(y)}" font-family="${FONT}" font-size="${size}" font-weight="${o.weight ?? 400}" fill="${fill}"`
    + `${o.anchor ? ` text-anchor="${o.anchor}"` : ''}${o.opacity !== undefined ? ` opacity="${o.opacity}"` : ''}>${esc(s)}</text>`;
}
/** Splits `s` into lines of at most `max` characters, at spaces. */
function wrap(s: string, max: number, lines = 3): string[] {
  const out: string[] = [];
  let cur = '';
  for (const w of s.split(/\s+/)) {
    if (cur && (cur + ' ' + w).length > max) { out.push(cur); cur = w; } else cur = cur ? `${cur} ${w}` : w;
  }
  if (cur) out.push(cur);
  if (out.length > lines) { out.length = lines; out[lines - 1] = out[lines - 1].replace(/\s*\S*$/, '') + '…'; }
  return out;
}

const W = 1200, H = 900;

function scene(name: PhotoItem['scene'], r: Rng): string {
  const hue = int(r, -12, 12);
  switch (name) {
    case 'sunset': {
      const horizon = 560, sunX = between(r, 300, 900), sunY = between(r, 430, 500), deck = 470;
      const x1 = between(r, 250, 420), x2 = between(r, 760, 950), top = 250;
      let body = `<rect width="${W}" height="${horizon}" fill="url(#sky)"/>`
        + `<circle cx="${n1(sunX)}" cy="${n1(sunY)}" r="${n1(between(r, 70, 105))}" fill="${hsl(45 + hue, 100, 86)}"/>`
        + `<rect y="${horizon}" width="${W}" height="${H - horizon}" fill="url(#water)"/>`;
      for (let i = 0; i < 8; i++) {
        const w = 300 - i * 30;
        body += `<rect x="${n1(sunX - w / 2 + between(r, -20, 20))}" y="${horizon + 18 + i * 40}" width="${w}" height="10" rx="5" fill="${hsl(40 + hue, 100, 75)}" opacity="${round(0.7 - i * 0.07, 2)}"/>`;
      }
      const ink = hsl(340 + hue, 40, 12);
      body += `<rect x="-10" y="${deck}" width="${W + 20}" height="16" fill="${ink}"/>`
        + `<rect x="${n1(x1)}" y="${top}" width="26" height="${horizon - top}" fill="${ink}"/><rect x="${n1(x2)}" y="${top}" width="26" height="${horizon - top}" fill="${ink}"/>`
        + `<path d="M -10 ${top + 120} Q ${n1(x1 / 2)} ${deck - 10} ${n1(x1 + 13)} ${top} Q ${n1((x1 + x2) / 2 + 13)} ${deck + 30} ${n1(x2 + 13)} ${top} Q ${n1((x2 + W) / 2 + 13)} ${deck - 10} ${W + 10} ${top + 120}" fill="none" stroke="${ink}" stroke-width="7"/>`;
      for (let x = 40; x < W; x += 60) body += `<line x1="${x}" y1="${deck}" x2="${x}" y2="${deck - 60}" stroke="${ink}" stroke-width="3" opacity="0.7"/>`;
      return svg(W, H, body, grad('sky', [[0, hsl(270 + hue, 45, 22)], [0.6, hsl(15 + hue, 80, 55)], [1, hsl(42 + hue, 95, 70)]])
        + grad('water', [[0, hsl(230, 40, 30)], [1, hsl(240, 45, 10)]]));
    }
    case 'tram': {
      const g = (x: number) => 760 - 0.2 * x;
      const pastel = ['#f6d3a5', '#f2b5a0', '#c9e0d0', '#f7e6a3', '#d6c7e8', '#a8d0e6', '#f4c7c3'];
      let body = `<rect width="${W}" height="${H}" fill="url(#sky)"/>`;
      for (let x = -40, i = 0; x < W; x += 175, i++) {
        const h = between(r, 300, 420), y = g(x + 175) - h;
        body += `<rect x="${x}" y="${n1(y)}" width="178" height="${n1(h + 260)}" fill="${pick(r, pastel)}" stroke="#7a6a5a" stroke-width="2"/>`;
        for (let row = 0; row < 3; row++) for (let col = 0; col < 3; col++)
          body += `<rect x="${x + 25 + col * 50}" y="${n1(y + 40 + row * 90)}" width="28" height="48" fill="#3b4a6b"/>`;
      }
      body += `<polygon points="0,${g(0)} ${W},${g(W)} ${W},${H} 0,${H}" fill="#8a8580"/>`
        + `<line x1="0" y1="${g(0) + 40}" x2="${W}" y2="${g(W) + 40}" stroke="#444" stroke-width="6"/><line x1="0" y1="${g(0) + 80}" x2="${W}" y2="${g(W) + 80}" stroke="#444" stroke-width="6"/>`
        + `<line x1="0" y1="${g(0) - 420}" x2="${W}" y2="${g(W) - 420}" stroke="#333" stroke-width="4"/>`;
      const cx = between(r, 450, 750), gy = g(cx) + 40;
      let tram = `<rect x="-240" y="-240" width="480" height="220" rx="26" fill="${hsl(46 + hue, 92, 55)}" stroke="#5a4500" stroke-width="4"/>`
        + `<rect x="-240" y="-110" width="480" height="20" fill="#ffffff"/>`
        + `<line x1="0" y1="-240" x2="70" y2="-${n1(gy - (g(cx + 70) - 420))}" stroke="#333" stroke-width="7"/>`;
      for (let i = 0; i < 5; i++) tram += `<rect x="${-210 + i * 86}" y="-215" width="62" height="78" rx="6" fill="#9fd3f0" stroke="#333" stroke-width="3"/>`;
      tram += `<circle cx="-150" cy="-12" r="24" fill="#222"/><circle cx="150" cy="-12" r="24" fill="#222"/>`;
      body += `<g transform="translate(${n1(cx)} ${n1(gy)}) rotate(-11.31)">${tram}</g>`;
      return svg(W, H, body, grad('sky', [[0, hsl(205 + hue, 70, 62)], [1, hsl(200 + hue, 70, 88)]]));
    }
    case 'fruit': {
      const wall = int(r, 0, 1) ? 30 + hue : 200 + hue;
      let body = `<rect width="${W}" height="${H}" fill="url(#wall)"/><rect y="560" width="${W}" height="340" fill="${hsl(28, 45, 38)}"/>`;
      for (let y = 600; y < H; y += 70) body += `<line x1="0" y1="${y}" x2="${W}" y2="${y}" stroke="${hsl(28, 45, 30)}" stroke-width="4"/>`;
      body += `<ellipse cx="600" cy="560" rx="330" ry="62" fill="#e9e4dc"/>`;
      const oranges = int(r, 3, 4);
      for (let i = 0; i < oranges; i++) {
        const x = 400 + i * (400 / Math.max(1, oranges - 1)) + between(r, -20, 20), y = between(r, 500, 540), rad = between(r, 72, 88);
        body += `<circle cx="${n1(x)}" cy="${n1(y)}" r="${n1(rad)}" fill="${hsl(30, 92, 52)}" stroke="${hsl(25, 90, 40)}" stroke-width="3"/>`
          + `<circle cx="${n1(x - rad / 3)}" cy="${n1(y - rad / 3)}" r="${n1(rad / 4)}" fill="${hsl(35, 100, 70)}"/>`;
      }
      const ax = between(r, 500, 700);
      body += `<circle cx="${n1(ax)}" cy="455" r="68" fill="#c62828" stroke="#8e1b1b" stroke-width="3"/><line x1="${n1(ax)}" y1="390" x2="${n1(ax + 10)}" y2="360" stroke="#5d4037" stroke-width="7"/>`;
      const bx = between(r, 330, 480);
      for (let i = 0; i < 3; i++) {
        const x = bx + i * 22, y = 420 + i * 18;
        body += `<path d="M ${n1(x)} ${y} Q ${n1(x + 170)} ${y + 120} ${n1(x + 360)} ${y - 20} Q ${n1(x + 170)} ${y + 55} ${n1(x)} ${y} Z" fill="${hsl(50, 90, 60)}" stroke="#b08a10" stroke-width="5"/>`;
      }
      body += `<path d="M 270 560 Q 600 900 930 560 Z" fill="#fafafa" stroke="#cfcfcf" stroke-width="4"/>`
        + `<path d="M 300 600 Q 600 800 900 600" fill="none" stroke="${hsl(215 + hue, 60, 45)}" stroke-width="14"/>`;
      return svg(W, H, body, grad('wall', [[0, hsl(wall, 30, 86)], [1, hsl(wall, 30, 72)]]));
    }
    case 'plant': {
      let body = `<rect width="${W}" height="${H}" fill="${hsl(40 + hue, 30, 88)}"/>`
        + `<rect x="230" y="40" width="740" height="600" fill="url(#sky)" stroke="#ffffff" stroke-width="34"/>`
        + `<line x1="600" y1="40" x2="600" y2="640" stroke="#fff" stroke-width="22"/><line x1="230" y1="330" x2="970" y2="330" stroke="#fff" stroke-width="22"/>`;
      for (let i = 0; i < 3; i++) body += `<ellipse cx="${n1(between(r, 320, 880))}" cy="${n1(between(r, 100, 280))}" rx="${n1(between(r, 50, 90))}" ry="26" fill="#ffffff" opacity="0.9"/>`;
      body += `<rect x="160" y="640" width="880" height="56" fill="#f7f7f7" stroke="#d8d8d8" stroke-width="3"/>`;
      const leaves = int(r, 8, 12);
      for (let i = 0; i < leaves; i++) {
        const a = -75 + (150 / (leaves - 1)) * i + between(r, -6, 6), len = between(r, 110, 190);
        body += `<ellipse cx="600" cy="${n1(500 - len)}" rx="${n1(between(r, 30, 46))}" ry="${n1(len)}" transform="rotate(${n1(a)} 600 500)" fill="${hsl(110 + between(r, 0, 35), 50, between(r, 25, 42))}"/>`;
      }
      body += `<polygon points="470,500 730,500 700,650 500,650" fill="${hsl(18, 60, 50)}"/><rect x="455" y="490" width="290" height="40" rx="8" fill="${hsl(18, 60, 44)}"/>`;
      return svg(W, H, body, grad('sky', [[0, hsl(205, 60, 78)], [1, hsl(200, 60, 93)]]));
    }
    case 'tiles': {
      const ink = pick(r, ['#1f4e9c', '#1d6f6a', '#c47f12', '#2d3e8c', '#8e2c48']);
      const size = 200;
      let body = `<rect width="${W}" height="${H}" fill="#cfc8b8"/>`;
      for (let y = 0; y < H; y += size) for (let x = 0; x < W; x += size) {
        const cx = x + size / 2, cy = y + size / 2;
        body += `<rect x="${x + 4}" y="${y + 4}" width="${size - 8}" height="${size - 8}" fill="#f8f5ec"/>`
          + `<polygon points="${cx},${y + 22} ${x + size - 22},${cy} ${cx},${y + size - 22} ${x + 22},${cy}" fill="none" stroke="${ink}" stroke-width="10"/>`
          + `<circle cx="${cx}" cy="${cy}" r="34" fill="${ink}"/>`;
        for (const [qx, qy] of [[x + 4, y + 4], [x + size - 4, y + 4], [x + 4, y + size - 4], [x + size - 4, y + size - 4]])
          body += `<circle cx="${qx}" cy="${qy}" r="40" fill="${ink}" opacity="0.85"/>`;
      }
      return svg(W, H, body);
    }
    case 'books': {
      let body = `<rect width="${W}" height="${H}" fill="${hsl(35 + hue, 25, 82)}"/>`;
      const palette = ['#b23a48', '#2f5d8a', '#e0a526', '#3f7f4f', '#6a4c93', '#d96c3b', '#1d3557', '#8d6e63', '#c9cba3', '#264653'];
      const vase = int(r, 0, 2);
      for (const [s, board] of [270, 560, 850].entries()) {
        let x = 70;
        while (x < 1080) {
          const w = between(r, 32, 70), h = between(r, 170, 240), c = pick(r, palette);
          if (s === vase && x > 880) { body += `<ellipse cx="${n1(x + 60)}" cy="${board - 70}" rx="55" ry="70" fill="${hsl(190, 50, 55)}"/>`; break; }
          body += `<rect x="${n1(x)}" y="${n1(board - h)}" width="${n1(w)}" height="${n1(h)}" fill="${c}" stroke="#222" stroke-width="2"/>`
            + `<rect x="${n1(x)}" y="${n1(board - h + 26)}" width="${n1(w)}" height="12" fill="#ffffff" opacity="0.5"/>`;
          x += w + between(r, 1, 6);
        }
        body += `<rect x="40" y="${board}" width="1120" height="30" fill="${hsl(28, 50, 32)}"/>`;
      }
      body += `<rect x="20" y="0" width="24" height="${H}" fill="${hsl(28, 50, 28)}"/><rect x="1156" y="0" width="24" height="${H}" fill="${hsl(28, 50, 28)}"/>`;
      return svg(W, H, body);
    }
    case 'coffee': {
      const cx = between(r, 480, 620), cy = between(r, 400, 480);
      let body = `<rect width="${W}" height="${H}" fill="${hsl(28 + hue, 35, 62)}"/>`;
      for (let i = 0; i < 9; i++) body += `<path d="M 0 ${60 + i * 100} Q 600 ${n1(30 + i * 100 + between(r, -20, 20))} 1200 ${70 + i * 100}" fill="none" stroke="${hsl(28 + hue, 35, 52)}" stroke-width="5"/>`;
      body += `<circle cx="${n1(cx)}" cy="${n1(cy)}" r="235" fill="#ffffff" stroke="#e2e2e2" stroke-width="6"/>`
        + `<rect x="${n1(cx + 120)}" y="${n1(cy - 30)}" width="120" height="60" rx="30" fill="#f4f4f4" stroke="#cccccc" stroke-width="5"/>`
        + `<circle cx="${n1(cx)}" cy="${n1(cy)}" r="150" fill="#fdfdfd" stroke="#cccccc" stroke-width="6"/>`
        + `<circle cx="${n1(cx)}" cy="${n1(cy)}" r="122" fill="#5b3a1e"/><circle cx="${n1(cx)}" cy="${n1(cy)}" r="98" fill="none" stroke="#c08a52" stroke-width="18" opacity="0.85"/>`
        + `<rect x="${n1(cx - 40)}" y="${n1(cy + 170)}" width="200" height="22" rx="11" fill="#b0b0b0" transform="rotate(-20 ${n1(cx)} ${n1(cy + 180)})"/>`;
      const kx = between(r, 880, 960), ky = between(r, 680, 760);
      for (let i = 0; i < 5; i++) {
        const a = -60 + i * 30;
        body += `<ellipse cx="${n1(kx + Math.sin(a * Math.PI / 180) * 90)}" cy="${n1(ky - Math.cos(a * Math.PI / 180) * 40)}" rx="${i === 2 ? 60 : 46}" ry="${i === 2 ? 70 : 52}" fill="${hsl(32, 75, 52 + (i % 2) * 6)}" stroke="${hsl(25, 70, 35)}" stroke-width="4"/>`;
      }
      return svg(W, H, body);
    }
    case 'beach': {
      const ux = between(r, 350, 800), stripe = pick(r, ['#e53935', '#1e88e5', '#fb8c00', '#8e24aa']);
      let body = `<rect width="${W}" height="400" fill="url(#sky)"/><circle cx="${n1(between(r, 900, 1100))}" cy="110" r="60" fill="#fff3b0"/>`
        + `<rect y="380" width="${W}" height="200" fill="${hsl(200 + hue, 75, 42)}"/>`;
      for (const y of [420, 470, 520]) body += `<path d="M 0 ${y} q 50 -18 100 0 t 100 0 t 100 0 t 100 0 t 100 0 t 100 0 t 100 0 t 100 0 t 100 0 t 100 0 t 100 0 t 100 0" fill="none" stroke="#ffffff" stroke-width="6" opacity="0.8"/>`;
      body += `<rect y="560" width="${W}" height="340" fill="${hsl(40, 60, 78)}"/>`
        + `<rect x="${n1(ux - 260)}" y="700" width="300" height="120" fill="${stripe}" transform="rotate(-6 ${n1(ux - 110)} 760)"/>`
        + `<rect x="${n1(ux - 260)}" y="740" width="300" height="30" fill="#ffffff" transform="rotate(-6 ${n1(ux - 110)} 760)"/>`
        + `<line x1="${n1(ux)}" y1="840" x2="${n1(ux + 40)}" y2="420" stroke="#6d4c41" stroke-width="12"/>`
        + `<path d="M ${n1(ux - 210)} 470 A 250 150 0 0 1 ${n1(ux + 290)} 470 Z" fill="${stripe}"/>`;
      for (let i = 0; i < 4; i++) {
        const a0 = Math.PI + (i * 2 + 1) * Math.PI / 8, a1 = a0 + Math.PI / 8, mx = ux + 40;
        body += `<path d="M ${n1(mx)} 470 L ${n1(mx + Math.cos(a0) * 250)} ${n1(470 + Math.sin(a0) * 150)} L ${n1(mx + Math.cos(a1) * 250)} ${n1(470 + Math.sin(a1) * 150)} Z" fill="#ffffff"/>`;
      }
      return svg(W, H, body, grad('sky', [[0, hsl(205 + hue, 75, 62)], [1, hsl(195, 80, 90)]]));
    }
    case 'night': {
      let body = `<rect width="${W}" height="${H}" fill="url(#sky)"/>`;
      for (let i = 0; i < 40; i++) body += `<circle cx="${n1(between(r, 0, W))}" cy="${n1(between(r, 0, 380))}" r="${n1(between(r, 1.5, 3.5))}" fill="#ffffff" opacity="${round(between(r, 0.5, 1), 2)}"/>`;
      body += `<circle cx="${n1(between(r, 150, 1050))}" cy="${n1(between(r, 90, 200))}" r="62" fill="#f5f0d0"/>`;
      for (let x = -20; x < W; ) {
        const w = between(r, 120, 220), h = between(r, 260, 540), y = H - h;
        body += `<rect x="${n1(x)}" y="${n1(y)}" width="${n1(w)}" height="${n1(h)}" fill="#0a0f1f"/>`;
        for (let wy = y + 30; wy < H - 40; wy += 50) for (let wx = x + 20; wx < x + w - 30; wx += 40)
          body += `<rect x="${n1(wx)}" y="${n1(wy)}" width="18" height="26" fill="${chance(r, 0.35) ? '#ffd56b' : '#1a2240'}"/>`;
        x += w + between(r, 0, 12);
      }
      return svg(W, H, body, grad('sky', [[0, hsl(225 + hue, 60, 10)], [1, hsl(230 + hue, 45, 28)]]));
    }
    case 'market': {
      let body = `<rect width="${W}" height="${H}" fill="#5d4037"/>`;
      for (let i = 0; i < 12; i++) body += `<rect x="${i * 100}" y="0" width="100" height="170" fill="${i % 2 ? '#ffffff' : '#d32f2f'}"/><circle cx="${i * 100 + 50}" cy="170" r="50" fill="${i % 2 ? '#ffffff' : '#d32f2f'}"/>`;
      const produce: [string, string, number, number][] = [['#e53935', '#8e1b1b', 40, 40], ['#43a047', '#1b5e20', 34, 46], ['#fdd835', '#b08a10', 44, 32]];
      const order = shuffle(r, produce);
      for (let c = 0; c < 3; c++) {
        const x0 = 50 + c * 375, [fill, edge, rx, ry] = order[c];
        for (let row = 0; row < 3; row++) for (let i = 0; i < 4; i++)
          body += `<ellipse cx="${n1(x0 + 50 + i * 80 + (row % 2) * 30 + between(r, -6, 6))}" cy="${n1(470 + row * 40 + between(r, -5, 5))}" rx="${rx}" ry="${ry}" fill="${fill}" stroke="${edge}" stroke-width="3"/>`;
        body += `<rect x="${x0}" y="540" width="350" height="320" fill="${hsl(30, 45, 45)}" stroke="#4e342e" stroke-width="6"/>`;
        for (let y = 600; y < 860; y += 70) body += `<line x1="${x0}" y1="${y}" x2="${x0 + 350}" y2="${y}" stroke="#4e342e" stroke-width="5"/>`;
        body += `<rect x="${x0 + 110}" y="300" width="130" height="80" rx="8" fill="#ffffff" stroke="#333" stroke-width="3"/>`
          + text(x0 + 175, 357, 46, '#222', `€${int(r, 1, 4)}`, { weight: 700, anchor: 'middle' });
      }
      return svg(W, H, body);
    }
    case 'park': {
      let body = `<rect width="${W}" height="400" fill="url(#sky)"/><rect y="380" width="${W}" height="520" fill="${hsl(105 + hue, 45, 45)}"/>`
        + `<path d="M 520 900 C 700 720 420 560 640 380" fill="none" stroke="${hsl(40, 50, 78)}" stroke-width="130"/>`;
      const trees: [number, number, number][] = [];
      for (let i = 0; i < 7; i++) {
        const left = i % 2 === 0, depth = between(r, 0, 1);
        trees.push([left ? between(r, 40, 380) : between(r, 780, 1160), 420 + depth * 380, 50 + depth * 80]);
      }
      trees.sort((a, b) => a[1] - b[1]);
      for (const [x, y, s] of trees)
        body += `<rect x="${n1(x - s / 7)}" y="${n1(y - s)}" width="${n1(s / 3.5)}" height="${n1(s)}" fill="#6d4c2f"/><circle cx="${n1(x)}" cy="${n1(y - s * 1.4)}" r="${n1(s * 0.95)}" fill="${hsl(115 + between(r, 0, 25), 45, between(r, 25, 36))}"/>`;
      body += `<rect x="860" y="730" width="230" height="26" fill="#8d6e63"/><rect x="860" y="690" width="230" height="20" fill="#8d6e63"/><rect x="875" y="756" width="16" height="60" fill="#4e342e"/><rect x="1060" y="756" width="16" height="60" fill="#4e342e"/>`;
      return svg(W, H, body, grad('sky', [[0, hsl(205, 70, 70)], [1, hsl(200, 70, 92)]]));
    }
    case 'concert': {
      let body = `<rect width="${W}" height="${H}" fill="#07070d"/>`;
      const beams = int(r, 4, 6);
      for (let i = 0; i < beams; i++) {
        const x = 120 + i * (960 / (beams - 1)), c = hsl(between(r, 0, 360), 90, 60), tx = between(r, 250, 950);
        body += `<polygon points="${n1(x - 12)},0 ${n1(x + 12)},0 ${n1(tx + 110)},600 ${n1(tx - 110)},600" fill="${c}" opacity="0.35"/><circle cx="${n1(x)}" cy="14" r="22" fill="${c}"/>`;
      }
      body += `<rect y="560" width="${W}" height="110" fill="#22222e"/><rect y="670" width="${W}" height="230" fill="url(#floor)"/>`;
      for (const x of [380, 600, 820]) body += `<circle cx="${x}" cy="440" r="34" fill="#000"/><rect x="${x - 40}" y="470" width="80" height="95" rx="20" fill="#000"/>`;
      for (let i = 0; i < 12; i++) {
        const x = 50 + i * 100 + between(r, -20, 20), y = between(r, 760, 820);
        body += `<circle cx="${n1(x)}" cy="${n1(y)}" r="${n1(between(r, 42, 56))}" fill="#000"/><ellipse cx="${n1(x)}" cy="${n1(y + 110)}" rx="85" ry="70" fill="#000"/>`;
        if (chance(r, 0.25)) body += `<line x1="${n1(x + 30)}" y1="${n1(y + 40)}" x2="${n1(x + 60)}" y2="${n1(y - 120)}" stroke="#000" stroke-width="22" stroke-linecap="round"/>`;
      }
      return svg(W, H, body, grad('floor', [[0, hsl(between(r, 200, 320), 55, 42)], [1, hsl(260, 40, 14)]]));
    }
    case 'tarts': {
      let body = `<rect width="${W}" height="${H}" fill="${hsl(212 + hue, 60, 38)}"/>`;
      for (let x = 0; x < W; x += 150) body += `<line x1="${x}" y1="0" x2="${x}" y2="${H}" stroke="#ffffff" stroke-width="3" opacity="0.4"/>`;
      for (let y = 0; y < H; y += 150) body += `<line x1="0" y1="${y}" x2="${W}" y2="${y}" stroke="#ffffff" stroke-width="3" opacity="0.4"/>`;
      body += `<circle cx="600" cy="450" r="390" fill="#fafafa" stroke="#dcdcdc" stroke-width="6"/><circle cx="600" cy="450" r="330" fill="none" stroke="#e6e6e6" stroke-width="4"/>`;
      const spots: [number, number][] = [[600, 450], [600, 250], [790, 360], [730, 600], [470, 600], [410, 360]];
      for (const [x, y] of spots.slice(0, int(r, 4, 6))) {
        body += `<circle cx="${x}" cy="${y}" r="98" fill="${hsl(32, 60, 50)}" stroke="${hsl(28, 60, 35)}" stroke-width="4"/><circle cx="${x}" cy="${y}" r="74" fill="${hsl(45, 85, 62)}"/>`;
        for (let k = 0; k < 6; k++) body += `<ellipse cx="${n1(x + between(r, -45, 45))}" cy="${n1(y + between(r, -45, 45))}" rx="${n1(between(r, 10, 22))}" ry="${n1(between(r, 8, 16))}" fill="#5d2f0e" opacity="0.85"/>`;
      }
      return svg(W, H, body);
    }
    case 'boat': {
      const cx = between(r, 400, 800);
      let body = `<rect width="${W}" height="540" fill="url(#sky)"/><polygon points="0,520 300,488 700,505 1200,480 1200,540 0,540" fill="${hsl(95, 30, 40)}"/>`
        + `<rect y="530" width="${W}" height="370" fill="${hsl(205 + hue, 60, 42)}"/>`;
      for (let i = 0; i < 8; i++) body += `<path d="M ${n1(between(r, 0, 1000))} ${n1(between(r, 600, 880))} q 30 -10 60 0 t 60 0" fill="none" stroke="#ffffff" stroke-width="4" opacity="0.6"/>`;
      body += `<polygon points="${n1(cx + 8)},230 ${n1(cx + 8)},620 ${n1(cx + 230)},620" fill="#fdfdfd" stroke="#bbbbbb" stroke-width="3"/>`
        + `<polygon points="${n1(cx - 8)},280 ${n1(cx - 8)},620 ${n1(cx - 160)},620" fill="#eeeeee" stroke="#bbbbbb" stroke-width="3"/>`
        + `<line x1="${n1(cx)}" y1="220" x2="${n1(cx)}" y2="640" stroke="#333" stroke-width="8"/>`
        + `<path d="M ${n1(cx - 230)} 640 L ${n1(cx + 260)} 640 L ${n1(cx + 190)} 710 L ${n1(cx - 170)} 710 Z" fill="${pick(r, ['#ffffff', '#c62828', '#1e3a5f'])}" stroke="#333" stroke-width="5"/>`;
      for (let i = 0; i < 4; i++) { const bx = between(r, 100, 1100), by = between(r, 60, 260); body += `<path d="M ${n1(bx)} ${n1(by)} q 20 -20 40 0 q 20 -20 40 0" fill="none" stroke="#333" stroke-width="5"/>`; }
      return svg(W, H, body, grad('sky', [[0, hsl(200 + hue, 70, 68)], [1, hsl(195, 80, 92)]]));
    }
    case 'desk': {
      let body = `<rect width="${W}" height="${H}" fill="${hsl(205 + hue, 15, 84)}"/>`
        + `<rect x="120" y="110" width="220" height="300" fill="${hsl(between(r, 0, 360), 55, 60)}" stroke="#ffffff" stroke-width="14"/>`
        + `<polygon points="0,${H} 1200,${H} 1200,620 0,620" fill="${hsl(28, 45, 40)}"/><rect y="600" width="${W}" height="36" fill="${hsl(30, 50, 52)}"/>`
        + `<rect x="430" y="330" width="340" height="250" rx="12" fill="#222"/><rect x="448" y="348" width="304" height="214" fill="${hsl(212, 75, 52)}"/>`;
      for (let i = 0; i < 4; i++) body += `<rect x="470" y="${375 + i * 45}" width="${n1(between(r, 120, 250))}" height="20" rx="10" fill="#ffffff" opacity="0.8"/>`;
      body += `<polygon points="400,580 800,580 830,612 370,612" fill="#9ea7ad"/>`
        + `<ellipse cx="1000" cy="596" rx="70" ry="16" fill="#333"/><line x1="1000" y1="590" x2="940" y2="400" stroke="#333" stroke-width="12"/><line x1="940" y1="400" x2="1040" y2="310" stroke="#333" stroke-width="12"/>`
        + `<polygon points="1010,300 1090,280 1110,380 1050,390" fill="${hsl(between(r, 0, 60), 70, 50)}"/>`
        + `<polygon points="1050,390 1110,380 1150,600 900,600" fill="#fff6c0" opacity="0.35"/>`
        + `<rect x="220" y="500" width="90" height="100" rx="10" fill="${hsl(between(r, 0, 360), 50, 55)}"/><rect x="300" y="520" width="36" height="50" rx="16" fill="none" stroke="${hsl(0, 0, 30)}" stroke-width="10"/>`
        + `<rect x="80" y="570" width="160" height="30" fill="${hsl(between(r, 0, 360), 45, 35)}"/>`;
      return svg(W, H, body);
    }
  }
}

const SW = 1170, SH = 2532;

export function screen(item: ScreenItem, name: string | undefined, time: string, dark: boolean, r: Rng): { svg: string; lines: string[] } {
  const fill = (s: string) => s.replace('{a}', name ?? NAMES[0]);
  const bg = dark ? '#121214' : '#f2f2f7', fg = dark ? '#f2f2f2' : '#1c1c1e', card = dark ? '#1f1f23' : '#ffffff', soft = dark ? '#2c2c2e' : '#e5e5ea';
  const heading = fill(item.heading), rows = item.rows.map(fill);
  let body = `<rect width="${SW}" height="${SH}" fill="${bg}"/>`
    + text(110, 105, 50, fg, time, { weight: 600 })
    + `<rect x="1000" y="70" width="84" height="42" rx="11" fill="none" stroke="${fg}" stroke-width="4"/><rect x="1008" y="78" width="${int(r, 30, 66)}" height="26" rx="6" fill="${fg}"/>`;
  for (let i = 0; i < 4; i++) body += `<rect x="${860 + i * 26}" y="${108 - 14 - i * 9}" width="16" height="${14 + i * 9}" rx="3" fill="${fg}"/>`;
  body += `<rect y="150" width="${SW}" height="560" fill="${item.color}"/>`
    + text(90, 470, heading.length > 12 ? 112 : 130, '#ffffff', heading, { weight: 700 })
    + text(92, 590, 66, '#ffffff', item.sub, { opacity: 0.9 });
  if (item.style === 'weather') body += `<circle cx="930" cy="380" r="120" fill="#ffe066"/>`;
  if (item.style === 'chat') {
    rows.forEach((row, i) => {
      const mine = i % 2 === 1, w = Math.min(980, 120 + row.length * 34), y = 800 + i * 210;
      const x = mine ? SW - 60 - w : 60;
      body += `<rect x="${x}" y="${y}" width="${w}" height="150" rx="60" fill="${mine ? item.color : soft}"/>` + text(x + 60, y + 98, 60, mine ? '#ffffff' : fg, row);
    });
  } else if (item.style === 'map') {
    body += `<rect y="710" width="${SW}" height="1300" fill="${dark ? '#2a2d2a' : '#eceee4'}"/>`
      + `<path d="M -20 ${1600 + int(r, -100, 100)} C 400 1500 700 1800 1200 ${1650 + int(r, -100, 100)}" fill="none" stroke="#9ccbe8" stroke-width="120"/>`
      + `<rect x="${int(r, 100, 600)}" y="${int(r, 820, 1100)}" width="380" height="260" rx="30" fill="#b9dca2"/>`;
    for (let i = 0; i < 6; i++) body += `<line x1="${int(r, -100, 1200)}" y1="710" x2="${int(r, -100, 1200)}" y2="2010" stroke="${dark ? '#444' : '#ffffff'}" stroke-width="34"/>`;
    for (let i = 0; i < 5; i++) body += `<line x1="0" y1="${int(r, 760, 1960)}" x2="${SW}" y2="${int(r, 760, 1960)}" stroke="${dark ? '#444' : '#ffffff'}" stroke-width="30"/>`;
    const sx = int(r, 150, 400), sy = int(r, 1700, 1900), px = int(r, 750, 1000), py = int(r, 900, 1150);
    body += `<polyline points="${sx},${sy} ${sx},${py + 300} ${px},${py + 300} ${px},${py + 60}" fill="none" stroke="#1e88e5" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>`
      + `<circle cx="${sx}" cy="${sy}" r="30" fill="#ffffff" stroke="#1e88e5" stroke-width="12"/>`
      + `<path d="M ${px} ${py + 70} L ${px - 50} ${py - 10} A 58 58 0 1 1 ${px + 50} ${py - 10} Z" fill="${item.color}"/><circle cx="${px}" cy="${py - 40}" r="22" fill="#ffffff"/>`;
    rows.forEach((row, i) => { body += `<rect x="50" y="${2050 + i * 140}" width="1070" height="120" rx="30" fill="${card}"/>` + text(110, 2128 + i * 140, 56, fg, row); });
  } else {
    rows.forEach((row, i) => {
      const y = 790 + i * 190;
      body += `<rect x="50" y="${y}" width="1070" height="160" rx="32" fill="${card}"/>`;
      if (item.style === 'list') body += `<circle cx="140" cy="${y + 80}" r="34" fill="none" stroke="${item.color}" stroke-width="8"/>`;
      else if (item.style === 'playlist') body += `<rect x="85" y="${y + 25}" width="110" height="110" rx="14" fill="${hsl(between(r, 0, 360), 55, 55)}"/>`;
      else if (item.style === 'calendar') body += `<rect x="80" y="${y + 25}" width="18" height="110" rx="9" fill="${hsl(between(r, 0, 360), 65, 55)}"/>`;
      else body += `<circle cx="140" cy="${y + 80}" r="26" fill="${item.color}"/>`;
      body += text(item.style === 'calendar' ? 130 : 215, y + 102, 62, fg, row);
    });
  }
  body += `<rect y="2350" width="${SW}" height="182" fill="${card}"/>`;
  for (const x of [200, 460, 710, 970]) body += `<circle cx="${x}" cy="2420" r="30" fill="${soft}"/>`;
  body += `<rect x="400" y="2496" width="370" height="14" rx="7" fill="${fg}"/>`;
  return { svg: svg(SW, SH, body), lines: [heading, item.sub, ...rows] };
}

const TW = 480, TH = 270;

export type LinkContent = Extract<Content, { kind: 'link' }>;

export function linkThumb(c: LinkContent, r: Rng): string {
  const topic = c.video?.topic ?? c.page!.topic;
  const color = TOPIC_COLORS[topic];
  const title = c.video?.title ?? c.page!.title;
  if (c.video && c.short) {
    const lines = wrap(title, 11, 4);
    let body = `<rect width="${TW}" height="${TH}" fill="#111"/><rect x="160" y="0" width="160" height="${TH}" fill="url(#g)"/>`;
    lines.forEach((l, i) => { body += text(240, 60 + i * 30, 24, '#ffffff', l, { weight: 700, anchor: 'middle' }); });
    body += `<circle cx="240" cy="215" r="30" fill="${hsl(0, 0, 8)}" opacity="0.45"/><polygon points="230,200 230,230 256,215" fill="#ffffff" opacity="0.9"/>`;
    return svg(TW, TH, body, grad('g', [[0, color], [1, hsl(between(r, 0, 360), 40, 20)]]));
  }
  if (c.video) {
    let body = `<rect width="${TW}" height="${TH}" fill="url(#g)"/>`;
    for (let i = 0; i < 3; i++) body += `<circle cx="${n1(between(r, 0, TW))}" cy="${n1(between(r, 0, TH))}" r="${n1(between(r, 50, 120))}" fill="#ffffff" opacity="0.15"/>`;
    const lines = wrap(title, 24, 2);
    body += `<rect x="0" y="${TH - 30 - lines.length * 34}" width="${TW}" height="${30 + lines.length * 34}" fill="#000" opacity="0.55"/>`;
    lines.forEach((l, i) => { body += text(18, TH - 20 - (lines.length - 1 - i) * 34, 28, '#ffffff', l, { weight: 700 }); });
    // A neutral play mark in the thumbnail's own palette (never a site's logo or button).
    body += `<circle cx="240" cy="97" r="42" fill="${hsl(0, 0, 8)}" opacity="0.45"/><polygon points="226,76 226,118 262,97" fill="#ffffff" opacity="0.9"/>`;
    return svg(TW, TH, body, grad('g', [[0, color], [1, hsl(between(r, 0, 360), 45, 18)]], true));
  }
  const p = c.page!;
  const host = p.host.replace(/^www\./, '');
  switch (p.style) {
    case 'news': {
      let body = `<rect width="${TW}" height="${TH}" fill="#ffffff"/><rect width="${TW}" height="46" fill="#222222"/>` + text(16, 32, 22, '#ffffff', host.toUpperCase(), { weight: 700 })
        + `<rect x="320" y="66" width="144" height="184" fill="${color}"/><circle cx="392" cy="140" r="${int(r, 30, 50)}" fill="#ffffff" opacity="0.6"/>`;
      wrap(p.title, 16, 4).forEach((l, i) => { body += text(16, 96 + i * 40, 31, '#111111', l, { weight: 700 }); });
      return svg(TW, TH, body);
    }
    case 'recipe': {
      let body = `<rect width="${TW}" height="${TH}" fill="${hsl(32, 60, 90)}"/><circle cx="240" cy="118" r="102" fill="#ffffff" stroke="#dddddd" stroke-width="4"/>`;
      for (let i = 0; i < 7; i++) body += `<circle cx="${n1(240 + between(r, -55, 55))}" cy="${n1(118 + between(r, -55, 55))}" r="${n1(between(r, 16, 32))}" fill="${hsl(between(r, 15, 60) + (i % 3 === 0 ? 75 : 0), 70, 50)}"/>`;
      body += `<rect y="${TH - 52}" width="${TW}" height="52" fill="#ffffff" opacity="0.9"/>` + text(240, TH - 17, 26, '#222', wrap(p.title, 30, 1)[0], { weight: 700, anchor: 'middle' });
      return svg(TW, TH, body);
    }
    case 'shop': {
      const accent = hsl(between(r, 0, 360), 45, 55);
      let body = `<rect width="${TW}" height="${TH}" fill="#f3f0ea"/>`;
      const t = p.title.toLowerCase();
      if (t.includes('mug')) body += `<rect x="170" y="70" width="120" height="140" rx="16" fill="${hsl(160, 35, 50)}"/><rect x="280" y="100" width="50" height="70" rx="25" fill="none" stroke="${hsl(160, 35, 40)}" stroke-width="14"/>`;
      else if (t.includes('lamp')) body += `<polygon points="200,60 280,60 310,130 170,130" fill="#c9a227"/><line x1="240" y1="130" x2="240" y2="215" stroke="#555" stroke-width="10"/><rect x="190" y="210" width="100" height="16" rx="8" fill="#555"/>`;
      else if (t.includes('desk')) body += `<rect x="120" y="110" width="240" height="26" fill="#c19a6b"/><rect x="135" y="136" width="14" height="90" fill="#8d6e63"/><rect x="331" y="136" width="14" height="90" fill="#8d6e63"/>`;
      else if (t.includes('jacket')) body += `<polygon points="180,60 300,60 350,120 330,230 150,230 130,120" fill="${hsl(210, 30, 30)}"/><rect x="150" y="150" width="180" height="16" fill="#e0e0e0"/>`;
      else for (let i = 0; i < 4; i++) body += `<rect x="${130 + i * 58}" y="50" width="52" height="180" fill="${hsl(38, 35, 70 + (i % 2) * 8)}"/>`;
      body += `<rect x="360" y="200" width="100" height="44" rx="10" fill="#222"/>` + text(410, 230, 24, '#ffffff', `€ ${int(r, 12, 89)}`, { weight: 700, anchor: 'middle' })
        + `<rect x="16" y="16" width="14" height="14" rx="7" fill="${accent}"/>` + text(38, 29, 16, '#555', host);
      return svg(TW, TH, body);
    }
    case 'map': {
      let body = `<rect width="${TW}" height="${TH}" fill="#ece8de"/><path d="M -10 ${int(r, 180, 230)} C 160 200 300 260 490 ${int(r, 190, 240)}" fill="none" stroke="#a8d4f0" stroke-width="44"/>`
        + `<rect x="${int(r, 40, 300)}" y="30" width="120" height="80" rx="10" fill="#c5e1a5"/>`;
      for (let i = 0; i < 5; i++) body += `<line x1="${int(r, 0, TW)}" y1="0" x2="${int(r, 0, TW)}" y2="${TH}" stroke="#ffffff" stroke-width="10"/>`;
      for (let i = 0; i < 3; i++) body += `<line x1="0" y1="${int(r, 0, TH)}" x2="${TW}" y2="${int(r, 0, TH)}" stroke="#ffffff" stroke-width="10"/>`;
      body += `<path d="M 240 150 L 214 112 A 32 32 0 1 1 266 112 Z" fill="${color}"/><circle cx="240" cy="96" r="12" fill="#ffffff"/>`;
      return svg(TW, TH, body);
    }
    default: {
      // One plain style for every host, coloured by topic, so no page imitates its site.
      const bgc = hsl(0, 0, 97), fg = '#222222';
      let body = `<rect width="${TW}" height="${TH}" fill="${bgc}"/><circle cx="40" cy="40" r="20" fill="${color}"/>` + text(70, 47, 20, fg, host, { opacity: 0.7 });
      wrap(p.title, 20, 3).forEach((l, i) => { body += text(24, 120 + i * 44, 36, fg, l, { weight: 700 }); });
      return svg(TW, TH, body);
    }
  }
}

// ---- other files ----

/** A mono 16-bit PCM WAV: a soft two-note tone with fades, `seconds` long. */
function wav(seconds: number, freq: number): Buffer {
  const rate = 16000, n = Math.round(seconds * rate);
  const b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVE', 8); b.write('fmt ', 12); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * 2, 28); b.writeUInt16LE(2, 32);
  b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    const f = i < n / 2 ? freq : freq * 1.25;
    const env = Math.min(1, i / 800, (n - i) / 800);
    b.writeInt16LE(Math.round(Math.sin((2 * Math.PI * f * i) / rate) * env * 0.3 * 32767), 44 + i * 2);
  }
  return b;
}

/** A one-page PDF with the lines in Helvetica; ASCII only. */
function pdf(lines: string[]): Buffer {
  const esc = (s: string) => s.replace(/[^\x20-\x7e]/g, '?').replace(/([\\()])/g, '\\$1');
  const stream = lines.map((l, i) => `BT /F1 ${i === 0 ? 24 : 14} Tf 72 ${760 - i * 32} Td (${esc(l)}) Tj ET`).join('\n');
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  let out = '%PDF-1.4\n';
  const offsets: number[] = [];
  objects.forEach((o, i) => { offsets.push(Buffer.byteLength(out)); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
  const xref = Buffer.byteLength(out);
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n` + offsets.map(o => `${String(o).padStart(10, '0')} 00000 n \n`).join('')
    + `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out, 'latin1');
}

function keywords(text: string): { word: string; weight: number }[] {
  const names = new Set(NAMES.map(n => n.toLowerCase()));
  const words = text.toLowerCase().match(/[\p{L}]+/gu) ?? [];
  const seen: string[] = [];
  for (const w of words) if (w.length >= 3 && !STOPWORDS.has(w) && !names.has(w) && !seen.includes(w)) seen.push(w);
  return seen.slice(0, 8).map((word, i) => ({ word, weight: round(1 - i * 0.1, 2) }));
}

function condition(code: number): string | undefined {
  if (code <= 1) return 'clear';
  if (code === 2) return 'partly_cloudy';
  if (code === 3) return 'cloudy';
  if (code === 45 || code === 48) return 'fog';
  if (code >= 51 && code <= 55) return 'drizzle';
  if (code >= 61 && code <= 65) return 'rain';
  if (code >= 80 && code <= 82) return 'showers';
  return undefined;
}

// ---- one capture ----

interface Written { model: Record<string, unknown>; serverAt: number }
interface Attachment { id: string; ext: string; bytes: Buffer; meta: Record<string, unknown> }

async function writeCapture(out: string, p: Plan): Promise<Written> {
  const r = mulberry32(p.seed);
  const c = p.content;
  const loc = local(p.t);
  const dateDir = loc.date.split('-');
  const dir = path.join(out, 'captures', ...dateDir, p.id);
  const deviceDir = path.join(out, 'enrichments', 'device', ...dateDir, p.id);
  const deviceAt = p.t + int(r, 12, 50) * 60_000 + int(r, 0, 59) * 1000;
  const serverAt = p.t + int(r, 60, 240) * 60_000 + int(r, 0, 59) * 1000;
  const facets: Record<string, Record<string, unknown>> = {};
  const facet = (kind: string, provenance: string, data: unknown) => {
    facets[kind] = { version: 1, status: 'ok', generated_at: stamp(deviceAt), provenance, data };
  };
  const assets: { name: string; bytes: Buffer }[] = [];
  const attachments: Attachment[] = [];
  const attach = (ext: string, bytes: Buffer, meta: Record<string, unknown>) => {
    const a = { id: uuid(r), ext, bytes, meta };
    attachments.push(a);
    return a;
  };
  const imgName = (ext: string) => `IMG_${int(r, 1000, 9999)}.${ext}`;
  const embedded = (withOffset: boolean) => ({ value: withOffset ? loc.datetime : loc.datetime.slice(0, 19), has_utc_offset: withOffset });

  // People: the sentence that names them, and where it goes.
  const [a, b] = p.names;
  const sentence = p.names.length === 2 ? pick(r, TWO_NAMES).replace('{a}', a).replace('{b}', b)
    : p.names.length === 1 ? pick(r, ONE_NAME).replace('{a}', a) : undefined;
  const md: Record<string, unknown> = {};
  let peopleSource: string | undefined;
  let commentText: string | undefined;
  const model: Record<string, unknown> = { image_descriptions: [] as unknown[] };
  const transcripts: Record<string, unknown>[] = [];
  const sounds: Record<string, unknown>[] = [];
  const recognized: Record<string, unknown>[] = [];
  const languages: Record<string, unknown>[] = [];
  let method = 'share_extension';
  let contentTypes: string[] = [];

  switch (c.kind) {
    case 'link': {
      const host = c.video ? (c.mobile ? 'm.youtube.com' : 'www.youtube.com') : c.page!.host;
      const id = Array.from({ length: 11 }, () => 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'[int(r, 0, 63)]).join('');
      const url = c.video ? (c.short ? `https://${host}/shorts/${id}` : `https://${host}/watch?v=${id}`) : `https://${host}${c.page!.path(r)}`;
      const item = c.video ?? c.page!;
      md.urls = [{ url, source: 'shared_payload' }];
      contentTypes = ['url'];
      if (chance(r, 0.7)) md.shared_title = item.title;
      const base = chance(r, 0.35) ? pick(r, LINK_NOTES) : undefined;
      const note = [base, sentence].filter(Boolean).join('. ');
      if (note) md.user_note = note;
      if (sentence) peopleSource = 'user_note';
      const thumb = await sharp(Buffer.from(linkThumb(c, r))).jpeg({ quality: 80 }).toBuffer();
      const sha = sha256(thumb);
      assets.push({ name: `${sha}.jpg`, bytes: thumb });
      const preview: Record<string, unknown> = { url, title: item.title, site_name: host.replace(/^(www|m)\./, ''), description: item.description,
        thumbnail: { relative_path: `assets/${sha}.jpg`, byte_count: thumb.length, sha256: sha, mime_type: 'image/jpeg' } };
      if (c.video) preview.channel = c.video.channel;
      if (c.mobile) preview.canonical_url = url.replace('://m.', '://www.');
      facet('link_preview', 'link_fetch', { items: [preview] });
      Object.assign(model, { title: item.title, topic: item.topic, tags: item.tags,
        summary: c.video ? `${c.short ? 'A short video' : 'A video'} from ${c.video.channel}: ${c.video.description}` : item.description });
      break;
    }
    case 'photo': {
      const camera = chance(r, 0.5);
      method = camera ? 'camera' : 'share_extension';
      // Seeded crop, mirror and tone, so two photos of the same scene do not look like copies (the market has text: never mirrored).
      const zoom = between(r, 1, 1.2), cw = Math.round(W / zoom), ch = Math.round(H / zoom);
      const bytes = await sharp(Buffer.from(scene(c.item.scene, r)))
        .extract({ left: int(r, 0, W - cw), top: int(r, 0, H - ch), width: cw, height: ch }).resize(W, H)
        .flop(c.item.scene !== 'market' && chance(r, 0.5)).modulate({ brightness: round(between(r, 0.92, 1.08), 2), saturation: round(between(r, 0.85, 1.2), 2) })
        .jpeg({ quality: 80 }).toBuffer();
      const meta: Record<string, unknown> = { uti: 'public.jpeg', mime_type: 'image/jpeg', representation_source: camera ? 'camera' : 'item_provider_file',
        media: { width_pixels: W, height_pixels: H, embedded_created_at: embedded(camera) } };
      if (!camera) meta.original_filename = imgName('JPG');
      const att = attach('jpg', bytes, meta);
      contentTypes = ['image'];
      if (sentence) {
        if (chance(r, 0.6)) { md.user_note = sentence; peopleSource = 'user_note'; } else commentText = sentence;
      }
      Object.assign(model, { title: pick(r, c.item.titles), topic: c.item.topic, tags: c.item.tags, summary: c.item.summary,
        image_descriptions: [{ attachment_id: att.id, text: c.item.description }] });
      break;
    }
    case 'screenshot': {
      const dark = loc.hour >= 20 || loc.hour < 8;
      const s = screen(c.item, a, `${loc.hour}:${pad(loc.minute)}`, dark, r);
      const bytes = await sharp(Buffer.from(s.svg)).png({ compressionLevel: 9, palette: true, colours: 64 }).toBuffer();
      const att = attach('png', bytes, { uti: 'public.png', mime_type: 'image/png', representation_source: 'item_provider_file',
        original_filename: imgName('PNG'), media: { width_pixels: SW, height_pixels: SH } });
      contentTypes = ['image'];
      facet('screenshot', 'heuristic', { items: [{ attachment_id: att.id, reason: 'screen_size_match' }] });
      recognized.push({ attachment_id: att.id, text: s.lines.join('\n'), languages: ['en'] });
      const chat = c.item.style === 'chat';
      if (chat) peopleSource = att.id;
      else if (sentence) { md.user_note = sentence; peopleSource = 'user_note'; }
      Object.assign(model, { title: chat ? `Chat with ${a} about Saturday` : c.item.title, topic: c.item.topic, tags: c.item.tags,
        summary: chat ? `A chat with ${a} making plans for the Saturday market.` : c.item.summary,
        image_descriptions: [{ attachment_id: att.id, text: chat ? c.item.description.replace('a contact name', `the name ${a}`) : c.item.description }] });
      break;
    }
    case 'note': {
      method = 'typed_note';
      const body = sentence ? `${c.item.text}\n${sentence}` : c.item.text;
      const att = attach('txt', Buffer.from(body, 'utf8'), { uti: 'public.utf8-plain-text', mime_type: 'text/plain', representation_source: 'typed_note' });
      contentTypes = ['text'];
      if (sentence) peopleSource = att.id;
      languages.push({ source: 'note_body', language: 'en', confidence: round(between(r, 0.9, 0.99), 2) });
      Object.assign(model, { title: c.item.title, topic: c.item.topic, tags: c.item.tags, summary: c.item.summary, keywords: keywords(body) });
      break;
    }
    case 'recording': {
      method = 'voice_recording';
      const seconds = round(between(r, 2, 4), 1);
      const att = attach('wav', wav(seconds, int(r, 180, 480)), { uti: 'com.microsoft.waveform-audio', mime_type: 'audio/wav',
        representation_source: 'recording', media: { duration_seconds: seconds } });
      contentTypes = ['audio'];
      const said = sentence ? `${c.item.text} ${sentence}` : c.item.text;
      const words = said.split(' ');
      const half = Math.ceil(words.length / 2);
      transcripts.push({ attachment_id: att.id, text: said, locale: 'en_GB', segments: [
        { start: 0, end: round(seconds / 2, 2), text: words.slice(0, half).join(' ') },
        { start: round(seconds / 2, 2), end: seconds, text: words.slice(half).join(' ') }] });
      sounds.push({ attachment_id: att.id, labels: [{ label: 'speech', confidence: round(between(r, 0.7, 0.95), 2) }] });
      if (sentence) peopleSource = att.id;
      Object.assign(model, { title: c.item.title, topic: c.item.topic, tags: c.item.tags, summary: c.item.summary, keywords: keywords(said) });
      break;
    }
    case 'video': {
      const camera = chance(r, 0.4);
      method = camera ? 'camera' : 'share_extension';
      const meta: Record<string, unknown> = { uti: 'com.apple.quicktime-movie', mime_type: 'video/quicktime', representation_source: camera ? 'camera' : 'item_provider_file',
        media: { duration_seconds: 1, width_pixels: 64, height_pixels: 48 } };
      if (!camera) meta.original_filename = imgName('MOV');
      attach('mov', await fsp.readFile(CLIP), meta);
      contentTypes = ['video'];
      md.user_note = sentence ? `${c.item.note}. ${sentence}` : c.item.note;
      if (sentence) peopleSource = 'user_note';
      Object.assign(model, { title: c.item.title, topic: c.item.topic, tags: c.item.tags, summary: c.item.summary });
      break;
    }
    case 'file': {
      method = 'file_import';
      const f = c.item;
      const [ext, uti, mime] = f.type === 'pdf' ? ['pdf', 'com.adobe.pdf', 'application/pdf']
        : f.type === 'csv' ? ['csv', 'public.comma-separated-values-text', 'text/csv'] : ['md', 'net.daringfireball.markdown', 'text/markdown'];
      const bytes = f.type === 'pdf' ? pdf(f.lines) : Buffer.from(f.lines.join('\n') + '\n', 'utf8');
      attach(ext, bytes, { uti, mime_type: mime, representation_source: 'item_provider_file', original_filename: f.name });
      contentTypes = [f.type === 'pdf' ? 'pdf' : 'file'];
      md.user_note = f.note;
      commentText = sentence;
      Object.assign(model, { title: f.title, topic: f.topic, tags: f.tags, summary: f.summary });
      break;
    }
  }
  if (typeof md.user_note === 'string' && md.user_note.length >= 20)
    languages.push({ source: 'user_note', language: 'en', confidence: round(between(r, 0.85, 0.99), 2) });
  if (languages.length) facet('language', 'natural_language', { items: languages });

  // Where and how: location, motion, audio route, weather, place.
  const place = PLACES[p.cluster];
  const observations: Record<string, unknown>[] = [];
  const outputs = p.ctx === 'car' ? [{ port_type: 'car_audio', port_name: 'CarPlay' }]
    : p.headphones ? [pick(r, [{ port_type: 'bluetooth_a2dp', port_name: 'Wireless Earbuds' }, { port_type: 'headphones', port_name: 'Headphones' },
      { port_type: 'bluetooth_le', port_name: 'Sport Earbuds' }])]
    : [{ port_type: 'built_in_speaker', port_name: 'Speaker' }];
  observations.push({ key: 'context.audio_route', provenance: 'av_audio_session', value: { outputs, inputs: [{ port_type: 'built_in_mic', port_name: 'Microphone' }] } });
  const battery = round(between(r, 0.15, 1), 2);
  const device: Record<string, unknown> = { battery_level: battery, battery_state: p.ctx === 'car' ? 'charging' : battery > 0.98 ? 'full' : 'unplugged',
    low_power_mode: battery < 0.2, thermal_state: 'nominal', interface_style: loc.hour >= 20 || loc.hour < 8 ? 'dark' : 'light', locale: 'en_GB',
    uses_24_hour_clock: true };
  if (method !== 'share_extension') device.orientation = 'portrait';
  observations.push({ key: 'context.device', provenance: 'device_state', value: device });
  const cellular = p.ctx !== 'still' || chance(r, 0.25);
  observations.push({ key: 'context.network', provenance: 'nw_path', value: { interface: cellular ? 'cellular' : 'wifi', expensive: cellular, constrained: false } });
  observations.push({ key: 'context.enabled', provenance: 'settings', value: { groups: p.located ? ['device_context', 'location'] : ['device_context'] } });
  if (p.prev) observations.push({ key: 'context.burst', provenance: 'last_saved', value: { previous_capture_id: p.prev.id, seconds_since_previous: p.prev.seconds } });

  if (p.located) {
    const lat = round(place.lat + between(r, -0.0005, 0.0005), 6), lon = round(place.lon + between(r, -0.0005, 0.0005), 6);
    const l: Record<string, unknown> = { latitude: lat, longitude: lon, horizontal_accuracy_meters: round(between(r, 5, 35), 1),
      observed_at: stamp(Math.floor(p.t / 1000) * 1000 - int(r, 1, 8) * 1000), provenance: 'core_location_request',
      altitude_meters: round(between(r, 5, 80), 1), vertical_accuracy_meters: round(between(r, 3, 15), 1) };
    if (p.ctx === 'car') Object.assign(l, { speed_meters_per_second: round(between(r, 8.5, 19), 1), speed_accuracy_meters_per_second: round(between(r, 0.5, 1.5), 1),
      course_degrees: int(r, 0, 359), course_accuracy_degrees: int(r, 5, 20) });
    else if (p.ctx === 'walk') Object.assign(l, { speed_meters_per_second: round(between(r, 1.1, 1.7), 1), speed_accuracy_meters_per_second: round(between(r, 0.3, 0.8), 1),
      course_degrees: int(r, 0, 359), course_accuracy_degrees: int(r, 10, 30) });
    md.capture_location = l;
    facet('place', 'geocoder', { items: [{ target: 'capture', sub_locality: place.sub_locality, locality: LOCALITY, region: LOCALITY, country: 'Portugal',
      nearby: { name: place.nearby, distance_meters: int(r, 20, 250) } }] });
    const hour = Math.floor(p.t / 3_600_000) * 3_600_000;
    const day = loc.offset === 3600 ? loc.hour >= 8 && loc.hour < 19 : loc.hour >= 7 && loc.hour < 17;
    const code = weighted(r, [[0, 4], [1, 3], [2, 3], [3, 2], [61, 2], [63, 1], [80, 1], [45, 0.5]] as const);
    const temp = round(between(r, loc.offset === 3600 ? 16 : 13, loc.offset === 3600 ? 23 : 19) - (day ? 0 : 3), 1);
    const wind = round(between(r, 1, 7), 1);
    const wet = code >= 61;
    const w: Record<string, unknown> = { observed_hour: stamp(hour), temperature_celsius: temp, apparent_temperature_celsius: round(temp - wind * 0.3, 1),
      relative_humidity_percent: int(r, wet ? 80 : 55, wet ? 97 : 85), precipitation_millimeters: wet ? round(between(r, 0.2, 3), 1) : 0,
      cloud_cover_percent: code <= 1 ? int(r, 0, 15) : code === 2 ? int(r, 30, 60) : int(r, 85, 100), wind_speed_meters_per_second: wind,
      weather_code: code, is_day: day, source: 'open-meteo.com', requested_latitude: round(lat, 2), requested_longitude: round(lon, 2) };
    const cond = condition(code);
    if (cond) w.condition = cond;
    facet('weather', 'open_meteo', w);
  }
  if (p.motion) {
    const ws = Math.floor(p.t / 1000) * 1000 - 600_000, we = ws + 1_200_000;
    const sample = (startMs: number, activities: string[], confidence: string) => ({ started_at: stamp(startMs), activities, confidence });
    let segments: ReturnType<typeof sample>[], at: ReturnType<typeof sample>;
    if (p.ctx === 'car') {
      at = sample(ws - int(r, 2, 40) * 60_000, ['automotive'], 'high');
      segments = [at, sample(Math.floor(p.t / 1000) * 1000 + int(r, 2, 6) * 60_000, ['automotive', 'stationary'], 'high')];
    } else if (p.ctx === 'walk') {
      const before = sample(ws - int(r, 10, 90) * 60_000, ['stationary'], 'high');
      at = sample(Math.floor(p.t / 1000) * 1000 - int(r, 1, 8) * 60_000, ['walking'], pick(r, ['medium', 'high']));
      segments = [before, at];
    } else {
      at = sample(ws - int(r, 5, 120) * 60_000, ['stationary'], 'high');
      segments = [at];
    }
    facet('motion_activity', 'core_motion', { window_start: stamp(ws), window_end: stamp(we), at_capture: at, segments });
  }

  // Comments, after the capture: a typed one, a spoken one.
  const comments: { id: string; json: Record<string, unknown>; audio?: Buffer }[] = [];
  const commentBase = (at: number, id: string) => {
    const l = local(at);
    return { schema_version: 1, schema_minor: 2, capture_id: p.id, comment_id: id, added_at: stamp(at), local_datetime: l.datetime,
      timezone_identifier: ZONE, utc_offset_seconds: l.offset, producer: PRODUCER };
  };
  let commentAt = p.t + int(r, 3, 180) * 60_000 + int(r, 0, 59_999);
  if (commentText || p.textComment) {
    const id = uuid(r);
    const t = commentText ?? pick(r, TEXT_COMMENTS);
    comments.push({ id, json: { ...commentBase(commentAt, id), text: t } });
    if (commentText) peopleSource = id;
    commentAt += int(r, 5, 120) * 60_000;
  }
  if (p.audioComment) {
    const id = uuid(r);
    const seconds = round(between(r, 1.5, 3), 1);
    const audio = wav(seconds, int(r, 200, 400));
    comments.push({ id, audio, json: { ...commentBase(commentAt, id), audio: { relative_path: `comments/${id}.wav`, uti: 'com.microsoft.waveform-audio',
      mime_type: 'audio/wav', byte_count: audio.length, sha256: sha256(audio), media: { duration_seconds: seconds } } } });
    transcripts.push({ attachment_id: id, text: pick(r, VOICE_COMMENTS), locale: 'en_GB', segments: [] });
    sounds.push({ attachment_id: id, labels: [{ label: 'speech', confidence: round(between(r, 0.7, 0.95), 2) }] });
  }
  if (recognized.length) facet('text_recognition', 'vision', { items: recognized });
  if (transcripts.length) facet('transcript', 'speech_recognition', { items: transcripts });
  if (sounds.length) facet('sound_classification', 'sound_analysis', { items: sounds });
  if (peopleSource) model.people = p.names.map(name => ({ name, source: peopleSource }));

  // The package: content, metadata.json, then complete.json. Then comments. Then the device enrichment, assets first.
  await fsp.mkdir(attachments.length ? path.join(dir, 'content') : dir, { recursive: true });
  const manifest: Record<string, unknown>[] = [];
  const metaAttachments = attachments.map(at => {
    const rel = `content/${at.id}.${at.ext}`;
    manifest.push({ relative_path: rel, byte_count: at.bytes.length, sha256: sha256(at.bytes) });
    return { attachment_id: at.id, relative_path: rel, byte_count: at.bytes.length, sha256: sha256(at.bytes), ...at.meta };
  });
  for (const at of attachments) await fsp.writeFile(path.join(dir, 'content', `${at.id}.${at.ext}`), at.bytes);
  const metadata = json({ schema_version: 1, schema_minor: 2, capture_id: p.id, captured_at: stamp(p.t), local_datetime: loc.datetime,
    timezone_identifier: ZONE, utc_offset_seconds: loc.offset, capture_method: method, content_types: contentTypes, urls: [], producer: PRODUCER,
    attachments: metaAttachments, metadata_observations: observations, extensions: {}, ...md });
  await fsp.writeFile(path.join(dir, 'metadata.json'), metadata);
  manifest.unshift({ relative_path: 'metadata.json', byte_count: metadata.length, sha256: sha256(metadata) });
  const complete = json({ schema_version: 1, schema_minor: 2, capture_id: p.id, files: manifest });
  await fsp.writeFile(path.join(dir, 'complete.json'), complete);
  if (comments.length) {
    await fsp.mkdir(path.join(dir, 'comments'));
    for (const k of comments) {
      if (k.audio) await fsp.writeFile(path.join(dir, 'comments', `${k.id}.wav`), k.audio);
      await fsp.writeFile(path.join(dir, 'comments', `${k.id}.json`), json(k.json));
    }
  }
  await fsp.mkdir(deviceDir, { recursive: true });
  if (assets.length) {
    await fsp.mkdir(path.join(deviceDir, 'assets'));
    for (const x of assets) await fsp.writeFile(path.join(deviceDir, 'assets', x.name), x.bytes);
  }
  await fsp.writeFile(path.join(deviceDir, 'enrichment.json'), json({ schema_version: 1, schema_minor: 2, capture_id: p.id, layer: 'device',
    package_digest: sha256(complete), producer: DEVICE_PRODUCER, generated_at: stamp(deviceAt), facets }));
  return { model, serverAt };
}

// ---- where it may write ----

/** `p` with symbolic links resolved as far as it exists (so /tmp and /private/tmp compare equal). */
function realish(p: string): string {
  const rest: string[] = [];
  let cur = p;
  while (!fs.existsSync(cur)) {
    const parent = path.dirname(cur);
    if (parent === cur) break;
    rest.unshift(path.basename(cur));
    cur = parent;
  }
  return path.join(fs.realpathSync(cur), ...rest);
}
const within = (base: string, p: string) => { const rel = path.relative(base, p); return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel)); };

const isDir = (p: string) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };

/** A Hippo folder has `captures/` holding a four-digit year directory, or `captures/` beside `enrichments/`.
 *  A `captures` folder of some other kind (holiday photos, say) is not one. */
function looksLikeHippoFolder(d: string): boolean {
  const captures = path.join(d, 'captures');
  if (!isDir(captures)) return false;
  if (isDir(path.join(d, 'enrichments'))) return true;
  try { return fs.readdirSync(captures).some(n => /^\d{4}$/.test(n) && isDir(path.join(captures, n))); } catch { return false; }
}

function checkOut(out: string): void {
  const real = realish(out);
  if (fs.existsSync(REPO_FIXTURES) && within(fs.realpathSync(REPO_FIXTURES), real))
    throw new Error(`${out} is inside the repository's fixtures/ directory; write the sample somewhere else`);
  for (let d = path.dirname(real); ; d = path.dirname(d)) {
    if (looksLikeHippoFolder(d)) throw new Error(`${out} is inside a Hippo folder (${d}); write the sample somewhere else`);
    if (path.dirname(d) === d) break;
  }
  if (fs.existsSync(out)) {
    if (!fs.statSync(out).isDirectory()) throw new Error(`${out} exists and is not a directory`);
    if (fs.readdirSync(out).length) throw new Error(`${out} is not empty; give a new or empty directory`);
  }
}

async function eachLimited<T>(items: T[], n: number, fn: (x: T) => Promise<void>): Promise<void> {
  let next = 0;
  const worker = async () => { while (next < items.length) await fn(items[next++]); };
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
}

/** Writes a new sample folder at `out` (which must not exist or be empty). Defaults: 300 captures, seed 1, ending today. */
export async function writeSample(opts: SampleOptions): Promise<{ captures: number }> {
  const count = opts.count ?? 300, seed = opts.seed ?? 1, end = opts.end ?? todayLocal();
  if (!Number.isInteger(count) || count < 1 || count > MAX_COUNT) throw new Error(`count must be a whole number from 1 to ${MAX_COUNT}`);
  if (!Number.isSafeInteger(seed)) throw new Error('seed must be a whole number');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(end) || new Date(`${end}T00:00:00Z`).toISOString().slice(0, 10) !== end) throw new Error('end must be a date YYYY-MM-DD');
  const out = path.resolve(opts.out);
  checkOut(out);
  const existed = fs.existsSync(out);
  fs.mkdirSync(out, { recursive: true });
  try {
    const plans = plan(count, seed, end);
    const written = new Map<string, Written>();
    await eachLimited(plans, 4, async p => { written.set(p.id, await writeCapture(out, p)); });

    // The server enrichment, made exactly as `hippo enrich` would from what the folder now holds, with hand-made model fields.
    const scan = await scanFolder(out);
    if (scan.pending.length || scan.captures.length !== count)
      throw new Error(`the sample folder reads back as ${scan.captures.length} complete and ${scan.pending.length} pending captures, expected ${count}`);
    for (const c of scan.captures) {
      const w = written.get(c.id)!;
      const value = normalize(w.model, c, []);
      if (!value) throw new Error(`sample model fields for ${c.id} do not fit the contract`);
      const digest = inputDigest(c, picturesToSend(c).map(a => a.sha256));
      const doc = composeServerDoc(c, { model: { value, provenance: 'sample', digest }, circumstances: deriveCircumstances(c), now: new Date(w.serverAt) });
      if (doc) await writeServerDoc(c, doc);
    }
    return { captures: scan.captures.length };
  } catch (e) {
    // Leave nothing half-made: the directory was new or empty.
    if (existed) for (const n of fs.readdirSync(out)) fs.rmSync(path.join(out, n), { recursive: true, force: true });
    else fs.rmSync(out, { recursive: true, force: true });
    throw e;
  }
}
