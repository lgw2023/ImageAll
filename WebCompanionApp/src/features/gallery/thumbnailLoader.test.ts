import { afterEach, describe, expect, it, vi } from 'vitest';

import { ThumbnailLoader } from './thumbnailLoader';

afterEach(() => {
  vi.useRealTimers();
});

describe('ThumbnailLoader', () => {
  it('caps concurrency, deduplicates URLs, and revokes retained object URLs', async () => {
    vi.useFakeTimers();
    let inFlight = 0;
    let maximumInFlight = 0;
    const calls: string[] = [];
    const completions: (() => void)[] = [];
    const revoked: string[] = [];
    const loader = new ThumbnailLoader({
      maximumConcurrent: 2,
      retentionMilliseconds: 50,
      fetchBlob: (url) => {
        calls.push(url);
        inFlight += 1;
        maximumInFlight = Math.max(maximumInFlight, inFlight);
        return new Promise<Blob>((resolve) => {
          completions.push(() => {
            inFlight -= 1;
            resolve(new Blob([url]));
          });
        });
      },
      createObjectURL: (blob) => `blob:${String(blob.size)}:${String(calls.length)}`,
      revokeObjectURL: (url) => revoked.push(url),
    });

    const first = loader.acquire('/thumbnail/1');
    const firstDuplicate = loader.acquire('/thumbnail/1');
    const second = loader.acquire('/thumbnail/2');
    const third = loader.acquire('/thumbnail/3');
    expect(calls).toEqual(['/thumbnail/1', '/thumbnail/2']);
    expect(maximumInFlight).toBe(2);

    completions[0]?.();
    await vi.waitFor(() => expect(calls).toContain('/thumbnail/3'));
    completions[1]?.();
    completions[2]?.();
    const URLs = await Promise.all([
      first.promise,
      firstDuplicate.promise,
      second.promise,
      third.promise,
    ]);
    expect(calls.filter((url) => url === '/thumbnail/1')).toHaveLength(1);
    expect(URLs[0]).toBe(URLs[1]);

    first.release();
    firstDuplicate.release();
    second.release();
    third.release();
    await vi.advanceTimersByTimeAsync(50);
    expect(revoked).toHaveLength(3);
  });

  it('aborts an in-flight request after rapid-scroll release', async () => {
    const observedSignals: AbortSignal[] = [];
    const loader = new ThumbnailLoader({
      fetchBlob: (_url, signal) => {
        observedSignals.push(signal);
        return new Promise<Blob>((_resolve, reject) => {
          signal.addEventListener('abort', () =>
            reject(new DOMException('cancelled', 'AbortError')),
          );
        });
      },
    });
    const lease = loader.acquire('/thumbnail/rapid-scroll');
    lease.release();

    await expect(lease.promise).rejects.toMatchObject({ name: 'AbortError' });
    expect(observedSignals[0]?.aborted).toBe(true);
    expect(loader.activeCount).toBe(0);
  });
});
