// By time: a column per local date when the range is at most 14 days, per ISO week (Monday to Sunday) when it spans at most
// 16 weeks, else per month; oldest on the left. Only buckets that hold items get a column. Within a column, y is the local
// time of day: the day starts at 05:00 at the far edge and ends at 04:59 nearest, so mornings are far and nights near.
// Items in one column closer than 60% of their height form a small pile. Dates and times are the capture's own local
// strings ("2026-11-07", "09:07"); nothing here reads the machine's time zone.
import type { DeskItem } from '../../../src/server/wire.ts';
import type { LayoutFn } from './types.ts';
import { byTime, collect, emptyResult, marginOf, viewRect } from './pile.ts';
import type { PileDraft } from './pile.ts';

export const DAY_LIMIT = 14;
export const WEEK_LIMIT = 16;
/** The time of day at the far edge of a column, in minutes after midnight. */
export const DAY_START = 5 * 60;
/** Items in a column whose y differs by less than this share of their height form one pile. */
export const PILE_CLOSENESS = 0.6;

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
  const width = view.width / keys.length;
  const top = view.height / 2, bottom = -view.height / 2;
  // One vertical scale for every column, so the same time of day is at the same y everywhere.
  const { my } = marginOf(items, sizes);
  const yOf = (it: DeskItem) => top - my - dayShare(it.local_time) * Math.max(0, view.height - 2 * my);

  const columns = keys.map((key, k) => ({ label: buckets.get(key)!.label, x: -view.width / 2 + width * (k + 0.5), width }));
  const drafts: PileDraft[] = [];
  keys.forEach((key, k) => {
    const x = columns[k].x;
    const inColumn = buckets.get(key)!.items.map(it => ({ it, y: yOf(it) }))
      .sort((a, b) => b.y - a.y || byTime(a.it, b.it));
    let group: { it: DeskItem; y: number }[] = [];
    const flush = () => {
      if (!group.length) return;
      const members = group.map(g => g.it);
      const times = members.map(m => m.local_time);
      const label = times[0] === times.at(-1) ? times[0] : `${times[0]}–${times.at(-1)}`;
      drafts.push({ key: `time:${key}@${members[0].id}`, label, items: members, x, y: group.reduce((s, g) => s + g.y, 0) / group.length });
      group = [];
    };
    for (const g of inColumn) {
      const anchor = group[0];
      if (anchor && anchor.y - g.y >= PILE_CLOSENESS * Math.max(sizes[anchor.it.kind].h, sizes[g.it.kind].h)) flush();
      group.push(g);
    }
    flush();
  });
  return { ...collect(drafts, sizes, viewRect(view)), backdrop: { type: 'columns', columns, top, bottom } };
};
