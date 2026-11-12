// The settings panel (spec section 8, "Controls"): theme, the model provider and its two model names, and map tiles on or
// off, saved through POST /api/settings. Keys and tokens are never shown, kept or sent here: a provider that needs one
// reads it from the environment on the server. Values read back from the server reach the page only as form values.
import type { Api, Settings, SettingsPatch } from '../api.ts';
import { el } from './dom.ts';

/** The providers the server knows (desktop/src/providers/index.ts), with names a person reads. */
export const PROVIDERS: { value: string; label: string }[] = [
  { value: 'claude-cli', label: 'Claude Code (claude)' },
  { value: 'codex-cli', label: 'Codex (codex)' },
  { value: 'anthropic-api', label: 'Anthropic API' },
  { value: 'openai-compatible', label: 'OpenAI-compatible API' },
  { value: 'fake', label: 'Fake (for trying the desk)' },
];

export interface SettingsDeps {
  api: Pick<Api, 'settings'>;
  /** The theme names there are (only `desk` today). */
  themes: string[];
  /** After a save, with the settings as the server now has them and as they were. */
  saved(now: Settings, before: Settings): void;
}

export interface SettingsPanel { open(): void; close(): void; isOpen(): boolean }

const titleCase = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** What changed between two sets of settings, as the patch the server takes. */
export function settingsPatch(before: Settings, after: Settings): SettingsPatch {
  const patch: SettingsPatch = {};
  if (after.provider !== before.provider) patch.provider = after.provider;
  if (after.askModel !== before.askModel) patch.askModel = after.askModel;
  if (after.enrichModel !== before.enrichModel) patch.enrichModel = after.enrichModel;
  if (after.mapTiles !== before.mapTiles) patch.mapTiles = after.mapTiles;
  if (after.theme !== before.theme) patch.theme = after.theme;
  return patch;
}

export function mountSettings(panel: HTMLElement, button: HTMLButtonElement, initial: Settings, deps: SettingsDeps): SettingsPanel {
  let current = { ...initial };

  const field = (id: string, label: string, control: HTMLElement, hint?: string) => {
    control.id = id;
    return el('div', { class: 'field' }, el('label', { text: label, attrs: { for: id } }), control,
      ...(hint ? [el('p', { class: 'hint', text: hint })] : []));
  };
  const theme = el('select');
  const provider = el('select');
  const askModel = el('input', { attrs: { type: 'text', maxlength: '120', autocomplete: 'off', spellcheck: 'false' } });
  const enrichModel = el('input', { attrs: { type: 'text', maxlength: '120', autocomplete: 'off', spellcheck: 'false' } });
  const tiles = el('input', { attrs: { type: 'checkbox', id: 'settings-tiles' } });
  const message = el('p', { class: 'message', attrs: { role: 'status' } });
  const cancel = el('button', { text: 'Cancel', attrs: { type: 'button' } });
  const save = el('button', { class: 'primary', text: 'Save', attrs: { type: 'button' } });

  panel.id ||= 'settings';
  panel.append(
    el('h2', { text: 'Settings' }),
    field('settings-theme', 'Theme', theme),
    field('settings-provider', 'Model provider', provider, 'Answers questions and reads captures during Update.'),
    el('div', { class: 'pair' },
      field('settings-ask-model', 'Model for asking', askModel),
      field('settings-enrich-model', 'Model for Update', enrichModel)),
    el('div', { class: 'field' },
      el('div', { class: 'switch' }, el('label', { text: 'Map tiles', attrs: { for: 'settings-tiles' } }), tiles),
      el('p', { class: 'hint', text: 'The place map is drawn from openstreetmap.org, which then sees the area you are looking at. Off: a plain sheet with place names.' })),
    el('div', { class: 'actions' }, message, cancel, save),
  );
  button.setAttribute('aria-controls', panel.id);

  const fill = () => {
    const options = (select: HTMLSelectElement, list: { value: string; label: string }[], value: string) => {
      const all = list.some(o => o.value === value) ? list : [...list, { value, label: value }];
      select.replaceChildren(...all.map(o => { const opt = el('option', { text: o.label }); opt.value = o.value; return opt; }));
      select.value = value;
    };
    options(theme, deps.themes.map(t => ({ value: t, label: titleCase(t) })), current.theme);
    options(provider, PROVIDERS, current.provider);
    askModel.value = current.askModel;
    enrichModel.value = current.enrichModel;
    tiles.checked = current.mapTiles;
    message.textContent = '';
    message.classList.remove('failed');
  };

  const isOpen = () => !panel.hidden;
  const open = () => {
    fill();
    panel.hidden = false;
    button.setAttribute('aria-expanded', 'true');
    theme.focus();
  };
  const close = (refocus = false) => {
    if (!isOpen()) return;
    panel.hidden = true;
    button.setAttribute('aria-expanded', 'false');
    if (refocus) button.focus();
  };

  button.addEventListener('click', () => (isOpen() ? close() : open()));
  cancel.addEventListener('click', () => close(true));
  panel.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(true); }
    else if (e.key === 'Enter' && (e.target as HTMLElement).tagName === 'INPUT' && (e.target as HTMLInputElement).type === 'text') { e.preventDefault(); save.click(); }
  });
  document.addEventListener('pointerdown', e => {
    if (isOpen() && !panel.contains(e.target as Node) && !button.contains(e.target as Node)) close();
  });

  save.addEventListener('click', async () => {
    const wanted: Settings = { theme: theme.value, provider: provider.value, askModel: askModel.value.trim(),
      enrichModel: enrichModel.value.trim(), mapTiles: tiles.checked };
    const patch = settingsPatch(current, wanted);
    if (!Object.keys(patch).length) { close(true); return; }
    save.disabled = true;
    message.textContent = 'Saving…';
    message.classList.remove('failed');
    try {
      const before = current;
      current = (await deps.api.settings(patch)).settings;
      deps.saved(current, before);
      close(true);
    } catch (e) {
      message.textContent = e instanceof Error ? e.message : String(e);
      message.classList.add('failed');
    } finally {
      save.disabled = false;
    }
  });

  return { open, close: () => close(), isOpen };
}
