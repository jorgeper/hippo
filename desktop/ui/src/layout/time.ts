// By time: a column per local date when the range is at most 14 days, per ISO week (Monday to Sunday) when it spans at most
// 16 weeks, else per month; oldest on the left. Only buckets that hold items get a column. Within a column, y is the local
// time of day: the day starts at 05:00 at the far edge and ends at 04:59 nearest, so mornings are far and nights near.
// Items in one column closer than 60% of their height form a small pile. Piles in a column are then pushed apart, in order,
// until each has its own depth plus room for its label under it; when a column cannot hold its piles that way inside the
// view, the two neighbours closest in time become one pile (labelled with the time range of all its members). Columns are
// never narrower than the widest pile, so neighbouring columns do not overlap either; the camera frames a wider desk.
// Dates and times are the capture's own local strings ("2026-11-07", "09:07"); nothing here reads the machine's time zone.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { LayoutFn } from './types.ts';
import { byTime, collect, emptyResult, marginOf } from './pile.ts';
import type { PileDraft } from './pile.ts';

export const DAY_LIMIT = 14;
export const WEEK_LIMIT = 16;
/** The time of day at the far edge of a column, in minutes after midnight. */
export const DAY_START = 5 * 60;
/** Items in a column whose y differs by less than this share of their height form one pile. */
export const PILE_CLOSENESS = 0.6;
/** Room kept under each pile in a column for its label (the tape and the gap above it), in desk units. */
export const TIME_LABEL_ROOM = 5;
/** Room between the widest piles of neighbouring columns, in desk units. */
export const COLUMN_GAP = 1.5;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const DAY_MS = 86_400_000;

/** Days since 1970-01-01 of a "YYYY-MM-DD" string, in UTC arithmetic only. */
export function dayNumber(date: string): number {
  return Math.round(Date.UTC(Number(date.slice(0, 4)), Number(date.slice(5, 7)) - 1, Number(date.slice(8, 10))) / DAY_MS);
}
const parts = (day: number) => { const d = new Date(day * DAY_MS); return { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate(), wd: d.getUTCDay() }; };
/** The Monday that starts the ISO week holding `day`. */
export const weekStart = (day: number) => day - ((parts(day).wd + 6) % 7);

export function dayLabel(day: number): string {
  const p = parts(day);
  return `${WEEKDAYS[p.wd]} ${p.d} ${MONTHS[p.m]}`;
}
export function weekLabel(monday: number): string {
  const a = parts(monday), b = parts(monday + 6);
  return a.m === b.m ? `${a.d}–${b.d} ${MONTHS[b.m]}` : `${a.d} ${MONTHS[a.m]} – ${b.d} ${MONTHS[b.m]}`;
}
export const monthLabel = (ym: string) => `${MONTHS[Number(ym.slice(5, 7)) - 1]} ${ym.slice(0, 4)}`;

export type TimeUnit = 'day' | 'week' | 'month';
export function timeUnit(dates: string[]): TimeUnit {
  const days = dates.map(dayNumber);
  const lo = Math.min(...days), hi = Math.max(...days);
  if (hi - lo + 1 <= DAY_LIMIT) return 'day';
  if ((weekStart(hi) - weekStart(lo)) / 7 + 1 <= WEEK_LIMIT) return 'week';
  return 'month';
}

/** A bucket's sortable key and its label. */
function bucketOf(date: string, unit: TimeUnit): { key: string; label: string } {
  if (unit === 'day') return { key: date, label: dayLabel(dayNumber(date)) };
  if (unit === 'week') {
    const monday = weekStart(dayNumber(date));
    return { key: String(monday).padStart(8, '0'), label: weekLabel(monday) };
  }
  return { key: date.slice(0, 7), label: monthLabel(date.slice(0, 7)) };
}

/** Share of the day (0 at DAY_START, nearly 1 just before it) for a "HH:MM" local time. */
export function dayShare(localTime: string): number {
  const minutes = Number(localTime.slice(0, 2)) * 60 + Number(localTime.slice(3, 5));
  return (((minutes - DAY_START) % 1440) + 1440) % 1440 / 1440;
}

/** A pile in the making: its members (far to near), the y its members' times ask for, and how far it reaches along y. */
interface ColumnPile { members: { it: DeskItem; y: number }[]; ideal: number; depth: number }

const meanY = (ms: { y: number }[]) => ms.reduce((s, m) => s + m.y, 0) / ms.length;

/**
 * Points for piles in one column, far to near: never closer than `pitch[k]` between pile k and k + 1, each inside
 * [lo[k], hi[k]] when the column can hold them, and otherwise as near the y its members ask for as it can be (least
 * squares: neighbours that would crowd each other share the displacement).
 */
