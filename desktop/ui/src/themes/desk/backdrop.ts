// What lies under the items: the thickness block that stands for a pile's hidden sheets. The backdrops a layout asks for
// (the place layout's map sheet, the time layout's columns) are in map.ts.
import { BoxGeometry, CanvasTexture, ClampToEdgeWrapping, Mesh, MeshStandardMaterial, RepeatWrapping, SRGBColorSpace } from 'three';
import type { Object3D } from 'three';
import type { Size } from '../../layout/types.ts';
import { PAPER } from './palette.ts';

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

/** The map sheet and the ruled columns are drawn in map.ts. */
export { buildBackdrop } from './map.ts';
