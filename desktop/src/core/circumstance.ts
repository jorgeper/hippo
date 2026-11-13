// Rule-made circumstances (spec section 5, "Circumstances"; hints in docs/context-signals.md).
// Reads only metadata.json and the device enrichment, never the server document.
// A missing signal yields no conclusion, never a negative one.
import type { Confidence, RawCapture } from './types.ts';
import type { Circumstance } from './record.ts';

export type { Circumstance };

interface Port { port_type: string; port_name?: string }
interface MotionSample { activities: string[]; confidence?: Confidence }

const CONFIDENCES: readonly string[] = ['low', 'medium', 'high'];

function isObject(v: unknown): v is Record<string, any> { return typeof v === 'object' && v !== null && !Array.isArray(v); }
const nonBlank = (v: unknown): v is string => typeof v === 'string' && v.trim() !== '';

function observation(c: RawCapture, key: string): Record<string, any> | undefined {
  const obs = c.metadata.metadata_observations;
  if (!Array.isArray(obs)) return undefined;
  const o = obs.find((x: unknown) => isObject(x) && x.key === key);
  return o && isObject(o.value) ? o.value : undefined;
}

function outputs(c: RawCapture): Port[] {
  const outs = observation(c, 'context.audio_route')?.outputs;
  if (!Array.isArray(outs)) return [];
  return outs.filter((p: unknown): p is Port => isObject(p) && typeof p.port_type === 'string');
}

function deviceData(c: RawCapture, kind: string): Record<string, any> | undefined {
  const f = c.device && isObject(c.device.facets) ? c.device.facets[kind] : undefined;
  return isObject(f) && f.status === 'ok' && isObject(f.data) ? f.data : undefined;
}

function motionAtCapture(c: RawCapture): MotionSample | undefined {
  const s = deviceData(c, 'motion_activity')?.at_capture;
  if (!isObject(s) || !Array.isArray(s.activities)) return undefined;
  const out: MotionSample = { activities: s.activities.filter((a: unknown): a is string => typeof a === 'string') };
  if (typeof s.confidence === 'string' && CONFIDENCES.includes(s.confidence)) out.confidence = s.confidence as Confidence;
  return out;
}

function speed(c: RawCapture): number | undefined {
  const loc = c.metadata.capture_location;
  const v = isObject(loc) ? loc.speed_meters_per_second : undefined;
  return typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : undefined;
}

/** A device name is the phone's to report and can be anything: evidence shows at most this many code points of it. */
export const PORT_NAME_MAX = 60;

/** The device's own name for evidence: control characters out (line breaks and tabs become spaces), at most 60 code points. */
function portName(p: Port, fallback: string): string {
  if (!nonBlank(p.port_name)) return fallback;
  const name = p.port_name.replace(/[\t\n\v\f\r\u0085]/g, ' ').replace(/\p{Cc}/gu, '').replace(/\s+/g, ' ').trim();
  if (name === '') return fallback;
  const cps = [...name];
  return cps.length <= PORT_NAME_MAX ? name : `${cps.slice(0, PORT_NAME_MAX - 1).join('').trimEnd()}…`;
}

export function deriveCircumstances(c: RawCapture): Circumstance[] {
  const out: Circumstance[] = [];
  const outs = outputs(c);
  const motion = motionAtCapture(c);
  const acts = motion?.activities ?? [];

  // in_car: (a) car audio, (b) automotive at capture, (c) speed above 3 m/s.
  const car = outs.find(p => p.port_type === 'car_audio');
  const automotive = acts.includes('automotive');
  const v = speed(c);
  const fast = v !== undefined && v > 3;
  const evidence: string[] = [];
  if (car) evidence.push(`audio route was ${portName(car, 'car audio')}`);
  if (automotive) evidence.push('motion at capture was automotive');
  if (fast) evidence.push(`speed was ${v.toFixed(1)} m/s`);
  const speedOnlyWhileMoving = fast && !car && !automotive && ['walking', 'running', 'cycling'].some(a => acts.includes(a));
  if (evidence.length && !speedOnlyWhileMoving) {
    let confidence: Confidence;
    if (car || (automotive && motion?.confidence === 'high') || evidence.length >= 2) confidence = 'high';
    else if (automotive) confidence = 'medium';
    else confidence = 'low';
    out.push({ label: 'in_car', confidence, evidence });
  }

  // walking, running, cycling: the motion sample at capture, with its own confidence.
  for (const a of ['walking', 'running', 'cycling'])
    if (acts.includes(a)) out.push({ label: a, confidence: motion?.confidence ?? 'low', evidence: [`motion at capture was ${a}`] });

  // on_headphones: wired or LE is high; A2DP or HFP is medium unless car audio is on the route.
  const strong = outs.find(p => p.port_type === 'headphones' || p.port_type === 'bluetooth_le');
  const weak = outs.find(p => p.port_type === 'bluetooth_a2dp' || p.port_type === 'bluetooth_hfp');
  if (strong) out.push({ label: 'on_headphones', confidence: 'high', evidence: [`audio route was ${portName(strong, 'headphones')}`] });
  else if (weak && !car) out.push({ label: 'on_headphones', confidence: 'medium', evidence: [`audio route was ${portName(weak, 'Bluetooth audio')}`] });

  // in_a_burst: the previous capture on this phone was moments earlier.
  const gap = observation(c, 'context.burst')?.seconds_since_previous;
  if (typeof gap === 'number' && Number.isFinite(gap) && gap >= 0 && gap < 180) {
    const n = Number.isInteger(gap) ? String(gap) : gap.toFixed(1);
    out.push({ label: 'in_a_burst', confidence: gap < 60 ? 'high' : 'medium', evidence: [`previous capture was ${n} s earlier`] });
  }

  // daylight / dark: weather's is_day for the hour of the capture.
  const isDay = deviceData(c, 'weather')?.is_day;
  if (isDay === true) out.push({ label: 'daylight', confidence: 'high', evidence: ['weather lookup says daytime'] });
  else if (isDay === false) out.push({ label: 'dark', confidence: 'high', evidence: ['weather lookup says night'] });

  return out;
}
