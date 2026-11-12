import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { ProviderError } from './types.ts';

/** Finds an executable on PATH without a shell. On Windows also tries .cmd/.exe. */
export function resolveCommand(name: string, pathVar: string | undefined, platform: string = process.platform): string | undefined {
  const dirs = (pathVar ?? '').split(path.delimiter).filter(Boolean);
  const exts = platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (const dir of dirs) {
    for (const ext of exts) {
      const candidate = path.join(dir, name + ext);
      try {
        if (!fs.statSync(candidate).isFile()) continue;
        if (platform !== 'win32') fs.accessSync(candidate, fs.constants.X_OK);
        return candidate;
      } catch { /* try next */ }
    }
  }
  return undefined;
}

export interface RunResult { stdout: string; stderr: string; code: number | null }

/** Runs a command with an argument array (never a shell), feeds `stdin`, kills it on timeout. */
export function run(command: string, args: string[], opts: { cwd: string; env: NodeJS.ProcessEnv; stdin?: string; timeoutMs: number; label: string }): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(command, args, { cwd: opts.cwd, env: opts.env, shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch {
      reject(new ProviderError('unavailable', `could not start ${opts.label}`));
      return;
    }
    let stdout = '', stderr = '', done = false, timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, opts.timeoutMs);
    const finish = (fn: () => void) => { if (done) return; done = true; clearTimeout(timer); fn(); };
    child.stdout.on('data', d => { stdout += d; });
    child.stderr.on('data', d => { stderr += d; });
    child.on('error', () => finish(() => reject(new ProviderError('unavailable', `could not start ${opts.label}`))));
    child.on('close', code => finish(() => {
      if (timedOut) reject(new ProviderError('timeout', `${opts.label} timed out after ${opts.timeoutMs} ms`));
      else resolve({ stdout, stderr, code });
    }));
    child.stdin.on('error', () => { /* child may exit before reading */ });
    child.stdin.end(opts.stdin ?? '');
  });
}
