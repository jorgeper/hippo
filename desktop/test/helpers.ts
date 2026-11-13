import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Ajv2020 } from 'ajv/dist/2020.js';
import type { EnrichmentDoc, Facet, RawCapture } from '../src/core/types.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
export const fixturesDir = path.resolve(here, '../../fixtures/packages');

/** Copies fixtures/packages into a fresh temp dir and returns it. Also points HIPPO_DESK_HOME at another temp dir. */
export function copyFixtures(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-fixtures-'));
  fs.cpSync(fixturesDir, dir, { recursive: true });
  process.env.HIPPO_DESK_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-home-'));
  return dir;
}

/** A RawCapture built in memory, for rules that need no files. `metadata` overrides the defaults. */
export function syntheticCapture(metadata: Record<string, any> = {}, extra: Partial<RawCapture> = {}): RawCapture {
  const id = typeof metadata.capture_id === 'string' ? metadata.capture_id : '00000000-0000-4000-8000-0000000000aa';
  return {
    id, dir: path.join(os.tmpdir(), 'hippo-synthetic', id), datePath: '2026/11/07', packageDigest: '0'.repeat(64),
    comments: [], serverPath: path.join(os.tmpdir(), 'hippo-synthetic', 'server', id, 'enrichment.json'),
    metadata: {
      schema_version: 1, capture_id: id, captured_at: '2026-11-07T17:00:00.000Z', local_datetime: '2026-11-07T09:00:00-08:00',
      timezone_identifier: 'America/Los_Angeles', utc_offset_seconds: -28800, capture_method: 'share_extension',
      content_types: [], urls: [], producer: { app_version: '0', build: '0', os_version: 'test' },
      attachments: [], metadata_observations: [], extensions: {}, ...metadata,
    },
    ...extra,
  };
}

/** A device or server enrichment document with the given facets, each `ok` unless the facet says otherwise. */
export function enrichmentDoc(layer: 'device' | 'server', facets: Record<string, Partial<Facet>>, producer = 'test'): EnrichmentDoc {
  const out: Record<string, Facet> = {};
  for (const [k, f] of Object.entries(facets))
    out[k] = { version: 1, status: 'ok', generated_at: '2026-11-07T18:00:00.000Z', provenance: 'test', ...f };
  return { schema_version: 1, capture_id: '00000000-0000-4000-8000-0000000000aa', layer, package_digest: '0'.repeat(64),
    producer: { name: producer, version: '1', build: '1' }, generated_at: '2026-11-07T18:00:00.000Z', facets: out };
}

/** Relative path (forward slashes) -> sha256 of every file under `folder`. */
export function snapshot(folder: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (dir: string) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else out[path.relative(folder, full).split(path.sep).join('/')] = crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex');
    }
  };
  walk(folder);
  return out;
}

const ajv = new Ajv2020({ allErrors: true, strictTypes: false });
// The format's timestamps: RFC 3339 UTC with milliseconds and Z.
ajv.addFormat('date-time', /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
const enrichmentSchema = ajv.compile(JSON.parse(fs.readFileSync(path.resolve(here, '../../schema/enrichment-v1.schema.json'), 'utf8')));

/** Validates against schema/enrichment-v1.schema.json; returns the error list (empty when valid). */
export function enrichmentErrors(doc: unknown): string[] {
  return enrichmentSchema(doc) ? [] : (enrichmentSchema.errors ?? []).map(e => `${e.instancePath} ${e.message}`);
}
