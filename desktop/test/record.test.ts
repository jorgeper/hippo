import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFixtures, enrichmentDoc, syntheticCapture } from './helpers.ts';
import { scanFolder } from '../src/core/folder.ts';
import { buildRecord, deriveKind } from '../src/core/record.ts';
import { deriveCircumstances } from '../src/core/circumstance.ts';
import { resolved } from '../src/core/resolve.ts';
import type { RawCapture } from '../src/core/types.ts';

async function fixtureRecords() {
  const s = await scanFolder(copyFixtures());
  return { captures: s.captures, records: await Promise.all(s.captures.map(buildRecord)) };
}

test('kinds of the seven fixtures', async () => {
  const { captures, records } = await fixtureRecords();
  assert.deepEqual(captures.map(deriveKind), ['note', 'link', 'photo', 'photo', 'video', 'recording', 'screenshot']);
  assert.deepEqual(records.map(r => r.kind), ['note', 'link', 'photo', 'photo', 'video', 'recording', 'screenshot']);
});

test('capture 7: audio beside a picture is a spoken comment; has picture, audio, location', async () => {
  const r = (await fixtureRecords()).records[6];
  const audio = r.attachments.find(a => a.type === 'audio');
  assert.equal(audio?.isSpokenComment, true);
  assert.equal(r.attachments.find(a => a.type === 'picture')?.isSpokenComment, undefined);
  for (const h of ['picture', 'audio', 'location'] as const) assert.ok(r.has.includes(h), h);
  assert.equal(r.place?.lat, 37.7749); assert.equal(r.place?.lon, -122.4194); assert.equal(r.place?.accuracy_m, 12);
  assert.equal((r.context['context.audio_route'] as any).outputs[0].port_name, 'CarPlay');
  assert.equal((r.context.capture_location as any).speed_meters_per_second, 11.2);
});

test('capture 7 with the server fixture: topic, one image description, not enriched by hippo-desk', async () => {
  const { captures, records } = await fixtureRecords();
  const r = records[6];
  assert.equal(r.topic, 'food');
  assert.equal(r.title, 'Cafe menu with specials code');
  assert.equal(r.summary, 'A cafe menu with a QR code for the specials.');
  assert.deepEqual(r.tags, ['cafe', 'menu', 'food']);
  assert.deepEqual(r.people, [{ name: 'Ana', source: 'user_note' }]);
  assert.equal(r.keywords.length, 3);
  assert.equal(r.image_descriptions.length, 1);
  assert.equal(r.image_descriptions[0].attachment_id, '00000000-0000-4000-8000-000700000001');
  assert.equal(r.enriched, false);
  assert.deepEqual(r.circumstances, deriveCircumstances(captures[6]));
});

test('enriched is true only for display from producer hippo-desk', async () => {
  const { captures } = await fixtureRecords();
  const c7 = captures[6];
  const server = { ...structuredClone(c7.server!), producer: { name: 'hippo-desk', version: '0.1.0', build: '1' } };
  assert.equal((await buildRecord({ ...c7, server })).enriched, true);
  const noDisplay = structuredClone(server); delete noDisplay.facets.display;
  assert.equal((await buildRecord({ ...c7, server: noDisplay })).enriched, false);
});

test('capture 2: gold link title wins, silver fields still show, site without www', async () => {
  const r = (await fixtureRecords()).records[1];
  assert.equal(r.title, 'Example Domain (server)');
  assert.equal(r.site, 'example.com');
  assert.deepEqual(r.urls, ['https://example.com/item']);
  assert.equal(r.link?.title, 'Example Domain (server)');
  assert.equal(r.link?.site_name, 'example.com');
  assert.ok(r.link?.thumbPath?.endsWith('.jpg'));
  assert.equal(r.summary, 'A placeholder page used in documentation examples.');
  assert.deepEqual(r.tags, ['example', 'reference']);
  assert.equal(r.source_app, 'Safari');
  assert.ok(r.has.includes('link'));
  assert.ok(r.text.includes('Example Domain (server)'));
});

