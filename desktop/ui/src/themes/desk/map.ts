// What lies under the items in two layouts (spec section 8): the place layout's paper map sheet and the time layout's ruled
// columns. The sheet is a printed map: paper with a neat line, a graticule with its figures, a scale bar and a north mark.
// With map tiles on, OpenStreetMap's raster tiles are printed inside the neat line (desaturated, multiplied with the
// paper's tone) and the attribution runs along the lower edge; with tiles off, or when any tile fails, it is the plain sheet
// with the place names written where no pile or pile label covers them. It unfolds (two folds opening) when the place
// layout arrives and folds away when it leaves. Text from captures reaches the sheet only through fillText.
import { BoxGeometry, BufferAttribute, BufferGeometry, Group, LineBasicMaterial, LineSegments, Mesh, MeshBasicMaterial,
  MeshStandardMaterial, PlaneGeometry } from 'three';
import type { Material, Object3D } from 'three';
import type { Backdrop } from '../../layout/types.ts';
import type { BackdropMotion } from '../types.ts';
import { lonLatToWorld, MAP_PX_PER_UNIT, TILE_SIZE, tilesFor, tileUrl, worldToLonLat } from '../../layout/mercator.ts';
import { faceTexture, fitLines } from '../../scene/textures.ts';
import { FONT, INK, MAP } from './palette.ts';

type MapBackdrop = Extract<Backdrop, { type: 'map' }>;
type ColumnsBackdrop = Extract<Backdrop, { type: 'columns' }>;
interface Box { x0: number; x1: number; y0: number; y1: number }

// ---------------------------------------------------------------- timing

const UNFOLD_MS = 600, FOLD_MS = 520, FADE_MS = 160;
const reducedMotion = typeof matchMedia === 'function' ? matchMedia('(prefers-reduced-motion: reduce)') : undefined;
const clamp01 = (v: number) => Math.max(0, Math.min(1, v));
const easeInOut = (u: number) => (u < 0.5 ? 4 * u * u * u : 1 - (-2 * u + 2) ** 3 / 2);
const span = (t: number, from: number, to: number) => easeInOut(clamp01((t - from) / (to - from)));

// ---------------------------------------------------------------- tiles

/** Processed tiles kept for the next sheet (a sheet is rebuilt whenever the set changes), and recent failures. */
const TILE_CACHE = 64, TILE_RETRY_MS = 60_000, TILE_TIMEOUT_MS = 12_000;
const tileCache = new Map<string, HTMLCanvasElement>();
const tileFailed = new Map<string, number>();
const tileLoading = new Map<string, Promise<HTMLCanvasElement | null>>();

/** One tile, desaturated (keeping a little colour) and multiplied with the paper's tint, as a 256-pixel canvas. */
function processTile(img: HTMLImageElement): HTMLCanvasElement {
  const c = document.createElement('canvas');
  c.width = c.height = TILE_SIZE;
  const ctx = c.getContext('2d', { willReadFrequently: true })!;
  ctx.drawImage(img, 0, 0, TILE_SIZE, TILE_SIZE);
  const data = ctx.getImageData(0, 0, TILE_SIZE, TILE_SIZE);
  const tint = ctx.createImageData(1, 1);
  const probe = document.createElement('canvas').getContext('2d')!;
  probe.fillStyle = MAP.tint;
  probe.fillRect(0, 0, 1, 1);
  tint.data.set(probe.getImageData(0, 0, 1, 1).data);
  const [tr, tg, tb] = [tint.data[0] / 255, tint.data[1] / 255, tint.data[2] / 255];
  const keep = MAP.keepColour;
  const d = data.data;
  for (let i = 0; i < d.length; i += 4) {
    const r = d[i] / 255, g = d[i + 1] / 255, b = d[i + 2] / 255;
    const l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    // A slightly steeper curve, so streets (white) and blocks (light grey) part more on the paper.
    const curve = (v: number) => clamp01((v - 0.62) * 1.35 + 0.66);
    d[i] = 255 * curve(l + (r - l) * keep) * tr;
    d[i + 1] = 255 * curve(l + (g - l) * keep) * tg;
    d[i + 2] = 255 * curve(l + (b - l) * keep) * tb;
  }
  ctx.putImageData(data, 0, 0);
  return c;
}

