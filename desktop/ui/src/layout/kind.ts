// By kind: one pile per kind in fixed slots, a 4 + 3 grid (link, photo, screenshot, note / recording, video, file). A kind
// with no items leaves its slot empty, so a pile never moves between questions.
import type { Kind } from '../../../src/core/types.ts';
import type { LayoutFn } from './types.ts';
import { collect, emptyResult, viewRect } from './pile.ts';
import type { PileDraft } from './pile.ts';

export const KIND_ORDER: Kind[] = ['link', 'photo', 'screenshot', 'note', 'recording', 'video', 'file'];
export const KIND_LABELS: Record<Kind, string> = { link: 'Links', photo: 'Photos', screenshot: 'Screenshots', note: 'Notes',
  recording: 'Recordings', video: 'Videos', file: 'Files' };

/** The slot of each kind: four across the far row, three centred on the near row, each a quarter of the width apart. */
export function kindSlot(kind: Kind, view: { width: number; height: number }): { x: number; y: number } {
  const k = KIND_ORDER.indexOf(kind);
  const step = view.width / 4;
  return k < 4 ? { x: (k - 1.5) * step, y: view.height / 4 } : { x: (k - 5) * step, y: -view.height / 4 };
}

export const kindLayout: LayoutFn = (items, view, sizes) => {
  if (!items.length) return emptyResult();
  const drafts: PileDraft[] = [];
  for (const kind of KIND_ORDER) {
    const members = items.filter(i => i.kind === kind);
    if (members.length) drafts.push({ key: kind, label: KIND_LABELS[kind], items: members, ...kindSlot(kind, view) });
  }
  return collect(drafts, sizes, viewRect(view));
};
