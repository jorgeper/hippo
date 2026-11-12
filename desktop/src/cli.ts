import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { indexPath, loadConfig, resolveFolder } from './core/paths.ts';
import { MAX_ATTEMPTS } from './enrich/state.ts';
import type { IndexReport } from './index/build.ts';
import { openIndex } from './index/db.ts';
import type { IndexDb } from './index/db.ts';
import { facets, matchIds, mediaOf, search, show } from './recall/engine.ts';
import { formatFacets, formatRecord, formatSearch } from './recall/format.ts';
import { validateSpec } from './recall/spec.ts';
// The enricher, the providers and the index builder (with its image libraries) are loaded only by the commands that use them,
// so search, show and facets never load a provider.

const usage = `Usage: hippo <command> [options]

Commands:
  enrich [--folder <path>] [--no-model] [--dry-run] [--limit n] [--provider name] [--model name]
         Writes one server enrichment document per capture that needs it, then updates the index.
  index  [--folder <path>] [--rebuild]
         Builds or updates the local index and thumbnails. No model, nothing written to the folder.
  status [--folder <path>]
         Counts by kind, how many are enriched, pending captures, failures, last runs.
  search [--folder <path>] [--json] [filters] | --spec '<json>'
         Filters (each repeatable or comma-separated): --kind --tag --topic --person --site --locality --circumstance --has
         --weekday --part-of-day; and --text "<words>" --phrase "<exact phrase>" --from YYYY-MM-DD --to YYYY-MM-DD
         --near lat,lon,radius_m --min-confidence low|medium|high --sort newest|oldest|relevance --limit n
  show   <id or id prefix of 8+ characters> [--folder <path>] [--json]
         Everything about one capture, with every file path.
  facets [--folder <path>] [--json]
         The vocabulary: kinds, topics, tags, people, sites, localities, circumstances, date range.
  sample --out <dir> [--count 300] [--seed 1] [--end YYYY-MM-DD]
         Writes a new folder of invented captures, already enriched, to try index, search and the desk on.
`;

class UsageError extends Error {}

type Command = (args: string[]) => Promise<number | void> | number | void;

type Options = Record<string, { type: 'string' | 'boolean'; multiple?: boolean }>;

function parse<T extends Options>(args: string[], options: T) {
  try { return parseArgs({ args, strict: true, allowPositionals: false, options }).values; }
  catch (e) { throw new UsageError((e as Error).message); }
}

function parseWithPositionals<T extends Options>(args: string[], options: T) {
  try { return parseArgs({ args, strict: true, allowPositionals: true, options }); }
  catch (e) { throw new UsageError((e as Error).message); }
}

function printIndexReport(r: IndexReport): void {
  for (const f of r.thumbFailures) process.stderr.write(`warning: no thumbnail for ${f.id}: ${f.reason}\n`);
  const parts = [`${r.captures} captures`, `${r.added} added`, `${r.updated} updated`, `${r.removed} removed`, `${r.thumbnails} thumbnails`];
  if (r.thumbFailures.length) parts.push(`${r.thumbFailures.length} thumbnail failures`);
  process.stdout.write(`Index: ${parts.join(' · ')}\n`);
}

