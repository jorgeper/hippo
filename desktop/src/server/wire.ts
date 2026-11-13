// What the desk page receives for each capture: the record from the index, with media references turned into URLs under
// /media. The page never sees a path it could ask for; the server resolves every /media URL through the index's media table.
import type { AttachmentRef, CaptureRecord, Circumstance } from '../core/record.ts';
import type { Kind } from '../core/types.ts';

export interface DeskItem {
  id: string; kind: Kind; title: string; summary?: string; topic?: string; tags: string[];
  people: { name: string; source: string }[]; keywords: { word: string; weight: number }[];
  captured_at: string; local_date: string; local_time: string; weekday: string; part_of_day: string; timezone: string;
  place?: { lat: number; lon: number; locality?: string; sub_locality?: string; nearby?: string };
  circumstances: Circumstance[]; site?: string; url?: string; is_video_link?: boolean; body_excerpt?: string;   // first 280 characters
  thumb?: string; display?: string; media?: string; media_type?: 'picture' | 'audio' | 'video' | 'file';     // URLs under /media
  duration_seconds?: number; file_name?: string;
  /** Attachments besides the main one (a note's own text does not count). */
  more_count: number;
  has: string[];
}

export interface DetailAttachment { id: string; type: AttachmentRef['type']; path: string; uti: string; byte_count: number;
  name?: string; duration_seconds?: number; is_spoken_comment?: boolean; mime?: string;
  url?: string; thumb?: string; display?: string; description?: string }
export interface DetailComment { id: string; added_at: string; text?: string; transcript?: string; audio?: string; audio_path?: string }

/** The back of a lifted item: everything about one capture, with media URLs and absolute file paths. */
export interface CaptureDetail {
  text: string; body?: string; method: string; source_app?: string; enriched: boolean; timezone: string;
  urls: string[];
  link?: { url: string; title?: string; site_name?: string; channel?: string; description?: string; thumb?: string };
  place?: { lat: number; lon: number; accuracy_m?: number; locality?: string; sub_locality?: string; nearby?: string };
  image_descriptions: { attachment_id: string; text: string }[];
  circumstances: Circumstance[];                         // each with its evidence lines
  context: Record<string, unknown>;
  attachments: DetailAttachment[];
  comments: DetailComment[];
  /** Every file the index recorded for the capture (originals, thumbnails, link thumbnail, comment audio). */
  files: { ref: string; mime: string; path: string; url: string }[];
}

export interface WireMedia { ref: string; mime: string; path?: string }

export const BODY_EXCERPT = 280;
const VIDEO_HOSTS = ['youtube.com', 'youtu.be', 'vimeo.com', 'tiktok.com'];

export const mediaUrl = (id: string, ref: string) => `/media/${encodeURIComponent(id)}/${encodeURIComponent(ref)}`;

function isVideoLink(url: string | undefined): boolean {
  if (!url) return false;
  try {
    const host = new URL(url).hostname.toLowerCase().replace(/\.$/, '');
    return VIDEO_HOSTS.some(h => host === h || host.endsWith(`.${h}`));
  } catch { return false; }
}

const MAIN_TYPE: Partial<Record<Kind, AttachmentRef['type']>> = { photo: 'picture', screenshot: 'picture', video: 'video',
  recording: 'audio', file: 'file' };

/** The attachment that stands for the capture: the first of the kind's type. Notes and links have none. */
export function mainAttachment(r: CaptureRecord): AttachmentRef | undefined {
  const type = MAIN_TYPE[r.kind];
  return type ? r.attachments.find(a => a.type === type) : undefined;
}

