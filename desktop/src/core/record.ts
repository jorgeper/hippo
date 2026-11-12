// One record per capture, everything derived without a model (spec section 5, "What it derives without a model").
import path from 'node:path';
import { assetPath } from './folder.ts';
import { deriveCircumstances } from './circumstance.ts';
import { present, resolved } from './resolve.ts';
import type { Confidence, Kind, RawCapture } from './types.ts';

export interface Circumstance { label: string; confidence: Confidence; evidence: string[] }
export interface AttachmentRef { id: string; type: 'picture' | 'audio' | 'video' | 'file' | 'text';
  path: string; uti: string; name?: string; sha256: string; byteCount: number; durationSeconds?: number;
  isSpokenComment?: boolean }
export interface CommentRef { id: string; added_at: string; text?: string; audioPath?: string; transcript?: string }
export type Weekday = 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat' | 'sun';
export type PartOfDay = 'morning' | 'afternoon' | 'evening' | 'night';
export type Has = 'picture' | 'audio' | 'comment' | 'location' | 'link';
export interface CaptureRecord {
  id: string; kind: Kind; method: string;
  captured_at: string; timezone: string; local_date: string; local_time: string;   // "2026-11-07", "09:07"
  weekday: Weekday; part_of_day: PartOfDay;
  title: string; summary?: string; topic?: string; tags: string[];
  people: { name: string; source: string }[]; keywords: { word: string; weight: number }[];
  image_descriptions: { attachment_id: string; text: string }[];
  circumstances: Circumstance[];
  text: string;                          // everything searchable, newline-joined (spec section 5 "Text")
  body?: string;                         // what the opened item shows: note text or first transcript
  urls: string[]; site?: string; source_app?: string;
  link?: { url: string; title?: string; site_name?: string; channel?: string; description?: string; thumbPath?: string };
  place?: { lat: number; lon: number; accuracy_m?: number; locality?: string; sub_locality?: string; nearby?: string };
  attachments: AttachmentRef[]; comments: CommentRef[];
  has: Has[];
  context: Record<string, unknown>;      // the raw context.* observation values and location extras, for the back of the item
  enriched: boolean;                     // server document carries display from producer hippo-desk
}

function isObject(v: unknown): v is Record<string, any> { return typeof v === 'object' && v !== null && !Array.isArray(v); }
const nonBlank = (v: unknown): v is string => typeof v === 'string' && v.trim() !== '';
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

// ---- attachments ----

const TEXT_UTIS = new Set(['public.utf8-plain-text', 'public.plain-text']);
const VIDEO_UTIS = new Set(['public.movie', 'public.video', 'com.apple.quicktime-movie', 'public.mpeg-4', 'com.apple.m4v-video',
  'public.avi', 'public.mpeg', 'public.3gpp', 'public.3gpp2']);
const PICTURE_UTIS = new Set(['public.image', 'public.png', 'public.jpeg', 'public.heic', 'public.heif', 'com.compuserve.gif',
  'public.tiff', 'org.webmproject.webp', 'com.microsoft.bmp', 'public.camera-raw-image', 'public.avif']);
const AUDIO_UTIS = new Set(['public.audio', 'com.apple.m4a-audio', 'public.mp3', 'public.mpeg-4-audio', 'com.microsoft.waveform-audio',
  'public.aiff-audio', 'public.aifc-audio', 'com.apple.coreaudio-format']);

function attachmentType(a: Record<string, any>): AttachmentRef['type'] {
  const uti = typeof a.uti === 'string' ? a.uti : '';
  const mime = typeof a.mime_type === 'string' ? a.mime_type.toLowerCase() : '';
  if (TEXT_UTIS.has(uti)) return 'text';
  if (VIDEO_UTIS.has(uti)) return 'video';
  if (PICTURE_UTIS.has(uti)) return 'picture';
  if (AUDIO_UTIS.has(uti)) return 'audio';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('image/')) return 'picture';
  if (mime.startsWith('audio/')) return 'audio';
  return 'file';
}

function rawAttachments(c: RawCapture): Record<string, any>[] {
  const list = c.metadata.attachments;
  return Array.isArray(list) ? list.filter(a => isObject(a) && nonBlank(a.attachment_id) && nonBlank(a.relative_path)) : [];
}

