// The shapes every layout shares (spec section 8, "What is on the desk, and how it is arranged"). A layout is a pure function
// from items and the usable desk area to positions, piles and an optional backdrop; adding a layout is adding a file.
// Desk units are centimetres on the surface: x to the right, y away from the viewer.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { Kind } from '../../../src/core/types.ts';

export interface Size { w: number; h: number }
export type SizeTable = Record<Kind, Size>;
/** The usable desk area in desk units, centred on 0,0 (the caller has already taken out the room the controls need). */
export interface View { width: number; height: number }
/**
 * Where one item lies. `order` 0 is the bottom of its pile; `rot` is in radians about the vertical; `pile` is a PileInfo key.
 * `badge`: a short mark this arrangement puts on the item (the person layout: "+1" when it names one more person).
 */
export interface Placement { id: string; x: number; y: number; order: number; rot: number; pile: string; badge?: string }
/** One pile: its point, label and members, `ids` top first. */
export interface PileInfo { key: string; label: string; count: number; x: number; y: number; ids: string[] }
/**
 * What is drawn under the items. `columns`: one per time bucket, each with its centre `x` and `width`, spanning `bottom` to
 * `top` in y. `map`: a sheet whose centre is `x`,`y`, at Web Mercator `zoom`, centred on `centerLat`,`centerLon`, drawn at
 * MAP_PX_PER_UNIT world pixels per desk unit (layout/mercator.ts), with place names to show when tiles are off.
 */
export type Backdrop =
  | { type: 'columns'; columns: { label: string; x: number; width: number }[]; top: number; bottom: number }
  | { type: 'map'; x: number; y: number; width: number; height: number; zoom: number; centerLat: number; centerLon: number;
      labels: { text: string; x: number; y: number }[] };
/** `empty` is set (and nothing else) when there are no items: the line the desk shows instead. */
export interface LayoutResult { placements: Placement[]; piles: PileInfo[]; backdrop?: Backdrop; empty?: string }
export type LayoutFn = (items: DeskItem[], view: View, sizes: SizeTable) => LayoutResult;
