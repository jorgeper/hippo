// Clamps a model answer to the contract (Review Focus 2). Whatever the model says, what comes out
// composes into a document that validates against schema/enrichment-v1.schema.json.
import { attachmentRefs, deriveKind } from '../core/record.ts';
import type { RawCapture } from '../core/types.ts';

export interface ModelEnrichment { title: string; summary?: string; image_descriptions: { attachment_id: string; text: string }[];
  tags: string[]; topic: string; people: { name: string; source: string }[]; keywords: { word: string; weight: number }[] }

export const TITLE_MAX = 60;          // Unicode code points, as the schema counts them
const MAX_TAGS = 8;
const MAX_KEYWORDS = 12;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TEXT_SOURCES = ['user_note', 'shared_text', 'shared_title'];

function isObject(v: unknown): v is Record<string, any> { return typeof v === 'object' && v !== null && !Array.isArray(v); }
/** Trimmed, inner whitespace runs collapsed to one space; undefined when blank or not a string. */
function line(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v.replace(/\s+/g, ' ').trim();
  return s === '' ? undefined : s;
}
const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const codePoints = (s: string) => [...s].length;

/** At most 60 code points, ending on a whole word when there is a space to cut at, never inside a grapheme. */
export function cutTitle(s: string): string {
  if (codePoints(s) <= TITLE_MAX) return s;
  let head = '';
  for (const { segment } of new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(s)) {
    if (codePoints(head) + codePoints(segment) > TITLE_MAX) break;
    head += segment;
  }
  const next = s.slice(head.length);
  if (!/^\s/.test(next)) {                              // the cut fell inside a word: go back to the last space
    const space = head.lastIndexOf(' ');
    if (space > 0) head = head.slice(0, space);
  }
  head = head.replace(/[\s,;:\-–—]+$/u, '');
  return head === '' ? [...s].slice(0, TITLE_MAX).join('').trim() : head;
}

const topicKey = (t: string) => t.toLowerCase().replace(/[\s_\-]+/g, ' ').trim();

export function normalize(raw: unknown, c: RawCapture, knownTopics: string[]): ModelEnrichment | undefined {
  if (!isObject(raw)) return undefined;
  const t = line(raw.title);
  if (t === undefined) return undefined;
  const title = cutTitle(t);

  const atts = attachmentRefs(c);
  const pictureIds = new Set(atts.filter(a => a.type === 'picture' && UUID.test(a.id)).map(a => a.id));
  const sources = new Set([...TEXT_SOURCES, ...atts.map(a => a.id), ...c.comments.map(k => k.id)].filter(id => id.trim() !== ''));

  const tags: string[] = [];
  for (const v of list(raw.tags)) {
    const tag = line(v)?.toLowerCase();
    if (tag !== undefined && !tags.includes(tag)) tags.push(tag);
    if (tags.length === MAX_TAGS) break;
  }

  let topic = line(raw.topic)?.toLowerCase() ?? tags[0] ?? 'other';
  const known = knownTopics.map(k => line(k)?.toLowerCase()).find(k => k !== undefined && topicKey(k) === topicKey(topic));
  if (known !== undefined) topic = known;

  const image_descriptions: ModelEnrichment['image_descriptions'] = [];
  for (const d of list(raw.image_descriptions)) {
    if (!isObject(d) || typeof d.attachment_id !== 'string' || !pictureIds.has(d.attachment_id)) continue;
    const text = typeof d.text === 'string' ? d.text.trim() : '';
    if (text !== '' && !image_descriptions.some(x => x.attachment_id === d.attachment_id))
      image_descriptions.push({ attachment_id: d.attachment_id, text });
  }

  const people: ModelEnrichment['people'] = [];
  for (const p of list(raw.people)) {
    if (!isObject(p)) continue;
    const name = line(p.name);
    if (name === undefined || typeof p.source !== 'string' || !sources.has(p.source)) continue;
    if (!people.some(x => x.name.toLowerCase() === name.toLowerCase())) people.push({ name, source: p.source });
  }

  const keywords: ModelEnrichment['keywords'] = [];
  const kind = deriveKind(c);
  if (kind === 'note' || kind === 'recording') {
    for (const k of list(raw.keywords)) {
      if (!isObject(k) || typeof k.weight !== 'number' || !Number.isFinite(k.weight)) continue;
      const word = line(k.word);
      if (word === undefined || keywords.some(x => x.word.toLowerCase() === word.toLowerCase())) continue;
      keywords.push({ word, weight: Math.min(1, Math.max(0, k.weight)) });
      if (keywords.length === MAX_KEYWORDS) break;
    }
  }

  const out: ModelEnrichment = { title, image_descriptions, tags, topic, people, keywords };
  const summary = typeof raw.summary === 'string' ? raw.summary.trim() : '';
  if (summary !== '') out.summary = summary;
  return out;
}
