import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const fixturesDir = path.resolve(here, '../../fixtures/packages');

/** Copies fixtures/packages into a fresh temp dir and returns it. Also points HIPPO_DESK_HOME at another temp dir. */
export function copyFixtures(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-fixtures-'));
  fs.cpSync(fixturesDir, dir, { recursive: true });
  process.env.HIPPO_DESK_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-home-'));
  return dir;
}
