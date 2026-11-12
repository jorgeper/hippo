// The theme seam (spec section 8, "Themes"): one module supplies the surface and lighting, a builder for each kind of object,
// the label style and the motion set. Nothing outside ui/src/themes/<name>/ may name a theme's material, colour or timing.
// Type-only imports from three, so this file costs nothing at run time.
import type { Object3D, PerspectiveCamera, Scene, WebGLRenderer } from 'three';
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Backdrop, Size, SizeTable } from '../layout/types.ts';

/** A side of the desk as the person sees it: `far` is away from them (+y), `near` toward them (-y). */
export type Edge = 'left' | 'right' | 'far' | 'near';

export type Easing = 'linear' | 'easeIn' | 'easeOut' | 'easeInOut';

/** Glide to the target under a damped spring, rising `lift` desk units at the middle of the move. Times in ms. */
export interface SpringMotion { type: 'spring'; delay: number; stiffness: number; damping: number; lift: number }
/**
 * A scripted arc of fixed `duration` (ms): up `height` desk units at its middle, turning `spin` radians about the item's
 * long axis (a flip is π), along `easing`.
 */
export interface ArcMotion { type: 'arc'; delay: number; duration: number; height: number; spin: number; easing: Easing }
export type MotionSpec = SpringMotion | ArcMotion;

export interface Motions {
  /** The `index`-th arrival (stagger by it), dealt in from `from`. */
  arrive(index: number, from: Edge): MotionSpec;
  /** The `index`-th leaver, swept off toward `to`. */
  leave(index: number, to: Edge): MotionSpec;
  /** The `index`-th stayer, gliding to its new place. */
  move(index: number): MotionSpec;
  lift: MotionSpec;
  flip: MotionSpec;
  /** While a question is with the model: a gentle swell of the desk, `period` ms, `amplitude` desk units. */
  thinking: { period: number; amplitude: number };
}

/** What a theme gets to set the stage: the scene to fill, the renderer to configure, the camera, the canvas size in CSS pixels. */
export interface StageContext { scene: Scene; renderer: WebGLRenderer; camera: PerspectiveCamera; viewSize: { width: number; height: number } }

export interface Theme {
  name: string;
  /** Object sizes in desk units, by kind; the layouts use these. */
  sizes: SizeTable;
  /** Surface, lights, environment, vignette. */
  setupStage(stage: StageContext): void;
  /** One capture as an object: `small` textures until the camera comes close, then `full`. */
  buildObject(item: DeskItem, lod: 'small' | 'full'): Object3D;
  buildPileLabel(text: string, count: number): Object3D;
  /** The block under a pile that draws only its top sheets; undefined when the pile needs none. */
  buildThickness(count: number, size: Size): Object3D | undefined;
  buildBackdrop(b: Backdrop, opts: { mapTiles: boolean }): Object3D;
  motions: Motions;
}