async function enrich(args: string[]): Promise<number> {
  const { makeProvider } = await import('./providers/index.ts');
  const { enrichFolder } = await import('./enrich/enrich.ts');
  const { buildIndex, markEnriched } = await import('./index/build.ts');
  const values = parse(args, {
    folder: { type: 'string' }, 'no-model': { type: 'boolean' }, 'dry-run': { type: 'boolean' },
    limit: { type: 'string' }, provider: { type: 'string' }, model: { type: 'string' } });
  let limit: number | undefined;
  if (values.limit !== undefined) {
    limit = Number(values.limit);
    if (!/^\d+$/.test(values.limit) || !Number.isSafeInteger(limit)) throw new UsageError('--limit takes a whole number');
  }
  const config = loadConfig();
  const folder = resolveFolder(values.folder);
  const noModel = values['no-model'] === true, dryRun = values['dry-run'] === true;
  const provider = noModel ? undefined : makeProvider(values.provider ?? config.provider);
  const model = values.model ?? config.enrichModel;

  // First SIGINT or SIGTERM: finish the calls in flight, then stop. A second one exits at once.
  const ac = new AbortController();
  const onSignal = () => {
    if (ac.signal.aborted) process.exit(130);
    process.stderr.write('Interrupted: stopping after the calls in flight… (again to quit now)\n');
    ac.abort();
  };
  process.on('SIGINT', onSignal);
  process.on('SIGTERM', onSignal);

  const started = Date.now();
  let r;
  try {
    r = await enrichFolder({ folder, provider, model, noModel, dryRun, limit, concurrency: config.concurrency, signal: ac.signal,
      onProgress: e => { if (e.what !== 'unchanged') process.stdout.write(`${e.id}  ${e.what}\n`); } });
  } finally {
    process.off('SIGINT', onSignal);
    process.off('SIGTERM', onSignal);
  }

  for (const p of r.wouldRemove) process.stdout.write(`would remove leftover temp file ${p}\n`);
  for (const w of r.warnings) process.stderr.write(`warning: ${w}\n`);
  if (dryRun) {
    process.stdout.write(`Dry run: would call the model for ${r.wouldCall.length} captures and write ${r.wouldWrite.length} documents. Nothing was written.\n`);
  }
  const parts = [`${r.captures} captures`, `${r.modelCalls} model calls`, `${r.written} written`, `${r.unchanged} unchanged`, `${r.failed.length} failed`];
  if (r.pending) parts.push(`${r.pending} pending`);
  if (r.skippedAfterRetries) parts.push(`${r.skippedAfterRetries} skipped after ${MAX_ATTEMPTS} failures`);
  if (r.deferred) parts.push(`${r.deferred} left for the next run`);
  if (r.tempFilesRemoved) parts.push(`${r.tempFilesRemoved} leftover temp files removed`);
  process.stdout.write(parts.join(' · ') + '\n');
  process.stdout.write(`Took ${((Date.now() - started) / 1000).toFixed(1)} s.\n`);
  let code = 0;
  if (r.stoppedBy) {
    process.stderr.write(`Stopped early (${r.stoppedBy}): ${r.stopReason ?? ''}\n`
      + `Got through ${r.written + r.unchanged + r.failed.length} of ${r.captures} captures; run hippo enrich again later to continue.\n`);
    code = r.stoppedBy === 'interrupted' ? 130 : 3;
  }
  if (dryRun) return code;
  // The index step runs even after a stop, so the desk shows what was written; the exit code stays what enrich decided.
  try {
    markEnriched(folder);
    printIndexReport(await buildIndex(folder));
  } catch (e) {
    process.stderr.write(`hippo enrich: the index step failed: ${(e as Error).message}\n`);
    if (code === 0) code = 1;
  }
  return code;
}

async function index(args: string[]): Promise<number> {
  const { buildIndex } = await import('./index/build.ts');
  const values = parse(args, { folder: { type: 'string' }, rebuild: { type: 'boolean' } });
  const folder = resolveFolder(values.folder);
  const r = await buildIndex(folder, { rebuild: values.rebuild === true });
  printIndexReport(r);
  return 0;
}

async function statusCommand(args: string[]): Promise<number> {
  const { status } = await import('./index/build.ts');
  const values = parse(args, { folder: { type: 'string' } });
  const s = status(resolveFolder(values.folder));
  const out = [`Folder: ${s.folder}`];
  if (!s.lastIndexAt) out.push('No index yet: run hippo index.');
  const kinds = (Object.entries(s.byKind) as [string, number][]).map(([k, n]) => `${n} ${k}`).join(' · ');
  out.push(`Captures: ${s.total} (${kinds})`, `Enriched: ${s.enriched} of ${s.total}`);
  out.push(`Pending: ${s.pending}${s.pending ? ' (not complete in the folder yet, skipped until they sync)' : ''}`);
  out.push(`Failures: ${s.failures.length}`);
  for (const f of s.failures)
    out.push(`  ${f.id}  ${f.attempts} of ${MAX_ATTEMPTS} attempts${f.attempts >= MAX_ATTEMPTS ? ' (no more retries until it changes)' : ''}  ${f.error}`);
  out.push(`Last enrich: ${s.lastEnrichAt ?? 'never'}`, `Last index: ${s.lastIndexAt ?? 'never'}`);
  process.stdout.write(out.join('\n') + '\n');
  return 0;
}