/** A tile from the tile server (anonymous CORS, so its pixels can be read), processed; null when it fails or times out. */
function loadTile(url: string): Promise<HTMLCanvasElement | null> {
  const hit = tileCache.get(url);
  if (hit) { tileCache.delete(url); tileCache.set(url, hit); return Promise.resolve(hit); }
  const failed = tileFailed.get(url);
  if (failed !== undefined && performance.now() - failed < TILE_RETRY_MS) return Promise.resolve(null);
  const pending = tileLoading.get(url);
  if (pending) return pending;
  const p = new Promise<HTMLCanvasElement | null>(resolve => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.decoding = 'async';
    // The page sends no referrer anywhere, but the tile server's usage policy requires one and answers a request without
    // it with an "Access blocked" picture (status 200). Tiles alone send the page's origin (the local address, no path).
    img.referrerPolicy = 'origin';
    const timer = setTimeout(() => { img.src = ''; resolve(null); }, TILE_TIMEOUT_MS);
    img.onload = () => {
      clearTimeout(timer);
      try { resolve(processTile(img)); } catch { resolve(null); }
    };
    img.onerror = () => { clearTimeout(timer); resolve(null); };
    img.src = url;
  }).then(c => {
    tileLoading.delete(url);
    if (!c) { tileFailed.set(url, performance.now()); return null; }
    tileFailed.delete(url);
    tileCache.set(url, c);
    while (tileCache.size > TILE_CACHE) tileCache.delete(tileCache.keys().next().value!);
    return c;
  });
  tileLoading.set(url, p);
  return p;
}

// ---------------------------------------------------------------- drawing the sheet

/** Canvas pixels per desk unit on the sheet, before the size cap. */
const SHEET_PX = 16, SHEET_MAX_PX = 2048;
/** The printed area is inset this far from the sheet's edge (desk units); the margin holds the figures and attribution. */
const INSET = 1.7;
const NAME_SIZE = 2.1, NAME_SMALL = 1.5, MINOR_NAME_SIZE = 1.2, MINOR_NAME_SMALL = 0.95, FIGURE_SIZE = 0.78, ATTRIBUTION_SIZE = 0.8;
/** Minor graticule lines between the major ones (plain sheet only). */
const MINOR_PER_MAJOR = 5;
const ATTRIBUTION = '© OpenStreetMap contributors';
/** Graticule steps in degrees, finest first; the sheet uses the finest that draws no more than about six lines across. */
const GRID_STEPS = [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 45];
/** Scale bar lengths in metres. */
const SCALE_STEPS = [20, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10_000, 20_000, 25_000, 50_000, 100_000, 200_000, 500_000, 1_000_000, 2_000_000];

const overlaps = (a: Box, b: Box) => a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1;
const inside = (a: Box, r: Box) => a.x0 >= r.x0 && a.x1 <= r.x1 && a.y0 >= r.y0 && a.y1 <= r.y1;

function hashOf(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return h >>> 0;
}

/** Degrees as a map figure: 9°08′W, 38°43′N (with seconds when the step is finer than a minute). */
function figure(v: number, axis: 'lon' | 'lat', step: number): string {
  const hemi = axis === 'lon' ? (v < 0 ? 'W' : v > 0 ? 'E' : '') : (v < 0 ? 'S' : v > 0 ? 'N' : '');
  const a = Math.abs(v);
  let d = Math.floor(a), m = (a - d) * 60;
  if (step >= 1) return `${Math.round(a)}°${hemi}`;
  if (step * 60 >= 1 - 1e-9) {
    m = Math.round(m);
    if (m === 60) { d++; m = 0; }
    return `${d}°${String(m).padStart(2, '0')}′${hemi}`;
  }
  let mm = Math.floor(m), s = Math.round((m - mm) * 60);
  if (s === 60) { mm++; s = 0; }
  if (mm === 60) { d++; mm = 0; }
  return `${d}°${String(mm).padStart(2, '0')}′${String(s).padStart(2, '0')}″${hemi}`;
}

interface SheetFrame {
  w: number; h: number;
  /** Desk point to sheet point (desk units from the sheet's top-left corner, y down). */
  toSheet(x: number, y: number): { x: number; y: number };
  /** Longitude and latitude to sheet point. */
  lonLat(lon: number, lat: number): { x: number; y: number };
  inner: Box;
  /** The piles and their labels, in sheet units. */
  covered: Box[];
}

