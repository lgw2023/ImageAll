import { requestBlob } from '@/api/client';

export type ThumbnailLease = {
  promise: Promise<string>;
  release: () => void;
};

type ThumbnailEntry = {
  url: string;
  state: 'queued' | 'loading' | 'ready';
  references: number;
  promise: Promise<string>;
  resolve: (objectURL: string) => void;
  reject: (error: unknown) => void;
  controller: AbortController | null;
  objectURL: string | null;
  evictionTimer: number | null;
};

type ThumbnailLoaderOptions = {
  maximumConcurrent?: number;
  retentionMilliseconds?: number;
  fetchBlob?: (url: string, signal: AbortSignal) => Promise<Blob>;
  createObjectURL?: (blob: Blob) => string;
  revokeObjectURL?: (url: string) => void;
};

function cancelledError() {
  return new DOMException('Thumbnail request cancelled', 'AbortError');
}

export class ThumbnailLoader {
  readonly maximumConcurrent: number;

  private readonly retentionMilliseconds: number;
  private readonly fetchBlob: (url: string, signal: AbortSignal) => Promise<Blob>;
  private readonly createObjectURL: (blob: Blob) => string;
  private readonly revokeObjectURL: (url: string) => void;
  private readonly entries = new Map<string, ThumbnailEntry>();
  private readonly queue: ThumbnailEntry[] = [];
  private activeRequests = 0;

  constructor(options: ThumbnailLoaderOptions = {}) {
    this.maximumConcurrent = options.maximumConcurrent ?? 6;
    this.retentionMilliseconds = options.retentionMilliseconds ?? 5_000;
    this.fetchBlob = options.fetchBlob ?? ((url, signal) => requestBlob(url, signal));
    this.createObjectURL = options.createObjectURL ?? ((blob) => URL.createObjectURL(blob));
    this.revokeObjectURL = options.revokeObjectURL ?? ((url) => URL.revokeObjectURL(url));
  }

  get activeCount(): number {
    return this.activeRequests;
  }

  acquire(url: string): ThumbnailLease {
    let entry = this.entries.get(url);
    if (!entry) {
      let resolve: (objectURL: string) => void = () => undefined;
      let reject: (error: unknown) => void = () => undefined;
      const promise = new Promise<string>((promiseResolve, promiseReject) => {
        resolve = promiseResolve;
        reject = promiseReject;
      });
      entry = {
        url,
        state: 'queued',
        references: 0,
        promise,
        resolve,
        reject,
        controller: null,
        objectURL: null,
        evictionTimer: null,
      };
      this.entries.set(url, entry);
      this.queue.push(entry);
    }

    entry.references += 1;
    if (entry.evictionTimer !== null) {
      window.clearTimeout(entry.evictionTimer);
      entry.evictionTimer = null;
    }
    this.pump();

    let released = false;
    return {
      promise: entry.promise,
      release: () => {
        if (released) return;
        released = true;
        this.release(entry);
      },
    };
  }

  dispose(): void {
    for (const entry of this.entries.values()) {
      entry.controller?.abort();
      if (entry.evictionTimer !== null) window.clearTimeout(entry.evictionTimer);
      if (entry.objectURL) this.revokeObjectURL(entry.objectURL);
      if (entry.state === 'queued') entry.reject(cancelledError());
    }
    this.entries.clear();
    this.queue.length = 0;
  }

  private release(entry: ThumbnailEntry): void {
    entry.references = Math.max(0, entry.references - 1);
    if (entry.references > 0) return;
    if (entry.state === 'queued') {
      this.entries.delete(entry.url);
      entry.reject(cancelledError());
      return;
    }
    if (entry.state === 'loading') {
      this.entries.delete(entry.url);
      entry.controller?.abort();
      return;
    }
    entry.evictionTimer = window.setTimeout(() => {
      if (entry.references > 0 || this.entries.get(entry.url) !== entry) return;
      if (entry.objectURL) this.revokeObjectURL(entry.objectURL);
      this.entries.delete(entry.url);
    }, this.retentionMilliseconds);
  }

  private pump(): void {
    while (this.activeRequests < this.maximumConcurrent) {
      const entry = this.queue.shift();
      if (!entry) return;
      if (this.entries.get(entry.url) !== entry || entry.references === 0) continue;
      this.start(entry);
    }
  }

  private start(entry: ThumbnailEntry): void {
    entry.state = 'loading';
    entry.controller = new AbortController();
    this.activeRequests += 1;
    void this.fetchBlob(entry.url, entry.controller.signal)
      .then((blob) => {
        if (this.entries.get(entry.url) !== entry || entry.references === 0) return;
        entry.objectURL = this.createObjectURL(blob);
        entry.state = 'ready';
        entry.resolve(entry.objectURL);
      })
      .catch((error: unknown) => {
        entry.reject(error);
        if (this.entries.get(entry.url) === entry) this.entries.delete(entry.url);
      })
      .finally(() => {
        this.activeRequests -= 1;
        this.pump();
      });
  }
}

export const thumbnailLoader = new ThumbnailLoader();
