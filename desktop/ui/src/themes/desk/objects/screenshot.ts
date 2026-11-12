// A phone-shaped print: rounded corners, a dark bezel, the screenshot filling the screen (cropped evenly, never stretched).
import type { Object3D } from 'three';
import type { DeskItem } from '../../../../../src/server/wire.ts';
import { drawCover, drawText, roundRect } from '../../../scene/textures.ts';
import { FONT, PHONE } from '../palette.ts';
import { buildSlab, pictureOf } from './slab.ts';

const BEZEL = 0.32;
const SCREEN_RADIUS = 0.72;

export function buildScreenshot(item: DeskItem, lod: 'small' | 'full'): Object3D {
  return buildSlab({
    kind: 'screenshot', item, lod, finish: 'screen', source: pictureOf(item, lod),
    draw: ({ ctx, w, h }, pic) => {
      ctx.fillStyle = PHONE.bezel;
      ctx.fillRect(0, 0, w, h);
      // A faint lighter rim, as the bezel catches the light at its edge.
      ctx.strokeStyle = PHONE.bezelEdge;
      ctx.lineWidth = 0.08;
      roundRect(ctx, 0.1, 0.1, w - 0.2, h - 0.2, 0.9);
      ctx.stroke();
      const x = BEZEL, y = BEZEL, sw = w - 2 * BEZEL, sh = h - 2 * BEZEL;
      ctx.save();
      roundRect(ctx, x, y, sw, sh, SCREEN_RADIUS);
      ctx.clip();
      ctx.fillStyle = PHONE.screen;
      ctx.fillRect(x, y, sw, sh);
      if (pic) drawCover(ctx, pic, x, y, sw, sh);
      else {
        // The placeholder: a few bars of an app, and the title.
        ctx.fillStyle = PHONE.barStrong;
        ctx.fillRect(x + 0.5, y + 0.9, sw - 1, 0.5);
        ctx.fillStyle = PHONE.bar;
        for (let k = 0; k < 7; k++) ctx.fillRect(x + 0.5, y + 4.6 + k * 1.15, (sw - 1) * (k % 3 === 2 ? 0.55 : 0.9), 0.42);
        drawText(ctx, item.title, x + 0.5, y + 1.9, sw - 1, 3, { font: `600 0.62px ${FONT.sans}`, color: PHONE.text, lineHeight: 0.78 });
      }
      ctx.restore();
    },
  });
}
