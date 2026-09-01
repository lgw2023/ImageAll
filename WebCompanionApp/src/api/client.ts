import type { z } from 'zod';

import { readAccountAuthorization } from './credentials';
import { APIError, errorFromResponse } from './errors';

let refreshPromise: Promise<boolean> | null = null;

type RequestOptions = Omit<RequestInit, 'credentials' | 'cache'> & {
  canRefresh?: boolean;
};

async function rawFetch(path: string, options: RequestOptions = {}): Promise<Response> {
  const headers = new Headers(options.headers);
  if (!headers.has('Accept')) headers.set('Accept', 'application/json');
  const authorization = readAccountAuthorization();
  if (authorization && !headers.has('Authorization')) headers.set('Authorization', authorization);
  if (options.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
  return fetch(path, {
    ...options,
    headers,
    credentials: 'same-origin',
    cache: 'no-store',
  });
}

async function refreshSession(): Promise<boolean> {
  if (readAccountAuthorization()) return false;
  refreshPromise ??= rawFetch('/web/session/refresh', {
    method: 'POST',
    body: '{}',
    canRefresh: false,
  })
    .then((response) => response.ok)
    .catch(() => false)
    .finally(() => {
      refreshPromise = null;
    });
  return refreshPromise;
}

export async function requestJSON<T>(
  path: string,
  schema: z.ZodType<T>,
  options: RequestOptions = {},
): Promise<T> {
  const { canRefresh = true, ...requestInit } = options;
  let response: Response;
  try {
    response = await rawFetch(path, requestInit);
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw error;
    throw new APIError(0, '无法连接 Mac', undefined, true);
  }

  if (response.status === 401 && canRefresh && (await refreshSession())) {
    return requestJSON(path, schema, { ...requestInit, canRefresh: false });
  }
  if (!response.ok) throw await errorFromResponse(response);
  const contentType = response.headers.get('content-type') ?? '';
  if (!contentType.includes('application/json')) {
    throw new APIError(response.status, '服务器返回了无法识别的数据');
  }
  const result = schema.safeParse(await response.json());
  if (!result.success) {
    throw new APIError(response.status, '服务器数据与当前 Web 版本不兼容');
  }
  return result.data;
}

export async function requestEmpty(path: string, options: RequestOptions): Promise<void> {
  const { canRefresh = true, ...requestInit } = options;
  const response = await rawFetch(path, requestInit);
  if (response.status === 401 && canRefresh && (await refreshSession())) {
    return requestEmpty(path, { ...requestInit, canRefresh: false });
  }
  if (!response.ok) throw await errorFromResponse(response);
}

export async function requestBlob(
  path: string,
  signal?: AbortSignal,
  options: Omit<RequestOptions, 'signal'> = {},
): Promise<Blob> {
  let response: Response;
  try {
    const headers = new Headers(options.headers);
    headers.set('Accept', '*/*');
    response = await rawFetch(path, { ...options, signal: signal ?? null, headers });
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw error;
    throw new APIError(0, '无法连接 Mac', undefined, true);
  }
  if (response.status === 401 && (await refreshSession()))
    return requestBlob(path, signal, options);
  if (!response.ok) throw await errorFromResponse(response);
  return response.blob();
}