function frameOf(b: MapBackdrop): SheetFrame {
  const centre = lonLatToWorld(b.centerLon, b.centerLat, b.zoom);
  const toSheet = (x: number, y: number) => ({ x: x - (b.x - b.width / 2), y: b.y + b.height / 2 - y });
  return {
    w: b.width, h: b.height, toSheet,
    lonLat: (lon, lat) => {
      const p = lonLatToWorld(lon, lat, b.zoom);
      return { x: b.width / 2 + (p.x - centre.x) / MAP_PX_PER_UNIT, y: b.height / 2 + (p.y - centre.y) / MAP_PX_PER_UNIT };
    },
    inner: { x0: INSET, x1: b.width - INSET, y0: INSET, y1: b.height - INSET },
    covered: (b.avoid ?? []).map(r => {
      const a = toSheet(r.x0, r.y1), c = toSheet(r.x1, r.y0);
      return { x0: a.x, x1: c.x, y0: a.y, y1: c.y };
    }),
  };
}

function drawPaper(ctx: CanvasRenderingContext2D, f: SheetFrame, seed: number): void {
  ctx.fillStyle = MAP.paper;
  ctx.fillRect(0, 0, f.w, f.h);
  // Fibres: short faint strokes, the same on every build of the same sheet.
  let s = seed || 1;
  const rnd = () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; };
  const n = Math.round(f.w * f.h * 0.9);
  for (let k = 0; k < n; k++) {
    ctx.fillStyle = rnd() < 0.5 ? MAP.fibre : MAP.fibreLight;
    ctx.fillRect(rnd() * f.w, rnd() * f.h, 0.1 + rnd() * 0.5, 0.05);
  }
  const r = Math.hypot(f.w, f.h) / 2;
  const age = ctx.createRadialGradient(f.w / 2, f.h / 2, r * 0.45, f.w / 2, f.h / 2, r);
  age.addColorStop(0, 'rgba(0, 0, 0, 0)');
  age.addColorStop(1, MAP.age);
  ctx.fillStyle = age;
  ctx.fillRect(0, 0, f.w, f.h);
}

/** The graticule: faint lines over the printed area (plain sheet only) and their figures in the margin (both). */
function drawGraticule(ctx: CanvasRenderingContext2D, f: SheetFrame, b: MapBackdrop, lines: boolean): void {
  const c = lonLatToWorld(b.centerLon, b.centerLat, b.zoom);
  const hw = (f.w / 2) * MAP_PX_PER_UNIT, hh = (f.h / 2) * MAP_PX_PER_UNIT;
  const nw = worldToLonLat(c.x - hw, c.y - hh, b.zoom), se = worldToLonLat(c.x + hw, c.y + hh, b.zoom);
  const lonSpan = se.lon - nw.lon;
  const step = GRID_STEPS.find(st => lonSpan / st <= 6) ?? 45;
  ctx.save();
  ctx.lineWidth = 0.05;
  ctx.strokeStyle = MAP.grid;
  ctx.fillStyle = MAP.gridText;
  ctx.font = `${FIGURE_SIZE}px ${FONT.sans}`;
  ctx.textBaseline = 'middle';
  const { inner } = f;
  if (lines) {
    // The minor lines first, faint, so the major ones lie over them.
    const minor = step / MINOR_PER_MAJOR;
    ctx.strokeStyle = MAP.gridMinor;
    ctx.lineWidth = 0.035;
    ctx.beginPath();
    for (let lon = Math.ceil(nw.lon / minor) * minor; lon <= se.lon; lon += minor) {
      const x = f.lonLat(lon, b.centerLat).x;
      if (x > inner.x0 && x < inner.x1) { ctx.moveTo(x, inner.y0); ctx.lineTo(x, inner.y1); }
    }
    for (let lat = Math.ceil(se.lat / minor) * minor; lat <= nw.lat; lat += minor) {
      const y = f.lonLat(b.centerLon, lat).y;
      if (y > inner.y0 && y < inner.y1) { ctx.moveTo(inner.x0, y); ctx.lineTo(inner.x1, y); }
    }
    ctx.stroke();
    ctx.strokeStyle = MAP.grid;
    ctx.lineWidth = 0.05;
  }
  for (let lon = Math.ceil(nw.lon / step) * step; lon <= se.lon; lon += step) {
    const x = f.lonLat(lon, b.centerLat).x;
    if (x < inner.x0 + 0.5 || x > inner.x1 - 0.5) continue;
    if (lines) { ctx.beginPath(); ctx.moveTo(x, inner.y0); ctx.lineTo(x, inner.y1); ctx.stroke(); }
    ctx.textAlign = 'center';
    const text = figure(lon, 'lon', step);
    ctx.fillText(text, x, INSET / 2);
  }
  const latStep = step;
  for (let lat = Math.ceil(se.lat / latStep) * latStep; lat <= nw.lat; lat += latStep) {
    const y = f.lonLat(b.centerLon, lat).y;
    if (y < inner.y0 + 0.5 || y > inner.y1 - 0.5) continue;
    if (lines) { ctx.beginPath(); ctx.moveTo(inner.x0, y); ctx.lineTo(inner.x1, y); ctx.stroke(); }
    ctx.save();
    ctx.translate(INSET / 2, y);
    ctx.rotate(-Math.PI / 2);
    ctx.textAlign = 'center';
    ctx.fillText(figure(lat, 'lat', latStep), 0, 0);
    ctx.restore();
  }
  ctx.restore();
}

