import test from 'node:test';
import assert from 'node:assert/strict';
import { layouts, EMPTY_LINE } from '../src/layout/index.ts';
import { lonLatToTile, lonLatToWorld, worldToLonLat } from '../src/layout/mercator.ts';
import type { LayoutResult, Placement, View } from '../src/layout/types.ts';
import type { DeskItem } from '../../src/server/wire.ts';
import type { LayoutName } from '../../src/recall/spec.ts';
import { SIZES, VIEW, forty, idOf, item } from './items.ts';

const NAMES: LayoutName[] = ['kind', 'time', 'place', 'topic', 'person'];
const MAX_ROT = (4 * Math.PI) / 180;
const EPS = 1e-9;

/** Every placement, rotated object included, lies inside the view. */
function assertInside(items: DeskItem[], r: LayoutResult, view: View): void {
  const byId = new Map(items.map(i => [i.id, i]));
  for (const p of r.placements) {
    const { w, h } = SIZES[byId.get(p.id)!.kind];
    const c = Math.abs(Math.cos(p.rot)), s = Math.abs(Math.sin(p.rot));
    const hw = (w * c + h * s) / 2, hh = (w * s + h * c) / 2;
    assert.ok(Math.abs(p.x) + hw <= view.width / 2 + EPS, `${p.id} x ${p.x} outside a view ${view.width} wide`);
    assert.ok(Math.abs(p.y) + hh <= view.height / 2 + EPS, `${p.id} y ${p.y} outside a view ${view.height} high`);
    assert.ok(Math.abs(p.rot) <= MAX_ROT + EPS, `${p.id} rotation ${p.rot}`);
  }
}

const pileOf = (r: LayoutResult, id: string) => r.placements.find(p => p.id === id)!.pile;
const pileNamed = (r: LayoutResult, label: string) => r.piles.find(p => p.label === label);

test('every layout places each item exactly once, inside the view, the same way twice', () => {
  const items = forty();
  for (const name of NAMES) {
    const r = layouts[name](items, VIEW, SIZES);
    assert.equal(r.placements.length, 40, name);
    assert.deepEqual(new Set(r.placements.map(p => p.id)), new Set(items.map(i => i.id)), name);
    assert.deepEqual(layouts[name](items, VIEW, SIZES), r, `${name} is deterministic`);
    assert.deepEqual(layouts[name]([...items].reverse(), VIEW, SIZES).placements.sort((a, b) => a.id.localeCompare(b.id)),
      [...r.placements].sort((a, b) => a.id.localeCompare(b.id)), `${name} does not depend on input order`);
    assertInside(items, r, VIEW);
    assert.equal(r.empty, undefined);
    // Piles and placements agree: each pile's ids are exactly the placements naming it, and counts match.
    for (const pile of r.piles) {
      const members = r.placements.filter(p => p.pile === pile.key);
      assert.equal(pile.count, members.length, `${name} ${pile.key}`);
      assert.deepEqual(new Set(pile.ids), new Set(members.map(p => p.id)), `${name} ${pile.key}`);
    }
    assert.equal(r.piles.reduce((n, p) => n + p.count, 0), 40, name);
  }
});

test('any layout given no items returns the empty line', () => {
  for (const name of NAMES) {
    assert.deepEqual(layouts[name]([], VIEW, SIZES), { placements: [], piles: [], empty: EMPTY_LINE }, name);
  }
  assert.equal(EMPTY_LINE, 'Nothing matches. Try fewer words, or say "start over".');
});

test('kind: all links sit at one point (within the jitter), and the link pile does not move when only 5 links are given', () => {
  const items = forty();
  const r = layouts.kind(items, VIEW, SIZES);
  const pile = r.piles.find(p => p.key === 'link')!;
  const links = r.placements.filter(p => items.find(i => i.id === p.id)!.kind === 'link');
  assert.ok(links.length > 1);
  for (const p of links) {
    assert.equal(p.pile, 'link');
    assert.ok(Math.abs(p.x - pile.x) <= 0.4 + EPS && Math.abs(p.y - pile.y) <= 0.4 + EPS, `${p.x},${p.y} vs ${pile.x},${pile.y}`);
  }
  const five = items.filter(i => i.kind === 'link').slice(0, 5);
  const r5 = layouts.kind(five, VIEW, SIZES);
  assert.equal(r5.piles.length, 1);
  assert.deepEqual([r5.piles[0].x, r5.piles[0].y], [pile.x, pile.y]);
  // Seven kinds, seven distinct slots, in a 4 + 3 grid: the first row further away than the second.
  const at = Object.fromEntries(r.piles.map(p => [p.key, p]));
  assert.deepEqual(r.piles.map(p => p.key), ['link', 'photo', 'screenshot', 'note', 'recording', 'video', 'file']);
  assert.ok(at.link.x < at.photo.x && at.photo.x < at.screenshot.x && at.screenshot.x < at.note.x);
  assert.ok(at.recording.x < at.video.x && at.video.x < at.file.x);
  assert.ok(at.link.y > at.recording.y);
  assert.equal(at.link.label, 'Links');
});

