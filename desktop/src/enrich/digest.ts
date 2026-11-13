// The input digest (spec section 5): SHA-256 over exactly what the model is shown, plus the prompt version.
// A capture is enriched again only when this changes, so a device facet the model never sees costs no call.
import crypto from 'node:crypto';
import type { RawCapture } from '../core/types.ts';
import { modelInput, PROMPT_VERSION } from './prompt.ts';

/** JSON with object keys sorted at every level; array order kept. */
export function canonicalJson(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(',')}]`;
  if (v !== null && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o).filter(k => o[k] !== undefined).sort().map(k => `${JSON.stringify(k)}:${canonicalJson(o[k])}`).join(',')}}`;
  }
  return JSON.stringify(v);
}

/** `pictureHashes`: the manifest SHA-256 of each original picture sent (at most four, attachment order), not of the JPEGs made from them. */
export function inputDigest(c: RawCapture, pictureHashes: string[]): string {
  const payload = { input: modelInput(c), picture_sha256: pictureHashes, prompt_version: PROMPT_VERSION };
  return crypto.createHash('sha256').update(canonicalJson(payload)).digest('hex');
}
