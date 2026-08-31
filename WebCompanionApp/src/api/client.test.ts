import { afterEach, describe, expect, it, vi } from 'vitest';
import { z } from 'zod';

import { setAccountAuthorization } from './credentials';
import { requestJSON } from './client';

afterEach(() => {
  setAccountAuthorization(null);
  vi.unstubAllGlobals();
});

describe('API session recovery', () => {
  it('coalesces concurrent 401 responses into one refresh before retrying each request', async () => {
    let releaseRefresh: () => void = () => {
      throw new Error('Refresh gate was not initialized');
    };
    const refreshGate = new Promise<void>((resolve) => {
      releaseRefresh = resolve;
    });
    const attempts = new Map<string, number>();
    let refreshCount = 0;

    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: RequestInfo | URL) => {
        const url =
          typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
        if (url === '/web/session/refresh') {
          refreshCount += 1;
          await refreshGate;
          return new Response(null, { status: 204 });
        }

        const attempt = (attempts.get(url) ?? 0) + 1;
        attempts.set(url, attempt);
        if (attempt === 1) return new Response(null, { status: 401 });
        return Response.json({ recovered: true });
      }),
    );

    const schema = z.object({ recovered: z.literal(true) });
    const first = requestJSON('/v1/first', schema);
    const second = requestJSON('/v1/second', schema);

    await vi.waitFor(() => expect(refreshCount).toBe(1));
    releaseRefresh();

    await expect(Promise.all([first, second])).resolves.toEqual([
      { recovered: true },
      { recovered: true },
    ]);
    expect(refreshCount).toBe(1);
    expect(attempts).toEqual(
      new Map([
        ['/v1/first', 2],
        ['/v1/second', 2],
      ]),
    );
  });
});
