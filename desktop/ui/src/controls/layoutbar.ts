// The layout buttons at the top right (spec section 8, "Controls"), in the order Kind, Time, Place, Topic, Person. A click
// re-arranges at once (no model, no network); when an answer to a question names another layout, the buttons follow.
import type { LayoutName } from '../../../src/recall/spec.ts';
import type { Store } from '../state.ts';
import { el } from './dom.ts';

export const LAYOUT_ORDER: LayoutName[] = ['kind', 'time', 'place', 'topic', 'person'];
const NAMES: Record<LayoutName, string> = { kind: 'Kind', time: 'Time', place: 'Place', topic: 'Topic', person: 'Person' };

export function mountLayoutBar(root: HTMLElement, store: Store): void {
  const buttons = LAYOUT_ORDER.map(name => {
    const b = el('button', { text: NAMES[name], attrs: { type: 'button', 'data-testid': `layout-${name}`, 'aria-pressed': 'false' } });
    b.addEventListener('click', () => store.setLayout(name));
    // Left and Right move along the row.
    b.addEventListener('keydown', e => {
      const k = LAYOUT_ORDER.indexOf(name);
      const next = e.key === 'ArrowRight' ? k + 1 : e.key === 'ArrowLeft' ? k - 1 : -1;
      if (next < 0 || next >= buttons.length) return;
      e.preventDefault();
      buttons[next].focus();
    });
    root.append(b);
    return b;
  });
  let shown: LayoutName | undefined;
  const render = (layout: LayoutName) => {
    if (layout === shown) return;
    shown = layout;
    LAYOUT_ORDER.forEach((name, k) => buttons[k].setAttribute('aria-pressed', String(name === layout)));
  };
  store.subscribe(s => render(s.layout));
  render(store.get().layout);
}