/** The neat line: a firm line round the printed area and a hairline just outside it. */
function drawNeatLine(ctx: CanvasRenderingContext2D, f: SheetFrame): void {
  const { inner } = f;
  ctx.save();
  ctx.strokeStyle = MAP.frame;
  ctx.lineWidth = 0.09;
  ctx.strokeRect(inner.x0, inner.y0, inner.x1 - inner.x0, inner.y1 - inner.y0);
  ctx.lineWidth = 0.03;
  ctx.strokeRect(inner.x0 - 0.28, inner.y0 - 0.28, inner.x1 - inner.x0 + 0.56, inner.y1 - inner.y0 + 0.56);
  ctx.restore();
}

/** The first of `candidates` (top-left corners) where a `w` × `h` box stays inside `within` and clear of `avoid`. */
function freeSpot(candidates: { x: number; y: number }[], w: number, h: number, within: Box, avoid: Box[]): Box | undefined {
  for (const c of candidates) {
    const box = { x0: c.x, x1: c.x + w, y0: c.y, y1: c.y + h };
    if (inside(box, within) && !avoid.some(a => overlaps(box, a))) return box;
  }
  return undefined;
}

/** A scale bar of a round length, in alternating blocks, with its length written after it; returns the box it took. */
function drawScale(ctx: CanvasRenderingContext2D, f: SheetFrame, b: MapBackdrop, avoid: Box[], backed: boolean): Box | undefined {
  const metresPerUnit = (156543.03392 * Math.cos((b.centerLat * Math.PI) / 180) / 2 ** b.zoom) * MAP_PX_PER_UNIT;
  if (!(metresPerUnit > 0)) return undefined;
  const metres = [...SCALE_STEPS].reverse().find(m => m / metresPerUnit <= 12) ?? SCALE_STEPS[0];
  const len = metres / metresPerUnit;
  if (len < 2) return undefined;
  const text = metres >= 1000 ? `${(metres / 1000).toLocaleString()} km` : `${metres} m`;
  ctx.save();
  ctx.font = `${FIGURE_SIZE * 1.15}px ${FONT.sans}`;
  const tw = ctx.measureText(text).width;
  const w = len + 0.8 + tw + 1.2, h = 1.9;
  const { inner } = f;
  const box = freeSpot([
    { x: inner.x0 + 0.9, y: inner.y1 - 0.9 - h }, { x: inner.x1 - 0.9 - w, y: inner.y1 - 0.9 - h },
    { x: inner.x0 + 0.9, y: inner.y0 + 0.9 }, { x: inner.x1 - 0.9 - w, y: inner.y0 + 0.9 },
  ], w, h, inner, avoid);
  if (!box) { ctx.restore(); return undefined; }
  if (backed) { ctx.fillStyle = MAP.paper; ctx.globalAlpha = 0.86; ctx.fillRect(box.x0, box.y0, w, h); ctx.globalAlpha = 1; }
  const x = box.x0 + 0.6, y = box.y0 + h / 2 - 0.2;
  const seg = len / 4;
  for (let k = 0; k < 4; k++) {
    ctx.fillStyle = k % 2 ? MAP.scaleLight : MAP.scaleDark;
    ctx.fillRect(x + k * seg, y, seg, 0.4);
  }
  ctx.strokeStyle = MAP.scaleDark;
  ctx.lineWidth = 0.05;
  ctx.strokeRect(x, y, len, 0.4);
  ctx.fillStyle = MAP.gridText;
  ctx.textBaseline = 'middle';
  ctx.textAlign = 'left';
  ctx.fillText(text, x + len + 0.6, y + 0.2);
  ctx.restore();
  return box;
}

