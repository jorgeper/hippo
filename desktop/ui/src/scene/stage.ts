// The stage: the renderer, a camera looking down at the desk tilted a little from vertical, zoom toward a point and panning
// (both eased; the pointer gestures that ask for them live in ui/src/interact), picking, the hand (holding, carrying and
// lifting objects for the gestures), and a frame loop that draws only when something changed and redraws
// the shadow map only while a shadow caster moves. It knows nothing about how things look: the theme supplies the surface,
// lights, objects, labels and motions. It survives window resizes, device-pixel-ratio changes and a lost WebGL context.
import { DirectionalLight, Group, PerspectiveCamera, Plane, Quaternion, Raycaster, Scene, Vector2, Vector3, WebGLRenderer } from 'three';
import type { Object3D } from 'three';
import type { DeskItem } from '../../../src/server/wire.ts';
import type { LayoutResult, Size, View } from '../layout/types.ts';
import type { Theme } from '../themes/types.ts';
import { createArranger } from './arrange.ts';
import type { Bounds, Rect } from './arrange.ts';
import { createObjects } from './objects.ts';
import type { Pose } from './objects.ts';
import { setAnisotropy } from './textures.ts';

export interface FrameInfo { time: number; dt: number; moving: boolean }
export interface PickResult { id?: string; pile?: string }
/** A pose off the desk: where a lifted object stands and how it is turned. */
export interface FreePose { position: Vector3; quaternion: Quaternion }
export interface ScreenRect { left: number; top: number; width: number; height: number }

/** What the gestures do with the objects (ui/src/interact): every call is about the object standing for a capture id. */
export interface Hand {
  /** Takes the object into the hand: its pose is set from here until it is let go; the arrangement's motions for it wait. */
  hold(id: string): boolean;
  /** Puts a held object down at a desk pose at once (dragging it). */
  carry(id: string, pose: Pose): void;
  /** Sets a held object's pose anywhere (lifting it toward the person, turning it over). */
  place(id: string, pose: FreePose): void;
  /** The held object's pose now. */
  poseOf(id: string): FreePose | undefined;
  /** Lets a held object go; `velocity` (desk units per second) carries into its next motion. */
  release(id: string, velocity?: { x: number; y: number }): void;
  /** Where the object belongs on the desk, as a pose off the desk (lying flat there). */
  homeOf(id: string): FreePose | undefined;
  /**
   * Where a `size` object stands to fill about `share` of the view height (less when that would be too wide), facing the
   * person; its face, `thick` in front of its origin, is what fills it.
   */
  liftPose(size: Size, share: number, thick?: number): FreePose;
  /**
   * The window rectangle (CSS pixels) a held object's face covers: `size` centred on the object, on whichever of its two
   * faces (its base, or `depth` above it) is nearer the camera. Not its bounding box, which a turned slab overstates.
   */
  screenRect(id: string, size: Size, depth: number): ScreenRect | undefined;
  /** Moves a pile (label, block, drawn objects) by dx,dy desk units at once. */
  shiftPile(key: string, dx: number, dy: number): void;
  /** The veil over everything while an item is lifted. */
  setLifting(on: boolean): void;
  /** Runs `step` every frame (before drawing) while it answers true. */
  animate(step: (now: number, dt: number) => boolean): void;
}

