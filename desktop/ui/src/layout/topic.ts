// By topic: one pile per topic, largest first, in the shared grid; items with no topic in "Other", last. When more piles
// than the grid holds, the smallest topics (and "Other") merge into a last pile "More".
import type { LayoutFn } from './types.ts';
import { collect, emptyResult, gridCells, gridPoints, groupBy, largestFirst, viewRect } from './pile.ts';
import type { PileDraft } from './pile.ts';
import type { DeskItem } from '../../../src/server/wire.ts';

export const NO_TOPIC = 'Other';
export const MORE = 'More';

export const topicLayout: LayoutFn = (items, view, sizes) => {
  if (!items.length) return emptyResult();
  const groups = groupBy(items, it => {
    const t = it.topic?.trim();
    return t ? { key: `topic:${t.toLowerCase()}`, label: t } : { key: 'other', label: NO_TOPIC };
  });
  const all = [...groups].map(([key, g]) => ({ key, label: g.label, items: g.items }));
  const named = all.filter(g => g.key !== 'other').sort(largestFirst);
  const other = all.find(g => g.key === 'other');
  let piles = other ? [...named, other] : named;

  const { capacity } = gridCells(view, sizes);
  if (piles.length > capacity) {
    const keep = named.slice(0, Math.max(0, capacity - 1));
    const rest: DeskItem[] = piles.filter(g => !keep.includes(g)).flatMap(g => g.items);
    piles = [...keep, { key: 'more', label: MORE, items: rest }];
  }
  const points = gridPoints(piles.length, view, sizes);
  const drafts: PileDraft[] = piles.map((g, k) => ({ ...g, ...points[k] }));
  return collect(drafts, sizes, viewRect(view));
};