/** A north mark: a slim needle with N over it, in a free corner. */
function drawNorth(ctx: CanvasRenderingContext2D, f: SheetFrame, avoid: Box[]): Box | undefined {
  const w = 1.8, h = 3.6, { inner } = f;
  const box = freeSpot([
    { x: inner.x1 - 1 - w, y: inner.y0 + 1 }, { x: inner.x0 + 1, y: inner.y0 + 1 },
    { x: inner.x1 - 1 - w, y: inner.y1 - 1 - h }, { x: inner.x0 + 1, y: inner.y1 - 1 - h },
  ], w, h, inner, avoid);
  if (!box) return undefined;
  const cx = box.x0 + w / 2;
  ctx.save();
  ctx.fillStyle = MAP.scaleDark;
  ctx.beginPath();
  ctx.moveTo(cx, box.y0 + 1.3); ctx.lineTo(cx + 0.42, box.y1); ctx.lineTo(cx, box.y1 - 0.5); ctx.closePath(); ctx.fill();
  ctx.strokeStyle = MAP.scaleDark;
  ctx.lineWidth = 0.05;
  ctx.beginPath();
  ctx.moveTo(cx, box.y0 + 1.3); ctx.lineTo(cx - 0.42, box.y1); ctx.lineTo(cx, box.y1 - 0.5); ctx.closePath(); ctx.stroke();
  ctx.font = `600 ${FIGURE_SIZE * 1.4}px ${FONT.map}`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText('N', cx, box.y0 + 0.5);
  ctx.restore();
  return box;
}

/**
 * The place names, in italic book lettering with a paper halo, each as near its place as it can be without lying under a
 * pile or a pile's label, another name, the scale bar or the north mark; smaller when there is no room at full size, and
 * left out only when there is none at all.
 */
function drawNames(ctx: CanvasRenderingContext2D, f: SheetFrame, b: MapBackdrop, avoid: Box[]): void {
  const taken = [...avoid, ...f.covered];
  const within = { x0: f.inner.x0 + 0.6, x1: f.inner.x1 - 0.6, y0: f.inner.y0 + 0.6, y1: f.inner.y1 - 0.6 };
  const rings = [0, 2.5, 5, 8, 11, 15, 19, 24, 30, 37, 45];
  for (const l of b.labels) {
    const at = f.toSheet(l.x, l.y);
    const sizes = l.minor ? [MINOR_NAME_SIZE, MINOR_NAME_SMALL] : [NAME_SIZE, NAME_SMALL];
    for (const size of sizes) {
      ctx.font = l.minor ? `${size}px ${FONT.map}` : `italic ${size}px ${FONT.map}`;
      const [line] = fitLines(l.text, Math.min(30, within.x1 - within.x0), 1, s => ctx.measureText(s).width);
      if (!line) break;
      const w = ctx.measureText(line).width + 0.8, h = size * 1.25;
      const candidates: { x: number; y: number }[] = [];
      for (const r of rings) {
        const steps = r === 0 ? 1 : 16;
        for (let k = 0; k < steps; k++) {
          const a = (k / steps) * Math.PI * 2;
          candidates.push({ x: at.x + Math.cos(a) * r * 1.4 - w / 2, y: at.y + Math.sin(a) * r - h / 2 });
        }
      }
      const box = freeSpot(candidates, w, h, within, taken);
      if (!box) continue;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.lineJoin = 'round';
      ctx.strokeStyle = MAP.nameHalo;
      ctx.lineWidth = size * 0.22;
      const cx = (box.x0 + box.x1) / 2, cy = (box.y0 + box.y1) / 2;
      ctx.strokeText(line, cx, cy);
      ctx.fillStyle = l.minor ? MAP.nameMinor : MAP.name;
      ctx.fillText(line, cx, cy);
      taken.push(box);
      break;
    }
  }
}

/** The two fold creases, a third of the way in from each side: a shaded edge beside a lit one. */
function drawCreases(ctx: CanvasRenderingContext2D, f: SheetFrame): void {
  for (const x of [f.w / 3, (2 * f.w) / 3]) {
    ctx.fillStyle = MAP.crease;
    ctx.fillRect(x - 0.09, 0, 0.09, f.h);
    ctx.fillStyle = MAP.creaseLight;
    ctx.fillRect(x, 0, 0.12, f.h);
  }
}

/** The attribution along the lower edge, in the margin, at whichever end no pile covers. */
function drawAttribution(ctx: CanvasRenderingContext2D, f: SheetFrame): void {
  ctx.save();
  ctx.font = `${ATTRIBUTION_SIZE}px ${FONT.sans}`;
  const w = ctx.measureText(ATTRIBUTION).width;
  const y = f.h - INSET / 2;
  const right = { x0: f.inner.x1 - w, x1: f.inner.x1, y0: y - ATTRIBUTION_SIZE, y1: y + ATTRIBUTION_SIZE };
  const atRight = !f.covered.some(c => overlaps(c, right));
  ctx.fillStyle = MAP.attribution;
  ctx.textBaseline = 'middle';
  ctx.textAlign = atRight ? 'right' : 'left';
  ctx.fillText(ATTRIBUTION, atRight ? f.inner.x1 : f.inner.x0, y);
  ctx.restore();
}

