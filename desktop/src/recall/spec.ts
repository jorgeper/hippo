// The search spec (spec section 7): one JSON shape for everything that asks for captures. All fields optional; fields combine
// with AND, values within a field with OR (except `has`, where all must hold).
import type { Confidence, Kind } from '../core/types.ts';
import type { Has, PartOfDay, Weekday } from '../core/record.ts';

export type LayoutName = 'kind' | 'time' | 'place' | 'topic' | 'person';
export type SortOrder = 'newest' | 'oldest' | 'relevance';

export interface SearchSpec {
  kinds?: Kind[];
  text?: string[];                        // each entry a word or a phrase; any may match
  tags?: string[]; topics?: string[]; people?: string[]; sites?: string[];
  time?: { from?: string; to?: string; weekdays?: string[]; parts_of_day?: string[] };   // local dates "YYYY-MM-DD", inclusive
  place?: { localities?: string[]; near?: { lat: number; lon: number; radius_m: number } };
  circumstances?: { labels: string[]; min_confidence?: Confidence };                     // default low
  has?: Has[];                                                       // all listed must hold
  include_ids?: string[]; exclude_ids?: string[];
  sort?: SortOrder; limit?: number;                                  // defaults newest, 500
}

export const KINDS: Kind[] = ['link', 'photo', 'screenshot', 'note', 'recording', 'video', 'file'];
export const HAS_VALUES: Has[] = ['picture', 'audio', 'comment', 'location', 'link'];
export const WEEKDAYS: Weekday[] = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
export const PARTS_OF_DAY: PartOfDay[] = ['morning', 'afternoon', 'evening', 'night'];
export const CONFIDENCES: Confidence[] = ['low', 'medium', 'high'];
export const SORTS: SortOrder[] = ['newest', 'oldest', 'relevance'];
export const DEFAULT_LIMIT = 500;
export const MAX_LIMIT = 5000;

const TOP_KEYS = ['kinds', 'text', 'tags', 'topics', 'people', 'sites', 'time', 'place', 'circumstances', 'has', 'include_ids',
  'exclude_ids', 'sort', 'limit'];
const FULL_WEEKDAYS: Record<string, Weekday> = { monday: 'mon', tuesday: 'tue', wednesday: 'wed', thursday: 'thu', friday: 'fri',
  saturday: 'sat', sunday: 'sun' };

function isObject(v: unknown): v is Record<string, unknown> { return typeof v === 'object' && v !== null && !Array.isArray(v); }

