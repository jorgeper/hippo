// The ask bar and the reply line above it (spec section 8, "Controls"). Enter sends; Up and Down walk the sentences sent
// before (the draft being typed comes back past the newest); Escape clears. While a question is out the lamp breathes and
// typing goes on: a second question sent before the first returns supersedes it (the store drops the older answer).
// "start over" on its own clears the desk, the pins and the set-aside pile here, as the store's start over does.
import type { Store } from '../state.ts';
import { el } from './dom.ts';

export const PLACEHOLDER = 'What are you looking for?';
const START_OVER = /^\s*start\s+over\s*[.!]*\s*$/i;

export interface AskBar { focus(): void; input: HTMLInputElement }

export function mountAskBar(bar: HTMLElement, reply: HTMLElement, store: Store): AskBar {
  const lamp = el('span', { class: 'lamp', attrs: { 'aria-hidden': 'true' } });
  const input = el('input', { attrs: { type: 'text', 'data-testid': 'ask', 'aria-label': 'Ask the desk', placeholder: PLACEHOLDER,
    autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', enterkeyhint: 'send', maxlength: '500' } });
  bar.append(lamp, input);
  const footer = bar.parentElement ?? bar;

  /** Where Up and Down are in the sentences: -1 when not walking them; `draft` is what was typed before the walk began. */
  let cursor = -1, draft = '';
  const show = (text: string) => {
    input.value = text;
    input.setSelectionRange(text.length, text.length);
  };

  input.addEventListener('input', () => { cursor = -1; });
  input.addEventListener('keydown', e => {
    if (e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
    const sentences = store.get().sentences;
    if (e.key === 'Enter') {
      e.preventDefault();
      const text = input.value.trim();
      if (!text) return;
      input.value = '';
      cursor = -1; draft = '';
      void (START_OVER.test(text) ? store.startOver() : store.ask(text));
    } else if (e.key === 'ArrowUp') {
      if (!sentences.length) return;
      e.preventDefault();
      if (cursor === -1) { draft = input.value; cursor = sentences.length; }
      cursor = Math.max(0, cursor - 1);
      show(sentences[cursor]);
    } else if (e.key === 'ArrowDown') {
      if (cursor === -1) return;
      e.preventDefault();
      cursor++;
      if (cursor >= sentences.length) { cursor = -1; show(draft); } else show(sentences[cursor]);
    } else if (e.key === 'Escape') {
      // With text it clears the bar and goes no further; an empty bar lets Escape through to the desk.
      if (!input.value && cursor === -1) return;
      e.preventDefault();
      e.stopPropagation();
      input.value = '';
      cursor = -1; draft = '';
    }
  });

  const render = (s: ReturnType<Store['get']>) => {
    if (reply.textContent !== s.reply) reply.textContent = s.reply;
    footer.classList.toggle('thinking', s.thinking);
    input.setAttribute('aria-busy', String(s.thinking));
  };
  store.subscribe(render);
  render(store.get());

  return { focus: () => input.focus({ preventScroll: true }), input };
}
