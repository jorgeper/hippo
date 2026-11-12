import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { classifyFailure, DEFAULT_TIMEOUT_MS, ProviderError } from './types.ts';
import type { ModelRequest, Provider } from './types.ts';
import { childEnv, resolveCommand, run } from './spawn.ts';

/** Argument list for `codex exec` (checked against `codex exec --help`, codex-cli 0.166.0). The prompt goes through stdin. */
export function codexArgs(req: ModelRequest, dir: string, schemaFile: string, outFile: string): string[] {
  const args = ['exec', '--skip-git-repo-check', '--ephemeral', '--sandbox', 'read-only', '--cd', dir, '--output-schema', schemaFile, '--output-last-message', outFile];
  if (req.model && req.model !== 'haiku') args.push('--model', req.model);
  for (const img of req.images ?? []) args.push('--image', path.resolve(img));
  return args;
}

export function codexCliProvider(env: Record<string, string | undefined> = process.env): Provider {
  return {
    name: 'codex-cli',
    async complete(req) {
      const command = resolveCommand('codex', env.PATH ?? process.env.PATH);
      if (!command) throw new ProviderError('unavailable', 'the codex command was not found on PATH');
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-codex-'));
      try {
        const schemaFile = path.join(dir, 'schema.json');
        const outFile = path.join(dir, 'out.json');
        fs.writeFileSync(schemaFile, JSON.stringify(req.schema));
        const stdin = `${req.system}\n\n${req.prompt}`;
        const r = await run(command, codexArgs(req, dir, schemaFile, outFile), { cwd: dir, env: childEnv(env), stdin, timeoutMs: req.timeoutMs ?? DEFAULT_TIMEOUT_MS, label: 'codex' });
        if (r.code !== 0) {
          const c = classifyFailure(r.stderr + '\n' + r.stdout);
          throw new ProviderError(c, `codex failed (${c})`);
        }
        let text: string;
        try { text = fs.readFileSync(outFile, 'utf8'); } catch { throw new ProviderError('bad_output', 'codex wrote no final message'); }
        try { return { value: JSON.parse(text), model: req.model || 'codex' }; } catch { throw new ProviderError('bad_output', 'codex output was not JSON'); }
      } finally {
        fs.rmSync(dir, { recursive: true, force: true });
      }
    },
  };
}