function isLocalDate(v: unknown): v is string {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

/** Checks a spec from JSON (an agent, the desk, the ask step) and returns it typed, or every problem found, each naming its field. */
export function validateSpec(input: unknown): { ok: true; spec: SearchSpec } | { ok: false; errors: string[] } {
  if (!isObject(input)) return { ok: false, errors: ['spec: expected a JSON object'] };
  const errors: string[] = [];
  const spec: SearchSpec = {};

  const unknownKeys = (o: Record<string, unknown>, allowed: string[], prefix: string) => {
    for (const k of Object.keys(o)) if (!allowed.includes(k)) errors.push(`${prefix}${k}: unknown field (expected one of ${allowed.join(', ')})`);
  };
  const strings = (v: unknown, field: string): string[] | undefined => {
    if (v === undefined) return undefined;
    if (!Array.isArray(v)) { errors.push(`${field}: expected a list of strings`); return undefined; }
    const bad = v.findIndex(x => typeof x !== 'string');
    if (bad >= 0) { errors.push(`${field}[${bad}]: expected a string`); return undefined; }
    return v as string[];
  };
  const oneOfEach = <T extends string>(v: unknown, field: string, allowed: readonly T[], what: string, map = (s: string) => s): T[] | undefined => {
    const list = strings(v, field);
    if (!list) return undefined;
    const out: T[] = [];
    for (const s of list) {
      const m = map(s);
      if (allowed.includes(m as T)) out.push(m as T);
      else errors.push(`${field}: unknown ${what} ${JSON.stringify(s)} (expected one of ${allowed.join(', ')})`);
    }
    return out.length === list.length ? out : undefined;
  };
  const oneOf = <T extends string>(v: unknown, field: string, allowed: readonly T[]): T | undefined => {
    if (v === undefined) return undefined;
    if (typeof v === 'string' && allowed.includes(v as T)) return v as T;
    errors.push(`${field}: expected one of ${allowed.join(', ')}`);
    return undefined;
  };

  unknownKeys(input, TOP_KEYS, '');

  const kinds = oneOfEach(input.kinds, 'kinds', KINDS, 'kind');
  if (kinds) spec.kinds = kinds;
  for (const k of ['text', 'tags', 'topics', 'people', 'sites', 'include_ids', 'exclude_ids'] as const) {
    const list = strings(input[k], k);
    if (list) spec[k] = list;
  }

  if (input.time !== undefined) {
    if (!isObject(input.time)) errors.push('time: expected an object');
    else {
      const t = input.time;
      unknownKeys(t, ['from', 'to', 'weekdays', 'parts_of_day'], 'time.');
      const time: NonNullable<SearchSpec['time']> = {};
      for (const k of ['from', 'to'] as const) {
        if (t[k] === undefined) continue;
        if (isLocalDate(t[k])) time[k] = t[k]; else errors.push(`time.${k}: expected YYYY-MM-DD`);
      }
      const weekdays = oneOfEach(t.weekdays, 'time.weekdays', WEEKDAYS, 'weekday', s => FULL_WEEKDAYS[s.toLowerCase()] ?? s.toLowerCase());
      if (weekdays) time.weekdays = weekdays;
      const parts = oneOfEach(t.parts_of_day, 'time.parts_of_day', PARTS_OF_DAY, 'part of day', s => s.toLowerCase());
      if (parts) time.parts_of_day = parts;
      spec.time = time;
    }
  }

  if (input.place !== undefined) {
    if (!isObject(input.place)) errors.push('place: expected an object');
    else {
      const p = input.place;
      unknownKeys(p, ['localities', 'near'], 'place.');
      const place: NonNullable<SearchSpec['place']> = {};
      const localities = strings(p.localities, 'place.localities');
      if (localities) place.localities = localities;
      if (p.near !== undefined) {
        if (!isObject(p.near)) errors.push('place.near: expected an object {lat, lon, radius_m}');
        else {
          const n = p.near;
          unknownKeys(n, ['lat', 'lon', 'radius_m'], 'place.near.');
          const num = (k: string, ok: (x: number) => boolean, expect: string) => {
            const x = n[k];
            if (typeof x === 'number' && Number.isFinite(x) && ok(x)) return x;
            errors.push(`place.near.${k}: expected ${expect}`);
            return undefined;
          };
          const lat = num('lat', x => x >= -90 && x <= 90, 'a number from -90 to 90');
          const lon = num('lon', x => x >= -180 && x <= 180, 'a number from -180 to 180');
          const radius = num('radius_m', x => x > 0, 'a number of meters above 0');
          if (lat !== undefined && lon !== undefined && radius !== undefined) place.near = { lat, lon, radius_m: radius };
        }
      }
      spec.place = place;
    }
  }

  if (input.circumstances !== undefined) {
    if (!isObject(input.circumstances)) errors.push('circumstances: expected an object {labels, min_confidence}');
    else {
      const c = input.circumstances;
      unknownKeys(c, ['labels', 'min_confidence'], 'circumstances.');
      if (c.labels === undefined) errors.push('circumstances.labels: expected a list of strings');
      const labels = strings(c.labels, 'circumstances.labels');
      const min = oneOf(c.min_confidence, 'circumstances.min_confidence', CONFIDENCES);
      if (labels) {
        spec.circumstances = { labels };
        if (min) spec.circumstances.min_confidence = min;
      }
    }
  }

  const has = oneOfEach(input.has, 'has', HAS_VALUES, 'value');
  if (has) spec.has = has;
  const sort = oneOf(input.sort, 'sort', SORTS);
  if (sort) spec.sort = sort;
  if (input.limit !== undefined) {
    const l = input.limit;
    if (typeof l === 'number' && Number.isInteger(l) && l >= 1 && l <= MAX_LIMIT) spec.limit = l;
    else errors.push(`limit: expected a whole number from 1 to ${MAX_LIMIT}`);
  }

  return errors.length ? { ok: false, errors } : { ok: true, spec };
}