/** Draws the whole sheet: with `tiles` (all of them loaded) the printed map, else the plain sheet with place names. */
function drawSheet(canvas: HTMLCanvasElement, b: MapBackdrop, tiles: { canvas: HTMLCanvasElement; px: number; py: number; size: number }[] | undefined): void {
  const f = frameOf(b);
  const ctx = canvas.getContext('2d')!;
  ctx.setTransform(canvas.width / f.w, 0, 0, canvas.height / f.h, 0, 0);
  ctx.clearRect(0, 0, f.w, f.h);
  drawPaper(ctx, f, hashOf(`${b.centerLat},${b.centerLon},${b.zoom}`));
  if (tiles) {
    ctx.save();
    ctx.beginPath();
    ctx.rect(f.inner.x0, f.inner.y0, f.inner.x1 - f.inner.x0, f.inner.y1 - f.inner.y0);
    ctx.clip();
    ctx.imageSmoothingQuality = 'high';
    for (const t of tiles) ctx.drawImage(t.canvas, t.px / MAP_PX_PER_UNIT, t.py / MAP_PX_PER_UNIT, t.size / MAP_PX_PER_UNIT, t.size / MAP_PX_PER_UNIT);
    ctx.restore();
  }
  drawGraticule(ctx, f, b, !tiles);
  drawNeatLine(ctx, f);
  const marks: Box[] = [];
  const scale = drawScale(ctx, f, b, f.covered, !!tiles);
  if (scale) marks.push(scale);
  const north = drawNorth(ctx, f, [...f.covered, ...marks]);
  if (north) marks.push(north);
  if (!tiles) drawNames(ctx, f, b, marks);
  else drawAttribution(ctx, f);
  drawCreases(ctx, f);
}

// ---------------------------------------------------------------- the sheet as an object

const THICK = 0.03;

/** A soft shadow texture: a dark rectangle blurred at its edges, shared by every sheet. */
let shadowTexture: ReturnType<typeof faceTexture> | undefined;
function sheetShadow(): ReturnType<typeof faceTexture> {
  if (shadowTexture) return shadowTexture;
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const ctx = c.getContext('2d')!;
  ctx.shadowColor = MAP.shadow;
  ctx.shadowBlur = 18;
  ctx.shadowOffsetX = 400;
  ctx.fillStyle = MAP.shadow;
  ctx.fillRect(22 - 400, 22, 84, 84);
  shadowTexture = faceTexture(c);
  shadowTexture.userData.shared = true;
  return shadowTexture;
}
/** How far the shadow reaches past the sheet, and how far it falls away from the key light (lower right). */
const SHADOW_SPREAD = 0.11, SHADOW_FALL = { x: 0.5, y: -0.6 };

/** A panel `w` × `h` whose top face shows the u range `u0`–`u1` of the sheet's texture. */
function panel(w: number, h: number, u0: number, u1: number, front: Material, back: Material, edge: Material): Mesh {
  const g = new BoxGeometry(w, h, THICK);
  const uv = g.getAttribute('uv') as BufferAttribute;
  // BoxGeometry's faces come in the order +x, -x, +y, -y, +z, -z, four vertices each: +z is vertices 16 to 19.
  for (let i = 16; i < 20; i++) uv.setX(i, u0 + uv.getX(i) * (u1 - u0));
  uv.needsUpdate = true;
  const mesh = new Mesh(g, [edge, edge, edge, edge, front, back]);
  mesh.receiveShadow = true;
  return mesh;
}

