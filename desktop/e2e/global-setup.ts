// Before the browser tests: a 120-capture sample folder ending today, indexed under a temp HIPPO_DESK_HOME, the page built,
// and the desk server running on a free port with the fake provider (no model is called). The returned function stops the
// server and removes every temp directory. Nothing here touches a real Hippo folder.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { writeSample } from '../src/index/sample.ts';
import { buildIndex } from '../src/index/build.ts';
import { startServer } from '../src/server/server.ts';
import { fakeProvider } from '../src/providers/fake.ts';

const desktop = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function localToday(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export default async function globalSetup(): Promise<() => Promise<void>> {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-e2e-'));
  const previousHome = process.env.HIPPO_DESK_HOME;
  process.env.HIPPO_DESK_HOME = path.join(tmp, 'home');
  let server: Awaited<ReturnType<typeof startServer>> | undefined;
  const cleanup = async () => {
    try { await server?.close(); } catch { /* already closed */ }
    server = undefined;
    if (previousHome === undefined) delete process.env.HIPPO_DESK_HOME; else process.env.HIPPO_DESK_HOME = previousHome;
    fs.rmSync(tmp, { recursive: true, force: true });
  };
  try {
    const folder = path.join(tmp, 'sample');
    await writeSample({ out: folder, count: 120, seed: 7, end: localToday() });
    await buildIndex(folder);
    const vite = path.join(desktop, 'node_modules', 'vite', 'bin', 'vite.js');
    const built = spawnSync(process.execPath, [vite, 'build', 'ui'], { cwd: desktop, encoding: 'utf8' });
    if (built.status !== 0) throw new Error(`building the page failed:\n${built.stdout}\n${built.stderr}`);
    server = await startServer({ folder, port: 0, provider: fakeProvider(), uiDir: path.join(desktop, 'ui', 'dist'), log: () => {} });
    process.env.HIPPO_E2E_URL = server.url;
    process.env.HIPPO_E2E_ORIGIN = `http://127.0.0.1:${server.port}`;
  } catch (e) {
    await cleanup();
    throw e;
  }
  return cleanup;
}
