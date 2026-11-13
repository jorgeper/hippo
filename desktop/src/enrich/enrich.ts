// `hippo enrich`: one pass over a Hippo folder (spec section 5). For each complete capture it recomputes the
// rule-made circumstances, asks the model when the input digest changed, and writes the capture's server
// document when its facets differ. That document is the only thing it ever writes into the folder.
import { scanFolder } from '../core/folder.ts';
import { deriveCircumstances } from '../core/circumstance.ts';
import type { Circumstance, AttachmentRef } from '../core/record.ts';
import type { RawCapture } from '../core/types.ts';
import { ensureThumbs } from '../index/thumbs.ts';
import { ProviderError } from '../providers/types.ts';
import type { Provider } from '../providers/types.ts';
import { inputDigest } from './digest.ts';
import { normalize } from './normalize.ts';
import type { ModelEnrichment } from './normalize.ts';
import { buildUserPrompt, hasContent, modelInput, OUTPUT_SCHEMA, picturesToSend, PROMPT_VERSION, SYSTEM_PROMPT } from './prompt.ts';
import type { ModelInput } from './prompt.ts';
import { composeServerDoc, facetsDiffer, sweepTempFiles, writeServerDoc } from './serverdoc.ts';
import { MAX_ATTEMPTS, openFailureStore } from './state.ts';

export interface EnrichOptions { folder: string; provider?: Provider; model?: string; noModel?: boolean; dryRun?: boolean;
  limit?: number; concurrency?: number; now?: () => Date; onProgress?: (e: { done: number; total: number; id: string; what: string }) => void;
  /** When aborted: no new model call or write starts, calls in flight finish (and their documents are written), the rest is deferred. */
  signal?: AbortSignal }
export type StopCode = 'usage_limit' | 'not_signed_in' | 'unavailable' | 'interrupted';
export interface EnrichReport { captures: number; pending: number; modelCalls: number; written: number; unchanged: number;
  failed: { id: string; reason: string }[]; skippedAfterRetries: number; stoppedBy?: StopCode; wouldCall: string[]; wouldWrite: string[];
  /** The provider error message when `stoppedBy` is set. */
  stopReason?: string;
  /** Captures left untouched for the next run: over `limit`, or not reached after a stop. */
  deferred: number;
  /** Stale temp files (from a killed run) removed from capture server directories. */
  tempFilesRemoved: number;
  /** Dry run only: the stale temp files a real run would remove. */
  wouldRemove: string[];
  /** Problems that did not fail a capture, for example the local failures table could not be updated. */
  warnings: string[] }

