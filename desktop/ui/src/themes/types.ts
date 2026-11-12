// The theme seam (spec section 8, "Themes"): one module supplies the surface and lighting, a builder for each kind of object,
// the label style and the motion set. Nothing outside ui/src/themes/<name>/ may name a theme's material, colour or timing.
// Type-only imports from three, so this file costs nothing at run time.
import type { Object3D, PerspectiveCamera, Scene, WebGLRenderer } from 'three';
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Kind } from '../../../src/core/types.ts';
import type { Backdrop, Size, SizeTable } from '../layout/types.ts';

/** A side of the desk as the person sees it: `far` is away from them (+y), `near` toward them (-y). */
export type Edge = 'left' | 'right' | 'far' | 'near';

export type Easing = 'linear' | 'easeIn' | 'easeOut' | 'easeInOut';

/**
 * Glide to the target under a damped spring, rising `lift` desk units at the middle of the move. Times in ms. `stiffness`
 * is k in 1/s² and `damping` the damping ratio (1: no overshoot; below 1: a little). For an arrival, `spin` is how far
 * (radians about the vertical) it starts turned from its resting angle. `reach`, when set, replaces "from off the desk" (or
 * "off the desk" for a leaver) with a short slide of that many desk units; `fade` fades it in (or out) along the way. The
 * last two are what reduced motion uses.
 */
export interface SpringMotion { type: 'spring'; delay: number; stiffness: number; damping: number; lift: number;
  spin?: number; reach?: number; fade?: boolean }
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
  /** While a question is with the model the key light breathes: one breath every `period` ms, swelling by `amplitude` (a share of its intensity). */
  thinking: { period: number; amplitude: number };
}

/**
 * A backdrop's own motion (the map sheet unfolding, the columns fading in), carried as `userData.motion` on the object
 * `buildBackdrop` returns and driven by the stage: `step(now)` is called every frame (`now` in ms) and answers whether it
 * changed, so the frame is drawn; `leave(now)` starts it going away, after which `step` answering false means it has gone.
 */
export interface BackdropMotion { step(now: number): boolean; leave(now: number): void }

/** What a theme gets to set the stage: the scene to fill, the renderer to configure, the camera, the canvas size in CSS pixels. */
export interface StageContext { scene: Scene; renderer: WebGLRenderer; camera: PerspectiveCamera; viewSize: { width: number; height: number } }

/**
 * What the stage expects of an object a theme builds (an item, label, block, badge or backdrop): it lies on the desk with its
 * bottom at z = 0, centred on x,y = 0, its `w` along x and `h` along y. Geometries, materials and textures shared between
 * objects carry `userData.shared = true`; everything else belongs to the one object and is disposed with it. An item may
 * carry `userData.ready`, a promise that settles once its pictures are drawn (or have fallen back to a placeholder): the
 * stage shows a full-size object only then. Any object may carry `userData.dispose()` to stop its own pending work.
 * Materials of an item are its own, so the stage may fade it.
 */
export interface Theme {
  name: string;
  /** Object sizes in desk units, by kind; the layouts use these. */
  sizes: SizeTable;
  /** How thick each kind of object is, in desk units (the stage stacks piles with it). */
  depths: Record<Kind, number>;
  /** Surface, lights, environment, vignette. The stage takes the shadow-casting lights as the key light. */
  setupStage(stage: StageContext): void;
  /** One capture as an object: `small` textures until the camera comes close, then `full`. */
  buildObject(item: DeskItem, lod: 'small' | 'full'): Object3D;
  /** A pile's label; with `count` 0 (the empty-state line) or 1 it shows the text alone. */
  buildPileLabel(text: string, count: number): Object3D;
  /** A small mark laid on an item's corner (in the person layout: how many more people it names). */
  buildBadge(text: string): Object3D;
  /** The block under a pile that draws only its top sheets; undefined when the pile needs none. */
  buildThickness(count: number, size: Size): Object3D | undefined;
  /**
   * What lies under a layout's items. `arrive`: it comes onto a desk that had no backdrop of this type (the map unfolds);
   * false when it replaces one of the same type (the set changed under the same layout) and should simply be there.
   */
  buildBackdrop(b: Backdrop, opts: { mapTiles: boolean; arrive: boolean }): Object3D;
  /** CSS custom properties for the page's controls over the desk (their colours and fonts); the page sets them on :root. */
  chrome: Record<string, string>;
  motions: Motions;
}
