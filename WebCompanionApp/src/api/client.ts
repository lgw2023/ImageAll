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

/** Diagnose only after a failed media element request. Never fetch a full original. */
export async function inspectVideoFailure(path: string, signal: AbortSignal): Promise<string> {
  const response = await rawFetch(path, { signal, headers: { Range: 'bytes=0-0' } });
  if (response.status !== 404) {
    await response.body?.cancel();
    if (response.status === 401 || response.status === 403)
      return '视频访问授权已失效，请重新连接 Mac 后重试。';
    if (response.status === 409) return '视频已变化，请刷新详情后重试。';
    if (response.ok)
      return 'Mac 已能读取视频，但浏览器未能播放。请重试，或在 Mac ImageAll／系统播放器中查看。';
    return '视频当前不可用，请检查 Mac 连接和来源后重试。';
  }
  const reader = response.body?.getReader();
  if (!reader) return '视频当前不可用，请检查 Mac 来源后重试。';
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    let part = await reader.read();
    while (!part.done) {
      const value = part.value;
      total += value.byteLength;
      if (total > 8192) return 'Mac 返回了无法识别的视频状态，请重试。';
      chunks.push(value);
      part = await reader.read();
    }
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    const payload: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (payload && typeof payload === 'object' && 'mediaFailureReason' in payload) {
      if (payload.mediaFailureReason === 'cloudVideoOriginalRequired')
        return '视频原件仍在 iCloud。请在 Mac ImageAll 打开此视频并明确获取原件，完成后重试播放；网页不会自动下载原件。';
      if (payload.mediaFailureReason === 'unsupportedVideoRepresentation')
        return 'Photos 返回了编辑合成资源。请在 Mac“照片”中播放，或导出视频文件并接入 ImageAll 后重试。';
    }
    return '视频原件在 Mac 本机不可用。请检查来源；若原件在 iCloud，请先在 Mac 明确获取后重试。';
  } catch {
    return '视频当前不可用，请检查 Mac 来源后重试。';
  } finally {
    await reader.cancel();
  }
}
