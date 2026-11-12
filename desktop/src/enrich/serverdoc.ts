// The capture's server enrichment document: the only thing hippo-desk writes into a Hippo folder
// (spec section 5, "Where results go"; docs/enrichment-format.md, "Write order").
import fs from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import type { Circumstance } from '../core/record.ts';
import type { EnrichmentDoc, Facet, RawCapture } from '../core/types.ts';
import type { ModelEnrichment } from './normalize.ts';
import { PROMPT_VERSION } from './prompt.ts';

export const OWNED_KINDS = ['summary', 'tags', 'display', 'image_description', 'people', 'circumstance', 'hippo_desk_state'] as const;
/** Kinds made by the model (and the state that says so), carried over unchanged when there is no new model result. */
const MODEL_KINDS = ['summary', 'tags', 'display', 'image_description', 'people', 'hippo_desk_state'];

export const MAX_DOC_BYTES = 1_048_576;      // the phone's limit on a server document

const packageJson = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../package.json');
export const PRODUCER = { name: 'hippo-desk', version: String(JSON.parse(readFileSync(packageJson, 'utf8')).version), build: '1' };

function isObject(v: unknown): v is Record<string, any> { return typeof v === 'object' && v !== null && !Array.isArray(v); }
const stamp = (d: Date) => d.toISOString();       // RFC 3339 UTC with milliseconds and Z

function existingFacets(c: RawCapture): Record<string, Facet> {
  return c.server && isObject(c.server.facets) ? c.server.facets : {};
}

const same = (a: unknown, b: unknown) => isObject(a) && isObject(b)
  && a.status === b.status && a.provenance === b.provenance && isDeepStrictEqual(a.data, b.data);

/** The server document for `c`, or undefined when there is nothing to write and nothing exists. */
export function composeServerDoc(c: RawCapture, parts: { model?: { value: ModelEnrichment; provenance: string; digest: string };
  circumstances: Circumstance[]; now: Date }): EnrichmentDoc | undefined {
  const old = existingFacets(c);
  const at = stamp(parts.now);
  const facets: Record<string, Facet> = {};
  for (const [k, f] of Object.entries(old)) if (!(OWNED_KINDS as readonly string[]).includes(k)) facets[k] = f;

  // A new facet that says the same as the old one keeps the old object, so its generated_at does not move.
  const put = (kind: string, provenance: string, data: unknown) => {
    const f: Facet = { version: 1, status: 'ok', generated_at: at, provenance, data };
    facets[kind] = same(old[kind], f) ? old[kind] : f;
  };

  const m = parts.model;
  if (m) {
    const v = m.value;
    if (v.summary !== undefined && v.summary !== '') put('summary', m.provenance, { text: v.summary });
    if (v.tags.length) put('tags', m.provenance, { values: v.tags });
    const display: Record<string, unknown> = { title: v.title, topic: v.topic };
    if (v.keywords.length) display.keywords = v.keywords;
    put('display', m.provenance, display);
    if (v.image_descriptions.length) put('image_description', m.provenance, { items: v.image_descriptions });
    if (v.people.length) put('people', m.provenance, { items: v.people });
    put('hippo_desk_state', 'hippo-desk', { input_digest: m.digest, prompt_version: PROMPT_VERSION });
  } else {
    for (const k of MODEL_KINDS) if (old[k] !== undefined) facets[k] = old[k];
  }

  if (parts.circumstances.length) {
    put('circumstance', 'rules', { items: parts.circumstances.map(ci => {
      const item: Record<string, unknown> = { label: ci.label, confidence: ci.confidence };
      if (ci.evidence.length) item.evidence = ci.evidence;
      return item;
    }) });
  }

  if (!c.server && Object.keys(facets).length === 0) return undefined;
  return { schema_version: 1, schema_minor: 2, capture_id: c.id, layer: 'server', package_digest: c.packageDigest,
    producer: { ...PRODUCER }, generated_at: at, facets };
}

/** True when the documents' facets differ in kind, status, provenance or data; generated_at is ignored. */
export function facetsDiffer(a: EnrichmentDoc | undefined, b: EnrichmentDoc | undefined): boolean {
  if (!a || !b) return a !== b;
  const fa = isObject(a.facets) ? a.facets : {}, fb = isObject(b.facets) ? b.facets : {};
  const ka = Object.keys(fa).sort(), kb = Object.keys(fb).sort();
  if (!isDeepStrictEqual(ka, kb)) return true;
  return ka.some(k => !same(fa[k], fb[k]));
}

function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (isObject(v)) return Object.fromEntries(Object.keys(v).sort().map(k => [k, sortKeys(v[k])]));
  return v;
}

/** Any JSON value with keys sorted at every level, two-space indent, trailing newline: the same bytes every time. */
export function stableJson(v: unknown): string {
  return JSON.stringify(sortKeys(v), null, 2) + '\n';
}

/** Keys sorted, two-space indent, trailing newline. */
export function serializeDoc(doc: EnrichmentDoc): string {
  return stableJson(doc);
}

/** Writes the document to a temp file beside `enrichment.json`, then renames it over; the temp file never outlives a failure. */
export async function writeServerDoc(c: RawCapture, doc: EnrichmentDoc): Promise<void> {
  const bytes = Buffer.from(serializeDoc(doc), 'utf8');
  if (bytes.length > MAX_DOC_BYTES) throw new Error(`the server document would be ${bytes.length} bytes, over the 1 MiB limit`);
  const dir = path.dirname(c.serverPath);
  const created = await fs.mkdir(dir, { recursive: true });       // the first directory this call made, if any
  const tmp = path.join(dir, `.enrichment.json.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`);
  try {
    const fh = await fs.open(tmp, 'wx');
    try { await fh.writeFile(bytes); await fh.sync(); } finally { await fh.close(); }
    await fs.rename(tmp, c.serverPath);
  } catch (e) {
    await fs.rm(tmp, { force: true });
    // Leave no empty directories behind: remove what this call created, leaf first, while empty.
    if (created) {
      for (let d = dir; d.length >= created.length; d = path.dirname(d)) {
        try { await fs.rmdir(d); } catch { break; }
        if (d === created) break;
      }
    }
    throw e;
  }
}

/** Exactly the temp names `writeServerDoc` makes: `.enrichment.json.<pid>.<8 hex>.tmp`. */
export const TEMP_NAME = /^\.enrichment\.json\.\d+\.[0-9a-f]{8}\.tmp$/;
/** A temp file younger than this may belong to another `hippo enrich` running right now. */
export const TEMP_MIN_AGE_MS = 60_000;

/** Temp files a killed run left in the capture's server directory: older than a minute and named exactly like ours.
 *  Removes them unless `dryRun`; returns their paths. Nothing else is ever deleted. */
export async function sweepTempFiles(c: RawCapture, opts: { dryRun?: boolean; nowMs?: number } = {}): Promise<string[]> {
  const dir = path.dirname(c.serverPath);
  let names: string[];
  try { names = await fs.readdir(dir); } catch { return []; }
  const nowMs = opts.nowMs ?? Date.now();
  const found: string[] = [];
  for (const n of names.filter(n => TEMP_NAME.test(n))) {
    const p = path.join(dir, n);
    try {
      const st = await fs.lstat(p);
      if (!st.isFile() || nowMs - st.mtimeMs <= TEMP_MIN_AGE_MS) continue;
      if (!opts.dryRun) await fs.rm(p);
      found.push(p);
    } catch { /* gone already, or not removable: leave it */ }
  }
  return found;
}
