import { useEffect, useState } from 'react';

import { assetPreviewURL } from '@/api/assets';
import { requestBlob } from '@/api/client';
import { APIError, errorMessage } from '@/api/errors';

export type AssetPreviewState =
  | { status: 'idle' | 'loading'; url: null; message: null }
  | { status: 'ready'; url: string; message: null }
  | { status: 'cloudRequired' | 'failed'; url: null; message: string };

function requiresCloudPreview(error: unknown): boolean {
  return (
    error instanceof APIError &&
    error.status === 409 &&
    error.message.toLocaleLowerCase().includes('cloud preview required')
  );
}

export function useAssetPreview(
  assetID: string,
  contentRevision: number,
  enabled: boolean,
  reloadGeneration: number,
): AssetPreviewState {
  const requestKey = `${assetID}:${String(contentRevision)}:${String(reloadGeneration)}`;
  const [result, setResult] = useState<{ key: string; preview: AssetPreviewState }>({
    key: '',
    preview: { status: 'idle', url: null, message: null },
  });

  useEffect(() => {
    if (!enabled) return;
    const controller = new AbortController();
    let objectURL: string | null = null;
    void requestBlob(
      `${assetPreviewURL(assetID, contentRevision)}&cloud=${String(reloadGeneration)}`,
      controller.signal,
    )
      .then((blob) => {
        if (!blob.type.startsWith('image/')) throw new Error('Host 未返回可显示的图片预览');
        objectURL = URL.createObjectURL(blob);
        setResult({ key: requestKey, preview: { status: 'ready', url: objectURL, message: null } });
      })
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === 'AbortError') return;
        setResult({
          key: requestKey,
          preview: requiresCloudPreview(error)
            ? { status: 'cloudRequired', url: null, message: '这张照片仅存在于 iCloud。' }
            : { status: 'failed', url: null, message: errorMessage(error) },
        });
      });
    return () => {
      controller.abort();
      if (objectURL) URL.revokeObjectURL(objectURL);
    };
  }, [assetID, contentRevision, enabled, reloadGeneration, requestKey]);

  if (!enabled) return { status: 'idle', url: null, message: null };
  return result.key === requestKey
    ? result.preview
    : { status: 'loading', url: null, message: null };
}