function screenshotIds(c: RawCapture): Set<string> {
  const f = c.device && isObject(c.device.facets) ? c.device.facets.screenshot : undefined;
  const items = isObject(f) && f.status === 'ok' && isObject(f.data) ? f.data.items : undefined;
  return new Set(Array.isArray(items) ? items.filter(isObject).map(i => i.attachment_id).filter(nonBlank) : []);
}

function urlList(c: RawCapture): string[] {
  const urls = Array.isArray(c.metadata.urls) ? c.metadata.urls : [];
  return [...new Set(urls.map((u: unknown) => (isObject(u) && nonBlank(u.url) ? u.url.trim() : undefined)).filter(nonBlank))];
}

/** Kind precedence, spec section 5: video, screenshot or photo, recording, file, link (not a typed note), note. */
export function deriveKind(c: RawCapture): Kind {
  const atts = rawAttachments(c).map(a => ({ id: a.attachment_id as string, type: attachmentType(a) }));
  if (atts.some(a => a.type === 'video')) return 'video';
  const pic = atts.find(a => a.type === 'picture');
  if (pic) return screenshotIds(c).has(pic.id) ? 'screenshot' : 'photo';
  if (atts.some(a => a.type === 'audio')) return 'recording';
  if (atts.some(a => a.type === 'file')) return 'file';
  if (urlList(c).length > 0 && c.metadata.capture_method !== 'typed_note') return 'link';
  return 'note';
}

// ---- time ----

const WEEKDAYS: Weekday[] = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const pad = (n: number) => String(n).padStart(2, '0');

interface Local { y: number; mo: number; d: number; h: number; mi: number }

function inZone(t: Date, zone: string): Local | undefined {
  try {
    const parts = new Intl.DateTimeFormat('en-US', { timeZone: zone, year: 'numeric', month: 'numeric', day: 'numeric',
      hour: 'numeric', minute: 'numeric', hourCycle: 'h23' }).formatToParts(t);
    const get = (type: string) => Number(parts.find(p => p.type === type)?.value);
    const l = { y: get('year'), mo: get('month'), d: get('day'), h: get('hour') % 24, mi: get('minute') };
    return Object.values(l).every(Number.isFinite) ? l : undefined;
  } catch { return undefined; }
}

function withOffset(t: Date, seconds: number): Local {
  const s = new Date(t.getTime() + seconds * 1000);
  return { y: s.getUTCFullYear(), mo: s.getUTCMonth() + 1, d: s.getUTCDate(), h: s.getUTCHours(), mi: s.getUTCMinutes() };
}

/** The capture's own wall clock: its zone, else its UTC offset, never the machine's zone. */
function localTime(c: RawCapture): Local {
  const md = c.metadata;
  const t = new Date(typeof md.captured_at === 'string' ? md.captured_at : NaN);
  if (!Number.isNaN(t.getTime())) {
    const z = nonBlank(md.timezone_identifier) ? inZone(t, md.timezone_identifier) : undefined;
    if (z) return z;
    return withOffset(t, finite(md.utc_offset_seconds) ? md.utc_offset_seconds : 0);
  }
  const m = typeof md.local_datetime === 'string' ? /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(md.local_datetime) : null;
  if (m) return { y: +m[1], mo: +m[2], d: +m[3], h: +m[4], mi: +m[5] };
  const [y, mo, d] = c.datePath.split('/').map(Number);
  return { y, mo, d, h: 0, mi: 0 };
}

function partOfDay(h: number): PartOfDay {
  if (h >= 5 && h <= 11) return 'morning';
  if (h >= 12 && h <= 16) return 'afternoon';
  if (h >= 17 && h <= 21) return 'evening';
  return 'night';
}

function offsetName(seconds: number): string {
  const sign = seconds < 0 ? '-' : '+';
  const a = Math.abs(Math.round(seconds / 60));
  return `UTC${sign}${pad(Math.floor(a / 60))}:${pad(a % 60)}`;
}

// ---- title ----

function cutTitle(line: string): string {
  const chars = [...line];
  if (chars.length <= 60) return line;
  const head = chars.slice(0, 60).join('');
  const space = head.lastIndexOf(' ');
  const base = (space > 0 ? head.slice(0, space) : chars.slice(0, 59).join('')).trimEnd();
  return `${base}…`;
}

