import { parseArgs } from 'node:util';
import { loadConfig, resolveFolder } from './core/paths.ts';
import { makeProvider } from './providers/index.ts';
import { enrichFolder } from './enrich/enrich.ts';
import { MAX_ATTEMPTS } from './enrich/state.ts';

const usage = `Usage: hippo <command> [options]

Commands:
  enrich [--folder <path>] [--no-model] [--dry-run] [--limit n] [--provider name] [--model name]
         Writes one server enrichment document per capture that needs it.
`;

class UsageError extends Error {}

type Command = (args: string[]) => Promise<number | void> | number | void;

async function enrich(args: string[]): Promise<number> {
  let values;
  try {
    ({ values } = parseArgs({ args, strict: true, allowPositionals: false, options: {
      folder: { type: 'string' }, 'no-model': { type: 'boolean' }, 'dry-run': { type: 'boolean' },
      limit: { type: 'string' }, provider: { type: 'string' }, model: { type: 'string' } } }));
  } catch (e) { throw new UsageError((e as Error).message); }
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

  const started = Date.now();
  const r = await enrichFolder({ folder, provider, model, noModel, dryRun, limit, concurrency: config.concurrency,
    onProgress: e => { if (e.what !== 'unchanged') process.stdout.write(`${e.id}  ${e.what}\n`); } });

  if (dryRun) {
    process.stdout.write(`Dry run: would call the model for ${r.wouldCall.length} captures and write ${r.wouldWrite.length} documents. Nothing was written.\n`);
  }
  const parts = [`${r.captures} captures`, `${r.modelCalls} model calls`, `${r.written} written`, `${r.unchanged} unchanged`, `${r.failed.length} failed`];
  if (r.pending) parts.push(`${r.pending} pending`);
  if (r.skippedAfterRetries) parts.push(`${r.skippedAfterRetries} skipped after ${MAX_ATTEMPTS} failures`);
  if (r.deferred) parts.push(`${r.deferred} left for the next run`);
  process.stdout.write(parts.join(' · ') + '\n');
  process.stdout.write(`Took ${((Date.now() - started) / 1000).toFixed(1)} s.\n`);
  if (r.stoppedBy) {
    process.stderr.write(`Stopped early (${r.stoppedBy}): ${r.stopReason ?? ''}\n`
      + `Got through ${r.written + r.unchanged + r.failed.length} of ${r.captures} captures; run hippo enrich again later to continue.\n`);
    return 3;
  }
  return 0;
}

const commands: Record<string, Command> = { enrich };

const [name, ...args] = process.argv.slice(2);
const run = name !== undefined && Object.hasOwn(commands, name) ? commands[name] : undefined;
if (!run) {
  process.stderr.write(usage);
  process.exit(2);
}
try {
  process.exit((await run(args)) ?? 0);
} catch (e) {
  process.stderr.write(`hippo ${name}: ${(e as Error).message}\n`);
  if (e instanceof UsageError) process.stderr.write(usage);
  process.exit(e instanceof UsageError ? 2 : 1);
}
