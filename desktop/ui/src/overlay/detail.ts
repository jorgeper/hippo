// The lifted item made sharp (spec section 8, "Handling", Open an item): HTML laid over the object once it has risen, so long
// text and players are crisp and scroll. The front is the thing itself (the picture at full resolution, the note's text,
// the recording with a player and its transcript, the link with a button that opens it in the browser, the video playing,
// the file's name and path), with the capture's other attachments and comments below it; the back is everything about it.
// Text from captures, the model and the server only ever goes in as textContent; media come only from this page's own
// /media route, and the browser opens only http and https links.
import type { CaptureResponse, DeskItem } from '../api.ts';
import type { CaptureDetail, DetailAttachment, DetailComment } from '../../../src/server/wire.ts';
import type { ScreenRect } from '../scene/stage.ts';
import { el } from '../controls/dom.ts';

/**
 * The card never gets smaller than this (CSS pixels), so the back's sections have room on a narrow item. The front of a
 * narrow upright picture (a phone screenshot) may be as narrow as `frontW`, so no wide slab of edge surrounds it.
 */
export const MIN_CARD = { w: 460, h: 380, frontW: 240 };
/** The back lies a little beyond the object's face on every side, so the object's rim (a cassette's shell) does not show. */
const BACK_SPILL = 8;
/** Room kept free around the card, and under it for its buttons. */
const MARGIN = 16, ACTIONS_ROOM = 64;

/** Picture types a browser shows: the original is used for these, the made display copy for the rest (HEIC). */
const SHOWABLE = /^image\/(jpeg|png|gif|webp)$/;

export const CIRCUMSTANCES: Record<string, string> = {
  in_car: 'In a car', walking: 'Walking', running: 'Running', cycling: 'Cycling', on_headphones: 'On headphones',
  in_a_burst: 'In a burst of captures', daylight: 'In daylight', dark: 'In the dark',
};
const METHODS: Record<string, string> = {
  share_extension: 'Shared from another app', camera: 'Taken with the camera', typed_note: 'Typed on the phone',
  voice_recording: 'Recorded on the phone', file_import: 'Imported as a file',
};
const WEEKDAYS: Record<string, string> = { mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday', fri: 'Friday', sat: 'Saturday', sun: 'Sunday' };
/** A table's own entry for a key from a capture, never an inherited one (`constructor`, `__proto__`, `toString`). */
const own = (table: Record<string, string>, key: string): string | undefined => (Object.hasOwn(table, key) ? table[key] : undefined);
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

const humanise = (s: string) => {
  const t = s.replace(/^context\./, '').replace(/[._]+/g, ' ').trim();
  return t.charAt(0).toUpperCase() + t.slice(1);
};

/** A circumstance label in words; one this page does not know, as written. */
export const circumstanceWords = (label: string): string => own(CIRCUMSTANCES, label) ?? label;
/** How the capture was made, in words. */
export const methodWords = (method: string): string => own(METHODS, method) ?? humanise(method);

/** Only this page's own media route: `/media/<id>/<ref>`. */
export function mediaSrc(u: string | undefined): string | undefined {
  return u && /^\/media\/[^/?#]+\/[^/?#]+$/.test(u) ? u : undefined;
}

/** The link the browser may open: only http and https. */
export function safeLink(u: string | undefined): string | undefined {
  if (!u) return undefined;
  try {
    const p = new URL(u);
    return p.protocol === 'http:' || p.protocol === 'https:' ? u : undefined;
  } catch { return undefined; }
}

/** "Tuesday 10 November 2026, 14:32" from the capture's own local date and time. */
export function whenLine(item: Pick<DeskItem, 'local_date' | 'local_time' | 'weekday'>): string {
  const [y, m, d] = item.local_date.split('-').map(Number);
  const day = own(WEEKDAYS, item.weekday) ?? item.weekday;
  const date = Number.isFinite(y) && m >= 1 && m <= 12 ? `${d} ${MONTHS[m - 1]} ${y}` : item.local_date;
  return `${day} ${date}, ${item.local_time}`;
}

export function bytes(n: number): string {
  if (n < 1024) return `${n} bytes`;
  const units = ['KB', 'MB', 'GB'];
  let v = n / 1024, k = 0;
  while (v >= 1024 && k < units.length - 1) { v /= 1024; k++; }
  return `${v < 10 ? v.toFixed(1) : Math.round(v)} ${units[k]}`;
}

/** A length as m:ss, counting whole seconds as the browser's own players do, so the label and the player agree. */
export function duration(s: number | undefined): string {
  if (s === undefined || !Number.isFinite(s)) return '';
  const t = Math.max(0, Math.floor(s)), m = Math.floor(t / 60), r = t % 60;
  return `${m}:${String(r).padStart(2, '0')}`;
}

/** Beyond this a gap is "More than a month": a phone's clock or a bad value can make it any size. */
const GAP_DAYS_MAX = 30;

/** A gap in plain words: "9 s", "45 min", "2 h 4 min", "1 day 4 h", up to 30 days; "More than a month" beyond. */
export function gapWords(seconds: number): string {
  if (!(seconds <= GAP_DAYS_MAX * 86400)) return 'More than a month';
  if (seconds < 59.5) return `${Math.round(seconds)} s`;
  if (seconds < 86400 - 30) {
    const m = Math.round(seconds / 60), h = Math.floor(m / 60), mm = m % 60;
    return h ? `${h} h${mm ? ` ${mm} min` : ''}` : `${mm} min`;
  }
  const hours = Math.round(seconds / 3600), d = Math.floor(hours / 24), h = hours % 24;
  return `${d} ${d === 1 ? 'day' : 'days'}${h ? ` ${h} h` : ''}`;
}

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : {});
const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);
const str = (v: unknown): string | undefined => (typeof v === 'string' && v.trim() ? v.trim() : undefined);

