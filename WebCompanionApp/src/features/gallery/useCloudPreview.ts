import { useCallback, useEffect, useRef, useState } from 'react';

import {
  cancelCloudPreview,
  downloadLegacyCloudPreview,
  fetchCloudPreviewSnapshot,
  startCloudPreview,
} from '@/api/assets';
import type { CloudPreviewSnapshot } from '@/api/contracts/asset';
import { APIError, errorMessage } from '@/api/errors';

export type CloudPreviewState = {
  status: 'available' | 'downloading' | 'cancelling' | 'failed';
  progress: number;
  message: string;
};

type ActiveOperation = {
  assetID: string;
  operationID: string;
  generation: number;
  status: CloudPreviewState['status'] | 'completed';
};

type UseCloudPreviewOptions = {
  assetID: string;
  active: boolean;
  supportsLifecycle: boolean;
  online: boolean;
  onCompleted: () => void;
};

const initialState: CloudPreviewState = {
  status: 'available',
  progress: 0,
  message: '这张照片目前只在 iCloud 中。只会在你确认后获取当前预览。',
};

function cloudFailureMessage(error: unknown, fallback: string): string {
  return error instanceof APIError && error.status === 0 ? errorMessage(error) : fallback;
}

export function useCloudPreview({
  assetID,
  active,
  supportsLifecycle,
  online,
  onCompleted,
}: UseCloudPreviewOptions) {
  const [state, setState] = useState<CloudPreviewState>(initialState);
  const generationRef = useRef(0);
  const activeOperationRef = useRef<ActiveOperation | null>(null);
  const pollTimerRef = useRef<number | null>(null);

  const stopPolling = useCallback(() => {
    if (pollTimerRef.current !== null) window.clearTimeout(pollTimerRef.current);
    pollTimerRef.current = null;
  }, []);

  const isCurrent = useCallback(
    (requestedAssetID: string, generation: number) =>
      requestedAssetID === assetID && generation === generationRef.current,
    [assetID],
  );

  const applySnapshotRef = useRef<(snapshot: CloudPreviewSnapshot, generation: number) => void>(
    () => undefined,
  );

  const poll = useCallback(
    (requestedAssetID: string, generation: number) => {
      stopPolling();
      pollTimerRef.current = window.setTimeout(() => {
        void fetchCloudPreviewSnapshot(requestedAssetID)
          .then((snapshot) => applySnapshotRef.current(snapshot, generation))
          .catch((error: unknown) => {
            if (!isCurrent(requestedAssetID, generation)) return;
            activeOperationRef.current = null;
            setState({
              status: 'failed',
              progress: 0,
              message: cloudFailureMessage(error, '无法读取 iCloud 预览进度，请重试。'),
            });
          });
      }, 320);
    },
    [isCurrent, stopPolling],
  );

  const applySnapshot = useCallback(
    (snapshot: CloudPreviewSnapshot, generation: number) => {
      if (!isCurrent(snapshot.assetID, generation)) return;
      if (snapshot.phase === 'downloading') {
        activeOperationRef.current = {
          assetID: snapshot.assetID,
          operationID: snapshot.operationID,
          generation,
          status: 'downloading',
        };
        setState({
          status: 'downloading',
          progress: snapshot.progress,
          message: 'Mac 正在从 iCloud 获取这张照片的有界预览。',
        });
        poll(snapshot.assetID, generation);
        return;
      }
      stopPolling();
      activeOperationRef.current =
        snapshot.phase === 'completed'
          ? {
              assetID: snapshot.assetID,
              operationID: snapshot.operationID,
              generation,
              status: 'completed',
            }
          : null;
      if (snapshot.phase === 'completed') {
        setState({ status: 'available', progress: 1, message: 'iCloud 预览已获取。' });
        onCompleted();
      } else if (snapshot.phase === 'cancelled') {
        setState({ ...initialState, message: '已停止获取；需要时可以重新开始。' });
      } else {
        setState({
          status: 'failed',
          progress: snapshot.progress,
          message: snapshot.message ?? '无法获取 iCloud 预览。',
        });
      }
    },
    [isCurrent, onCompleted, poll, stopPolling],
  );
  applySnapshotRef.current = applySnapshot;

  useEffect(() => {
    stopPolling();
    generationRef.current += 1;
    setState(initialState);
    if (!active || !supportsLifecycle) return;
    const generation = generationRef.current;
    const controller = new AbortController();
    void fetchCloudPreviewSnapshot(assetID, controller.signal)
      .then((snapshot) => {
        if (snapshot.phase === 'downloading') applySnapshot(snapshot, generation);
      })
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === 'AbortError') return;
        if (error instanceof APIError && error.status === 404) return;
      });
    return () => controller.abort();
  }, [active, applySnapshot, assetID, stopPolling, supportsLifecycle]);

  useEffect(
    () => () => {
      stopPolling();
      generationRef.current += 1;
      const operation = activeOperationRef.current;
      activeOperationRef.current = null;
      if (supportsLifecycle && operation?.status === 'downloading') {
        void cancelCloudPreview(operation.assetID, operation.operationID).catch(() => undefined);
      }
    },
    [assetID, stopPolling, supportsLifecycle],
  );

  const start = useCallback(async () => {
    if (!active || !online || state.status === 'downloading' || state.status === 'cancelling')
      return;
    stopPolling();
    const generation = ++generationRef.current;
    setState({
      status: 'downloading',
      progress: 0,
      message: '正在请 Mac 获取当前照片的 iCloud 预览。',
    });
    if (!supportsLifecycle) {
      try {
        const blob = await downloadLegacyCloudPreview(assetID);
        if (!blob.type.startsWith('image/')) throw new Error('Host 未返回可显示的图片预览');
        if (!isCurrent(assetID, generation)) return;
        setState({ status: 'available', progress: 1, message: 'iCloud 预览已获取。' });
        onCompleted();
      } catch (error) {
        if (!isCurrent(assetID, generation)) return;
        setState({
          status: 'failed',
          progress: 0,
          message: cloudFailureMessage(error, '无法获取 iCloud 预览，请重试。'),
        });
      }
      return;
    }
    const operationID = crypto.randomUUID();
    activeOperationRef.current = {
      assetID,
      operationID,
      generation,
      status: 'downloading',
    };
    try {
      applySnapshot(await startCloudPreview(assetID, operationID), generation);
    } catch (error) {
      if (!isCurrent(assetID, generation)) return;
      activeOperationRef.current = null;
      setState({
        status: 'failed',
        progress: 0,
        message: cloudFailureMessage(error, '无法获取 iCloud 预览，请重试。'),
      });
    }
  }, [
    active,
    applySnapshot,
    assetID,
    isCurrent,
    onCompleted,
    online,
    state.status,
    stopPolling,
    supportsLifecycle,
  ]);

  const cancel = useCallback(async () => {
    const operation = activeOperationRef.current;
    if (!supportsLifecycle || operation?.status !== 'downloading') return;
    stopPolling();
    operation.status = 'cancelling';
    setState((current) => ({ ...current, status: 'cancelling', message: '正在停止获取…' }));
    try {
      applySnapshot(
        await cancelCloudPreview(operation.assetID, operation.operationID),
        operation.generation,
      );
    } catch (error) {
      if (!isCurrent(operation.assetID, operation.generation)) return;
      operation.status = 'downloading';
      setState((current) => ({
        ...current,
        status: 'downloading',
        message: cloudFailureMessage(error, 'Mac 暂时无法取消；仍在继续获取。'),
      }));
      poll(operation.assetID, operation.generation);
    }
  }, [applySnapshot, isCurrent, poll, stopPolling, supportsLifecycle]);

  return { state, start, cancel };
}
