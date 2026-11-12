import { parseArgs } from 'node:util';
import { loadConfig, resolveFolder } from './core/paths.ts';
import { makeProvider } from './providers/index.ts';
import { enrichFolder } from './enrich/enrich.ts';
import { MAX_ATTEMPTS } from './enrich/state.ts';
import { buildIndex, markEnriched, status } from './index/build.ts';
import type { IndexReport } from './index/build.ts';

const usage = `Usage: hippo <command> [options]

Commands:
  enrich [--folder <path>] [--no-model] [--dry-run] [--limit n] [--provider name] [--model name]
         Writes one server enrichment document per capture that needs it, then updates the index.
  index  [--folder <path>] [--rebuild]
         Builds or updates the local index and thumbnails. No model, nothing written to the folder.
  status [--folder <path>]
         Counts by kind, how many are enriched, pending captures, failures, last runs.
`;

class UsageError extends Error {}

type Command = (args: string[]) => Promise<number | void> | number | void;

function parse<T extends Record<string, { type: 'string' | 'boolean' }>>(args: string[], options: T) {
  try { return parseArgs({ args, strict: true, allowPositionals: false, options }).values; }
  catch (e) { throw new UsageError((e as Error).message); }
}

function printIndexReport(r: IndexReport): void {
  for (const f of r.thumbFailures) process.stderr.write(`warning: no thumbnail for ${f.id}: ${f.reason}\n`);
  const parts = [`${r.captures} captures`, `${r.added} added`, `${r.updated} updated`, `${r.removed} removed`, `${r.thumbnails} thumbnails`];
  if (r.thumbFailures.length) parts.push(`${r.thumbFailures.length} thumbnail failures`);
  process.stdout.write(`Index: ${parts.join(' · ')}\n`);
}

async function enrich(args: string[]): Promise<number> {
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
  const values = parse(args, { folder: { type: 'string' }, rebuild: { type: 'boolean' } });
  const folder = resolveFolder(values.folder);
  const r = await buildIndex(folder, { rebuild: values.rebuild === true });
  printIndexReport(r);
  return 0;
}

function statusCommand(args: string[]): number {
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

const commands: Record<string, Command> = { enrich, index, status: statusCommand };

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