function firstLine(text: string | undefined): string | undefined {
  return text?.split(/\r?\n/).map(l => l.trim()).find(l => l !== '');
}

const KIND_NAMES: Record<Kind, string> = { link: 'Link', photo: 'Photo', screenshot: 'Screenshot', note: 'Note',
  recording: 'Recording', video: 'Video', file: 'File' };

// ---- the record ----

function safePath(dir: string, rel: string): string | undefined {
  if (path.isAbsolute(rel)) return undefined;
  const full = path.resolve(dir, rel);
  const r = path.relative(dir, full);
  return r === '' || r.startsWith('..') || path.isAbsolute(r) ? undefined : full;
}

export async function buildRecord(c: RawCapture): Promise<CaptureRecord> {
  const md = c.metadata;
  const res = resolved(c);
  const kind = deriveKind(c);
  const lt = localTime(c);
  const local_date = `${lt.y}-${pad(lt.mo)}-${pad(lt.d)}`;
  const urls = urlList(c);

  // Attachments, in metadata order. Audio beside a picture is a spoken comment on it.
  const attachments: AttachmentRef[] = [];
  for (const a of rawAttachments(c)) {
    const full = safePath(c.dir, a.relative_path);
    if (!full) continue;
    const ref: AttachmentRef = { id: a.attachment_id, type: attachmentType(a), path: full, uti: typeof a.uti === 'string' ? a.uti : '',
      sha256: typeof a.sha256 === 'string' ? a.sha256 : '', byteCount: finite(a.byte_count) ? a.byte_count : 0 };
    if (nonBlank(a.original_filename)) ref.name = a.original_filename;
    if (isObject(a.media) && finite(a.media.duration_seconds)) ref.durationSeconds = a.media.duration_seconds;
    attachments.push(ref);
  }
  if (attachments.some(a => a.type === 'picture'))
    for (const a of attachments) if (a.type === 'audio') a.isSpokenComment = true;

  const transcriptOf = (id: string) => {
    const t = res.transcripts.get(id)?.text;
    return nonBlank(t) ? t.trim() : undefined;
  };
  const comments: CommentRef[] = c.comments.map(k => {
    const ref: CommentRef = { id: k.id, added_at: k.added_at };
    if (k.text !== undefined) ref.text = k.text;
    if (k.audioPath !== undefined) ref.audioPath = k.audioPath;
    const t = transcriptOf(k.id);
    if (t !== undefined) ref.transcript = t;
    return ref;
  });
  const firstTranscript = [...attachments.map(a => transcriptOf(a.id)), ...comments.map(k => k.transcript)].find(nonBlank);

  const note = nonBlank(c.noteBody) ? c.noteBody.trim() : undefined;
  const body = note ?? firstTranscript;

  // Link: the first URL with its resolved preview.
  let link: CaptureRecord['link'];
  let site: string | undefined;
  if (urls.length) {
    link = { url: urls[0] };
    const p = res.linkPreviews.get(urls[0]);
    if (p) {
      for (const k of ['title', 'site_name', 'channel', 'description'] as const) if (nonBlank(p[k])) link[k] = p[k].trim();
      if (p.thumbnail && p.thumbnailLayer === 'device') {
        const thumb = await assetPath(c, p.thumbnail);
        if (thumb) link.thumbPath = thumb;
      }
    }
    try {
      const host = new URL(urls[0]).hostname.replace(/^www\./, '');
      if (host) site = host;
    } catch { /* not a URL with a host */ }
  }

  // Place: the capture location, else the first picture's embedded location; names from the place facet.
  let place: CaptureRecord['place'];
  const loc = md.capture_location;
  let target: string | undefined;
  if (isObject(loc) && finite(loc.latitude) && finite(loc.longitude)) {
    place = { lat: loc.latitude, lon: loc.longitude };
    if (finite(loc.horizontal_accuracy_meters)) place.accuracy_m = loc.horizontal_accuracy_meters;
    target = 'capture';
  } else {
    for (const a of rawAttachments(c)) {
      const e = isObject(a.media) ? a.media.embedded_location : undefined;
      if (attachmentType(a) === 'picture' && isObject(e) && finite(e.latitude) && finite(e.longitude)) {
        place = { lat: e.latitude, lon: e.longitude }; target = a.attachment_id; break;
      }
    }
  }
  if (place && target) {
    const p = res.places.get(target);
    if (p) {
      if (nonBlank(p.locality)) place.locality = p.locality.trim();
      if (nonBlank(p.sub_locality)) place.sub_locality = p.sub_locality.trim();
      if (isObject(p.nearby) && nonBlank(p.nearby.name)) place.nearby = p.nearby.name.trim();
    }
  }

  // Text: everything searchable, spec section 5 "Text".
  const commentIds = new Set(comments.map(k => k.id));
  const lines: unknown[] = [note, md.shared_title, md.shared_text, md.user_note];
  for (const u of urls) { const p = res.linkPreviews.get(u); if (p) lines.push(p.title, p.description); }
  for (const r of res.recognizedText.values()) lines.push(r.text);
  for (const t of res.transcripts.values()) if (!commentIds.has(t.attachment_id)) lines.push(t.text);
  for (const k of comments) lines.push(k.text, k.transcript);
  const text = [...new Set(lines.filter(nonBlank).map(s => s.trim()))].join('\n');

  // Title: first non-blank of the chain in the brief.
  const firstWords = firstTranscript?.split(/\s+/).filter(Boolean).slice(0, 8).join(' ');
  const noteLine = firstLine(note);
  const title = [res.display?.title, res.linkPreviews.get(urls[0] ?? '')?.title, md.shared_title,
    noteLine === undefined ? undefined : cutTitle(noteLine), firstWords, attachments[0]?.name]
    .find(nonBlank)?.trim() ?? `${KIND_NAMES[kind]} · ${local_date}`;

  const context: Record<string, unknown> = {};
  for (const o of Array.isArray(md.metadata_observations) ? md.metadata_observations : [])
    if (isObject(o) && typeof o.key === 'string' && o.key.startsWith('context.') && present(o.value)) context[o.key] = o.value;
  if (isObject(loc)) {
    const extras: Record<string, number> = {};
    for (const k of ['altitude_meters', 'vertical_accuracy_meters', 'speed_meters_per_second', 'speed_accuracy_meters_per_second',
      'course_degrees', 'course_accuracy_degrees']) if (finite(loc[k])) extras[k] = loc[k];
    if (Object.keys(extras).length) context.capture_location = extras;
  }

  const has: Has[] = [];
  if (attachments.some(a => a.type === 'picture')) has.push('picture');
  if (attachments.some(a => a.type === 'audio') || comments.some(k => k.audioPath !== undefined)) has.push('audio');
  if (comments.length) has.push('comment');
  if (place) has.push('location');
  if (urls.length) has.push('link');

  const display = c.server && isObject(c.server.facets) ? c.server.facets.display : undefined;
  const enriched = c.server?.producer?.name === 'hippo-desk' && isObject(display) && display.status === 'ok';

  const record: CaptureRecord = {
    id: c.id, kind, method: typeof md.capture_method === 'string' ? md.capture_method : '',
    captured_at: typeof md.captured_at === 'string' ? md.captured_at : '',
    timezone: nonBlank(md.timezone_identifier) ? md.timezone_identifier : offsetName(finite(md.utc_offset_seconds) ? md.utc_offset_seconds : 0),
    local_date, local_time: `${pad(lt.h)}:${pad(lt.mi)}`,
    weekday: WEEKDAYS[new Date(Date.UTC(lt.y, lt.mo - 1, lt.d)).getUTCDay()], part_of_day: partOfDay(lt.h),
    title, tags: res.tags ?? [], people: res.people, keywords: res.display?.keywords ?? [],
    image_descriptions: res.imageDescriptions, circumstances: deriveCircumstances(c),
    text, urls, attachments, comments, has, context, enriched,
  };
  if (nonBlank(res.summary)) record.summary = res.summary;
  if (nonBlank(res.display?.topic)) record.topic = res.display.topic;
  if (body !== undefined) record.body = body;
  if (site !== undefined) record.site = site;
  const app = nonBlank(md.source_application) ? md.source_application.trim() : res.sourceApp?.app;
  if (nonBlank(app)) record.source_app = app;
  if (link) record.link = link;
  if (place) record.place = place;
  return record;
}