test('a pile stacks oldest at the bottom (order 0) and lists its ids newest first', () => {
  const items = [item(1, { kind: 'note', date: '2026-11-08', time: '10:00' }), item(2, { kind: 'note', date: '2026-11-07', time: '10:00' }),
    item(3, { kind: 'note', date: '2026-11-09', time: '10:00' })];
  const r = layouts.kind(items, VIEW, SIZES);
  const order = (id: string) => r.placements.find(p => p.id === id)!.order;
  assert.deepEqual([order(idOf(2)), order(idOf(1)), order(idOf(3))], [0, 1, 2]);
  assert.deepEqual(r.piles[0].ids, [idOf(3), idOf(1), idOf(2)]);
});

test('time: three dates give three columns, oldest left, labelled by day; morning is further away than evening', () => {
  const items = forty();
  const r = layouts.time(items, VIEW, SIZES);
  assert.equal(r.backdrop?.type, 'columns');
  if (r.backdrop?.type !== 'columns') return;
  const cols = r.backdrop.columns;
  assert.deepEqual(cols.map(c => c.label), ['Sat 7 Nov', 'Sun 8 Nov', 'Mon 9 Nov']);
  assert.ok(cols[0].x < cols[1].x && cols[1].x < cols[2].x);
  for (const it of items) {
    const p = r.placements.find(q => q.id === it.id)!;
    const col = cols[Number(it.local_date.slice(8)) - 7];
    assert.ok(Math.abs(p.x - col.x) <= col.width / 2 + EPS, `${it.id} in its date's column`);
  }
  const morning = item(1, { date: '2026-11-07', time: '07:30' }), evening = item(2, { date: '2026-11-07', time: '21:15' });
  const r2 = layouts.time([morning, evening], VIEW, SIZES);
  const y = (id: string) => r2.placements.find(p => p.id === id)!.y;
  assert.ok(y(morning.id) > y(evening.id), 'morning at the far edge, evening nearer');
});

test('time: items in one column close in time form a small pile; hours apart they do not', () => {
  const a = item(1, { date: '2026-11-07', time: '10:00' }), b = item(2, { date: '2026-11-07', time: '10:05' });
  const c = item(3, { date: '2026-11-07', time: '15:00' });
  const r = layouts.time([a, b, c], VIEW, SIZES);
  assert.equal(pileOf(r, a.id), pileOf(r, b.id));
  assert.notEqual(pileOf(r, a.id), pileOf(r, c.id));
  assert.equal(r.piles.length, 2);
});

test('time: forty dates give ISO-week columns; a long range gives month columns; labels need no time zone', () => {
  const start = Date.UTC(2026, 8, 28);   // Monday 28 Sep 2026
  const days = Array.from({ length: 40 }, (_, k) => new Date(start + k * 86_400_000).toISOString().slice(0, 10));
  const r = layouts.time(days.map((d, k) => item(k, { date: d })), VIEW, SIZES);
  assert.equal(r.backdrop?.type, 'columns');
  if (r.backdrop?.type !== 'columns') return;
  assert.deepEqual(r.backdrop.columns.map(c => c.label),
    ['28 Sep – 4 Oct', '5–11 Oct', '12–18 Oct', '19–25 Oct', '26 Oct – 1 Nov', '2–8 Nov']);

  const months = ['2026-06-15', '2026-07-01', '2026-08-31', '2026-11-07'].map((d, k) => item(k, { date: d }));
  const rm = layouts.time(months, VIEW, SIZES);
  assert.ok(rm.backdrop?.type === 'columns');
  if (rm.backdrop?.type !== 'columns') return;
  assert.deepEqual(rm.backdrop.columns.map(c => c.label), ['Jun 2026', 'Jul 2026', 'Aug 2026', 'Nov 2026']);

  // Two dates 14 days inclusive are still days; one more day turns them into weeks.
  const d14 = layouts.time([item(1, { date: '2026-11-01' }), item(2, { date: '2026-11-14' })], VIEW, SIZES);
  assert.ok(d14.backdrop?.type === 'columns' && d14.backdrop.columns[0].label === 'Sun 1 Nov');
  const d15 = layouts.time([item(1, { date: '2026-11-01' }), item(2, { date: '2026-11-15' })], VIEW, SIZES);
  assert.ok(d15.backdrop?.type === 'columns' && d15.backdrop.columns[0].label === '26 Oct – 1 Nov');
  // A week across the new year.
  const ny = layouts.time([item(1, { date: '2026-12-01' }), item(2, { date: '2027-01-02' })], VIEW, SIZES);
  assert.ok(ny.backdrop?.type === 'columns');
  if (ny.backdrop?.type === 'columns') assert.deepEqual(ny.backdrop.columns.map(c => c.label), ['30 Nov – 6 Dec', '28 Dec – 3 Jan']);
});

