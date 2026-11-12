// What every desk object shares: a thin slab with rounded corners (or a cut corner for a sheet of paper) whose top face is a
// canvas the kind draws on, one material per object so the whole object is one draw call. The face is drawn at once with
// a placeholder, then again when its picture arrives; `userData.ready` settles after that.
import { ExtrudeGeometry, Mesh, MeshPhysicalMaterial, MeshStandardMaterial, Shape } from 'three';
import type { BufferGeometry, Material } from 'three';
import type { DeskItem } from '../../../../../src/server/wire.ts';
import type { Kind } from '../../../../../src/core/types.ts';
import { cachedPicture, faceTexture, loadPicture, loadVideoFrame, makeFace, roundRect } from '../../../scene/textures.ts';
import type { Face, Picture } from '../../../scene/textures.ts';
import { FONT, MARK, WASHES } from '../palette.ts';

export const SIZES: Record<Kind, { w: number; h: number }> = {
  photo: { w: 15, h: 10 }, screenshot: { w: 7, h: 15 }, link: { w: 12, h: 9 }, note: { w: 9, h: 9 },
  recording: { w: 10, h: 6.4 }, video: { w: 15, h: 9 }, file: { w: 10.5, h: 14 },
};
export const DEPTHS: Record<Kind, number> = {
  photo: 0.08, screenshot: 0.1, link: 0.12, note: 0.05, recording: 0.65, video: 0.08, file: 0.05,
};
/** Corner radii, and the size of a sheet's folded corner. */
const RADIUS: Record<Kind, number> = { photo: 0.25, screenshot: 1.0, link: 0.45, note: 0.12, recording: 0.5, video: 0.25, file: 0 };
export const FOLD = 2.2;
/** Pixels on the long side of a face. */
export const FACE_PX = { small: 256, full: 1024 };

export type Finish = 'gloss' | 'screen' | 'matte' | 'plastic';

const geometries = new Map<Kind, BufferGeometry>();

/** The kind's slab, built once: the top face is mapped to the whole canvas, every other face to its bottom edge row. */
export function slabGeometry(kind: Kind): BufferGeometry {
  const hit = geometries.get(kind);
  if (hit) return hit;
  const { w, h } = SIZES[kind], r = RADIUS[kind], x0 = -w / 2, y0 = -h / 2;
  const s = new Shape();
  if (kind === 'file') {
    s.moveTo(x0, y0); s.lineTo(x0 + w, y0); s.lineTo(x0 + w, y0 + h - FOLD); s.lineTo(x0 + w - FOLD, y0 + h); s.lineTo(x0, y0 + h); s.closePath();
  } else {
    s.moveTo(x0 + r, y0);
    s.lineTo(x0 + w - r, y0); s.quadraticCurveTo(x0 + w, y0, x0 + w, y0 + r);
    s.lineTo(x0 + w, y0 + h - r); s.quadraticCurveTo(x0 + w, y0 + h, x0 + w - r, y0 + h);
    s.lineTo(x0 + r, y0 + h); s.quadraticCurveTo(x0, y0 + h, x0, y0 + h - r);
    s.lineTo(x0, y0 + r); s.quadraticCurveTo(x0, y0, x0 + r, y0);
  }
  const bevel = kind === 'recording';
  const depth = DEPTHS[kind];
  const g = new ExtrudeGeometry(s, bevel
    ? { depth: depth - 0.16, bevelEnabled: true, bevelThickness: 0.08, bevelSize: 0.08, bevelSegments: 2, curveSegments: 6 }
    : { depth, bevelEnabled: false, curveSegments: 6 });
  if (bevel) g.translate(0, 0, 0.08);
  const pos = g.getAttribute('position'), nor = g.getAttribute('normal'), uv = g.getAttribute('uv');
  for (let i = 0; i < pos.count; i++) {
    if (nor.getZ(i) > 0.7) uv.setXY(i, (pos.getX(i) - x0) / w, (pos.getY(i) - y0) / h);
    else uv.setXY(i, 0.5, 0.006);
  }
  uv.needsUpdate = true;
  g.clearGroups();
  g.computeBoundingBox();
  g.computeBoundingSphere();
  g.userData.shared = true;
  geometries.set(kind, g);
  return g;
}

function material(finish: Finish): Material {
  switch (finish) {
    // Base layers are rough so the key light's glare is a moving sheen from the clear coat, not a white-out. A print's coat
    // is thin and smooth: the light shows as a small bright glint that moves as the print moves, while a full, wider coat
    // washed the picture out at the desk's tilt and when zoomed in.
    case 'gloss': return new MeshPhysicalMaterial({ roughness: 0.62, metalness: 0, clearcoat: 0.45, clearcoatRoughness: 0.05, specularIntensity: 0.25, envMapIntensity: 0.8 });
    case 'screen': return new MeshPhysicalMaterial({ roughness: 0.55, metalness: 0, clearcoat: 0.5, clearcoatRoughness: 0.12, specularIntensity: 0.5 });
    case 'plastic': return new MeshPhysicalMaterial({ roughness: 0.6, metalness: 0, clearcoat: 0.18, clearcoatRoughness: 0.35, specularIntensity: 0.3 });
    default: return new MeshStandardMaterial({ roughness: 0.86, metalness: 0 });
  }
}