/** Where sound went, by port: the built-in ones by what they are, the others by their own names. */
const BUILT_IN_PORTS: Record<string, string> = { built_in_speaker: 'the speaker', built_in_receiver: 'the earpiece' };
const PORTS: Record<string, string> = { headphones: 'headphones', car_audio: 'the car', bluetooth_a2dp: 'Bluetooth audio',
  bluetooth_le: 'Bluetooth audio', bluetooth_hfp: 'a Bluetooth headset', airplay: 'AirPlay', hdmi: 'a screen', usb_audio: 'a USB device' };
const ORIENTATIONS: Record<string, string> = { portrait: 'Held upright', portrait_upside_down: 'Held upside down',
  landscape_left: 'Held sideways', landscape_right: 'Held sideways', face_up: 'Lying face up', face_down: 'Lying face down' };
const NETWORKS: Record<string, string> = { wifi: 'On Wi-Fi', cellular: 'On mobile data', wired: 'On a wired network', other: 'On a network', none: 'Offline' };
const BATTERY: Record<string, string> = { unplugged: 'not charging', charging: 'charging', full: 'full' };

/**
 * The phone's state when the capture was saved, one short plain line per fact (spec docs/context-signals.md): where sound
 * was going, the battery, low power mode, dark appearance, heat, how it was held, the network, the gap since the previous
 * capture, the height and speed of the location fix. Ids, the switches that were on, and defaults that say nothing (light
 * appearance, normal heat, the locale and clock) are left out, as are signals this does not know.
 */
