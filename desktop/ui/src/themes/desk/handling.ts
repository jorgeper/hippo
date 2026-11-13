// What the desk theme adds for the person's handling (spec section 8, "Handling"): the pin pushed into a kept item, and the
// veil laid over the desk while a pile is open or an item is lifted.
import { CylinderGeometry, Group, Mesh, MeshBasicMaterial, MeshStandardMaterial, PlaneGeometry, SphereGeometry } from 'three';
import type { Object3D } from 'three';
import type { Scrim } from '../types.ts';
import { HANDLING, PIN } from './palette.ts';

const HEAD_R = 0.5, POINT_H = 0.55;
const head = new SphereGeometry(HEAD_R, 20, 14);
head.userData.shared = true;
const point = new CylinderGeometry(0.07, 0.07, POINT_H, 8);
point.rotateX(Math.PI / 2);
point.translate(0, 0, POINT_H / 2);
point.userData.shared = true;

let headMat: MeshStandardMaterial | undefined, pointMat: MeshStandardMaterial | undefined;

export function buildPin(): Object3D {
  headMat ??= Object.assign(new MeshStandardMaterial({ color: PIN.head, emissive: PIN.headLight, emissiveIntensity: 0.08, roughness: 0.32, metalness: 0 }),
    { userData: { shared: true } });
  pointMat ??= Object.assign(new MeshStandardMaterial({ color: PIN.point, roughness: 0.3, metalness: 0.85 }), { userData: { shared: true } });
  const g = new Group();
  g.name = 'pin';
  const p = new Mesh(point, pointMat);
  const h = new Mesh(head, headMat);
  h.position.z = POINT_H + HEAD_R * 0.7;
  h.scale.z = 0.7;
  h.castShadow = p.castShadow = true;
  g.add(p, h);
  return g;
}

/** Fades over this long (ms), each way. */
const SCRIM_MS = 260;
const SCRIM_SIZE = 6000;

export function buildScrim(): Scrim {
  const mat = new MeshBasicMaterial({ color: HANDLING.scrim, transparent: true, opacity: 0, depthWrite: false });
  const mesh = new Mesh(new PlaneGeometry(SCRIM_SIZE, SCRIM_SIZE), mat);
  mesh.name = 'desk-scrim';
  mesh.visible = false;
  mesh.renderOrder = 1;
  let from = 0, to = 0, t0 = 0, level = 0;
  const reduced = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
  return {
    object: mesh,
    set(on, now) {
      const target = on ? 1 : 0;
      if (target === to) return;
      from = level; to = target; t0 = now;
    },
    step(now) {
      if (level === to) return false;
      const ms = reduced() ? SCRIM_MS / 3 : SCRIM_MS;
      const u = Math.min(1, (now - t0) / ms);
      level = from + (to - from) * (u * (2 - u));
      if (u >= 1) level = to;
      mat.opacity = level * HANDLING.scrimOpacity;
      mesh.visible = level > 0.001;
      return true;
    },
    shown: () => to === 1,
  };
}
