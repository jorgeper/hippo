// A print of a video: the display picture, else the video's own first frame, with a play mark and its length.
import type { Object3D } from 'three';
import type { DeskItem } from '../../../../../src/server/wire.ts';
import { PAPER } from '../palette.ts';
import { buildSlab, clock, drawPill, drawPlay, pictureOf } from './slab.ts';
import { drawPrintPicture } from './photo.ts';

const BORDER = 0.55;

export function buildVideo(item: DeskItem, lod: 'small' | 'full'): Object3D {
  return buildSlab({
    kind: 'video', item, lod, finish: 'gloss', source: pictureOf(item, lod, true),
    draw: ({ ctx, w, h }, pic) => {
      ctx.fillStyle = PAPER.print;
      ctx.fillRect(0, 0, w, h);
      const x = BORDER, y = BORDER, iw = w - 2 * BORDER, ih = h - 2 * BORDER;
      if (pic) drawPrintPicture(ctx, item, pic, x, y, iw, ih);
      else drawFilm(ctx, item, x, y, iw, ih);
      drawPlay(ctx, w / 2, h / 2, Math.min(iw, ih) * 0.17);
      if (item.duration_seconds !== undefined) drawPill(ctx, clock(item.duration_seconds), x + iw - 0.35, y + 0.35, 0.75);
    },
  });
}

/** The placeholder: a dark frame with sprocket holes along the top and bottom. */
function drawFilm(ctx: CanvasRenderingContext2D, item: DeskItem, x: number, y: number, w: number, h: number): void {
  drawPrintPicture(ctx, item, null, x, y, w, h);
  ctx.save();
  ctx.fillStyle = 'rgba(10, 12, 18, 0.55)';
  ctx.fillRect(x, y, w, h);
  ctx.fillStyle = 'rgba(10, 12, 18, 0.85)';
  ctx.fillRect(x, y, w, 0.9);
  ctx.fillRect(x, y + h - 0.9, w, 0.9);
  ctx.fillStyle = 'rgba(255, 255, 255, 0.55)';
  for (let k = 0.5; k < w - 0.4; k += 1.1) {
    ctx.fillRect(x + k, y + 0.28, 0.5, 0.34);
    ctx.fillRect(x + k, y + h - 0.62, 0.5, 0.34);
  }
  ctx.restore();
}
