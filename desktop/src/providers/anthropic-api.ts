import fs from 'node:fs';
import { classifyFailure, DEFAULT_TIMEOUT_MS, ProviderError } from './types.ts';
import type { Provider } from './types.ts';

/** `haiku` is the alias for the current small model (Claude Haiku 5.5). */
export const HAIKU_MODEL_ID = 'claude-haiku-5-5';

export function anthropicApiProvider(env: Record<string, string | undefined> = process.env): Provider {
  return {
    name: 'anthropic-api',
    async complete(req) {
      const key = env.ANTHROPIC_API_KEY;
      if (!key) throw new ProviderError('unavailable', 'ANTHROPIC_API_KEY is not set');
      const model = req.model === 'haiku' ? HAIKU_MODEL_ID : req.model;
      const content: unknown[] = [];
      for (const img of req.images ?? []) {
        content.push({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: fs.readFileSync(img).toString('base64') } });
      }
      content.push({ type: 'text', text: req.prompt });
      let res: Response;
      try {
        res = await fetch('https://api.anthropic.com/v1/messages', {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
          body: JSON.stringify({
            model, max_tokens: 4096, system: req.system,
            messages: [{ role: 'user', content }],
            output_config: { format: { type: 'json_schema', schema: req.schema } },
          }),
          signal: AbortSignal.timeout(req.timeoutMs ?? DEFAULT_TIMEOUT_MS),
        });
      } catch (e: any) {
        if (e?.name === 'TimeoutError' || e?.name === 'AbortError') throw new ProviderError('timeout', 'anthropic-api timed out');
        throw new ProviderError('unavailable', 'anthropic-api could not be reached');
      }
      if (!res.ok) {
        if (res.status === 429) throw new ProviderError('usage_limit', 'anthropic-api rate limited (429)');
        if (res.status === 401 || res.status === 403) throw new ProviderError('not_signed_in', `anthropic-api rejected the key (${res.status})`);
        throw new ProviderError(classifyFailure(''), `anthropic-api failed (${res.status})`);
      }
      const body: any = await res.json().catch(() => undefined);
      const text = Array.isArray(body?.content) ? body.content.find((b: any) => b?.type === 'text')?.text : undefined;
      if (typeof text !== 'string') throw new ProviderError('bad_output', 'anthropic-api returned no text');
      try { return { value: JSON.parse(text), model }; } catch { throw new ProviderError('bad_output', 'anthropic-api output was not JSON'); }
    },
  };
}
