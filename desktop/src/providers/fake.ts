import type { ModelRequest, Provider } from './types.ts';
import { readPromptCapture } from '../enrich/prompt.ts';
import type { ModelInput } from '../enrich/prompt.ts';
import { readAskPrompt } from '../recall/ask.ts';
import type { SearchSpec } from '../recall/spec.ts';

function firstText(i: ModelInput): string | undefined {
  const candidates = [i.note?.text, i.shared_title, i.shared_text, i.user_note,
    ...(i.links ?? []).flatMap(l => [l.title, l.description]),
    ...(i.recognized_text ?? []).map(r => r.text), ...(i.transcripts ?? []).map(t => t.text),
    ...(i.comments ?? []).flatMap(k => [k.text, k.transcript])];
  return candidates.find((s): s is string => typeof s === 'string' && s.trim() !== '');
}

/** The canned answer to an enrichment request (one with the `TASK: enrich` line); `{}` for anything else. */
export function fakeEnrichment(req: ModelRequest): unknown {
  const input = readPromptCapture(req.prompt);
  if (!input) return {};
  const text = firstText(input);
  return {
    title: text ? text.trim().split(/\s+/).slice(0, 6).join(' ') : `Untitled ${input.kind}`,
    summary: 'Fake summary.',
    image_descriptions: (input.pictures ?? []).map(id => ({ attachment_id: id, text: `Fake description of ${id}.` })),
    tags: ['fake', input.kind],
    topic: 'fake',
    people: [],
    keywords: [],
  };
}

/** The previous Monday-to-Sunday week before the week that holds `today` (YYYY-MM-DD). */
function lastWeek(today: string): { from: string; to: string } {
  const d = new Date(`${today}T00:00:00Z`);
  const monday = new Date(d.getTime() - (((d.getUTCDay() + 6) % 7) + 7) * 86_400_000);
  const day = (t: Date) => t.toISOString().slice(0, 10);
  return { from: day(monday), to: day(new Date(monday.getTime() + 6 * 86_400_000)) };
}

/** The canned answer to an ask request (one with the `TASK: ask` line), or undefined for any other request. Starts from the
 *  current spec and applies, by lower-cased substring of the sentence and in this order: start over, youtube, screenshot,
 *  last week, car, by place / time / topic / person. Reply "{count} found". */
export function fakeAsk(req: ModelRequest): unknown {
  const p = readAskPrompt(req.prompt);
  if (!p) return undefined;
  const s = p.sentence.toLowerCase();
  let spec: SearchSpec = structuredClone(p.spec);
  let layout = 'keep';
  if (s.includes('start over')) { spec = {}; layout = 'kind'; }
  if (s.includes('youtube')) { spec.kinds = ['link']; spec.sites = ['youtube.com']; }
  if (s.includes('screenshot')) { spec.kinds = ['screenshot']; delete spec.sites; }
  if (s.includes('last week')) spec.time = lastWeek(p.today);
  if (s.includes('car')) spec.circumstances = { labels: ['in_car'] };
  for (const l of ['place', 'time', 'topic', 'person']) if (s.includes(`by ${l}`)) layout = l;
  return { spec, layout, reply: '{count} found' };
}

/** Canned answers for tests. With no handler: the fake ask answer for ask requests, the fake enrichment for enrichment requests,
 *  `{}` otherwise. A handler may be async. */
export function fakeProvider(handler?: (req: ModelRequest) => unknown): Provider {
  return {
    name: 'fake',
    async complete(req) {
      return { value: await (handler ? handler(req) : fakeAsk(req) ?? fakeEnrichment(req)), model: 'fake' };
    },
  };
}
