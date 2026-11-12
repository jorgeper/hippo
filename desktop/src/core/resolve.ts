// The format's override rule (docs/enrichment-format.md, "Override rule"): per item, field by field.
// A gold (server) field wins only when the gold facet is `ok` and the field is present and non-blank;
// otherwise the silver (device) field shows. Empty or failed facets contribute nothing.
import type { EnrichmentDoc, Facet, RawCapture } from './types.ts';

export type Layer = 'device' | 'server';
export interface AssetRef { relative_path: string; byte_count: number; sha256: string; mime_type?: string }
export interface LinkPreview { url: string; title?: string; site_name?: string; channel?: string; description?: string;
  canonical_url?: string; thumbnail?: AssetRef; thumbnailLayer?: Layer; [k: string]: unknown }
export interface PlaceItem { target: string; sub_locality?: string; locality?: string; region?: string; country?: string;
  nearby?: { name?: string; distance_meters?: number }; [k: string]: unknown }
export interface RecognizedText { attachment_id: string; text?: string; languages?: string[]; [k: string]: unknown }
export interface Transcript { attachment_id: string; text?: string; locale?: string; segments?: unknown[]; [k: string]: unknown }
export interface Display { title?: string; topic?: string; keywords?: { word: string; weight: number }[] }

export interface Resolved {
  linkPreviews: Map<string, LinkPreview>;        // by url
  places: Map<string, PlaceItem>;                // by target
  recognizedText: Map<string, RecognizedText>;   // by attachment_id
  transcripts: Map<string, Transcript>;          // by attachment_id (or comment_id)
  summary?: string;
  tags?: string[];
  sourceApp?: { app: string; reason?: string };
  display?: Display;
  imageDescriptions: { attachment_id: string; text: string }[];
  people: { name: string; source: string }[];
  circumstances: { label: string; confidence: string; evidence?: string[] }[];
}

type Item = Record<string, unknown>;

function isObject(v: unknown): v is Record<string, any> { return typeof v === 'object' && v !== null && !Array.isArray(v); }

/** Present and non-blank: not missing, not a blank string, not an empty array. */
export function present(v: unknown): boolean {
  if (v === undefined || v === null) return false;
  if (typeof v === 'string') return v.trim() !== '';
  if (Array.isArray(v)) return v.length > 0;
  if (typeof v === 'number') return Number.isFinite(v);
  return true;
}

function okData(doc: EnrichmentDoc | undefined, kind: string): Record<string, any> | undefined {
  const f: Facet | undefined = doc && isObject(doc.facets) ? doc.facets[kind] : undefined;
  if (!isObject(f) || f.status !== 'ok' || !isObject(f.data)) return undefined;
  return f.data;
}

function copyPresent(into: Item, from: Item): string[] {
  const set: string[] = [];
  for (const [k, v] of Object.entries(from)) if (present(v)) { into[k] = v; set.push(k); }
  return set;
}

/** Merges `{items}` facets keyed by `key`; silver order first, then gold-only items. Each value records which layer set each field. */
function mergeItems(c: RawCapture, kind: string, key: (i: Item) => string | undefined): Map<string, { item: Item; from: Record<string, Layer> }> {
  const out = new Map<string, { item: Item; from: Record<string, Layer> }>();
  for (const layer of ['device', 'server'] as const) {
    const items = okData(layer === 'device' ? c.device : c.server, kind)?.items;
    if (!Array.isArray(items)) continue;
    for (const it of items) {
      if (!isObject(it)) continue;
      const k = key(it);
      if (k === undefined) continue;
      let e = out.get(k);
      if (!e) { e = { item: {}, from: {} }; out.set(k, e); }
      for (const f of copyPresent(e.item, it)) e.from[f] = layer;
    }
  }
  return out;
}

/** Merges a single-item facet (matched by kind). */
function mergeSingle(c: RawCapture, kind: string): Item | undefined {
  const out: Item = {};
  for (const doc of [c.device, c.server]) { const d = okData(doc, kind); if (d) copyPresent(out, d); }
  return Object.keys(out).length ? out : undefined;
}

const str = (k: string) => (i: Item) => (typeof i[k] === 'string' && present(i[k]) ? (i[k] as string) : undefined);

function byKey<T>(m: Map<string, { item: Item }>): Map<string, T> {
  return new Map([...m].map(([k, e]) => [k, e.item as T]));
}

export function resolved(c: RawCapture): Resolved {
  const links = mergeItems(c, 'link_preview', str('url'));
  const linkPreviews = new Map<string, LinkPreview>();
  for (const [url, e] of links) {
    const lp = { ...e.item } as LinkPreview;
    if (lp.thumbnail !== undefined) lp.thumbnailLayer = e.from.thumbnail;
    linkPreviews.set(url, lp);
  }

  const out: Resolved = {
    linkPreviews,
    places: byKey<PlaceItem>(mergeItems(c, 'place', str('target'))),
    recognizedText: byKey<RecognizedText>(mergeItems(c, 'text_recognition', str('attachment_id'))),
    transcripts: byKey<Transcript>(mergeItems(c, 'transcript', str('attachment_id'))),
    imageDescriptions: [], people: [], circumstances: [],
  };

  const summary = mergeSingle(c, 'summary');
  if (typeof summary?.text === 'string') out.summary = summary.text.trim();
  const tags = mergeSingle(c, 'tags');
  if (Array.isArray(tags?.values)) {
    const values = tags.values.filter((v): v is string => typeof v === 'string' && v.trim() !== '').map(v => v.trim());
    if (values.length) out.tags = values;
  }
  const app = mergeSingle(c, 'source_app_guess');
  if (typeof app?.app === 'string') {
    out.sourceApp = { app: app.app.trim() };
    if (typeof app.reason === 'string') out.sourceApp.reason = app.reason;
  }

  const display = mergeSingle(c, 'display');
  if (display) {
    const d: Display = {};
    if (typeof display.title === 'string') d.title = display.title.trim();
    if (typeof display.topic === 'string') d.topic = display.topic.trim();
    if (Array.isArray(display.keywords)) {
      const kw = display.keywords
        .filter((k): k is { word: string; weight: number } => isObject(k) && typeof k.word === 'string' && k.word.trim() !== ''
          && typeof k.weight === 'number' && Number.isFinite(k.weight))
        .map(k => ({ word: k.word.trim(), weight: k.weight }));
      if (kw.length) d.keywords = kw;
    }
    if (Object.keys(d).length) out.display = d;
  }

  for (const e of mergeItems(c, 'image_description', str('attachment_id')).values())
    if (typeof e.item.text === 'string') out.imageDescriptions.push({ attachment_id: e.item.attachment_id as string, text: e.item.text.trim() });
  const personKey = (i: Item) => (typeof i.name === 'string' && present(i.name) && typeof i.source === 'string' && present(i.source)
    ? `${i.name.trim()}\u0000${i.source}` : undefined);
  for (const e of mergeItems(c, 'people', personKey).values())
    out.people.push({ name: (e.item.name as string).trim(), source: e.item.source as string });
  for (const e of mergeItems(c, 'circumstance', str('label')).values()) {
    if (typeof e.item.confidence !== 'string') continue;
    const ci: Resolved['circumstances'][number] = { label: e.item.label as string, confidence: e.item.confidence };
    if (Array.isArray(e.item.evidence)) ci.evidence = e.item.evidence.filter((s): s is string => typeof s === 'string');
    out.circumstances.push(ci);
  }
  return out;
}