export function spreadColumn(ideal: number[], pitch: number[], lo: number[], hi: number[]): number[] {
  const n = ideal.length;
  if (!n) return [];
  // With offset o[k] = pitch[0] + ... + pitch[k - 1], "y[k] - y[k + 1] >= pitch[k]" is "y[k] + o[k] never increases":
  // pool adjacent violators over z = ideal + o finds the closest such sequence.
  const o = [0];
  for (let k = 1; k < n; k++) o.push(o[k - 1] + pitch[k - 1]);
  const blocks: { sum: number; count: number }[] = [];
  for (let k = 0; k < n; k++) {
    blocks.push({ sum: ideal[k] + o[k], count: 1 });
    while (blocks.length > 1) {
      const b = blocks[blocks.length - 1], a = blocks[blocks.length - 2];
      if (a.sum / a.count >= b.sum / b.count) break;
      a.sum += b.sum; a.count += b.count;
      blocks.pop();
    }
  }
  const y: number[] = [];
  for (const b of blocks) for (let j = 0; j < b.count; j++) y.push(b.sum / b.count - o[y.length]);
  // Into the area: down from the far edge, then up from the near edge, keeping the spacing.
  for (let k = 0; k < n; k++) y[k] = Math.min(y[k], hi[k], k ? y[k - 1] - pitch[k - 1] : Infinity);
  for (let k = n - 1; k >= 0; k--) y[k] = Math.max(y[k], lo[k], k < n - 1 ? y[k + 1] + pitch[k] : -Infinity);
  return y;
}

export const timeLayout: LayoutFn = (items, view, sizes) => {
  if (!items.length) return emptyResult();
  const unit = timeUnit(items.map(i => i.local_date));
  const buckets = new Map<string, { label: string; items: DeskItem[] }>();
  for (const it of [...items].sort(byTime)) {
    const b = bucketOf(it.local_date, unit);
    let g = buckets.get(b.key);
    if (!g) buckets.set(b.key, g = { label: b.label, items: [] });
    g.items.push(it);
  }
  const keys = [...buckets.keys()].sort();
  // A column is never narrower than the widest pile (turn and jitter included) plus a gap.
  const { mx, my } = marginOf(items, sizes);
  const width = Math.max(view.width / keys.length, 2 * mx + COLUMN_GAP);
  const span = width * keys.length;
  const top = view.height / 2, bottom = -view.height / 2;
  // One vertical scale for every column, so the same time of day is at the same y everywhere.
  const yOf = (it: DeskItem) => top - my - dayShare(it.local_time) * Math.max(0, view.height - 2 * my);

  const columns = keys.map((key, k) => ({ label: buckets.get(key)!.label, x: -span / 2 + width * (k + 0.5), width }));
  const drafts: PileDraft[] = [];
  keys.forEach((key, k) => {
    const x = columns[k].x;
    const inColumn = buckets.get(key)!.items.map(it => ({ it, y: yOf(it) }))
      .sort((a, b) => b.y - a.y || byTime(a.it, b.it));
    // Items close in time form the first piles.
    const piles: ColumnPile[] = [];
    let group: { it: DeskItem; y: number }[] = [];
    const flush = () => {
      if (group.length) piles.push({ members: group, ideal: meanY(group), depth: marginOf(group.map(g => g.it), sizes).my });
      group = [];
    };
    for (const g of inColumn) {
      const anchor = group[0];
      if (anchor && anchor.y - g.y >= PILE_CLOSENESS * Math.max(sizes[anchor.it.kind].h, sizes[g.it.kind].h)) flush();
      group.push(g);
    }
    flush();
    // While the column cannot hold its piles one under another, each with its label under it, the two neighbours whose
    // points are closest become one.
    const needed = () => piles.reduce((s, p) => s + 2 * p.depth, 0) + (piles.length - 1) * TIME_LABEL_ROOM;
    while (piles.length > 1 && needed() > view.height) {
      let best = 0;
      for (let j = 1; j < piles.length - 1; j++) if (piles[j].ideal - piles[j + 1].ideal < piles[best].ideal - piles[best + 1].ideal) best = j;
      const members = [...piles[best].members, ...piles[best + 1].members];
      piles.splice(best, 2, { members, ideal: meanY(members), depth: Math.max(piles[best].depth, piles[best + 1].depth) });
    }
    const ys = spreadColumn(piles.map(p => p.ideal), piles.slice(1).map((p, j) => piles[j].depth + TIME_LABEL_ROOM + p.depth),
      piles.map(p => bottom + p.depth), piles.map(p => top - p.depth));
    piles.forEach((p, j) => {
      const members = p.members.map(m => m.it);
      const times = members.map(m => m.local_time);
      const label = times[0] === times.at(-1) ? times[0] : `${times[0]}–${times.at(-1)}`;
      drafts.push({ key: `time:${key}@${members[0].id}`, label, items: members, x, y: ys[j] });
    });
  });
  const area = { x0: -span / 2, x1: span / 2, y0: bottom, y1: top };
  return { ...collect(drafts, sizes, area), backdrop: { type: 'columns', columns, top, bottom } };
};