export function deviceLines(context: Record<string, unknown>): string[] {
  const out: string[] = [];
  const route = obj(context['context.audio_route']);
  const outputs = Array.isArray(route.outputs) ? route.outputs.map(obj) : [];
  const where = [...new Set(outputs.map(o => {
    const type = str(o.port_type) ?? '';
    return own(BUILT_IN_PORTS, type) ?? str(o.port_name) ?? own(PORTS, type);
  }).filter((x): x is string => !!x))];
  if (where.length) out.push(`Sound going to ${where.join(' and ')}`);

  const dev = obj(context['context.device']);
  const level = num(dev.battery_level), state = own(BATTERY, str(dev.battery_state) ?? '');
  if (level !== undefined) out.push(`Battery at ${Math.round(Math.min(1, Math.max(0, level)) * 100)}%${state ? `, ${state}` : ''}`);
  else if (state) out.push(`Battery ${state}`);
  if (dev.low_power_mode === true) out.push('Low power mode on');
  if (dev.interface_style === 'dark') out.push('Dark appearance');
  if (dev.thermal_state === 'serious' || dev.thermal_state === 'critical') out.push('Running hot');
  else if (dev.thermal_state === 'fair') out.push('Running warm');
  const held = own(ORIENTATIONS, str(dev.orientation) ?? '');
  if (held) out.push(held);

  const net = obj(context['context.network']);
  const on = own(NETWORKS, str(net.interface) ?? '');
  if (on) out.push([on, net.expensive === true ? 'metered' : '', net.constrained === true ? 'low data mode' : ''].filter(Boolean).join(', '));

  const gap = num(obj(context['context.burst']).seconds_since_previous);
  if (gap !== undefined && gap >= 0) out.push(`${gapWords(gap)} after the previous capture`);

  const loc = obj(context.capture_location);
  const alt = num(loc.altitude_meters);
  if (alt !== undefined) out.push(alt < 0 ? `${Math.round(-alt)} m below sea level` : `${Math.round(alt)} m above sea level`);
  const speed = num(loc.speed_meters_per_second);
  if (speed !== undefined && speed >= 0.5) out.push(`Moving at ${Math.round(speed * 3.6)} km/h`);
  return out;
}

export interface DetailHooks { flip(): void; close(): void }

export interface DetailOverlay {
  /** Fills the card for this item (front and back), hidden; the full detail fills in when `detail` settles. */
  prepare(item: DeskItem, detail: Promise<CaptureResponse>): void;
  /** Fades the card in over `rect`, showing `side`. */
  show(rect: ScreenRect, back: boolean): void;
  /** Follows the object (the window changed). */
  place(rect: ScreenRect): void;
  /** Fades the card out but keeps it (the item is turning over). */
  conceal(): void;
  close(): void;
  isOpen(): boolean;
  element: HTMLElement;
}

const section = (label: string, ...content: Node[]) => [el('dt', { text: label }), el('dd', {}, ...content)];
const soft = (text: string) => el('span', { class: 'soft', text });
const line = (...content: (Node | string)[]) => {
  const p = el('p');
  p.append(...content);
  return p;
};

