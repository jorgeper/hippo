export interface ModelRequest { system: string; prompt: string; images?: string[]; schema: object; model: string; timeoutMs?: number }
export type ProviderErrorCode = 'usage_limit' | 'not_signed_in' | 'timeout' | 'bad_output' | 'unavailable' | 'failed';

export class ProviderError extends Error {
  code: ProviderErrorCode;
  constructor(code: ProviderErrorCode, message: string) {
    super(message);
    this.name = 'ProviderError';
    this.code = code;
  }
}

export interface Provider { name: string; complete(req: ModelRequest): Promise<{ value: unknown; model: string }> }

export const DEFAULT_TIMEOUT_MS = 120_000;

/** Maps free text from a failed model call to an error code. */
export function classifyFailure(text: string): ProviderErrorCode {
  if (/usage limit|rate limit|limit reached|hit your .*limit|quota|too many requests/i.test(text)) return 'usage_limit';
  if (/not logged in|not signed in|please run \/login|\/login|sign in|log in|unauthorized|invalid api key|authentication/i.test(text)) return 'not_signed_in';
  return 'failed';
}