export interface Stage {
  /** Puts these items on the desk where the layout says: animated, and redirected from where things are if called mid-flight. */
  setItems(items: DeskItem[], layout: LayoutResult): void;
  /** While a question is with the model: the key light breathes. Input stays enabled. */
  setThinking(on: boolean): void;
  /** Eases the camera back to frame what is on the desk. */
  resetView(): void;
  /** What is under a point of the window: an item (and its pile), or a pile's label or block. */
  pick(clientX: number, clientY: number): PickResult | undefined;
  /** The object standing for a capture, while it is built. */
  objectOf(id: string): Object3D | undefined;
  /** `frame`: after each drawn frame. `view`: the layouts' area changed (the window was resized); lay out again. */
  on(event: 'frame', handler: (f: FrameInfo) => void): () => void;
  on(event: 'view', handler: (v: View) => void): () => void;
  /** The desk area, in desk units, the layouts should fill: at least VIEW_MIN_WIDTH wide, shaped like the room the controls leave. */
  view(): View;
  setMapTiles(on: boolean): void;
  /** The desk point under a window point, seen by the camera as it is now (on the level `z` desk units above the desk). */
  groundAt(clientX: number, clientY: number, z?: number): { x: number; y: number } | undefined;
  /** The window point (CSS pixels) where a desk point x,y at height z shows now. */
  toWindow(x: number, y: number, z?: number): { x: number; y: number };
  /** The part of the desk the window shows now (the near edge's width, the narrower one). */
  visible(): Rect;
  /** Starts panning from a window point (dragging empty desk); false when that point is not over the desk. */
  panStart(clientX: number, clientY: number): boolean;
  /** Pans so the desk point the pan started from stays under this window point. */
  panTo(clientX: number, clientY: number): void;
  /** Zooms toward a window point by `factor` (below 1 is closer). */
  zoomAt(clientX: number, clientY: number, factor: number): void;
  /** Zooms for a wheel event: scroll, or a trackpad pinch (which arrives as a wheel with ctrlKey). */
  wheelZoom(e: WheelEvent): void;
  hand: Hand;
  /** For checks: what the scene draws and holds, and anything stray or not where it was sent (see ObjectStore.audit). */
  check(): { onDesk: number; held: number; active: number; entries: number; built: number; drawn: string[]; stray: string[]; offTarget: string[] };
  /** `low` draws at device pixel ratio 1 with a smaller shadow map; the stage drops to it by itself when frames are slow. */
  setQuality(q: 'high' | 'low'): void;
  /** Counts for checks: the renderer's, the objects', the renderer string. */
  info(): { calls: number; triangles: number; geometries: number; textures: number; programs: number; quality: 'high' | 'low';
    objects: ReturnType<ReturnType<typeof createObjects>['stats']>; camera: CameraState; goal: CameraState; bounds?: Bounds };
  dispose(): void;
}

/** Room, in CSS pixels, kept free for the controls: the layout buttons along the top, the ask bar and reply along the bottom. */
export const MARGIN = { top: 64, bottom: 136, side: 28 };
/** The layouts keep everything inside the view only from about 83 units wide. */
export const VIEW_MIN_WIDTH = 90;
/** At the reset view, about this many CSS pixels per desk unit. */
const PX_PER_UNIT = 11.5;
/** Framing never zooms in further than this many CSS pixels per desk unit. */
const MAX_FRAME_PX_PER_UNIT = 17;
const TILT = (18 * Math.PI) / 180;
const FOV = 32;
/** Zoom range, as a share of the framed distance: 6x in, 2x out (0.5x). */
const ZOOM_IN = 6, ZOOM_OUT = 2;
/** How quickly the camera catches up with where it should be (per second). */
const CAMERA_RATE = 13;
/** With prefers-reduced-motion the camera steps there instead: all but 1% of the way in about a tenth of a second. */
const CAMERA_RATE_REDUCED = 46;
const DPR_CAP = 2;
/** Frames between checks of which objects need full-size faces. */
const LOD_EVERY = 8;
/** Drop to low quality when moving frames average more than this (ms) over SLOW_SAMPLE frames. */
const SLOW_FRAME_MS = 26, SLOW_SAMPLE = 90;

interface CameraState { tx: number; ty: number; dist: number }

