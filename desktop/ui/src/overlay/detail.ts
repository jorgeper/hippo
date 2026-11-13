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

/** The card never gets smaller than this (CSS pixels), so the back's sections have room on a narrow item. */
export const MIN_CARD = { w: 460, h: 380 };
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
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

const humanise = (s: string) => {
  const t = s.replace(/^context\./, '').replace(/[._]+/g, ' ').trim();
  return t.charAt(0).toUpperCase() + t.slice(1);
};

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
  const day = WEEKDAYS[item.weekday] ?? item.weekday;
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

export function duration(s: number | undefined): string {
  if (s === undefined || !Number.isFinite(s)) return '';
  const t = Math.round(s), m = Math.floor(t / 60), r = t % 60;
  return `${m}:${String(r).padStart(2, '0')}`;
}

/** A value of the capture's context as one line of text. */
function contextText(v: unknown): string {
  if (v === null || v === undefined) return '';
  if (typeof v === 'string') return v;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (Array.isArray(v)) return v.map(contextText).filter(Boolean).join(', ');
  if (typeof v === 'object') return Object.entries(v as Record<string, unknown>).map(([k, x]) => `${humanise(k).toLowerCase()} ${contextText(x)}`).join(', ');
  return '';
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
    let w = Math.max(MIN_CARD.w, rect.width), h = Math.max(MIN_CARD.h, rect.height);
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
      layout(rect);
      setSide(b);
      root.hidden = false;
      root.classList.remove('concealed');
      requestAnimationFrame(() => root.classList.add('shown'));
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
  if (d) {
    const method = METHODS[d.method] ?? humanise(d.method);
    add('Captured', line(d.source_app ? `${method}, from ${d.source_app}` : method));
    const ctx = Object.entries(d.context).map(([k, v]) => [humanise(k), contextText(v)] as const).filter(([, v]) => v);
    if (ctx.length) add('Device', ...ctx.map(([k, v]) => line(el('span', { class: 'key', text: `${k}: ` }), v)));
  }
  const circumstances = d?.circumstances ?? item.circumstances;
  if (circumstances.length) {
    add('Likely', ...circumstances.map(c => {
      const box = el('div', { class: 'likely' });
      box.append(line(el('span', { class: 'likely-label', text: CIRCUMSTANCES[c.label] ?? c.label }),
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
  if (d?.files.length) add('Files', ...d.files.map(f => el('p', { class: 'path' }, el('span', { class: 'path-text', text: f.path }), soft(` ${f.mime}`))));
  if (!d) facts.append(...section('', line(soft('Reading the rest…'))));
  return [el('h2', { class: 'title', text: item.title || humanise(item.kind) }), facts];
}
