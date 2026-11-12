import type { ModelRequest, Provider } from './types.ts';

/** Canned answers for tests. With no handler the value is `{}`. */
export function fakeProvider(handler?: (req: ModelRequest) => unknown): Provider {
  return {
    name: 'fake',
    async complete(req) {
      return { value: handler ? handler(req) : {}, model: 'fake' };
    },
  };
}