test('capture 4: comments and link in has, comment and note text searchable', async () => {
  const r = (await fixtureRecords()).records[3];
  assert.ok(r.has.includes('comment')); assert.ok(r.has.includes('link'));
  assert.ok(r.text.includes('Bought this one.'));
  assert.ok(r.text.includes('Trail for next weekend'));
  assert.equal(r.comments.length, 2);
  assert.equal(r.comments[0].text, 'Bought this one.');
  assert.ok(r.comments[1].audioPath?.endsWith('.m4a'));
  assert.equal(r.site, 'example.com');
  assert.deepEqual(r.attachments.map(a => a.type), ['picture', 'picture', 'file']);
});

test('capture 1: local time fields and title from the note body', async () => {
  const r = (await fixtureRecords()).records[0];
  assert.equal(r.local_date, '2026-11-07'); assert.equal(r.local_time, '09:01');
  assert.equal(r.weekday, 'sat'); assert.equal(r.part_of_day, 'morning');
  assert.equal(r.timezone, 'America/Los_Angeles');
  assert.equal(r.title, 'Call the plumber about the upstairs sink.');
  assert.equal(r.body, 'Call the plumber about the upstairs sink.');
  assert.deepEqual(r.has, []);
  assert.equal(r.method, 'typed_note');
});

test('titles fall back to filename, then kind and date', async () => {
  const { records } = await fixtureRecords();
  assert.equal(records[2].title, 'IMG_0003.PNG');
  assert.equal(records[4].title, 'clip.mov');
  const bare = syntheticCapture({ capture_method: 'typed_note' });
  assert.equal((await buildRecord(bare)).title, 'Note · 2026-11-07');
});

test('local date uses the capture zone, not the machine zone', async () => {
  const lisbon = await buildRecord(syntheticCapture({ captured_at: '2026-11-07T23:30:00.000Z', timezone_identifier: 'Europe/Lisbon', utc_offset_seconds: 0 }));
  assert.equal(lisbon.local_date, '2026-11-07'); assert.equal(lisbon.local_time, '23:30'); assert.equal(lisbon.part_of_day, 'night');
  const la = await buildRecord(syntheticCapture({ captured_at: '2026-11-08T07:30:00.000Z', timezone_identifier: 'America/Los_Angeles', utc_offset_seconds: -28800 }));
  assert.equal(la.local_date, '2026-11-07'); assert.equal(la.part_of_day, 'night'); assert.equal(la.weekday, 'sat');
  const offsetOnly = syntheticCapture({ captured_at: '2026-11-08T07:30:00.000Z', utc_offset_seconds: 3600 });
  delete offsetOnly.metadata.timezone_identifier;
  const r = await buildRecord(offsetOnly);
  assert.equal(r.local_date, '2026-11-08'); assert.equal(r.local_time, '08:30');
});

test('part of day boundaries', async () => {
  const pod = async (h: string) => (await buildRecord(syntheticCapture({ captured_at: `2026-11-07T${h}:00:00.000Z`, timezone_identifier: 'UTC', utc_offset_seconds: 0 }))).part_of_day;
  assert.deepEqual(await Promise.all(['04', '05', '11', '12', '16', '17', '21', '22'].map(pod)),
    ['night', 'morning', 'morning', 'afternoon', 'afternoon', 'evening', 'evening', 'night']);
});

test('a typed note whose text holds a URL stays a note', async () => {
  const c = syntheticCapture({ capture_method: 'typed_note', content_types: ['text'], urls: [{ url: 'https://www.example.org/x', source: 'detected_in_text' }] },
    { noteBody: 'Read https://www.example.org/x later' });
  assert.equal(deriveKind(c), 'note');
  const r = await buildRecord(c);
  assert.equal(r.kind, 'note'); assert.equal(r.site, 'example.org'); assert.ok(r.has.includes('link'));
});

test('a shared URL from the share sheet is a link', () => {
  assert.equal(deriveKind(syntheticCapture({ urls: [{ url: 'https://example.org', source: 'shared_payload' }] })), 'link');
});

