// Handwriting on the desk: a pile's label on a strip of paper tape (its name and, for more than one, the count), the
// empty-state line on a wider strip, and the small sticker that marks an item in the person layout.
import { CircleGeometry, Group, Mesh, MeshStandardMaterial, PlaneGeometry } from 'three';
import type { Object3D } from 'three';
import { faceTexture, fitLines, isRtl } from '../../scene/textures.ts';
import { FONT, INK, MARK, PAPER } from './palette.ts';
import { hashOf } from './objects/slab.ts';

/** Canvas pixels per desk unit for labels. */
const PX = 40;
const TEXT = 1.45, COUNT = 1.15, TAPE_H = 2.5, PAD = 0.9, MAX_W = 26;
const EMPTY_TEXT = 1.6, EMPTY_MAX_W = 52;
/** Labels lie just above the desk (and the backdrop sheet). */
const LIFT = 0.04;

const plane = new PlaneGeometry(1, 1);
plane.userData.shared = true;
const disc = new CircleGeometry(0.85, 28);
disc.userData.shared = true;

let measurer: CanvasRenderingContext2D | undefined;
function measureCtx(): CanvasRenderingContext2D {
  measurer ??= document.createElement('canvas').getContext('2d')!;
  return measurer;
}

/** A strip of tape `w` × `h` units with torn ends, drawn on `ctx` (already scaled to units). */
function drawTape(ctx: CanvasRenderingContext2D, w: number, h: number, seed: number): void {
  const teeth = Math.max(4, Math.round(h / 0.32));
  const tooth = 0.22;
  ctx.beginPath();
  ctx.moveTo(tooth, 0);
  ctx.lineTo(w - tooth, 0);
  for (let k = 1; k <= teeth; k++) ctx.lineTo(w - (k % 2 ? 0 : tooth) - ((seed >> k) & 1) * 0.06, (h * k) / teeth);
  ctx.lineTo(tooth, h);
  for (let k = teeth - 1; k >= 0; k--) ctx.lineTo((k % 2 ? 0 : tooth) + ((seed >> (k + 3)) & 1) * 0.06, (h * k) / teeth);
  ctx.closePath();
  ctx.fillStyle = PAPER.tape;
  ctx.fill();
  ctx.fillStyle = PAPER.tapeEdge;
  ctx.fillRect(0, 0, w, 0.08);
  ctx.fillRect(0, h - 0.08, w, 0.08);
}

function labelMesh(canvas: HTMLCanvasElement, w: number, h: number, seed: number): Object3D {
  const mat = new MeshStandardMaterial({ map: faceTexture(canvas), roughness: 0.92, metalness: 0, alphaTest: 0.5 });
  const mesh = new Mesh(plane, mat);
  mesh.scale.set(w, h, 1);
  mesh.receiveShadow = true;
  mesh.rotation.z = (((seed % 1000) / 1000) - 0.5) * 0.07;
  mesh.position.z = LIFT;
  const root = new Group();
  root.add(mesh);
  return root;
}

export function buildPileLabel(text: string, count: number): Object3D {
  const seed = hashOf(text);
  const m = measureCtx();
  const empty = count === 0;
  const size = empty ? EMPTY_TEXT : TEXT;
  m.font = `${size}px ${FONT.hand}`;
  const countText = count > 1 ? count.toLocaleString() : '';
  const measure = (s: string) => m.measureText(s).width;
  const countW = countText ? (m.font = `${COUNT}px ${FONT.hand}`, measure(countText)) + 1.1 : 0;
  m.font = `${size}px ${FONT.hand}`;
  const maxText = (empty ? EMPTY_MAX_W : MAX_W) - 2 * PAD - countW;
  const lines = fitLines(text.trim() || ' ', maxText, empty ? 2 : 1, measure);
  const textW = Math.max(0, ...lines.map(measure));
  const w = Math.max(4, textW + countW + 2 * PAD), h = empty ? TAPE_H + (lines.length - 1) * size * 1.15 + 0.4 : TAPE_H;
  const canvas = document.createElement('canvas');
  canvas.width = Math.ceil(w * PX);
  canvas.height = Math.ceil(h * PX);
  const ctx = canvas.getContext('2d')!;
  ctx.scale(canvas.width / w, canvas.height / h);
  drawTape(ctx, w, h, seed);
  ctx.fillStyle = INK.hand;
  ctx.font = `${size}px ${FONT.hand}`;
  ctx.textBaseline = 'middle';
  const rtl = isRtl(text);
  ctx.direction = rtl ? 'rtl' : 'ltr';
  ctx.textAlign = empty ? 'center' : rtl ? 'right' : 'left';
  const top = (h - lines.length * size * 1.15) / 2 + size * 0.6;
  lines.forEach((l, k) => ctx.fillText(l, empty ? w / 2 : rtl ? PAD + textW : PAD, top + k * size * 1.15));
  if (countText) {
    const cx = w - PAD - (countW - 1.1) / 2 - 0.2, cy = h / 2;
    ctx.strokeStyle = INK.handSoft;
    ctx.lineWidth = 0.07;
    ctx.beginPath();
    ctx.ellipse(cx, cy, (countW - 1.1) / 2 + 0.45, COUNT * 0.62, -0.08, 0, Math.PI * 2);
    ctx.stroke();
    ctx.fillStyle = INK.handSoft;
    ctx.font = `${COUNT}px ${FONT.hand}`;
    ctx.direction = 'ltr';
    ctx.textAlign = 'center';
    ctx.fillText(countText, cx, cy + 0.05);
  }
  return labelMesh(canvas, w, h, seed);
}

export function buildBadge(text: string): Object3D {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 96;
  const ctx = canvas.getContext('2d')!;
  ctx.fillStyle = MARK.badge;
  ctx.fillRect(0, 0, 96, 96);
  ctx.fillStyle = MARK.badgeText;
  ctx.font = `700 ${text.length > 2 ? 34 : 42}px ${FONT.sans}`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, 48, 51, 84);
  const mesh = new Mesh(disc, new MeshStandardMaterial({ map: faceTexture(canvas), roughness: 0.55, metalness: 0 }));
  mesh.receiveShadow = true;
  return mesh;
}
