// A glossy print with a white border. A picture far from the print's shape sits whole on the white (a matted print)
// instead of being cropped hard; nothing is ever stretched.
import type { Object3D } from 'three';
import type { DeskItem } from '../../../../../src/server/wire.ts';
import { aspectMismatch, drawContain, drawCover } from '../../../scene/textures.ts';
import type { Picture } from '../../../scene/textures.ts';
import { PAPER } from '../palette.ts';
import { buildSlab, drawWash, pictureOf } from './slab.ts';

const BORDER = 0.55;
/** Pictures whose shape differs from the window by more than this are shown whole instead of cropped. */
export const CROP_LIMIT = 1.3;

/** The picture inside a print's border, or the kind's placeholder wash with a little sun and hills. */
export function drawPrintPicture(ctx: CanvasRenderingContext2D, item: DeskItem, pic: Picture | null, x: number, y: number, w: number, h: number): void {
  if (pic) {
    if (aspectMismatch(pic, w, h) > CROP_LIMIT) drawContain(ctx, pic, x, y, w, h);
    else drawCover(ctx, pic, x, y, w, h);
    return;
  }
  drawWash(ctx, item.id, x, y, w, h);
  ctx.save();
  ctx.beginPath();
  ctx.rect(x, y, w, h);
  ctx.clip();
  ctx.fillStyle = 'rgba(255, 255, 255, 0.55)';
  ctx.beginPath();
  ctx.arc(x + w * 0.72, y + h * 0.3, Math.min(w, h) * 0.12, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = 'rgba(0, 0, 0, 0.16)';
  ctx.beginPath();
  ctx.moveTo(x, y + h);
  ctx.lineTo(x, y + h * 0.72);
  ctx.lineTo(x + w * 0.3, y + h * 0.48);
  ctx.lineTo(x + w * 0.55, y + h * 0.7);
  ctx.lineTo(x + w * 0.75, y + h * 0.56);
  ctx.lineTo(x + w, y + h * 0.78);
  ctx.lineTo(x + w, y + h);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

export function buildPhoto(item: DeskItem, lod: 'small' | 'full'): Object3D {
  return buildSlab({
    kind: 'photo', item, lod, finish: 'gloss', source: pictureOf(item, lod),
    draw: ({ ctx, w, h }, pic) => {
      ctx.fillStyle = PAPER.print;
      ctx.fillRect(0, 0, w, h);
      drawPrintPicture(ctx, item, pic, BORDER, BORDER, w - 2 * BORDER, h - 2 * BORDER);
    },
  });
}
