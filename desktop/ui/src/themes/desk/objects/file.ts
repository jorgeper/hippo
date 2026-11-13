// A white sheet with its top right corner folded over: the file's type, its name, and a few grey lines of "text".
import type { Object3D } from 'three';
import type { DeskItem } from '../../../../../src/server/wire.ts';
import { drawText, roundRect } from '../../../scene/textures.ts';
import { FILE_OTHER, FILE_TYPES, FONT, INK, PAPER } from '../palette.ts';
import { FOLD, buildSlab, hashOf } from './slab.ts';

const PAD = 0.9;

export function buildFile(item: DeskItem, lod: 'small' | 'full'): Object3D {
  return buildSlab({
    kind: 'file', item, lod, finish: 'matte',
    draw: ({ ctx, w, h }) => {
      ctx.fillStyle = PAPER.sheet;
      ctx.fillRect(0, 0, w, h);
      // The folded corner: the flap, and its shadow on the sheet.
      ctx.fillStyle = PAPER.foldShade;
      ctx.beginPath(); ctx.moveTo(w - FOLD - 0.25, 0); ctx.lineTo(w - FOLD - 0.25, FOLD + 0.25); ctx.lineTo(w, FOLD + 0.25); ctx.closePath(); ctx.fill();
      ctx.fillStyle = PAPER.fold;
      ctx.beginPath(); ctx.moveTo(w - FOLD, 0); ctx.lineTo(w - FOLD, FOLD); ctx.lineTo(w, FOLD); ctx.closePath(); ctx.fill();
      const name = item.file_name ?? item.title;
      const ext = /\.([A-Za-z0-9]{1,5})$/.exec(name)?.[1]?.toLowerCase() ?? '';
      let y = PAD;
      if (ext) {
        ctx.save();
        ctx.font = `700 0.72px ${FONT.sans}`;
        const tw = ctx.measureText(ext.toUpperCase()).width;
        ctx.fillStyle = FILE_TYPES[ext] ?? FILE_OTHER;
        roundRect(ctx, PAD, y, tw + 0.7, 1.1, 0.18);
        ctx.fill();
        ctx.fillStyle = PAPER.sheet;
        ctx.textBaseline = 'middle';
        ctx.fillText(ext.toUpperCase(), PAD + 0.35, y + 0.58);
        ctx.restore();
        y += 1.7;
      }
      y += drawText(ctx, name, PAD, y, w - 2 * PAD - (ext ? 0 : FOLD), 3, { font: `650 0.92px ${FONT.sans}`, color: INK.text, lineHeight: 1.1 });
      y += 0.5;
      if (item.title && item.title !== name) y += drawText(ctx, item.title, PAD, y, w - 2 * PAD, 2, { font: `500 0.7px ${FONT.sans}`, color: INK.soft, lineHeight: 0.88 }) + 0.4;
      // Lines of "text" down the rest of the sheet.
      ctx.fillStyle = 'rgba(40, 44, 56, 0.13)';
      const seed = hashOf(item.id);
      for (let k = 0; y + 0.3 < h - PAD; k++, y += 0.78) {
        const share = k % 5 === 4 ? 0.45 : 0.8 + (((seed >> (k % 24)) & 7) / 7) * 0.2;
        ctx.fillRect(PAD, y, (w - 2 * PAD) * share, 0.26);
      }
    },
  });
}