// ---- recall: search, show, facets. Read the index only; no model, no network, nothing written to the folder. ----

/** The folder's index, which must exist already: these commands never build one. */
function openExistingIndex(flag: string | undefined): IndexDb {
  const folder = resolveFolder(flag);
  if (!fs.existsSync(indexPath(folder))) throw new Error(`no index for ${folder} yet: run hippo index first.`);
  return openIndex(folder);
}

/** Repeatable flags that also take comma-separated values. */
const listOf = (v: string[] | undefined) => v?.flatMap(x => x.split(',')).map(x => x.trim()).filter(x => x !== '');

const FILTER_FLAGS = ['kind', 'tag', 'topic', 'person', 'site', 'locality', 'circumstance', 'has', 'text', 'phrase', 'from', 'to',
  'weekday', 'part-of-day', 'near', 'min-confidence', 'sort', 'limit'] as const;

function searchCommand(args: string[]): number {
  const many = { type: 'string', multiple: true } as const, one = { type: 'string' } as const;
  const values = parse(args, {
    folder: one, json: { type: 'boolean' }, spec: one,
    kind: many, tag: many, topic: many, person: many, site: many, locality: many, circumstance: many, has: many,
    text: many, phrase: many, from: one, to: one, weekday: many, 'part-of-day': many, near: one, 'min-confidence': one, sort: one, limit: one });

  let raw: Record<string, unknown> = {};
  if (values.spec !== undefined) {
    const mixed = FILTER_FLAGS.filter(f => values[f] !== undefined);
    if (mixed.length) throw new UsageError(`--spec cannot be combined with ${mixed.map(f => `--${f}`).join(', ')}; put everything in the spec`);
    try { raw = JSON.parse(values.spec); } catch (e) { throw new UsageError(`--spec is not valid JSON: ${(e as Error).message}`); }
  } else {
    const put = (key: string, v: unknown) => { if (v !== undefined) raw[key] = v; };
    put('kinds', listOf(values.kind)); put('tags', listOf(values.tag)); put('topics', listOf(values.topic));
    put('people', listOf(values.person)); put('sites', listOf(values.site)); put('has', listOf(values.has));
    const text = [...(values.text ?? []).flatMap(t => t.split(/\s+/)).filter(w => w !== ''), ...(values.phrase ?? [])];
    if (text.length) raw.text = text;
    const time: Record<string, unknown> = {};
    if (values.from !== undefined) time.from = values.from;
    if (values.to !== undefined) time.to = values.to;
    if (values.weekday) time.weekdays = listOf(values.weekday);
    if (values['part-of-day']) time.parts_of_day = listOf(values['part-of-day']);
    if (Object.keys(time).length) raw.time = time;
    const place: Record<string, unknown> = {};
    if (values.locality) place.localities = listOf(values.locality);
    if (values.near !== undefined) {
      const parts = values.near.split(',').map(x => x.trim());
      const nums = parts.map(Number);
      if (parts.length !== 3 || parts.some(x => x === '') || nums.some(n => !Number.isFinite(n)))
        throw new UsageError('place.near: --near takes lat,lon,radius_m (for example 38.7223,-9.1393,500)');
      place.near = { lat: nums[0], lon: nums[1], radius_m: nums[2] };
    }
    if (Object.keys(place).length) raw.place = place;
    if (values['min-confidence'] !== undefined && !values.circumstance) throw new UsageError('--min-confidence needs --circumstance');
    if (values.circumstance) {
      raw.circumstances = { labels: listOf(values.circumstance),
        ...(values['min-confidence'] !== undefined ? { min_confidence: values['min-confidence'] } : {}) };
    }
    put('sort', values.sort);
    if (values.limit !== undefined) raw.limit = /^\d+$/.test(values.limit) ? Number(values.limit) : values.limit;
  }
  const checked = validateSpec(raw);
  if (!checked.ok) throw new UsageError(checked.errors.join('\n'));

  const db = openExistingIndex(values.folder);
  try {
    const result = search(db, checked.spec);
    process.stdout.write(values.json ? JSON.stringify(result, null, 2) + '\n' : formatSearch(result));
  } finally { db.close(); }
  return 0;
}

