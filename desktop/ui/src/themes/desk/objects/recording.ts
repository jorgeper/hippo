// A cassette: the shell with its screws, a paper label with the first words of the transcript in a handwriting-style font
// and the length, a window with two reels, and the tape guide along the bottom.
import type { Object3D } from 'three';
import type { DeskItem } from '../../../../../src/server/wire.ts';
import { drawText, roundRect } from '../../../scene/textures.ts';
import { FONT, INK, TAPE } from '../palette.ts';
import { buildSlab, clock, hashOf } from './slab.ts';

export function buildRecording(item: DeskItem, lod: 'small' | 'full'): Object3D {
  return buildSlab({
    kind: 'recording', item, lod, finish: 'plastic',
    draw: ({ ctx, w, h }) => {
      const shell = ctx.createLinearGradient(0, 0, 0, h);
      shell.addColorStop(0, TAPE.shellLight);
      shell.addColorStop(1, TAPE.shell);
      ctx.fillStyle = shell;
      ctx.fillRect(0, 0, w, h);
      // Screws in the corners and the middle of the bottom.
      ctx.fillStyle = TAPE.screw;
      for (const [x, y] of [[0.45, 0.45], [w - 0.45, 0.45], [0.45, h - 0.45], [w - 0.45, h - 0.45], [w / 2, h - 0.5]]) {
        ctx.beginPath(); ctx.arc(x, y, 0.16, 0, Math.PI * 2); ctx.fill();
      }
      // The label.
      const lx = 0.75, ly = 0.55, lw = w - 1.5, lh = 3.85;
      ctx.fillStyle = TAPE.label;
      roundRect(ctx, lx, ly, lw, lh, 0.22);
      ctx.fill();
      ctx.fillStyle = TAPE.bands[hashOf(item.id) % TAPE.bands.length];
      ctx.fillRect(lx, ly + 1.55, lw, 1.95);
      ctx.fillStyle = TAPE.labelLine;
      ctx.fillRect(lx + 0.35, ly + 1.32, lw - 0.7, 0.03);
      // The first words, handwritten, and the length.
      const words = (item.body_excerpt ?? item.title).replace(/\s+/g, ' ').trim();
      const length = item.duration_seconds !== undefined ? clock(item.duration_seconds) : '';
      ctx.font = `0.82px ${FONT.hand}`;
      const lenW = length ? ctx.measureText(length).width + 0.4 : 0;
      drawText(ctx, words, lx + 0.4, ly + 0.28, lw - 0.8 - lenW, 1, { font: `0.9px ${FONT.hand}`, color: INK.hand, lineHeight: 1 });
      if (length) {
        ctx.save();
        ctx.font = `0.82px ${FONT.hand}`;
        ctx.fillStyle = INK.handSoft;
        ctx.textAlign = 'right';
        ctx.textBaseline = 'top';
        ctx.fillText(length, lx + lw - 0.4, ly + 0.36);
        ctx.restore();
      }
      // The window and its reels.
      const wx = w / 2 - 2.5, wy = ly + 1.75, ww = 5, wh = 1.55;
      ctx.fillStyle = TAPE.window;
      roundRect(ctx, wx, wy, ww, wh, 0.7);
      ctx.fill();
      ctx.strokeStyle = TAPE.windowEdge;
      ctx.lineWidth = 0.06;
      ctx.stroke();
      const cy = wy + wh / 2;
      ctx.fillStyle = TAPE.tape;
      ctx.beginPath(); ctx.arc(wx + 1.15, cy, 0.68, 0, Math.PI * 2); ctx.fill();
      ctx.beginPath(); ctx.arc(wx + ww - 1.15, cy, 0.5, 0, Math.PI * 2); ctx.fill();
      for (const rx of [wx + 1.15, wx + ww - 1.15]) drawReel(ctx, rx, cy);
      // The tape guide along the bottom.
      ctx.fillStyle = TAPE.shellLight;
      ctx.beginPath();
      ctx.moveTo(1.6, h); ctx.lineTo(2.2, h - 1.45); ctx.lineTo(w - 2.2, h - 1.45); ctx.lineTo(w - 1.6, h); ctx.closePath();
      ctx.fill();
      ctx.fillStyle = TAPE.window;
      for (const x of [3.1, w - 3.1]) { ctx.beginPath(); ctx.arc(x, h - 0.75, 0.22, 0, Math.PI * 2); ctx.fill(); }
      ctx.fillRect(w / 2 - 0.35, h - 0.95, 0.7, 0.4);
    },
  });
}

function drawReel(ctx: CanvasRenderingContext2D, x: number, y: number): void {
  ctx.fillStyle = TAPE.reel;
  ctx.beginPath(); ctx.arc(x, y, 0.36, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = TAPE.reelHole;
  ctx.beginPath(); ctx.arc(x, y, 0.17, 0, Math.PI * 2); ctx.fill();
  for (let k = 0; k < 6; k++) {
    const a = (k * Math.PI) / 3;
    ctx.fillRect(x + Math.cos(a) * 0.17 - 0.04, y + Math.sin(a) * 0.17 - 0.04, 0.08, 0.08);
  }
}
