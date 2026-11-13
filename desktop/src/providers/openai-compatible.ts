import { DEFAULT_TIMEOUT_MS, ProviderError } from './types.ts';
import type { Provider } from './types.ts';
import { readImageBase64 } from './spawn.ts';

export function openaiCompatibleProvider(env: Record<string, string | undefined> = process.env): Provider {
  return {
    name: 'openai-compatible',
    async complete(req) {
      const missing = [
        !env.OPENAI_BASE_URL && 'OPENAI_BASE_URL',
        !env.OPENAI_API_KEY && 'OPENAI_API_KEY',
        (!req.model || req.model === 'haiku') && 'an explicit model name',
      ].filter(Boolean);
      if (missing.length) throw new ProviderError('unavailable', `openai-compatible needs ${missing.join(', ')}`);
      const url = env.OPENAI_BASE_URL!.replace(/\/+$/, '') + '/chat/completions';
      const userContent: unknown[] = [{ type: 'text', text: req.prompt }];
      for (const img of req.images ?? []) {
        userContent.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${readImageBase64(img)}` } });
      }
      let res: Response;
      try {
        res = await fetch(url, {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${env.OPENAI_API_KEY}` },
          body: JSON.stringify({
            model: req.model,
            messages: [{ role: 'system', content: req.system }, { role: 'user', content: userContent }],
            response_format: { type: 'json_schema', json_schema: { name: 'result', strict: true, schema: req.schema } },
          }),
          signal: AbortSignal.timeout(req.timeoutMs ?? DEFAULT_TIMEOUT_MS),
        });
      } catch (e: any) {
        if (e?.name === 'TimeoutError' || e?.name === 'AbortError') throw new ProviderError('timeout', 'openai-compatible timed out');
        throw new ProviderError('unavailable', 'openai-compatible could not be reached');
      }
      if (!res.ok) {
        if (res.status === 429) throw new ProviderError('usage_limit', 'openai-compatible rate limited (429)');
        if (res.status === 401 || res.status === 403) throw new ProviderError('not_signed_in', `openai-compatible rejected the key (${res.status})`);
        throw new ProviderError('failed', `openai-compatible failed (${res.status})`);
      }
      const body: any = await res.json().catch(() => undefined);
      const text = body?.choices?.[0]?.message?.content;
      if (typeof text !== 'string') throw new ProviderError('bad_output', 'openai-compatible returned no text');
      try { return { value: JSON.parse(text), model: req.model }; } catch { throw new ProviderError('bad_output', 'openai-compatible output was not JSON'); }
    },
  };
}
