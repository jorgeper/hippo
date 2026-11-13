import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const defaultEnvFile = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../.env');

/** Parses KEY=value lines: comments, `export` prefix, single or double quotes. Never logs. */
export function parseEnv(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!m) continue;
    let v = m[2].trim();
    const q = v[0];
    if ((q === '"' || q === "'") && v.indexOf(q, 1) > 0) {
      const end = v.indexOf(q, 1);
      v = v.slice(1, end);
      if (q === '"') v = v.replace(/\\n/g, '\n').replace(/\\"/g, '"');
    } else {
      v = v.replace(/\s+#.*$/, '');
    }
    out[m[1]] = v;
  }
  return out;
}

/** The .env file (if present) under the process environment: process values win. Empty values count as unset. */
export function loadEnv(file: string = defaultEnvFile, processEnv: Record<string, string | undefined> = process.env): Record<string, string | undefined> {
  let fromFile: Record<string, string> = {};
  try { fromFile = parseEnv(fs.readFileSync(file, 'utf8')); } catch { /* no file is fine */ }
  const merged: Record<string, string | undefined> = { ...fromFile };
  for (const [k, v] of Object.entries(processEnv)) if (v !== undefined && v !== '') merged[k] = v;
  for (const k of Object.keys(merged)) if (merged[k] === '') delete merged[k];
  return merged;
}
