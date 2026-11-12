// By person: one pile per first-named person, largest first, in the shared grid, then "Nobody mentioned". A capture is one
// object, so one naming several people sits in the pile of the first (the theme marks the others). When more piles than the
// grid holds, the smallest named piles merge into "Others"; "Nobody mentioned" stays its own pile.
import type { LayoutFn } from './types.ts';
import { collect, emptyResult, gridCells, gridPoints, groupBy, largestFirst, viewRect } from './pile.ts';
import type { PileDraft } from './pile.ts';

export const NOBODY = 'Nobody mentioned';
export const OTHERS = 'Others';

export const personLayout: LayoutFn = (items, view, sizes) => {
  if (!items.length) return emptyResult();
  const groups = groupBy(items, it => {
    const name = it.people[0]?.name.trim();
    return name ? { key: `person:${name.toLowerCase()}`, label: name } : { key: 'nobody', label: NOBODY };
  });
  const all = [...groups].map(([key, g]) => ({ key, label: g.label, items: g.items }));
  let named = all.filter(g => g.key !== 'nobody').sort(largestFirst);
  const nobody = all.find(g => g.key === 'nobody');

  const { capacity } = gridCells(view, sizes);
  if (named.length + (nobody ? 1 : 0) > capacity) {
    const keep = named.slice(0, Math.max(0, capacity - 1 - (nobody ? 1 : 0)));
    named = [...keep, { key: 'others', label: OTHERS, items: named.slice(keep.length).flatMap(g => g.items) }];
  }
  const piles = nobody ? [...named, nobody] : named;
  const points = gridPoints(piles.length, view, sizes);
  const drafts: PileDraft[] = piles.map((g, k) => ({ ...g, ...points[k] }));
  return collect(drafts, sizes, viewRect(view));
};
