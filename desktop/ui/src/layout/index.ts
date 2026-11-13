// The five layouts by name (spec section 8). Adding a layout is adding a file and a line here.
import type { LayoutName } from '../../../src/recall/spec.ts';
import type { LayoutFn } from './types.ts';
import { kindLayout } from './kind.ts';
import { timeLayout } from './time.ts';
import { placeLayout } from './place.ts';
import { topicLayout } from './topic.ts';
import { personLayout } from './person.ts';

export { EMPTY_LINE } from './pile.ts';
export type { Backdrop, LayoutFn, LayoutResult, PileInfo, Placement, Size, SizeTable, View } from './types.ts';

export const layouts: Record<LayoutName, LayoutFn> = {
  kind: kindLayout, time: timeLayout, place: placeLayout, topic: topicLayout, person: personLayout,
};
