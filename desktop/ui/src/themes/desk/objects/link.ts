// A matte card: the page's thumbnail on the top 60%, its title and site below, a play mark for a video link.
import type { Object3D } from 'three';
import type { DeskItem } from '../../../../../src/server/wire.ts';
import { drawCover, drawLine, drawText, graphemes } from '../../../scene/textures.ts';
import { FONT, INK, PAPER } from '../palette.ts';
import { buildSlab, drawPlay, drawWash, pictureOf } from './slab.ts';

const PICTURE_SHARE = 0.6;
const PAD = 0.55;

export function buildLink(item: DeskItem, lod: 'small' | 'full'): Object3D {
  return buildSlab({
    kind: 'link', item, lod, finish: 'matte', source: pictureOf(item, lod),
    draw: ({ ctx, w, h }, pic) => {
      ctx.fillStyle = PAPER.card;
      ctx.fillRect(0, 0, w, h);
      const ph = h * PICTURE_SHARE;
      if (pic) drawCover(ctx, pic, 0, 0, w, ph);
      else {
        drawWash(ctx, item.site ?? item.id, 0, 0, w, ph);
        const initial = graphemes((item.site ?? item.title).replace(/^www\./, '').trim())[0]?.toUpperCase() ?? '';
        ctx.save();
        ctx.fillStyle = 'rgba(255, 255, 255, 0.85)';
        ctx.font = `700 ${ph * 0.5}px ${FONT.sans}`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(initial, w / 2, ph / 2);
        ctx.restore();
      }
      ctx.fillStyle = PAPER.cardEdge;
      ctx.fillRect(0, ph, w, 0.05);
      if (item.is_video_link) drawPlay(ctx, w / 2, ph / 2, ph * 0.2);
      drawText(ctx, item.title, PAD, ph + 0.36, w - 2 * PAD, 2, { font: `650 0.9px ${FONT.sans}`, color: INK.text, lineHeight: 1.02 });
      if (item.site) drawLine(ctx, item.site, PAD, h - 1.15, w - 2 * PAD, { font: `500 0.68px ${FONT.sans}`, color: INK.soft, lineHeight: 0.8 });
    },
  });
}