function mapSheet(b: MapBackdrop, opts: { mapTiles: boolean; arrive: boolean }): Object3D {
  const w = b.width, h = b.height, pw = w / 3;
  const scale = Math.min(SHEET_PX, SHEET_MAX_PX / Math.max(w, h));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(w * scale));
  canvas.height = Math.max(1, Math.round(h * scale));

  const wanted = opts.mapTiles ? tilesFor(b) : [];
  const urls = wanted.map(t => tileUrl(t.z, t.x, t.y));
  const sizeOf = (z: number) => TILE_SIZE * 2 ** (b.zoom - z);
  const ready = urls.map(u => tileCache.get(u));
  const allReady = wanted.length > 0 && ready.every(Boolean);
  drawSheet(canvas, b, allReady ? wanted.map((t, k) => ({ canvas: ready[k]!, px: t.px, py: t.py, size: sizeOf(t.z) })) : undefined);

  const texture = faceTexture(canvas);
  const front = new MeshStandardMaterial({ map: texture, roughness: 0.93, metalness: 0 });
  const back = new MeshStandardMaterial({ color: MAP.back, roughness: 0.95, metalness: 0 });
  const edge = new MeshStandardMaterial({ color: MAP.edge, roughness: 0.95, metalness: 0 });
  const materials: Material[] = [front, back, edge];

  const root = new Group();
  root.position.set(b.x, b.y, 0);
  const centre = panel(pw, h, 1 / 3, 2 / 3, front, back, edge);
  centre.position.z = THICK / 2;
  root.add(centre);
  // The outer thirds hinge on the folds, at the sheet's top surface: turned by π they lie folded over the middle third.
  const right = new Group(), left = new Group();
  right.position.set(pw / 2, 0, THICK);
  left.position.set(-pw / 2, 0, THICK);
  const rp = panel(pw, h, 2 / 3, 1, front, back, edge);
  rp.position.set(pw / 2, 0, -THICK / 2);
  const lp = panel(pw, h, 0, 1 / 3, front, back, edge);
  lp.position.set(-pw / 2, 0, -THICK / 2);
  right.add(rp);
  left.add(lp);
  root.add(right, left);

  const shadowMat = new MeshBasicMaterial({ map: sheetShadow(), transparent: true, depthWrite: false, toneMapped: false });
  materials.push(shadowMat);
  const shadow = new Mesh(new PlaneGeometry(1, 1), shadowMat);
  shadow.renderOrder = -1;
  root.add(shadow);

  let dirty = false, disposed = false;
  if (wanted.length && !allReady) {
    void Promise.all(urls.map(loadTile)).then(tiles => {
      if (disposed || tiles.some(t => !t)) return;   // a tile that fails leaves the plain sheet
      drawSheet(canvas, b, wanted.map((t, k) => ({ canvas: tiles[k]!, px: t.px, py: t.py, size: sizeOf(t.z) })));
      texture.needsUpdate = true;
      dirty = true;
    });
  }

  /** `l`, `r`: how far open each outer third is (0 folded, 1 flat); `alpha`: how present the whole sheet is. */
  const pose = (l: number, r: number, alpha: number) => {
    left.rotation.y = Math.PI * (1 - l);
    right.rotation.y = -Math.PI * (1 - r);
    const x0 = -pw / 2 - pw * Math.max(0, Math.cos(Math.PI * (1 - l)));
    const x1 = pw / 2 + pw * Math.max(0, Math.cos(Math.PI * (1 - r)));
    const sw = (x1 - x0) * (1 + 2 * SHADOW_SPREAD), sh = h * (1 + 2 * SHADOW_SPREAD * (w / h) * 0.5);
    shadow.scale.set(sw, sh, 1);
    shadow.position.set((x0 + x1) / 2 + SHADOW_FALL.x, SHADOW_FALL.y, 0.002);
    for (const m of materials) {
      const fading = alpha < 1;
      if (m !== shadowMat && m.transparent !== fading) { m.transparent = fading; m.needsUpdate = true; }
      m.opacity = alpha;
    }
    root.visible = alpha > 0.001;
  };

  let phase: 'in' | 'still' | 'out' | 'gone' = opts.arrive ? 'in' : 'still';
  let since = -1;
  // An arriving sheet starts folded and unseen, so no frame drawn before its first step can show it lying open.
  if (phase === 'still') pose(1, 1, 1);
  else if (reducedMotion?.matches) pose(1, 1, 0);
  else pose(0, 0, 0);
  const motion: BackdropMotion = {
    step(now) {
      if (since < 0) since = now;
      const t = now - since, reduced = !!reducedMotion?.matches;
      let changed = dirty;
      dirty = false;
      if (phase === 'in') {
        if (reduced) pose(1, 1, clamp01(t / FADE_MS));
        else pose(span(t, 280, UNFOLD_MS), span(t, 80, 380), clamp01(t / 120));
        if (t >= (reduced ? FADE_MS : UNFOLD_MS)) { phase = 'still'; pose(1, 1, 1); }
        changed = true;
      } else if (phase === 'out') {
        if (reduced) pose(1, 1, 1 - clamp01(t / FADE_MS));
        else pose(1 - span(t, 0, 260), 1 - span(t, 160, 420), 1 - clamp01((t - 400) / 120));
        if (t >= (reduced ? FADE_MS : FOLD_MS)) { phase = 'gone'; root.visible = false; return false; }
        changed = true;
      } else if (phase === 'gone') return false;
      return changed;
    },
    leave(now) { if (phase !== 'gone') { phase = 'out'; since = now; } },
  };
  root.userData.motion = motion;
  root.userData.dispose = () => { disposed = true; };
  return root;
}