test('topic: one pile per topic, largest first, "Other" for items with none; counts sum to 40', () => {
  const items = forty();
  const r = layouts.topic(items, VIEW, SIZES);
  const topics = new Set(items.map(i => i.topic ?? 'Other'));
  assert.equal(r.piles.length, topics.size);
  assert.deepEqual(new Set(r.piles.map(p => p.label)), topics);
  assert.equal(r.piles.reduce((n, p) => n + p.count, 0), 40);
  assert.equal(r.piles.at(-1)!.label, 'Other');
  const named = r.piles.slice(0, -1).map(p => p.count);
  assert.deepEqual(named, [...named].sort((a, b) => b - a));
});

test('topic: more piles than fit merge the smallest into a last pile "More"', () => {
  const items: DeskItem[] = [];
  let n = 0;
  for (let t = 0; t < 30; t++) for (let k = 0; k <= t; k++) items.push(item(n++, { topic: `topic ${String(t).padStart(2, '0')}` }));
  items.push(item(n++), item(n++));   // no topic
  const view = { width: 70, height: 45 };
  const r = layouts.topic(items, view, SIZES);
  assert.ok(r.piles.length < 31, `${r.piles.length} piles`);
  assert.ok(r.piles.length >= 2);
  assert.equal(r.piles.at(-1)!.label, 'More');
  const kept = r.piles.slice(0, -1).map(p => p.label);
  assert.deepEqual(kept, Array.from({ length: kept.length }, (_, k) => `topic ${String(29 - k).padStart(2, '0')}`));
  assert.equal(r.piles.reduce((s, p) => s + p.count, 0), items.length);
  assertInside(items, r, view);
  // Piles sit in a grid: no two pile points closer than the largest object.
  for (const a of r.piles) for (const b of r.piles) if (a !== b) assert.ok(Math.hypot(a.x - b.x, a.y - b.y) >= 15 - EPS);
});

test('person: an item naming Ana then Rui is in pile Ana; nobody mentioned comes last', () => {
  const items = forty();
  const r = layouts.person(items, VIEW, SIZES);
  const pile = r.piles.find(p => p.key === pileOf(r, idOf(0)))!;
  assert.equal(pile.label, 'Ana');
  assert.equal(r.piles.at(-1)!.label, 'Nobody mentioned');
  assert.deepEqual(r.piles.map(p => p.label).sort(), ['Ana', 'Marta', 'Nobody mentioned']);
});

test('person: more piles than fit merge the smallest named piles into "Others" and keep "Nobody mentioned"', () => {
  const items: DeskItem[] = [];
  let n = 0;
  for (let t = 0; t < 20; t++) for (let k = 0; k <= t; k++) items.push(item(n++, { people: [{ name: `P${String(t).padStart(2, '0')}`, source: 'text' }] }));
  items.push(item(n++), item(n++));
  const view = { width: 70, height: 45 };
  const r = layouts.person(items, view, SIZES);
  assert.ok(r.piles.length < 21);
  assert.deepEqual(r.piles.slice(-2).map(p => p.label), ['Others', 'Nobody mentioned']);
  assert.equal(r.piles.at(-1)!.count, 2);
  const kept = r.piles.slice(0, -2).map(p => p.label);
  assert.deepEqual(kept, Array.from({ length: kept.length }, (_, k) => `P${String(19 - k).padStart(2, '0')}`));
  assert.equal(r.piles.reduce((s, p) => s + p.count, 0), items.length);
  assertInside(items, r, view);
});

