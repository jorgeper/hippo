import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { classifyFailure, DEFAULT_TIMEOUT_MS, ProviderError } from './types.ts';
import type { ModelRequest, Provider } from './types.ts';
import { childEnv, resolveCommand, run } from './spawn.ts';

/** Argument list for the signed-in `claude` command (design section 6). The prompt goes through stdin. */
export function claudeArgs(req: ModelRequest): string[] {
  const args = [
    '-p', '--output-format', 'json',
    '--json-schema', JSON.stringify(req.schema),
    '--model', req.model,
    '--system-prompt', req.system,
    '--tools', '',
    '--strict-mcp-config', '--disable-slash-commands', '--no-session-persistence',
    '--setting-sources', '',
  ];
  const images = (req.images ?? []).map(p => path.resolve(p));
  if (images.length) {
    const dirs = [...new Set(images.map(p => path.dirname(p)))];
    // --tools takes a list; the earlier empty --tools is replaced by this one.
    args.splice(args.indexOf('--tools'), 2, '--tools', 'Read');
    for (const d of dirs) args.push('--add-dir', d);
    args.push('--permission-mode', 'dontAsk');
  }
  return args;
}

export function claudeCliProvider(env: Record<string, string | undefined> = process.env): Provider {
  return {
    name: 'claude-cli',
    async complete(req) {
      const command = resolveCommand('claude', env.PATH ?? process.env.PATH);
      if (!command) throw new ProviderError('unavailable', 'the claude command was not found on PATH');
      const images = (req.images ?? []).map(p => path.resolve(p));
      const prompt = images.length
        ? `${req.prompt}\n\nPicture files to look at with the Read tool:\n${images.map(p => `- ${p}`).join('\n')}`
        : req.prompt;
      const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'hippo-claude-'));
      try {
        const r = await run(command, claudeArgs({ ...req, images }), { cwd, env: childEnv(env), stdin: prompt, timeoutMs: req.timeoutMs ?? DEFAULT_TIMEOUT_MS, label: 'claude' });
        let parsed: any;
        try { parsed = JSON.parse(r.stdout); } catch { parsed = undefined; }
        const text = [typeof parsed?.result === 'string' ? parsed.result : '', r.stderr, parsed ? '' : r.stdout].join('\n');
        if (parsed?.is_error || (r.code !== 0 && !parsed?.structured_output)) {
          throw new ProviderError(classifyFailure(text), `claude failed (${classifyFailure(text)})`);
        }
        if (!parsed || typeof parsed !== 'object') throw new ProviderError('bad_output', 'claude output was not JSON');
        if (parsed.structured_output === undefined || parsed.structured_output === null) throw new ProviderError('bad_output', 'claude result had no structured_output');
        return { value: parsed.structured_output, model: req.model };
      } finally {
        fs.rmSync(cwd, { recursive: true, force: true });
      }
    },
  };
}
