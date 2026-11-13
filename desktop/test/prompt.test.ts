import test from 'node:test';
import assert from 'node:assert/strict';
import { enrichmentDoc, syntheticCapture } from './helpers.ts';
import { modelInput, NOTE_LIMIT } from '../src/enrich/prompt.ts';

const ATT = '00000000-0000-4000-8000-0000000000b1';
const COMMENT = '00000000-0000-4000-8000-0000000000c1';
const URL1 = 'https://example.com/page';
const long = (n: number) => 'word '.repeat(n / 5).trim() + ' tail';

/** A capture whose transcripts, recognized text, link description and note body are each `n` characters or more. */
function capture(n: number) {
  const text = long(n);
  return syntheticCapture({ urls: [{ url: URL1 }] }, {
    noteBody: text,
    comments: [{ id: COMMENT, added_at: '2026-11-07T18:00:00.000Z' }],
    device: enrichmentDoc('device', {
      link_preview: { data: { items: [{ url: URL1, title: 'A page', description: text }] } },
      text_recognition: { data: { items: [{ attachment_id: ATT, text, languages: ['en'] }] } },
      transcript: { data: { items: [{ attachment_id: ATT, text, locale: 'en', segments: [] },
        { attachment_id: COMMENT, text, locale: 'en', segments: [] }] } },
    }),
  });
}
const cps = (s: string | undefined) => [...(s ?? '')].length;

test('the note body, transcripts, recognized text and link descriptions are each cut to 6,000 characters', () => {
  assert.equal(NOTE_LIMIT, 6000);
  const i = modelInput(capture(9000));
  assert.equal(cps(i.note?.text), NOTE_LIMIT);
  assert.equal(cps(i.transcripts?.[0].text), NOTE_LIMIT);
  assert.equal(cps(i.recognized_text?.[0].text), NOTE_LIMIT);
  assert.equal(cps(i.links?.[0].description), NOTE_LIMIT);
  assert.equal(cps(i.comments?.[0].transcript), NOTE_LIMIT);
  assert.ok(long(9000).startsWith(i.transcripts![0].text));
});

test('text at or under 6,000 characters goes as it is; the cut counts code points, never splitting one', () => {
  const short = modelInput(capture(100));
  assert.equal(short.transcripts?.[0].text, long(100));
  assert.equal(short.links?.[0].description, long(100));
  const astral = '🦛'.repeat(7000);
  const c = syntheticCapture({ urls: [{ url: URL1 }] }, { device: enrichmentDoc('device', {
    text_recognition: { data: { items: [{ attachment_id: ATT, text: astral, languages: [] }] } },
    link_preview: { data: { items: [{ url: URL1, description: astral }] } },
  }) });
  const i = modelInput(c);
  assert.ok(i.recognized_text?.[0].text === '🦛'.repeat(NOTE_LIMIT), `${cps(i.recognized_text?.[0].text)} code points`);
  assert.ok(i.links?.[0].description === '🦛'.repeat(NOTE_LIMIT), `${cps(i.links?.[0].description)} code points`);
});