function showCommand(args: string[]): number {
  const { values, positionals } = parseWithPositionals(args, { folder: { type: 'string' }, json: { type: 'boolean' } });
  if (positionals.length !== 1) throw new UsageError('show takes exactly one capture id');
  const db = openExistingIndex(values.folder);
  try {
    const ids = matchIds(db, positionals[0]);
    if (ids.length > 1) {
      process.stderr.write(`hippo show: ${positionals[0]} matches ${ids.length >= 10 ? '10 or more' : ids.length} captures; give more of the id.\n`);
      return 1;
    }
    const record = ids.length === 1 ? show(db, ids[0]) : undefined;
    if (!record) {
      process.stderr.write(`hippo show: no capture with id ${positionals[0]} (a prefix needs at least 8 characters).\n`);
      return 1;
    }
    process.stdout.write(values.json ? JSON.stringify(record, null, 2) + '\n' : formatRecord(record, mediaOf(db, record.id)));
  } finally { db.close(); }
  return 0;
}

function facetsCommand(args: string[]): number {
  const values = parse(args, { folder: { type: 'string' }, json: { type: 'boolean' } });
  const db = openExistingIndex(values.folder);
  try {
    const f = facets(db);
    process.stdout.write(values.json ? JSON.stringify(f, null, 2) + '\n' : formatFacets(f));
  } finally { db.close(); }
  return 0;
}

async function sampleCommand(args: string[]): Promise<number> {
  const { writeSample } = await import('./index/sample.ts');
  const values = parse(args, { out: { type: 'string' }, count: { type: 'string' }, seed: { type: 'string' }, end: { type: 'string' } });
  if (values.out === undefined) throw new UsageError('sample needs --out <dir> (a new or empty directory)');
  const whole = (flag: string, v: string | undefined) => {
    if (v === undefined) return undefined;
    if (!/^\d+$/.test(v) || !Number.isSafeInteger(Number(v))) throw new UsageError(`--${flag} takes a whole number`);
    return Number(v);
  };
  const count = whole('count', values.count), seed = whole('seed', values.seed);
  if (values.end !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(values.end)) throw new UsageError('--end takes a date YYYY-MM-DD');
  const started = Date.now();
  const out = path.resolve(values.out);
  const r = await writeSample({ out, count, seed, end: values.end });
  process.stdout.write(`Wrote ${r.captures} invented capture${r.captures === 1 ? '' : 's'} to ${out} in ${((Date.now() - started) / 1000).toFixed(1)} s.\n`
    + `Next: hippo index --folder ${JSON.stringify(out)}, then hippo search or hippo facets.\n`);
  return 0;
}

const commands: Record<string, Command> = { enrich, index, status: statusCommand, search: searchCommand, show: showCommand, facets: facetsCommand,
  sample: sampleCommand };

const [name, ...args] = process.argv.slice(2);
const run = name !== undefined && Object.hasOwn(commands, name) ? commands[name] : undefined;
// Exit codes are set, not forced, so piped output is never cut off.
if (!run) {
  process.stderr.write(usage);
  process.exitCode = 2;
} else {
  try {
    process.exitCode = (await run(args)) ?? 0;
  } catch (e) {
    process.stderr.write(`hippo ${name}: ${(e as Error).message}\n`);
    if (e instanceof UsageError) process.stderr.write(usage);
    process.exitCode = e instanceof UsageError ? 2 : 1;
  }
}
