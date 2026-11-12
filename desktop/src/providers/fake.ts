import type { ModelRequest, Provider } from './types.ts';
import { readPromptCapture } from '../enrich/prompt.ts';
import type { ModelInput } from '../enrich/prompt.ts';

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

/** Canned answers for tests. With no handler: the fake enrichment for enrichment requests, `{}` otherwise. A handler may be async. */
export function fakeProvider(handler?: (req: ModelRequest) => unknown): Provider {
  return {
    name: 'fake',
    async complete(req) {
      return { value: await (handler ? handler(req) : fakeEnrichment(req)), model: 'fake' };
    },
  };
}