const STOP_CODES: readonly string[] = ['usage_limit', 'not_signed_in', 'unavailable'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

interface Job { c: RawCapture; input: ModelInput; pictures: AttachmentRef[]; digest: string; circumstances: Circumstance[] }

function isObject(v: unknown): v is Record<string, any> { return typeof v === 'object' && v !== null && !Array.isArray(v); }
const message = (e: unknown) => (e instanceof ProviderError ? `${e.code}: ${e.message}` : e instanceof Error ? e.message : String(e));

/** Enriched means the server document records this exact input digest and prompt version, whoever wrote it. */
function isEnriched(c: RawCapture, digest: string): boolean {
  const f = c.server && isObject(c.server.facets) ? c.server.facets.hippo_desk_state : undefined;
  return isObject(f) && f.status === 'ok' && isObject(f.data) && f.data.input_digest === digest && f.data.prompt_version === PROMPT_VERSION;
}

function topicOf(c: RawCapture): string | undefined {
  const f = c.server && isObject(c.server.facets) ? c.server.facets.display : undefined;
  const t = isObject(f) && f.status === 'ok' && isObject(f.data) ? f.data.topic : undefined;
  return typeof t === 'string' && t.trim() !== '' ? t.replace(/\s+/g, ' ').trim() : undefined;
}

/** Does not run the index step; the CLI does (Task B6). */
export async function enrichFolder(o: EnrichOptions): Promise<EnrichReport> {
  const now = o.now ?? (() => new Date());
  const n = o.concurrency ?? 3;
  const concurrency = Number.isFinite(n) ? Math.max(1, Math.floor(n)) : 3;
  const aborted = () => o.signal?.aborted === true;
  const model = o.model ?? 'haiku';
  const provider = o.provider;
  if (!o.noModel && !o.dryRun && !provider) throw new Error('enrichFolder needs a provider unless noModel is set');

  const scan = await scanFolder(o.folder);
  const report: EnrichReport = { captures: scan.captures.length, pending: scan.pending.length, modelCalls: 0, written: 0, unchanged: 0,
    failed: [], skippedAfterRetries: 0, wouldCall: [], wouldWrite: [], deferred: 0, tempFilesRemoved: 0, wouldRemove: [], warnings: [] };
  const total = scan.captures.length;
  let done = 0;
  const progress = (id: string, what: string) => o.onProgress?.({ done: ++done, total, id, what });

  // Topics in use: every existing server document's display.topic, growing as answers arrive.
  const topics: string[] = [];
  const addTopic = (t: string | undefined) => { if (t !== undefined && !topics.includes(t)) topics.push(t); };
  for (const c of scan.captures) addTopic(topicOf(c));

  const store = openFailureStore(o.folder, { readOnly: o.dryRun || o.noModel });
  try {
    /** Composes and, unless it is a dry run, writes the document when its facets differ. Throws on a failed write. */
    const settle = async (c: RawCapture, m: { value: ModelEnrichment; provenance: string; digest: string } | undefined,
      circumstances: Circumstance[], note = '') => {
      const doc = composeServerDoc(c, { model: m, circumstances, now: now() });
      if (!doc || !facetsDiffer(c.server, doc)) { report.unchanged++; progress(c.id, `${note}unchanged`); return; }
      if (o.dryRun) { report.wouldWrite.push(c.id); progress(c.id, `${note}would write`); return; }
      await writeServerDoc(c, doc);
      report.written++;
      progress(c.id, `${note}written`);
    };
    const fail = (id: string, reason: string) => { report.failed.push({ id, reason }); progress(id, `failed: ${reason}`); };
    /** The failures table is bookkeeping: an error there is reported, never fatal to the run. */
    const bookkeeping = (what: string, fn: () => void): string | undefined => {
      try { fn(); return undefined; } catch (e) { const w = `failures table: could not ${what}: ${message(e)}`; report.warnings.push(w); return w; }
    };

    // Temp files a killed run left behind (older than a minute, named exactly like ours).
    for (const c of scan.captures) {
      const found = await sweepTempFiles(c, { dryRun: o.dryRun });
      if (o.dryRun) report.wouldRemove.push(...found); else report.tempFilesRemoved += found.length;
    }

    const queue: Job[] = [];
    let interrupted = false;
    for (const c of scan.captures) {
      if (aborted()) { interrupted = true; report.deferred++; continue; }
      if (c.serverUnreadable) { fail(c.id, 'existing server document is unreadable'); continue; }
      if (!UUID.test(c.id)) { fail(c.id, 'capture id is not a lowercase UUID'); continue; }
      const circumstances = deriveCircumstances(c);
      const pictures = picturesToSend(c);
      const input = modelInput(c);
      const digest = inputDigest(c, pictures.map(p => p.sha256));
      let wantModel = !o.noModel && hasContent(input) && !isEnriched(c, digest);
      let note = '';
      if (wantModel) {
        let f: ReturnType<typeof store.get>;
        bookkeeping(`read the failure row for ${c.id}`, () => { f = store.get(c.id); });
        if (f && f.input_digest === digest && f.attempts >= MAX_ATTEMPTS) {
          report.skippedAfterRetries++;
          note = `model skipped after ${f.attempts} failed attempts (${f.last_error}); `;
          wantModel = false;
        }
      }
      if (wantModel) {
        if (o.limit !== undefined && queue.length + report.wouldCall.length >= o.limit) { report.deferred++; progress(c.id, 'left for the next run (limit)'); continue; }
        if (o.dryRun) { report.wouldCall.push(c.id); report.wouldWrite.push(c.id); progress(c.id, 'would call the model and write'); continue; }
        queue.push({ c, input, pictures, digest, circumstances });
        continue;
      }
      try { await settle(c, undefined, circumstances, note); } catch (e) { fail(c.id, message(e)); }
    }

    let stop: { code: StopCode; reason: string } | undefined;
    let next = 0, finished = 0;
    const runJob = async (job: Job) => {
      const { c } = job;
      const failJob = (reason: string) => {
        const w = bookkeeping(`record the failure for ${c.id}`, () => store.record(c.id, job.digest, reason, now()));
        fail(c.id, w ? `${reason} (${w.replace('failures table: ', '')})` : reason);
        finished++;
      };
      const images: string[] = [];
      try { for (const p of job.pictures) images.push((await ensureThumbs(p.path, p.sha256)).display); }
      catch (e) { failJob(`cannot prepare a picture: ${message(e)}`); return; }
      if (stop || aborted()) return;
      const prompt = buildUserPrompt(job.input, [...topics], images);
      report.modelCalls++;
      let answer: { value: unknown; model: string };
      try {
        answer = await provider!.complete({ system: SYSTEM_PROMPT, prompt, images, schema: OUTPUT_SCHEMA, model });
      } catch (e) {
        if (e instanceof ProviderError && STOP_CODES.includes(e.code)) {
          if (!stop) stop = { code: e.code as StopCode, reason: e.message };
          progress(c.id, `stopped: ${e.code}`);
          return;
        }
        // After an interrupt a call may die with its child process (Ctrl-C reaches the whole process group): not a failure.
        if (aborted()) { progress(c.id, 'stopped: interrupted'); return; }
        failJob(message(e)); return;
      }
      const value = normalize(answer.value, c, topics);
      if (!value) { failJob('bad_output: the answer does not fit the contract'); return; }
      addTopic(value.topic);
      try { await settle(c, { value, provenance: `${provider!.name}:${answer.model}`, digest: job.digest }, job.circumstances); }
      catch (e) { failJob(message(e)); return; }
      bookkeeping(`clear the failure row for ${c.id}`, () => store.clear(c.id));
      finished++;
    };
    const worker = async () => { while (!stop && !aborted() && next < queue.length) await runJob(queue[next++]); };
    await Promise.all(Array.from({ length: Math.min(concurrency, queue.length) }, worker));

    report.deferred += queue.length - finished;
    if (stop) { report.stoppedBy = stop.code; report.stopReason = stop.reason; }
    else if (interrupted || aborted()) { report.stoppedBy = 'interrupted'; report.stopReason = 'interrupted'; }
    return report;
  } finally {
    store.close();
  }
}