export function mountDetail(host: HTMLElement, hooks: DetailHooks): DetailOverlay {
  const front = el('div', { class: 'detail-face detail-front' });
  const back = el('div', { class: 'detail-face detail-back' });
  const card = el('div', { class: 'detail-card', attrs: { tabindex: '-1', title: 'Click the edge to turn it over' } }, front, back);
  const link = el('button', { class: 'detail-button primary', text: 'Open in browser', attrs: { type: 'button', 'data-testid': 'open-link' } });
  const flip = el('button', { class: 'detail-button', text: 'Turn over', attrs: { type: 'button', 'data-testid': 'flip', title: 'Turn it over (F)' } });
  const close = el('button', { class: 'detail-button', text: 'Put back', attrs: { type: 'button', 'data-testid': 'close-detail', title: 'Put it back (Esc)' } });
  const actions = el('div', { class: 'detail-actions' }, link, flip, close);
  const root = el('div', { class: 'detail', attrs: { 'data-testid': 'detail', role: 'dialog', 'aria-label': 'Item', hidden: '' } }, card, actions);
  host.append(root);

  let current: DeskItem | undefined;
  let url: string | undefined;
  let token = 0;
  let side: 'front' | 'back' = 'front';
  /** What had focus before the card took it, given back when the card closes. */
  let before: Element | null = null;

  card.addEventListener('click', e => { if (e.target === card) hooks.flip(); });
  flip.addEventListener('click', () => hooks.flip());
  close.addEventListener('click', () => hooks.close());
  link.addEventListener('click', () => { if (url) window.open(url, '_blank', 'noopener'); });
  // The overlay's own wheel and pointer events stay with it (scrolling the text, using a player), never reaching the desk.
  root.addEventListener('wheel', e => e.stopPropagation(), { passive: true });

  function setSide(b: boolean): void {
    side = b ? 'back' : 'front';
    root.dataset.side = side;
    flip.textContent = b ? 'Turn back' : 'Turn over';
    link.hidden = b || !url;
    front.hidden = b;
    back.hidden = !b;
    // A player keeps playing only while its side shows.
    if (b) for (const m of front.querySelectorAll('audio, video')) (m as HTMLMediaElement).pause();
  }

  function layout(rect: ScreenRect): void {
    const vw = window.innerWidth, vh = window.innerHeight;
    const spill = side === 'back' ? BACK_SPILL : 0;
    const upright = side === 'front' && rect.height > rect.width;
    let w = Math.max(upright ? MIN_CARD.frontW : MIN_CARD.w, rect.width + 2 * spill), h = Math.max(MIN_CARD.h, rect.height + 2 * spill);
    w = Math.min(w, vw - 2 * MARGIN);
    h = Math.min(h, vh - MARGIN - ACTIONS_ROOM);
    let left = rect.left + rect.width / 2 - w / 2, top = rect.top + rect.height / 2 - h / 2;
    left = Math.max(MARGIN, Math.min(vw - MARGIN - w, left));
    top = Math.max(MARGIN, Math.min(vh - ACTIONS_ROOM - h, top));
    Object.assign(card.style, { left: `${left}px`, top: `${top}px`, width: `${w}px`, height: `${h}px` });
    card.style.setProperty('--card-h', `${h}px`);
    Object.assign(actions.style, { left: `${left}px`, top: `${top + h + 12}px`, width: `${w}px` });
  }

  return {
    element: root,
    prepare(item, detail) {
      const t = ++token;
      current = item;
      url = item.kind === 'link' ? safeLink(item.url) : undefined;
      root.dataset.kind = item.kind;
      root.dataset.id = item.id;
      card.className = `detail-card kind-${item.kind}`;
      root.setAttribute('aria-label', item.title || item.kind);
      front.replaceChildren(...frontOf(item, undefined));
      back.replaceChildren(...backOf(item, undefined));
      root.dataset.loaded = 'false';
      setSide(false);
      detail.then(r => {
        if (t !== token) return;
        current = r.item;
        if (item.kind === 'link') url = safeLink(r.detail.link?.url ?? r.item.url);
        front.replaceChildren(...frontOf(r.item, r.detail));
        back.replaceChildren(...backOf(r.item, r.detail));
        root.dataset.loaded = 'true';
        setSide(side === 'back');
      }, (e: unknown) => {
        if (t !== token) return;
        back.append(el('p', { class: 'detail-error', text: `The rest could not be read: ${e instanceof Error ? e.message : String(e)}` }));
        root.dataset.loaded = 'failed';
      });
    },
    show(rect, b) {
      if (!current) return;
      setSide(b);
      layout(rect);
      root.hidden = false;
      root.classList.remove('concealed');
      requestAnimationFrame(() => root.classList.add('shown'));
      if (!root.contains(document.activeElement)) before = document.activeElement;
      card.focus({ preventScroll: true });
    },
    place(rect) { if (!root.hidden) layout(rect); },
    conceal() { root.classList.add('concealed'); },
    close() {
      token++;
      current = undefined;
      for (const m of root.querySelectorAll('audio, video')) (m as HTMLMediaElement).pause();
      root.classList.remove('shown', 'concealed');
      root.hidden = true;
      front.replaceChildren();
      back.replaceChildren();
      // Focus goes back where it was (the ask bar, say), if that is still on the page.
      const was = before;
      before = null;
      if (was instanceof HTMLElement && was !== document.body && was.isConnected) was.focus({ preventScroll: true });
    },
    isOpen: () => !root.hidden,
  };
}

// ---------------------------------------------------------------- the front: the thing itself

function picture(src: string | undefined, alt: string, cls = 'picture'): HTMLElement {
  const s = mediaSrc(src);
  if (!s) return el('div', { class: `${cls} missing`, text: 'No picture' });
  return el('img', { class: cls, attrs: { src: s, alt, decoding: 'async', draggable: 'false' } });
}

/** The capture's main attachment: the first of its kind's type. */
function mainOf(item: DeskItem, d: CaptureDetail | undefined): DetailAttachment | undefined {
  const type = { photo: 'picture', screenshot: 'picture', video: 'video', recording: 'audio', file: 'file' }[item.kind as string];
  return type ? d?.attachments.find(a => a.type === type) : undefined;
}

