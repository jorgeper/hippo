// What lies under the items: the thickness block that stands for a pile's hidden sheets, the time layout's column guides and
// day labels chalked on the desk, and (until the map task) a plain paper sheet with place names for the place layout.
import { BoxGeometry, BufferAttribute, BufferGeometry, CanvasTexture, ClampToEdgeWrapping, Group, LineBasicMaterial, LineSegments, Mesh,
  MeshBasicMaterial, MeshStandardMaterial, PlaneGeometry, RepeatWrapping, SRGBColorSpace } from 'three';
import type { Object3D } from 'three';
import type { Backdrop, Size } from '../../layout/types.ts';
import { faceTexture, fitLines, makeFace } from '../../scene/textures.ts';
import { FONT, INK, PAPER } from './palette.ts';

// ---------------------------------------------------------------- thickness

/** Height of the block: a little per hidden sheet, never taller than this. */
const BLOCK_BASE = 0.25, BLOCK_PER_SHEET = 0.035, BLOCK_MAX = 3.2;
/** Desk units between the drawn sheet edges on the block's sides. */
const SHEET_SPACING = 0.11;
const LINES_PER_TILE = 16;

let blockMaterial: MeshStandardMaterial | undefined;
/** One texture for every block: sheet edges on its left half (the sides), plain paper on its right half (the top). */
function blockMat(): MeshStandardMaterial {
  if (blockMaterial) return blockMaterial;
  const c = document.createElement('canvas');
  c.width = 16; c.height = 128;
  const ctx = c.getContext('2d')!;
  ctx.fillStyle = PAPER.block;
  ctx.fillRect(0, 0, 16, 128);
  ctx.fillStyle = PAPER.blockLine;
  for (let k = 0; k < LINES_PER_TILE; k++) ctx.fillRect(0, k * 8 + 6, 8, 1.4);
  const t = new CanvasTexture(c);
  t.colorSpace = SRGBColorSpace;
  t.wrapS = ClampToEdgeWrapping;
  t.wrapT = RepeatWrapping;
  t.userData.shared = true;
  blockMaterial = new MeshStandardMaterial({ map: t, roughness: 0.9, metalness: 0 });
  blockMaterial.userData.shared = true;
  return blockMaterial;
}

export function buildThickness(count: number, size: Size): Object3D | undefined {
  if (count <= 0) return undefined;
  const height = Math.min(BLOCK_MAX, BLOCK_BASE + BLOCK_PER_SHEET * count);
  const g = new BoxGeometry(size.w * 0.97, size.h * 0.97, height);
  g.translate(0, 0, height / 2);
  const pos = g.getAttribute('position'), nor = g.getAttribute('normal'), uv = g.getAttribute('uv');
  const tile = LINES_PER_TILE * SHEET_SPACING;
  for (let i = 0; i < pos.count; i++) {
    if (Math.abs(nor.getZ(i)) > 0.5) uv.setXY(i, 0.75, 0.5);
    else uv.setXY(i, 0.25, pos.getZ(i) / tile);
  }
  uv.needsUpdate = true;
  g.clearGroups();
  const mesh = new Mesh(g, blockMat());
  mesh.castShadow = true;
  mesh.receiveShadow = true;
  return mesh;
}

// ---------------------------------------------------------------- backdrops

const COLUMN_TEXT = 1.7, LABEL_PX = 40;

const plane = new PlaneGeometry(1, 1);
plane.userData.shared = true;

/** Chalky handwriting straight on the desk, centred at x,y. */
function chalk(text: string, x: number, y: number, maxW: number): Object3D | undefined {
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
  const mesh = new Mesh(plane, new MeshBasicMaterial({ map: faceTexture(c), transparent: true, depthWrite: false, toneMapped: false, opacity: 0.85 }));
  mesh.scale.set(w, h, 1);
  mesh.position.set(x, y, 0.01);
  mesh.renderOrder = 1;
  return mesh;
}

function columns(b: Extract<Backdrop, { type: 'columns' }>): Object3D {
  const group = new Group();
  // Guides between neighbouring columns, and at the outer edges.
  const xs = new Set<number>();
  for (const c of b.columns) { xs.add(c.x - c.width / 2); xs.add(c.x + c.width / 2); }
  const verts: number[] = [];
  for (const x of xs) verts.push(x, b.bottom, 0.01, x, b.top + 3.4, 0.01);
  const g = new BufferGeometry();
  g.setAttribute('position', new BufferAttribute(new Float32Array(verts), 3));
  const lines = new LineSegments(g, new LineBasicMaterial({ color: INK.chalk, transparent: true, opacity: INK.chalkGuideOpacity, depthWrite: false, toneMapped: false }));
  lines.renderOrder = 1;
  group.add(lines);
  for (const c of b.columns) {
    const label = chalk(c.label, c.x, b.top + 1.7, Math.max(3, c.width - 1));
    if (label) group.add(label);
  }
  return group;
}

/** The place layout's sheet, plain for now: paper with the place names where they are (the map task adds the tiles). */
function mapSheet(b: Extract<Backdrop, { type: 'map' }>): Object3D {
  const face = makeFace(b.width, b.height, 1024);
  const { ctx } = face;
  ctx.fillStyle = PAPER.map;
  ctx.fillRect(0, 0, b.width, b.height);
  ctx.font = `1.5px ${FONT.hand}`;
  ctx.fillStyle = PAPER.mapInk;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  for (const l of b.labels) {
    const [line] = fitLines(l.text, 20, 1, s => ctx.measureText(s).width);
    if (line) ctx.fillText(line, l.x - b.x + b.width / 2, b.height / 2 - (l.y - b.y));
  }
  const g = new BoxGeometry(b.width, b.height, 0.03);
  g.translate(0, 0, 0.015);
  const mats = new MeshStandardMaterial({ map: faceTexture(face.canvas), roughness: 0.95, metalness: 0 });
  const mesh = new Mesh(g, mats);
  mesh.receiveShadow = true;
  mesh.position.set(b.x, b.y, 0);
  return mesh;
}

export function buildBackdrop(b: Backdrop, _opts: { mapTiles: boolean }): Object3D {
  return b.type === 'columns' ? columns(b) : mapSheet(b);
}