export function toDeskItem(r: CaptureRecord, media: WireMedia[]): DeskItem {
  const refs = new Set(media.map(m => m.ref));
  const url = (ref: string) => (refs.has(ref) ? mediaUrl(r.id, ref) : undefined);
  const item: DeskItem = {
    id: r.id, kind: r.kind, title: r.title, tags: r.tags, people: r.people, keywords: r.keywords,
    captured_at: r.captured_at, local_date: r.local_date, local_time: r.local_time, weekday: r.weekday, part_of_day: r.part_of_day,
    timezone: r.timezone, circumstances: r.circumstances, more_count: 0, has: r.has,
  };
  if (r.summary) item.summary = r.summary;
  if (r.topic) item.topic = r.topic;
  if (r.place) {
    const p = r.place;
    item.place = { lat: p.lat, lon: p.lon };
    if (p.locality) item.place.locality = p.locality;
    if (p.sub_locality) item.place.sub_locality = p.sub_locality;
    if (p.nearby) item.place.nearby = p.nearby;
  }
  if (r.site) item.site = r.site;
  if (r.link) {
    item.url = r.link.url;
    if (isVideoLink(r.link.url)) item.is_video_link = true;
  }
  if (r.body) item.body_excerpt = [...r.body].slice(0, BODY_EXCERPT).join('');

  const main = mainAttachment(r);
  // The picture shown on the object: the main picture, else the first picture with a thumbnail, else the link's thumbnail.
  const picture = main?.type === 'picture' && refs.has(`thumb-${main.id}`) ? main
    : r.attachments.find(a => a.type === 'picture' && refs.has(`thumb-${a.id}`));
  if (picture) {
    item.thumb = url(`thumb-${picture.id}`);
    const display = url(`display-${picture.id}`);
    if (display) item.display = display;
  } else if (refs.has('link-thumb')) {
    item.thumb = item.display = url('link-thumb');
  }
  if (main) {
    const m = url(main.id);
    if (m) { item.media = m; item.media_type = main.type === 'text' ? 'file' : main.type; }
    if (main.durationSeconds !== undefined) item.duration_seconds = main.durationSeconds;
    if (main.name) item.file_name = main.name;
  }
  item.more_count = r.attachments.filter(a => a !== main && a.type !== 'text').length;
  return item;
}

export function toDetail(r: CaptureRecord, media: WireMedia[]): CaptureDetail {
  const byRef = new Map(media.map(m => [m.ref, m]));
  const url = (ref: string) => (byRef.has(ref) ? mediaUrl(r.id, ref) : undefined);
  const descriptions = new Map(r.image_descriptions.map(d => [d.attachment_id, d.text]));
  const d: CaptureDetail = {
    text: r.text, method: r.method, enriched: r.enriched, timezone: r.timezone, urls: r.urls,
    image_descriptions: r.image_descriptions, circumstances: r.circumstances, context: r.context,
    attachments: r.attachments.map(a => {
      const out: DetailAttachment = { id: a.id, type: a.type, path: a.path, uti: a.uti, byte_count: a.byteCount };
      if (a.name) out.name = a.name;
      if (a.durationSeconds !== undefined) out.duration_seconds = a.durationSeconds;
      if (a.isSpokenComment) out.is_spoken_comment = true;
      const m = byRef.get(a.id);
      if (m) { out.mime = m.mime; out.url = mediaUrl(r.id, a.id); }
      const thumb = url(`thumb-${a.id}`); if (thumb) out.thumb = thumb;
      const display = url(`display-${a.id}`); if (display) out.display = display;
      const text = descriptions.get(a.id); if (text) out.description = text;
      return out;
    }),
    comments: r.comments.map(k => {
      const out: DetailComment = { id: k.id, added_at: k.added_at };
      if (k.text) out.text = k.text;
      if (k.transcript) out.transcript = k.transcript;
      if (k.audioPath) out.audio_path = k.audioPath;
      const audio = url(`comment-${k.id}`); if (audio) out.audio = audio;
      return out;
    }),
    files: media.filter(m => m.path).map(m => ({ ref: m.ref, mime: m.mime, path: m.path!, url: mediaUrl(r.id, m.ref) })),
  };
  if (r.body) d.body = r.body;
  if (r.source_app) d.source_app = r.source_app;
  if (r.place) d.place = r.place;
  if (r.link) {
    const l = r.link;
    d.link = { url: l.url };
    for (const k of ['title', 'site_name', 'channel', 'description'] as const) if (l[k]) d.link[k] = l[k];
    const thumb = url('link-thumb'); if (thumb) d.link.thumb = thumb;
  }
  return d;
}
