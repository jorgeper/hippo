// The "Maybe these" pile (spec section 8, "Handling", Keep): dropping an item on empty desk with Shift held, or on this pile,
// pins it. The pile appears in the lower left corner with the first such drop; every item in it carries the theme's pin
// mark and stays on the desk when the question changes (the server keeps pinned ids in every result). Throwing one out of
// it unpins and sets it aside; Start over clears the pins.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { PileInfo, Placement, SizeTable, View } from '../layout/types.ts';
import type { Rect } from '../layout/pile.ts';
import { cornerPoint, extraPile } from './setaside.ts';

export const KEPT_KEY = 'kept';
export const KEPT_LABEL = 'Maybe these';

/** The kept pile: the pinned items on the desk (not dropped elsewhere), the latest kept on top; undefined when none. */
export function keptPile(pinned: readonly string[], onDesk: ReadonlyMap<string, DeskItem>, view: View, sizes: SizeTable,
  avoid: readonly Rect[]): { placements: Placement[]; pile: PileInfo } | undefined {
  const items = [...pinned].reverse().map(id => onDesk.get(id)).filter((i): i is DeskItem => !!i);
  if (!items.length) return undefined;
  return extraPile(KEPT_KEY, KEPT_LABEL, 'kept', items, cornerPoint('left', items, view, sizes, avoid), true);
}