// ---------------------------------------------------------------- the time layout's columns

const COLUMN_TEXT = 1.7, LABEL_PX = 40;
/** How high above the columns' top the day labels are written, and how far the rules reach past it. */
const COLUMN_LABEL_Y = 1.7, RULE_REACH = 3.4;
const COLUMN_FADE_MS = 320;

const unitPlane = new PlaneGeometry(1, 1);
unitPlane.userData.shared = true;

/** Chalky handwriting straight on the desk, centred at x,y. */
function chalk(text: string, x: number, y: number, maxW: number): Mesh | undefined {
  const m = document.createElement('canvas').getContext('2d')!;
  m.font = `${COLUMN_TEXT}px ${FONT.hand}`;
  const [line] = fitLines(text, maxW, 1, s => m.measureText(s).width);
  if (!line) return undefined;
  const w = m.measureText(line).width + 0.6, h = COLUMN_TEXT * 1.5;
  const c = document.createElement('canvas');
  c.width = Math.ceil(w * LABEL_PX); c.height = Math.ceil(h * LABEL_PX);
  const ctx = c.getContext('2d')!;
  ctx.scale(c.width / w, c.height / h);
  ctx.font = `${COLUMN_TEXT}px ${FONT.hand}`;
  ctx.fillStyle = INK.chalk;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(line, w / 2, h / 2);
  const mesh = new Mesh(unitPlane, new MeshBasicMaterial({ map: faceTexture(c), transparent: true, depthWrite: false, toneMapped: false, opacity: INK.chalkTextOpacity }));
  mesh.scale.set(w, h, 1);
  mesh.position.set(x, y, 0.01);
  mesh.renderOrder = 1;
  return mesh;
}

/** Faint ruled columns: a chalk rule between neighbouring days (and at the outer edges), the day written above each. */
function columns(b: ColumnsBackdrop, opts: { arrive: boolean }): Object3D {
  const group = new Group();
  const xs = new Set<number>();
  for (const c of b.columns) { xs.add(c.x - c.width / 2); xs.add(c.x + c.width / 2); }
  const verts: number[] = [];
  for (const x of xs) verts.push(x, b.bottom, 0.01, x, b.top + RULE_REACH, 0.01);
  const g = new BufferGeometry();
  g.setAttribute('position', new BufferAttribute(new Float32Array(verts), 3));
  const ruleMat = new LineBasicMaterial({ color: INK.chalk, transparent: true, opacity: INK.chalkGuideOpacity, depthWrite: false, toneMapped: false });
  const rules = new LineSegments(g, ruleMat);
  rules.renderOrder = 1;
  group.add(rules);
  const fades: { m: { opacity: number }; full: number }[] = [{ m: ruleMat, full: INK.chalkGuideOpacity }];
  for (const c of b.columns) {
    const label = chalk(c.label, c.x, b.top + COLUMN_LABEL_Y, Math.max(3, c.width - 1));
    if (!label) continue;
    group.add(label);
    fades.push({ m: label.material as MeshBasicMaterial, full: INK.chalkTextOpacity });
  }
  // Chalk comes up and goes away as a fade.
  let phase: 'in' | 'still' | 'out' | 'gone' = opts.arrive ? 'in' : 'still';
  let since = -1;
  const set = (a: number) => { for (const f of fades) f.m.opacity = f.full * a; group.visible = a > 0.001; };
  if (phase === 'in') set(0);
  const motion: BackdropMotion = {
    step(now) {
      if (since < 0) since = now;
      const t = clamp01((now - since) / COLUMN_FADE_MS);
      if (phase === 'in') { set(t); if (t >= 1) phase = 'still'; return true; }
      if (phase === 'out') { set(1 - t); if (t >= 1) { phase = 'gone'; return false; } return true; }
      return false;
    },
    leave(now) { if (phase !== 'gone') { phase = 'out'; since = now; } },
  };
  group.userData.motion = motion;
  return group;
}

export function buildBackdrop(b: Backdrop, opts: { mapTiles: boolean; arrive: boolean }): Object3D {
  return b.type === 'columns' ? columns(b, opts) : mapSheet(b, opts);
}
