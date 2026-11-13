// Synthetic desk items for the page's pure tests. Invented values only: no capture from a real folder.
import type { DeskItem } from '../../src/server/wire.ts';
import type { Kind } from '../../src/core/types.ts';
import type { SizeTable, View } from '../src/layout/types.ts';

/** The brief's object sizes in desk units (centimetres). */
export const SIZES: SizeTable = {
  photo: { w: 15, h: 10 }, screenshot: { w: 7, h: 15 }, link: { w: 12, h: 9 }, note: { w: 9, h: 9 },
  recording: { w: 10, h: 6.4 }, video: { w: 15, h: 9 }, file: { w: 10.5, h: 14 },
};
export const VIEW: View = { width: 160, height: 100 };

const KINDS: Kind[] = ['link', 'photo', 'screenshot', 'note', 'recording', 'video', 'file'];
const TOPICS = ['cooking', 'fitness', 'travel', 'work', undefined];
const WEEKDAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const pad = (n: number, w = 2) => String(n).padStart(w, '0');

export const idOf = (n: number) => `00000000-0000-4000-8000-${pad(n, 12)}`;

/** One item. `date` is a local date, `time` a local time "HH:MM"; captured_at is the same wall time in UTC (enough here). */
export function item(n: number, over: Partial<DeskItem> & { date?: string; time?: string } = {}): DeskItem {
  const { date = '2026-11-07', time = '09:00', ...rest } = over;
  const day = new Date(`${date}T00:00:00Z`).getUTCDay();
  const hour = Number(time.slice(0, 2));
  return {
    id: idOf(n), kind: KINDS[n % KINDS.length], title: `Item ${n}`, tags: [], people: [], keywords: [],
    captured_at: `${date}T${time}:00.000Z`, local_date: date, local_time: time, weekday: WEEKDAYS[day],
    part_of_day: hour < 12 ? 'morning' : hour < 18 ? 'afternoon' : hour < 22 ? 'evening' : 'night', timezone: 'Europe/Lisbon',
    circumstances: [], more_count: 0, has: [], ...rest,
  };
}

/**
 * Forty items over three dates (7, 8, 9 Nov 2026), seven kinds, four topics plus none, a few people, 34 located around Lisbon
 * and the last 6 with no location.
 */
export function forty(): DeskItem[] {
  const out: DeskItem[] = [];
  for (let n = 0; n < 40; n++) {
    const topic = TOPICS[n % TOPICS.length];
    const people = n % 4 === 0 ? [{ name: 'Ana', source: 'text' }, { name: 'Rui', source: 'text' }]
      : n % 4 === 1 ? [{ name: 'Marta', source: 'text' }] : [];
    const it = item(n, {
      date: `2026-11-${pad(7 + (n % 3))}`, time: `${pad(7 + ((n * 5) % 16))}:${pad((n * 13) % 60)}`, people,
      ...(topic ? { topic } : {}),
    });
    if (n < 34) it.place = { lat: 38.70 + (n % 5) * 0.012, lon: -9.16 + ((n * 3) % 5) * 0.012, locality: 'Lisboa',
      sub_locality: n % 2 ? 'Alfama' : 'Baixa' };
    out.push(it);
  }
  return out;
}