test('a long first line is cut at 60 characters on a word boundary', async () => {
  const line = 'This is a rather long first line of a typed note that goes well past sixty characters';
  const r = await buildRecord(syntheticCapture({ capture_method: 'typed_note' }, { noteBody: `\n  ${line}\nsecond line` }));
  assert.equal(r.title, 'This is a rather long first line of a typed note that goes…');
  assert.ok([...r.title].length <= 60);
});

test('a recording without a model title takes the first eight words of its transcript', async () => {
  const c = syntheticCapture({ capture_method: 'voice_recording', attachments: [{ attachment_id: 'a1', relative_path: 'content/a1.m4a', uti: 'com.apple.m4a-audio',
    byte_count: 1, sha256: '0'.repeat(64), representation_source: 'recording', original_filename: 'memo.m4a', media: { duration_seconds: 4 } }] },
    { device: enrichmentDoc('device', { transcript: { data: { items: [{ attachment_id: 'a1', text: 'one two three four five six seven eight nine ten', locale: 'en_US', segments: [] }] } } }) });
  const r = await buildRecord(c);
  assert.equal(r.kind, 'recording');
  assert.equal(r.title, 'one two three four five six seven eight');
  assert.equal(r.body, 'one two three four five six seven eight nine ten');
  assert.equal(r.attachments[0].durationSeconds, 4);
});

test('override rule: gold wins per field only when ok and non-blank; empty or failed gold never hides silver', () => {
  const silver = enrichmentDoc('device', {
    link_preview: { data: { items: [{ url: 'u1', title: 'Silver', channel: 'Chan' }, { url: 'u2', title: 'Two' }] } },
    place: { data: { items: [{ target: 'capture', locality: 'Lisbon', sub_locality: 'Alfama' }] } },
    transcript: { data: { items: [{ attachment_id: 'a1', text: 'silver words', locale: 'en_US', segments: [] }] } },
    source_app_guess: { data: { app: 'Safari', reason: 'uti:public.url' } },
  });
  const gold = enrichmentDoc('server', {
    link_preview: { data: { items: [{ url: 'u1', title: 'Gold', channel: '  ' }, { url: 'u3', title: 'Gold only' }] } },
    place: { status: 'empty', data: { items: [{ target: 'capture', locality: 'Porto' }] } },
    transcript: { status: 'failed', provenance: 'oops' },
    source_app_guess: { data: { app: '' } },
    summary: { data: { text: 'A summary.' } },
    tags: { data: { values: [] } },
  });
  const r = resolved(syntheticCapture({}, { device: silver, server: gold }));
  assert.deepEqual(r.linkPreviews.get('u1'), { url: 'u1', title: 'Gold', channel: 'Chan' });
  assert.equal(r.linkPreviews.get('u2')?.title, 'Two');
  assert.equal(r.linkPreviews.get('u3')?.title, 'Gold only');
  assert.equal(r.places.get('capture')?.locality, 'Lisbon');
  assert.equal(r.transcripts.get('a1')?.text, 'silver words');
  assert.equal(r.sourceApp?.app, 'Safari');
  assert.equal(r.summary, 'A summary.');
  assert.equal(r.tags, undefined);
});

test('the record is plain JSON with no undefined values', async () => {
  for (const r of (await fixtureRecords()).records) assert.deepEqual(JSON.parse(JSON.stringify(r)), r);
});

function withAttachment(uti: string, mime?: string): RawCapture {
  return syntheticCapture({ attachments: [{ attachment_id: 'x', relative_path: 'content/x.bin', uti, byte_count: 1, sha256: '0'.repeat(64),
    representation_source: 'item_provider_file', ...(mime ? { mime_type: mime } : {}) }], urls: [{ url: 'https://example.org', source: 'shared_payload' }] });
}

test('kind precedence by attachment type', () => {
  assert.equal(deriveKind(withAttachment('com.adobe.pdf', 'application/pdf')), 'file');
  assert.equal(deriveKind(withAttachment('public.heic')), 'photo');
  assert.equal(deriveKind(withAttachment('public.mpeg-4', 'video/mp4')), 'video');
  assert.equal(deriveKind(withAttachment('public.mp3', 'audio/mpeg')), 'recording');
  assert.equal(deriveKind(withAttachment('com.example.unknown')), 'file');
});