/** Where a kind's picture comes from: the thumbnail (or display picture, full size), else a video's first frame. */
export interface PictureSource { image?: string; video?: string }

export function pictureOf(item: DeskItem, lod: 'small' | 'full', withVideo = false): PictureSource {
  const image = lod === 'full' ? item.display ?? item.thumb : item.thumb ?? item.display;
  if (image) return { image };
  if (withVideo && item.media && item.media_type === 'video') return { video: item.media };
  return {};
}

export interface SlabSpec {
  kind: Kind;
  item: DeskItem;
  lod: 'small' | 'full';
  finish: Finish;
  source?: PictureSource;
  /** Draws the face; `pic` is null while loading and when there is no picture (draw the kind's placeholder then). */
  draw(face: Face, pic: Picture | null): void;
}

export function buildSlab(spec: SlabSpec): Mesh {
  const { w, h } = SIZES[spec.kind];
  const face = makeFace(w, h, FACE_PX[spec.lod]);
  const paint = (pic: Picture | null) => {
    face.ctx.save();
    spec.draw(face, pic);
    face.ctx.restore();
    if (spec.item.more_count > 0) drawMore(face, spec.item.more_count);
  };
  // A full-size face starts from the small picture when it is already loaded.
  const early = spec.lod === 'full' && spec.item.thumb ? cachedPicture(spec.item.thumb) ?? null : null;
  paint(early);
  const texture = faceTexture(face.canvas);
  const mat = material(spec.finish) as MeshStandardMaterial;
  mat.map = texture;
  const mesh = new Mesh(slabGeometry(spec.kind), mat);
  mesh.receiveShadow = true;
  let dead = false;
  mesh.userData.dispose = () => { dead = true; };
  const src = spec.source ?? {};
  const wanted = () => !dead;
  const load = src.image ? loadPicture(src.image, { wanted, urgent: spec.lod === 'full' })
    : src.video ? loadVideoFrame(src.video, { wanted, urgent: spec.lod === 'full' }) : undefined;
  mesh.userData.ready = load ? load.then(pic => {
    if (dead || !pic) return;
    paint(pic);
    texture.needsUpdate = true;
  }) : Promise.resolve();
  return mesh;
}

// ---------------------------------------------------------------- shared drawing

/** A stable 32-bit hash of a string (FNV-1a), to pick a placeholder's colours. */
export function hashOf(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return h >>> 0;
}

/** A soft two-colour wash, chosen by `seed`. */
export function drawWash(ctx: CanvasRenderingContext2D, seed: string, x: number, y: number, w: number, h: number): void {
  const [a, b] = WASHES[hashOf(seed) % WASHES.length];
  const g = ctx.createLinearGradient(x, y, x + w, y + h);
  g.addColorStop(0, a);
  g.addColorStop(1, b);
  ctx.fillStyle = g;
  ctx.fillRect(x, y, w, h);
}

/** A round, translucent play mark centred at cx,cy with radius r. */
export function drawPlay(ctx: CanvasRenderingContext2D, cx: number, cy: number, r: number): void {
  ctx.save();
  ctx.fillStyle = MARK.play;
  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = MARK.playIcon;
  ctx.beginPath();
  ctx.moveTo(cx - r * 0.32, cy - r * 0.45);
  ctx.lineTo(cx + r * 0.5, cy);
  ctx.lineTo(cx - r * 0.32, cy + r * 0.45);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

/** "m:ss" for a length in seconds. */
export function clock(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** A small dark pill with white text, its right edge at `right`, its top at `top`. */
export function drawPill(ctx: CanvasRenderingContext2D, text: string, right: number, top: number, size: number): void {
  ctx.save();
  ctx.font = `600 ${size}px ${FONT.sans}`;
  const tw = ctx.measureText(text).width, pw = tw + size * 0.9, ph = size * 1.45;
  ctx.fillStyle = MARK.duration;
  roundRect(ctx, right - pw, top, pw, ph, ph / 2);
  ctx.fill();
  ctx.fillStyle = MARK.durationText;
  ctx.textBaseline = 'middle';
  ctx.textAlign = 'center';
  ctx.fillText(text, right - pw / 2, top + ph / 2 + size * 0.04);
  ctx.restore();
}

/** "+N" (attachments besides the main one) in a dark circle in the bottom right corner. */
function drawMore(face: Face, n: number): void {
  const { ctx, w, h } = face;
  const r = Math.min(w, h) * 0.085 + 0.25;
  const cx = w - r - 0.45, cy = h - r - 0.45;
  const text = `+${Math.min(n, 99)}`;
  ctx.save();
  ctx.fillStyle = MARK.more;
  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = MARK.moreText;
  ctx.font = `700 ${r * (text.length > 2 ? 0.8 : 0.95)}px ${FONT.sans}`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, cx, cy + r * 0.05);
  ctx.restore();
}
