// A paper slip: its key words as a small word cloud (bigger for heavier words), or its first lines when it has fewer than
// four key words.
import type { Object3D } from 'three';
import type { DeskItem } from '../../../../../src/server/wire.ts';
import { drawText, fitWord } from '../../../scene/textures.ts';
import { FONT, INK, PAPER } from '../palette.ts';
import { buildSlab } from './slab.ts';

const PAD = 0.7;
const MIN_WORDS = 4;
const SMALLEST = 0.78, LARGEST = 1.9;

export function buildNote(item: DeskItem, lod: 'small' | 'full'): Object3D {
  return buildSlab({
    kind: 'note', item, lod, finish: 'matte',
    draw: ({ ctx, w, h }) => {
      ctx.fillStyle = PAPER.note;
      ctx.fillRect(0, 0, w, h);
      ctx.fillStyle = PAPER.noteLine;
      for (let y = 1.6; y < h - 0.4; y += 1.05) ctx.fillRect(0.3, y, w - 0.6, 0.035);
      const words = item.keywords.filter(k => k.word.trim());
      if (words.length >= MIN_WORDS) drawCloud(ctx, words, w, h);
      else drawText(ctx, item.body_excerpt ?? item.title, PAD, PAD, w - 2 * PAD, 6, { font: `500 0.86px ${FONT.sans}`, color: INK.text, lineHeight: 1.12 });
    },
  });
}

/**
 * Lays the words out in centred rows, heaviest first, and stops when the slip is full. A word too wide for the slip is set
 * smaller until it fits (down to the smallest cloud size) and is cut short only below that.
 */
function drawCloud(ctx: CanvasRenderingContext2D, keywords: { word: string; weight: number }[], w: number, h: number): void {
  const sorted = [...keywords].sort((a, b) => b.weight - a.weight).slice(0, 14);
  const hi = sorted[0].weight, lo = sorted[sorted.length - 1].weight;
  const maxW = w - 2 * PAD;
  type Placed = { text: string; size: number; width: number; colour: string; bold: boolean };
  const rows: { items: Placed[]; width: number; height: number }[] = [];
  let row: { items: Placed[]; width: number; height: number } = { items: [], width: 0, height: 0 };
  const gap = 0.45;
  sorted.forEach((k, i) => {
    const t = hi === lo ? 0.5 : (k.weight - lo) / (hi - lo);
    const bold = t > 0.55;
    const measureAt = (s: string, px: number) => { ctx.font = `${bold ? 700 : 500} ${px}px ${FONT.sans}`; return ctx.measureText(s).width; };
    const { text, size } = fitWord(k.word.trim(), maxW, SMALLEST + (LARGEST - SMALLEST) * t, SMALLEST, measureAt);
    const width = Math.min(maxW, measureAt(text, size));
    const placed = { text, size, width, colour: INK.cloud[i % INK.cloud.length], bold };
    if (row.items.length && row.width + gap + width > maxW) { rows.push(row); row = { items: [], width: 0, height: 0 }; }
    row.width += (row.items.length ? gap : 0) + width;
    row.height = Math.max(row.height, size * 1.18);
    row.items.push(placed);
  });
  if (row.items.length) rows.push(row);
  // Keep the rows that fit, then centre the block on the slip.
  const kept: typeof rows = [];
  let total = 0;
  for (const r of rows) { if (total + r.height > h - 2 * PAD) break; kept.push(r); total += r.height; }
  let y = (h - total) / 2;
  ctx.textBaseline = 'middle';
  for (const r of kept) {
    let x = (w - r.width) / 2;
    for (const p of r.items) {
      ctx.font = `${p.bold ? 700 : 500} ${p.size}px ${FONT.sans}`;
      ctx.fillStyle = p.colour;
      ctx.fillText(p.text, x, y + r.height / 2, maxW);
      x += p.width + gap;
    }
    y += r.height;
  }
}