function bestPicture(a: DetailAttachment | undefined, fallback: string | undefined): string | undefined {
  if (a?.url && a.mime && SHOWABLE.test(a.mime)) return a.url;
  return a?.display ?? fallback;
}

function frontOf(item: DeskItem, d: CaptureDetail | undefined): Node[] {
  const main = mainOf(item, d);
  const title = item.title || '';
  const out: Node[] = [];
  const mainBox = el('div', { class: 'front-main' });
  switch (item.kind) {
    case 'photo':
    case 'screenshot': {
      mainBox.append(picture(bestPicture(main, item.display ?? item.thumb), title));
      if (item.kind === 'photo' && title) mainBox.append(el('p', { class: 'caption', text: title }));
      break;
    }
    case 'video': {
      const src = mediaSrc(main?.url ?? item.media);
      if (src) {
        const poster = mediaSrc(item.display ?? item.thumb);
        mainBox.append(el('video', { class: 'player-video', attrs: { src, controls: '', preload: 'metadata', playsinline: '', ...(poster ? { poster } : {}) } }));
      } else mainBox.append(picture(item.display ?? item.thumb, title));
      if (title) mainBox.append(el('p', { class: 'caption', text: title }));
      break;
    }
    case 'recording': {
      const label = el('div', { class: 'tape-label' });
      label.append(el('h2', { class: 'title', text: title }));
      const len = duration(main?.duration_seconds ?? item.duration_seconds);
      if (len) label.append(el('p', { class: 'meta', text: len }));
      const src = mediaSrc(main?.url ?? item.media);
      if (src) label.append(el('audio', { attrs: { src, controls: '', preload: 'metadata' } }));
      const words = d?.body ?? item.body_excerpt;
      label.append(el('p', { class: 'transcript', text: words || (d ? 'No transcript.' : '') }));
      mainBox.append(label);
      break;
    }
    case 'note': {
      if (title) mainBox.append(el('h2', { class: 'title', text: title }));
      mainBox.append(el('p', { class: 'note-text', text: d?.body ?? item.body_excerpt ?? '' }));
      break;
    }
    case 'link': {
      const l = d?.link;
      const thumb = mediaSrc(l?.thumb ?? item.thumb);
      if (thumb) mainBox.append(el('div', { class: 'link-thumb' }, picture(thumb, '', 'picture')));
      mainBox.append(el('h2', { class: 'title', text: l?.title ?? title }));
      const site = [l?.site_name ?? item.site, l?.channel].filter((x): x is string => !!x);
      if (site.length) mainBox.append(el('p', { class: 'meta', text: site.join(', ') }));
      if (l?.description) mainBox.append(el('p', { class: 'description', text: l.description }));
      const u = l?.url ?? item.url;
      if (u) mainBox.append(el('p', { class: 'url', text: u }));
      break;
    }
    case 'file': {
      const name = main?.name ?? item.file_name ?? title;
      mainBox.append(el('h2', { class: 'title', text: name }));
      const facts = [main?.mime ?? main?.uti, main ? bytes(main.byte_count) : undefined].filter((x): x is string => !!x);
      if (facts.length) mainBox.append(el('p', { class: 'meta', text: facts.join(', ') }));
      if (title && title !== name) mainBox.append(el('p', { class: 'description', text: title }));
      const path = main ? d?.files.find(f => f.ref === main.id)?.path : undefined;
      if (path) mainBox.append(el('p', { class: 'path', text: path }));
      break;
    }
  }
  out.push(mainBox);
  const more = moreOf(d, main);
  if (more.length) {
    mainBox.classList.add('has-more');
    out.push(el('section', { class: 'more' }, el('h3', { text: 'Also in this capture' }), ...more));
  }
  return out;
}

