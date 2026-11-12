// Readable text for `hippo search`, `hippo show` and `hippo facets`. `--json` prints the objects themselves instead.
import type { CaptureRecord } from '../core/record.ts';
import type { Facets, FacetValue, MediaRef, SearchResult } from './engine.ts';

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const coord = (x: number) => String(Number(x.toFixed(5)));
const indent = (text: string, pad: string) => text.split(/\r?\n/).map(l => (l ? pad + l : l)).join('\n');

function placeLine(r: CaptureRecord): string | undefined {
  const p = r.place;
  if (!p) return undefined;
  const names = [p.nearby, p.sub_locality, p.locality].filter(Boolean).join(', ');
  const point = `${coord(p.lat)}, ${coord(p.lon)}`;
  return names ? `${names} (${point})` : point;
}

const likely = (r: CaptureRecord) => r.circumstances.map(c => `${c.label} (${c.confidence})`).join(', ');

/** One block per capture: local date and time, kind, title; then id, summary, place, tags, likely circumstances, first file. */
export function formatSearch(result: SearchResult): string {
  if (result.total === 0) return 'No captures match.\n';
  const head = result.items.length < result.total
    ? `Showing ${result.items.length} of ${plural(result.total, 'capture')}.` : `${plural(result.total, 'capture')}.`;
  const blocks = result.items.map(r => {
    const lines = [`${r.local_date} ${r.local_time} · ${r.kind} · ${r.title}`, `    id ${r.id}`];
    if (r.summary) lines.push(`    ${r.summary}`);
    const place = placeLine(r);
    if (place) lines.push(`    Place: ${place}`);
    if (r.tags.length) lines.push(`    Tags: ${r.tags.join(', ')}`);
    if (r.circumstances.length) lines.push(`    Likely: ${likely(r)}`);
    if (r.attachments[0]) lines.push(`    File: ${r.attachments[0].path}`);
    if (r.link) lines.push(`    Link: ${r.link.url}`);
    return lines.join('\n');
  });
  return `${head}\n\n${blocks.join('\n\n')}\n`;
}

/** Everything about one capture, including the evidence for each circumstance and every absolute file path. */
export function formatRecord(r: CaptureRecord, media: MediaRef[]): string {
  const out: string[] = [r.title, '', `id: ${r.id}`, `Kind: ${r.kind}${r.method ? ` (capture method ${r.method})` : ''}`,
    `Captured: ${r.local_date} ${r.local_time} ${r.timezone} (${r.weekday}, ${r.part_of_day}) · ${r.captured_at}`];
  const field = (label: string, value: string | undefined) => { if (value) out.push(`${label}: ${value}`); };
  const section = (label: string, lines: string[]) => { if (lines.length) out.push('', `${label}:`, ...lines); };

  field('Summary', r.summary);
  field('Topic', r.topic);
  field('Tags', r.tags.join(', '));
  field('People', r.people.map(p => `${p.name} (from ${p.source})`).join(', '));
  field('Keywords', r.keywords.map(k => `${k.word} ${k.weight}`).join(', '));
  field('Site', r.site);
  field('Source app', r.source_app);
  const place = placeLine(r);
  if (place) field('Place', `${place}${r.place?.accuracy_m !== undefined ? ` ±${r.place.accuracy_m} m` : ''}`);
  field('Has', r.has.join(', '));
  out.push(`Enriched on the desktop: ${r.enriched ? 'yes' : 'no'}`);
  if (r.urls.length) field('URLs', r.urls.join(' '));

  if (r.link) {
    const l = r.link;
    section('Link', [`  ${l.url}`, ...(['title', 'site_name', 'channel', 'description'] as const).filter(k => l[k]).map(k => `  ${k}: ${l[k]}`),
      ...(l.thumbPath ? [`  thumbnail: ${l.thumbPath}`] : [])]);
  }
  section('Likely circumstances (worked out by rules, not certain)', r.circumstances.flatMap(c =>
    [`  ${c.label} (${c.confidence})`, ...c.evidence.map(e => `    - ${e}`)]));
  section('Picture descriptions', r.image_descriptions.map(d => `  ${d.attachment_id}: ${d.text}`));
  if (r.body) section('Body', [indent(r.body, '  ')]);
  if (r.text) section('Text', [indent(r.text, '  ')]);
  section('Attachments', r.attachments.map(a => {
    const extra = [a.name, a.durationSeconds !== undefined ? `${a.durationSeconds} s` : undefined, a.isSpokenComment ? 'spoken comment' : undefined]
      .filter(Boolean).join(', ');
    return `  ${a.type}  ${a.path}${extra ? `  (${extra})` : ''}`;
  }));
  section('Comments', r.comments.flatMap(k => [`  ${k.added_at}  ${k.id}`,
    ...(k.text ? [indent(k.text, '    ')] : []), ...(k.transcript ? [`    transcript: ${k.transcript}`] : []),
    ...(k.audioPath ? [`    audio: ${k.audioPath}`] : [])]));
  section('Context', Object.entries(r.context).map(([k, v]) => `  ${k}: ${JSON.stringify(v)}`));
  section('Files in the index', media.map(m => `  ${m.ref}  ${m.mime}  ${m.path}`));
  return out.join('\n') + '\n';
}

const values = (xs: FacetValue[]) => (xs.length ? xs.map(x => `${x.value} ${x.count}`).join(' · ') : 'none');

export function formatFacets(f: Facets): string {
  const range = f.date_range ? `, ${f.date_range.from} to ${f.date_range.to}` : '';
  return [`${plural(f.total, 'capture')}${range}`,
    `Kinds: ${Object.entries(f.kinds).map(([k, n]) => `${k} ${n}`).join(' · ')}`,
    `Topics: ${values(f.topics)}`, `Tags: ${values(f.tags)}`, `People: ${values(f.people)}`, `Sites: ${values(f.sites)}`,
    `Localities: ${values(f.localities)}`, `Circumstances: ${values(f.circumstances)}`].join('\n') + '\n';
}
