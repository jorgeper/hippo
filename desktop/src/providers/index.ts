import { loadEnv } from '../core/env.ts';
import { ProviderError } from './types.ts';
import type { Provider } from './types.ts';
import { claudeCliProvider } from './claude-cli.ts';
import { codexCliProvider } from './codex-cli.ts';
import { anthropicApiProvider } from './anthropic-api.ts';
import { openaiCompatibleProvider } from './openai-compatible.ts';
import { fakeProvider } from './fake.ts';

export { ProviderError, fakeProvider };
export type { ModelRequest, Provider, ProviderErrorCode } from './types.ts';

export const providerNames = ['claude-cli', 'codex-cli', 'anthropic-api', 'openai-compatible', 'fake'];

/** `env` defaults to desktop/.env merged under the process environment. */
export function makeProvider(name: string, env: Record<string, string | undefined> = loadEnv()): Provider {
  switch (name) {
    case 'claude-cli': return claudeCliProvider(env);
    case 'codex-cli': return codexCliProvider(env);
    case 'anthropic-api': return anthropicApiProvider(env);
    case 'openai-compatible': return openaiCompatibleProvider(env);
    case 'fake': return fakeProvider();
    default: throw new ProviderError('unavailable', `unknown provider "${name}"; known: ${providerNames.join(', ')}`);
  }
}