export function createStage(canvas: HTMLCanvasElement, theme: Theme, opts: { mapTiles?: boolean } = {}): Stage {
  const renderer = new WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
  const scene = new Scene();
  const world = new Group();
  world.name = 'desk-world';
  scene.add(world);
  const camera = new PerspectiveCamera(FOV, 1, 1, 5000);
  camera.up.set(0, 0, 1);
  const probe = new PerspectiveCamera(FOV, 1, 1, 5000);
  probe.up.set(0, 0, 1);
  setAnisotropy(renderer.capabilities.getMaxAnisotropy());

  let cssW = 1, cssH = 1;
  let quality: 'high' | 'low' = 'high';
  let autoQuality = true;
  let furniture: Object3D[] = [];
  let keyLights: { light: DirectionalLight; base: number; dir: Vector3 }[] = [];
  let lost = false;
  let needsRender = true;
  let shadowDirty = true;
  let lodDirty = true;
  let thinking = false, thinkingSince = 0, breath = 0;
  let follow = true;
  let lastBounds: Bounds | undefined;
  let lastView: View | undefined;
  let frameNo = 0;
  let placed = false;
  let slowSum = 0, slowCount = 0;
  const listeners = { frame: new Set<(f: FrameInfo) => void>(), view: new Set<(v: View) => void>() };

  function setupTheme(): void {
    const before = new Set(scene.children);
    theme.setupStage({ scene, renderer, camera, viewSize: { width: cssW, height: cssH } });
    furniture = scene.children.filter(c => !before.has(c));
    keyLights = [];
    scene.traverse(o => {
      const l = o as DirectionalLight;
      if (l.isDirectionalLight && l.castShadow) {
        if (!l.target.parent) scene.add(l.target);
        keyLights.push({ light: l, base: l.intensity, dir: l.position.clone().sub(l.target.position).normalize() });
      }
    });
    renderer.shadowMap.autoUpdate = false;
    shadowDirty = true;
    applyQuality();
    if (lastBounds) fitShadows(lastBounds);
  }

  // ------------------------------------------------------------ objects and arrangement

  const objects = createObjects(world, theme, {
    settled: id => arranger.settled(id),
    changed: () => { needsRender = true; },
  });
  const arranger = createArranger(world, theme, objects);
  arranger.setMapTiles(!!opts.mapTiles);

  // ------------------------------------------------------------ camera

  const cur: CameraState = { tx: 0, ty: 0, dist: 150 };
  const goal: CameraState = { ...cur };
  let framedDist = 150;

  function place(c: PerspectiveCamera, s: CameraState): void {
    c.position.set(s.tx, s.ty - s.dist * Math.sin(TILT), s.dist * Math.cos(TILT));
    c.lookAt(s.tx, s.ty, 0);
    const near = Math.max(0.5, s.dist * 0.04), far = s.dist * 12 + 400;
    if (c.near !== near || c.far !== far) { c.near = near; c.far = far; c.updateProjectionMatrix(); }
    c.updateMatrixWorld(true);
  }

  const ground = new Plane(new Vector3(0, 0, 1), 0);
  const ray = new Raycaster();
  const ndc = new Vector2();
  const hit = new Vector3();

  /** The desk point under a CSS pixel of the canvas, seen from `c`. */
  function groundAt(c: PerspectiveCamera, px: number, py: number, out: Vector3): Vector3 | undefined {
    ndc.set((px / cssW) * 2 - 1, -(py / cssH) * 2 + 1);
    ray.setFromCamera(ndc, c);
    return ray.ray.intersectPlane(ground, out) ?? undefined;
  }

  const corner = new Vector3();
  /** Screen box (CSS px) of a desk box (its rectangle, up to the height of its tallest pile) seen from `probe`. */
  function screenBox(r: Bounds): { x0: number; x1: number; y0: number; y1: number } {
    const b = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
    for (const [x, y, z] of [[r.x0, r.y0, 0], [r.x1, r.y0, 0], [r.x0, r.y1, 0], [r.x1, r.y1, 0],
      [r.x0, r.y0, r.top], [r.x1, r.y0, r.top], [r.x0, r.y1, r.top], [r.x1, r.y1, r.top]]) {
      corner.set(x, y, z).project(probe);
      const sx = (corner.x + 1) / 2 * cssW, sy = (1 - corner.y) / 2 * cssH;
      b.x0 = Math.min(b.x0, sx); b.x1 = Math.max(b.x1, sx); b.y0 = Math.min(b.y0, sy); b.y1 = Math.max(b.y1, sy);
    }
    return b;
  }

  const usable = () => ({ x0: MARGIN.side, x1: cssW - MARGIN.side, y0: MARGIN.top, y1: cssH - MARGIN.bottom });

  /** The camera that shows `r` as large as fits in the room the controls leave, centred in it. */
  function frameRect(r: Bounds): CameraState {
    const u = usable(), uw = Math.max(50, u.x1 - u.x0), uh = Math.max(50, u.y1 - u.y0);
    const s: CameraState = { tx: (r.x0 + r.x1) / 2, ty: (r.y0 + r.y1) / 2, dist: 100 };
    const minDist = cssH / (2 * Math.tan((FOV * Math.PI) / 360) * MAX_FRAME_PX_PER_UNIT);
    const a = new Vector3(), b = new Vector3();
    for (let iter = 0; iter < 4; iter++) {
      let lo = 1, hi = 20000;
      for (let k = 0; k < 40; k++) {
        const mid = Math.sqrt(lo * hi);
        place(probe, { ...s, dist: mid });
        const box = screenBox(r);
        if (box.x1 - box.x0 <= uw && box.y1 - box.y0 <= uh) hi = mid; else lo = mid;
      }
      s.dist = Math.max(hi, minDist);
      place(probe, s);
      const box = screenBox(r);
      const ga = groundAt(probe, (box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2, a);
      const gb = groundAt(probe, (u.x0 + u.x1) / 2, (u.y0 + u.y1) / 2, b);
      if (!ga || !gb) break;
      s.tx += ga.x - gb.x;
      s.ty += ga.y - gb.y;
    }
    return s;
  }

  function frameTo(r: Bounds | undefined): void {
    if (!r || !Number.isFinite(r.x0)) return;
    Object.assign(goal, frameRect(r));
    framedDist = goal.dist;
  }

  /** The part of the desk the camera will show once it gets where it is going, as a box. */
  function visibleRect(): Rect {
    place(probe, goal);
    const r = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
    for (const [px, py] of [[0, 0], [cssW, 0], [0, cssH], [cssW, cssH]]) {
      const g = groundAt(probe, px, py, hit);
      if (!g) continue;
      r.x0 = Math.min(r.x0, g.x); r.x1 = Math.max(r.x1, g.x); r.y0 = Math.min(r.y0, g.y); r.y1 = Math.max(r.y1, g.y);
    }
    // The near edge is narrower than the far one; dealing uses the narrower width so nothing starts on screen.
    const near0 = groundAt(probe, 0, cssH, hit)?.x, near1 = groundAt(probe, cssW, cssH, new Vector3())?.x;
    if (near0 !== undefined && near1 !== undefined) { r.x0 = Math.max(r.x0, near0); r.x1 = Math.min(r.x1, near1); }
    return Number.isFinite(r.x0) ? r : { x0: -100, x1: 100, y0: -60, y1: 60 };
  }

  const reducedMotion = typeof matchMedia === 'function' ? matchMedia('(prefers-reduced-motion: reduce)') : undefined;

  /** Eases the camera toward the goal (a short step under reduced motion); true while it moves. */
  function easeCamera(dt: number): boolean {
    const k = 1 - Math.exp(-dt * (reducedMotion?.matches ? CAMERA_RATE_REDUCED : CAMERA_RATE));
    const dx = goal.tx - cur.tx, dy = goal.ty - cur.ty, dz = Math.log(goal.dist / cur.dist);
    if (Math.abs(dx) < 1e-3 && Math.abs(dy) < 1e-3 && Math.abs(dz) < 1e-4) {
      if (cur.tx === goal.tx && cur.ty === goal.ty && cur.dist === goal.dist) return false;
      Object.assign(cur, goal);
    } else {
      cur.tx += dx * k; cur.ty += dy * k; cur.dist *= Math.exp(dz * k);
    }
    place(camera, cur);
    return true;
  }

  function fitShadows(r: Rect): void {
    const cx = (r.x0 + r.x1) / 2, cy = (r.y0 + r.y1) / 2;
    const half = Math.max(r.x1 - r.x0, r.y1 - r.y0) * 0.65 + 20;
    for (const k of keyLights) {
      k.light.target.position.set(cx, cy, 0);
      k.light.position.set(cx, cy, 0).addScaledVector(k.dir, 200);
      const c = k.light.shadow.camera;
      c.left = -half; c.right = half; c.top = half; c.bottom = -half; c.near = 1; c.far = 500;
      c.updateProjectionMatrix();
      k.light.target.updateMatrixWorld();
      k.light.updateMatrixWorld();
    }
    shadowDirty = true;
  }

  // ------------------------------------------------------------ size, pixel ratio, quality

  function computeView(): View {
    const u = usable(), uw = Math.max(1, u.x1 - u.x0), uh = Math.max(1, u.y1 - u.y0);
    const width = Math.max(VIEW_MIN_WIDTH, uw / PX_PER_UNIT);
    return { width, height: (width * uh) / uw };
  }

  function applyQuality(): void {
    renderer.setPixelRatio(Math.min(quality === 'low' ? 1 : DPR_CAP, window.devicePixelRatio || 1));
    renderer.setSize(cssW, cssH, false);
    const size = quality === 'low' ? 1024 : 2048;
    for (const k of keyLights) {
      if (k.light.shadow.mapSize.x !== size) {
        k.light.shadow.mapSize.set(size, size);
        k.light.shadow.map?.dispose();
        (k.light.shadow as { map: unknown }).map = null;
      }
    }
    shadowDirty = true;
    needsRender = true;
  }

  function resize(): void {
    const w = Math.max(1, canvas.clientWidth), h = Math.max(1, canvas.clientHeight);
    if (w === cssW && h === cssH) return;
    cssW = w; cssH = h;
    camera.aspect = probe.aspect = w / h;
    camera.updateProjectionMatrix();
    probe.updateProjectionMatrix();
    applyQuality();
    if (follow) { frameTo(lastBounds); }
    place(camera, cur);
    const v = computeView();
    if (!lastView || Math.abs(v.width - lastView.width) > 0.01 || Math.abs(v.height - lastView.height) > 0.01) {
      lastView = v;
      for (const fn of listeners.view) fn(v);
    }
  }

  let dprQuery: MediaQueryList | undefined;
  function watchDpr(): void {
    dprQuery?.removeEventListener('change', onDpr);
    dprQuery = matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
    dprQuery.addEventListener('change', onDpr);
  }
  function onDpr(): void { applyQuality(); watchDpr(); }

  const resizeObserver = new ResizeObserver(() => resize());
  resizeObserver.observe(canvas);

  // ------------------------------------------------------------ context loss

  function onLost(e: Event): void { e.preventDefault(); lost = true; }
  function onRestored(): void {
    // three.js has rebuilt its own state and uploads textures again from their canvases; only what lived on the GPU alone
    // (the environment map) has to be made again, so the theme sets the stage afresh.
    for (const o of furniture) { o.removeFromParent(); objects.disposeObject(o); }
    scene.environment = null;
    setupTheme();
    lost = false;
    needsRender = true;
  }
  canvas.addEventListener('webglcontextlost', onLost);
  canvas.addEventListener('webglcontextrestored', onRestored);

  // ------------------------------------------------------------ input: zoom and pan

  const before = new Vector3(), after = new Vector3();
  function zoomAt(px: number, py: number, factor: number): void {
    place(probe, goal);
    const g0 = groundAt(probe, px, py, before);
    goal.dist = Math.min(framedDist * ZOOM_OUT, Math.max(framedDist / ZOOM_IN, goal.dist * factor));
    place(probe, goal);
    const g1 = groundAt(probe, px, py, after);
    if (g0 && g1) { goal.tx += g0.x - g1.x; goal.ty += g0.y - g1.y; }
    follow = false;
  }

  function local(e: { clientX: number; clientY: number }): { x: number; y: number } {
    const r = canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  function wheelZoom(e: WheelEvent): void {
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? cssH : 1;
    const k = e.ctrlKey ? 0.01 : 0.0016;   // a trackpad pinch arrives as a wheel with ctrlKey
    zoomAt(local(e).x, local(e).y, Math.exp(e.deltaY * unit * k));
  }

  // Panning keeps the desk point it started from under the pointer (the pointer gestures are in ui/src/interact/pointer.ts).
  let panAnchor: Vector3 | undefined;
  function panStart(clientX: number, clientY: number): boolean {
    const p = local({ clientX, clientY });
    place(probe, goal);
    const g = groundAt(probe, p.x, p.y, new Vector3());
    panAnchor = g;
    return !!g;
  }
  function panTo(clientX: number, clientY: number): void {
    if (!panAnchor) return;
    const p = local({ clientX, clientY });
    place(probe, goal);
    const g = groundAt(probe, p.x, p.y, hit);
    if (!g) return;
    goal.tx += panAnchor.x - g.x;
    goal.ty += panAnchor.y - g.y;
    follow = false;
  }
  canvas.style.touchAction = 'none';

  // ------------------------------------------------------------ picking

  const pickRay = new Raycaster();
  function pick(clientX: number, clientY: number): PickResult | undefined {
    const p = local({ clientX, clientY });
    ndc.set((p.x / cssW) * 2 - 1, -(p.y / cssH) * 2 + 1);
    pickRay.setFromCamera(ndc, camera);
    const hits = pickRay.intersectObjects([...objects.pickables(), ...arranger.pickables()], true);
    for (const h of hits) {
      const id = objects.idOf(h.object);
      if (id) { const pile = objects.pileOfId(id); return pile ? { id, pile } : { id }; }
      const pile = arranger.pileOf(h.object);
      if (pile) return { pile };
    }
    return undefined;
  }

  // ------------------------------------------------------------ the hand

  const steppers = new Set<(now: number, dt: number) => boolean>();
  const tmpV = new Vector3(), fwd = new Vector3();

  function liftPose(size: Size, share: number, thick = 0): FreePose {
    const u = usable(), uw = Math.max(50, u.x1 - u.x0), uh = Math.max(50, u.y1 - u.y0);
    const focal = cssH / (2 * Math.tan((FOV * Math.PI) / 360));    // CSS px per desk unit at depth 1
    const wantH = Math.min(cssH * share, uh * 0.9), wantW = uw * 0.86;
    const depth = Math.max((size.h * focal) / wantH, (size.w * focal) / wantW) + thick;
    // Through the middle of the room the controls leave, at that depth along the camera's axis.
    ndc.set(((u.x0 + u.x1) / 2 / cssW) * 2 - 1, -(((u.y0 + u.y1) / 2) / cssH) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    camera.getWorldDirection(fwd);
    const t = depth / Math.max(0.2, ray.ray.direction.dot(fwd));
    return { position: ray.ray.origin.clone().addScaledVector(ray.ray.direction, t), quaternion: camera.quaternion.clone() };
  }

  const hand: Hand = {
    hold(id) {
      const ok = !!objects.hold(id);
      if (ok) needsRender = true;
      return ok;
    },
    carry(id, pose) { objects.carry(id, pose); },
    place(id, pose) {
      const slot = objects.objectOf(id);
      if (!slot || !objects.isHeld(id)) return;
      slot.position.copy(pose.position);
      slot.quaternion.copy(pose.quaternion);
      slot.updateMatrixWorld(true);
      needsRender = true;
      lodDirty = true;
    },
    poseOf(id) {
      const slot = objects.objectOf(id);
      return slot ? { position: slot.position.clone(), quaternion: slot.quaternion.clone() } : undefined;
    },
    release(id, velocity) { objects.release(id, performance.now(), velocity); needsRender = true; },
    homeOf(id) {
      const h = objects.homeOf(id);
      if (!h) return undefined;
      return { position: new Vector3(h.x, h.y, h.z), quaternion: new Quaternion().setFromAxisAngle(new Vector3(0, 0, 1), h.rot) };
    },
    liftPose,
    screenRect(id, size, depth) {
      const slot = objects.objectOf(id);
      if (!slot) return undefined;
      slot.updateMatrixWorld(true);
      const near = (z: number) => tmpV.set(0, 0, z).applyMatrix4(slot.matrixWorld).distanceTo(camera.position);
      const z = near(depth) <= near(0) ? depth : 0;
      const c = canvas.getBoundingClientRect();
      const r = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
      for (const x of [-size.w / 2, size.w / 2]) for (const y of [-size.h / 2, size.h / 2]) {
        tmpV.set(x, y, z).applyMatrix4(slot.matrixWorld).project(camera);
        const sx = (tmpV.x + 1) / 2 * cssW, sy = (1 - tmpV.y) / 2 * cssH;
        r.x0 = Math.min(r.x0, sx); r.x1 = Math.max(r.x1, sx); r.y0 = Math.min(r.y0, sy); r.y1 = Math.max(r.y1, sy);
      }
      return { left: c.left + r.x0, top: c.top + r.y0, width: r.x1 - r.x0, height: r.y1 - r.y0 };
    },
    shiftPile(key, dx, dy) { arranger.shiftPile(key, dx, dy); needsRender = true; shadowDirty = true; },
    setLifting(on) { arranger.setLifting(on, performance.now()); needsRender = true; },
    animate(step) { steppers.add(step); },
  };

  // ------------------------------------------------------------ the frame loop

  let raf = 0, last = performance.now();
  const frameInfo: FrameInfo = { time: 0, dt: 0, moving: false };
  function tick(t: number): void {
    raf = requestAnimationFrame(tick);
    const dt = Math.min(0.05, Math.max(0, (t - last) / 1000));
    last = t;
    if (lost) return;
    frameNo++;
    let dirty = needsRender;
    needsRender = false;
    const r = objects.step(dt, t);
    if (r.moving) { dirty = true; lodDirty = true; }
    if (r.shadowsMoved) shadowDirty = true;
    const grown = arranger.step(dt, t);
    if (grown.moving) dirty = true;
    if (grown.shadows) shadowDirty = true;
    if (easeCamera(dt)) { dirty = true; lodDirty = true; }
    for (const fn of steppers) {
      if (fn(t, dt)) { dirty = true; lodDirty = true; } else steppers.delete(fn);
    }
    if (thinking || breath !== 0) {
      const { period, amplitude } = theme.motions.thinking;
      breath = thinking ? (1 - Math.cos(((t - thinkingSince) / period) * Math.PI * 2)) / 2 : Math.max(0, breath - dt * 2);
      for (const k of keyLights) k.light.intensity = k.base * (1 - amplitude * breath);
      dirty = true;
    }
    if (lodDirty && frameNo % LOD_EVERY === 0) {
      lodDirty = false;
      if (objects.updateLod(camera, cssH)) dirty = true;
    }
    if (!dirty) return;
    if (shadowDirty) { renderer.shadowMap.needsUpdate = true; shadowDirty = false; }
    renderer.render(scene, camera);
    if (r.moving && autoQuality && quality === 'high') {
      slowSum += dt * 1000; slowCount++;
      if (slowCount >= SLOW_SAMPLE) {
        if (slowSum / slowCount > SLOW_FRAME_MS) { quality = 'low'; applyQuality(); }
        slowSum = 0; slowCount = 0;
      }
    }
    frameInfo.time = t; frameInfo.dt = dt; frameInfo.moving = r.moving;
    for (const fn of listeners.frame) fn(frameInfo);
  }

  // ------------------------------------------------------------ start

  cssW = 0; cssH = 0;
  resize();
  watchDpr();
  setupTheme();
  place(camera, cur);
  raf = requestAnimationFrame(tick);

  return {
    setItems(items, layout) {
      arranger.apply(items, layout, b => {
        lastBounds = b;
        if (follow) frameTo(b);
        // The first fill starts from the framed view; later changes ease the camera there.
        if (!placed) { Object.assign(cur, goal); place(camera, cur); placed = true; }
        if (Number.isFinite(b.x0)) fitShadows(b);
        return visibleRect();
      }, performance.now());
      needsRender = true;
      lodDirty = true;
    },
    setThinking(on) {
      if (on && !thinking) thinkingSince = performance.now();
      thinking = on;
      needsRender = true;
    },
    resetView() {
      follow = true;
      frameTo(lastBounds);
      needsRender = true;
    },
    pick,
    objectOf: id => objects.objectOf(id),
    on(event: 'frame' | 'view', handler: ((f: FrameInfo) => void) | ((v: View) => void)) {
      const set = listeners[event] as Set<typeof handler>;
      set.add(handler);
      return () => { set.delete(handler); };
    },
    view: () => lastView ?? computeView(),
    setMapTiles(on) { arranger.setMapTiles(on); },
    groundAt(clientX, clientY, z = 0) {
      const p = local({ clientX, clientY });
      ndc.set((p.x / cssW) * 2 - 1, -(p.y / cssH) * 2 + 1);
      ray.setFromCamera(ndc, camera);
      const g = ray.ray.intersectPlane(new Plane(new Vector3(0, 0, 1), -z), new Vector3());
      return g ? { x: g.x, y: g.y } : undefined;
    },
    toWindow(x, y, z = 0) {
      const c = canvas.getBoundingClientRect();
      tmpV.set(x, y, z).project(camera);
      return { x: c.left + (tmpV.x + 1) / 2 * cssW, y: c.top + (1 - tmpV.y) / 2 * cssH };
    },
    visible() {
      const r = { x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity };
      for (const [px, py] of [[0, 0], [cssW, 0], [0, cssH], [cssW, cssH]]) {
        const g = groundAt(camera, px, py, hit);
        if (!g) continue;
        r.x0 = Math.min(r.x0, g.x); r.x1 = Math.max(r.x1, g.x); r.y0 = Math.min(r.y0, g.y); r.y1 = Math.max(r.y1, g.y);
      }
      const near0 = groundAt(camera, 0, cssH, hit)?.x, near1 = groundAt(camera, cssW, cssH, new Vector3())?.x;
      if (near0 !== undefined && near1 !== undefined) { r.x0 = Math.max(r.x0, near0); r.x1 = Math.min(r.x1, near1); }
      return Number.isFinite(r.x0) ? r : { x0: -60, x1: 60, y0: -30, y1: 30 };
    },
    panStart,
    panTo,
    zoomAt(clientX, clientY, factor) { const p = local({ clientX, clientY }); zoomAt(p.x, p.y, factor); },
    wheelZoom,
    hand,
    check() {
      const st = objects.stats();
      return { onDesk: st.onDesk, held: st.held, active: st.active, entries: st.entries, built: st.built, ...objects.audit() };
    },
    setQuality(q) { autoQuality = false; quality = q; applyQuality(); },
    info() {
      const i = renderer.info;
      return { calls: i.render.calls, triangles: i.render.triangles, geometries: i.memory.geometries, textures: i.memory.textures,
        programs: i.programs?.length ?? 0, quality, objects: objects.stats(), camera: { ...cur }, goal: { ...goal }, bounds: lastBounds };
    },
    dispose() {
      cancelAnimationFrame(raf);
      resizeObserver.disconnect();
      dprQuery?.removeEventListener('change', onDpr);
      canvas.removeEventListener('webglcontextlost', onLost);
      canvas.removeEventListener('webglcontextrestored', onRestored);
      renderer.dispose();
    },
  };
}