/** The capture's other attachments, then its comments. */
function moreOf(d: CaptureDetail | undefined, main: DetailAttachment | undefined): Node[] {
  if (!d) return [];
  const out: Node[] = [];
  for (const a of d.attachments) {
    if (a === main || a.type === 'text') continue;
    const row = el('div', { class: `attachment type-${a.type}` });
    if (a.type === 'picture') row.append(picture(bestPicture(a, a.thumb), a.description ?? ''));
    else if (a.type === 'audio' && mediaSrc(a.url)) row.append(el('audio', { attrs: { src: mediaSrc(a.url)!, controls: '', preload: 'metadata' } }));
    else if (a.type === 'video' && mediaSrc(a.url)) row.append(el('video', { attrs: { src: mediaSrc(a.url)!, controls: '', preload: 'metadata', playsinline: '' } }));
    const words = [a.name, a.is_spoken_comment ? 'Spoken comment' : undefined, a.duration_seconds !== undefined ? duration(a.duration_seconds) : undefined,
      bytes(a.byte_count)].filter((x): x is string => !!x);
    row.append(el('p', { class: 'meta', text: words.join(', ') }));
    if (a.description) row.append(el('p', { class: 'description', text: a.description }));
    out.push(row);
  }
  out.push(...d.comments.map(commentOf));
  return out;
}

function commentOf(c: DetailComment): Node {
  const row = el('div', { class: 'comment' });
  row.append(el('p', { class: 'meta', text: `Comment, ${c.added_at.slice(0, 16).replace('T', ' ')} UTC` }));
  const audio = mediaSrc(c.audio);
  if (audio) row.append(el('audio', { attrs: { src: audio, controls: '', preload: 'metadata' } }));
  const words = c.text ?? c.transcript;
  if (words) row.append(el('p', { class: 'comment-text', text: words }));
  return row;
}

// ---------------------------------------------------------------- the back: everything about it

function backOf(item: DeskItem, d: CaptureDetail | undefined): Node[] {
  const facts = el('dl', { class: 'facts' });
  const add = (label: string, ...content: Node[]) => { if (content.length) facts.append(...section(label, ...content)); };

  add('When', line(whenLine(item)), line(soft(item.timezone)));
  const place = d?.place ?? item.place;
  if (place) {
    const names = [place.sub_locality, place.locality].filter((x): x is string => !!x);
    const where: Node[] = [];
    if (names.length) where.push(line(names.join(', ')));
    if (place.nearby) where.push(line(soft(`Near ${place.nearby}`)));
    const acc = d?.place?.accuracy_m;
    where.push(line(soft(`${place.lat.toFixed(5)}, ${place.lon.toFixed(5)}${acc !== undefined ? `, within ${Math.round(acc)} m` : ''}`)));
    add('Where', ...where);
  }
  // What it means first; how it was captured and the phone's state after that; the files last.
  const circumstances = d?.circumstances ?? item.circumstances;
  if (circumstances.length) {
    add('Likely', ...circumstances.map(c => {
      const box = el('div', { class: 'likely' });
      box.append(line(el('span', { class: 'likely-label', text: circumstanceWords(c.label) }),
        el('span', { class: 'confidence', text: `${c.confidence} confidence`, attrs: { 'data-level': c.confidence } })));
      if (c.evidence.length) box.append(el('ul', { class: 'evidence' }, ...c.evidence.map(e => el('li', { text: e }))));
      return box;
    }));
  }
  if (item.summary) add('Summary', line(item.summary));
  if (item.topic) add('Topic', line(item.topic));
  if (item.tags.length) add('Tags', el('p', { class: 'tags' }, ...item.tags.map(t => el('span', { class: 'tag', text: t }))));
  if (item.people.length) add('People', ...item.people.map(p => line(p.name, ' ', soft(`found in ${p.source}`))));
  if (d?.image_descriptions.length) add('In the picture', ...d.image_descriptions.map(x => line(x.text)));
  if (d?.comments.length) add('Comments', ...d.comments.map(c => line(c.text ?? c.transcript ?? 'A spoken comment', ' ', soft(c.added_at.slice(0, 10)))));
  if (d) {
    const method = methodWords(d.method);
    add('Captured', line(d.source_app ? `${method}, from ${d.source_app}` : method));
    add('Device', ...deviceLines(d.context).map(t => line(t)));
  }
  if (d?.files.length) add('Files', ...d.files.map(f => el('p', { class: 'path' }, el('span', { class: 'path-text', text: f.path }), soft(` ${f.mime}`))));
  if (!d) facts.append(...section('', line(soft('Reading the rest…'))));
  return [el('h2', { class: 'title', text: item.title || humanise(item.kind) }), facts];
}