test('place: 20 m apart share a pile, 5 km apart do not; unlocated items are a "No location" pile on the right', () => {
  const A = { lat: 38.7223, lon: -9.1393 };
  const metresNorth = (m: number) => m / 111_320;
  const a = item(100, { place: { lat: A.lat, lon: A.lon, locality: 'Lisboa', sub_locality: 'Baixa' } });
  const b = item(101, { place: { lat: A.lat + metresNorth(20), lon: A.lon, locality: 'Lisboa', sub_locality: 'Baixa' } });
  const c = item(102, { place: { lat: A.lat + metresNorth(5000), lon: A.lon, locality: 'Lisboa', sub_locality: 'Lumiar' } });
  const items = [...forty(), a, b, c];
  const r = layouts.place(items, VIEW, SIZES);
  assert.equal(pileOf(r, a.id), pileOf(r, b.id));
  assert.notEqual(pileOf(r, a.id), pileOf(r, c.id));
  assertInside(items, r, VIEW);

  const none = pileNamed(r, 'No location')!;
  assert.equal(none.count, 6);
  assert.ok(none.x > 0.3 * VIEW.width, `No location at x ${none.x}`);
  for (const it of items.filter(i => !i.place)) assert.equal(pileOf(r, it.id), none.key);

  assert.equal(r.backdrop?.type, 'map');
  if (r.backdrop?.type !== 'map') return;
  const m = r.backdrop;
  assert.ok(Number.isInteger(m.zoom) && m.zoom >= 0 && m.zoom <= 19);
  assert.ok(Math.abs(m.x - m.width / 2 + VIEW.width / 2) < EPS, 'the map starts at the left edge');
  assert.ok(Math.abs(m.width - 0.8 * VIEW.width) < EPS);
  // Located items sit on the map sheet, away from 0,0 being a default; a pile is labelled by its commonest place name.
  for (const it of items.filter(i => i.place)) {
    const p = r.placements.find(q => q.id === it.id)!;
    assert.ok(p.x >= m.x - m.width / 2 - EPS && p.x <= m.x + m.width / 2 + EPS);
  }
  assert.ok(m.labels.some(l => l.text === 'Lisboa'));
  const small = layouts.place([a, b, c], VIEW, SIZES);
  assert.equal(small.piles.find(p => p.key === pileOf(small, a.id))!.label, 'Baixa');
  assert.equal(small.piles.find(p => p.key === pileOf(small, c.id))!.label, 'Lumiar');
});

test('place: north is away from the viewer and east is to the right', () => {
  const sw = item(1, { place: { lat: 38.70, lon: -9.20 } }), ne = item(2, { place: { lat: 38.80, lon: -9.10 } });
  const r = layouts.place([sw, ne], VIEW, SIZES);
  const at = (id: string) => r.placements.find(p => p.id === id)!;
  assert.ok(at(ne.id).x > at(sw.id).x && at(ne.id).y > at(sw.id).y);
});

test('place: with no located items there is no backdrop and everything is in "No location"', () => {
  const items = forty().map(i => { const { place, ...rest } = i; void place; return rest as DeskItem; });
  const r = layouts.place(items, VIEW, SIZES);
  assert.equal(r.backdrop, undefined);
  assert.equal(r.piles.length, 1);
  assert.equal(r.piles[0].label, 'No location');
  assert.equal(r.piles[0].count, 40);
  assertInside(items, r, VIEW);
});

test('place: a single located item still gets a map, at a zoom no closer than street level', () => {
  const r = layouts.place([item(1, { place: { lat: 38.7223, lon: -9.1393 } })], VIEW, SIZES);
  assert.ok(r.backdrop?.type === 'map' && r.backdrop.zoom <= 17);
  assert.ok(Math.abs(r.placements[0].x - (r.backdrop?.type === 'map' ? r.backdrop.x : NaN)) <= 0.4 + EPS);
});

test('mercator: Lisbon at zoom 12 is tile 1944, 1569; world pixels round-trip', () => {
  assert.deepEqual(lonLatToTile(-9.1393, 38.7223, 12), { x: 1944, y: 1569 });
  assert.deepEqual(lonLatToTile(0, 0, 0), { x: 0, y: 0 });
  const p = lonLatToWorld(-9.1393, 38.7223, 12);
  assert.ok(Math.abs(p.x / 256 - 1944.5) < 0.5 && Math.abs(p.y / 256 - 1569.5) < 0.5);
  const back = worldToLonLat(p.x, p.y, 12);
  assert.ok(Math.abs(back.lon + 9.1393) < 1e-9 && Math.abs(back.lat - 38.7223) < 1e-9);
  assert.deepEqual(lonLatToWorld(0, 0, 1), { x: 256, y: 256 });
});

test('placements carry the pile key and integer orders from 0', () => {
  for (const name of NAMES) {
    const r = layouts[name](forty(), VIEW, SIZES);
    for (const pile of r.piles) {
      const orders = r.placements.filter((p: Placement) => p.pile === pile.key).map(p => p.order).sort((a, b) => a - b);
      assert.deepEqual(orders, orders.map((_, k) => k), `${name} ${pile.key}`);
    }
  }
});
