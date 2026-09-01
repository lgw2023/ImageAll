import { useCallback, useEffect, useRef, useState } from 'react';

import { useQuery } from '@tanstack/react-query';
import {
  Check,
  ChevronLeft,
  ChevronRight,
  CloudDownload,
  ImageOff,
  SkipForward,
  X,
} from 'lucide-react';

import { fetchCapabilities } from '@/api/capabilities';
import type { ReviewDecisionAction, ReviewQueueItem } from '@/api/contracts/review';
import { useAssetPreview } from '@/features/gallery/useAssetPreview';
import { useCloudPreview } from '@/features/gallery/useCloudPreview';
import { useConnection } from '@/features/session/ConnectionContext';

const originLabels = {
  featurePrint: '特征向量',
  standardModel: '标准模型',
  personalModel: '个人模型',
  personalAdamW: '超级个人模型',
} as const;

type ReviewSinglePhotoDialogProps = {
  canMoveNext: boolean;
  canMovePrevious: boolean;
  item: ReviewQueueItem;
  message: string;
  onClose: () => void;
  onDecision: (action: ReviewDecisionAction) => void;
  onDefer: () => void;
  onMove: (offset: number) => void;
  pending: boolean;
  position: number;
  total: number;
};

export function ReviewSinglePhotoDialog({
  canMoveNext,
  canMovePrevious,
  item,
  message,
  onClose,
  onDecision,
  onDefer,
  onMove,
  pending,
  position,
  total,
}: ReviewSinglePhotoDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const [previewReloadGeneration, setPreviewReloadGeneration] = useState(0);
  const connection = useConnection();
  const title = item.fileName ?? `照片 ${item.assetID.slice(0, 8)}`;
  const revision = item.contentRevision ?? 0;
  const preview = useAssetPreview(
    item.assetID,
    revision,
    item.availability === 'available',
    previewReloadGeneration,
  );
  const capabilities = useQuery({
    queryKey: ['capabilities'],
    queryFn: ({ signal }) => fetchCapabilities(signal),
    staleTime: 60_000,
  });
  const handleCloudPreviewCompleted = useCallback(() => {
    setPreviewReloadGeneration((value) => value + 1);
  }, []);
  const cloudPreview = useCloudPreview({
    assetID: item.assetID,
    active: preview.status === 'cloudRequired',
    supportsLifecycle: capabilities.data?.capabilities.includes('cloudPreviewLifecycle') === true,
    online: connection.phase === 'online',
    onCompleted: handleCloudPreviewCompleted,
  });

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (!dialog.open && typeof dialog.showModal === 'function') dialog.showModal();
    return () => {
      if (dialog.open) dialog.close();
    };
  }, []);

  useEffect(() => {
    function handleShortcut(event: KeyboardEvent) {
      const target = event.target as HTMLElement | null;
      if (target?.matches('input, select, textarea')) return;
      if (target?.matches('button, a') && (event.key === ' ' || event.key === 'Enter')) return;
      const key = event.key.toLowerCase();
      if (key === 'p' && !pending) onDecision('accept');
      else if (key === 'x' && !pending) onDecision('reject');
      else if (key === 'u' && !pending) onDefer();
      else if (event.key === 'ArrowLeft' && canMovePrevious) onMove(-1);
      else if (event.key === 'ArrowRight' && canMoveNext) onMove(1);
      else if (event.key === ' ') onClose();
      else return;
      event.preventDefault();
    }
    window.addEventListener('keydown', handleShortcut);
    return () => window.removeEventListener('keydown', handleShortcut);
  }, [canMoveNext, canMovePrevious, onClose, onDecision, onDefer, onMove, pending]);

  return (
    <dialog
      aria-label="单图审核"
      className="review-single-photo"
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
      ref={dialogRef}
    >
      <div className="review-single-photo-panel">
        <header className="review-single-photo-header">
          <div>
            <p className="eyebrow">连续审核</p>
            <h2>{title}</h2>
            <p aria-label={`第 ${String(position)} 张，共 ${String(total)} 张`}>
              {position.toLocaleString('zh-CN')} / {total.toLocaleString('zh-CN')} ·{' '}
              {originLabels[item.suggestionOrigin]}
              {item.score === null ? '' : ` · ${(item.score * 100).toFixed(1)}%`}
            </p>
          </div>
          <button aria-label="关闭单图审核" className="icon-button" onClick={onClose} type="button">
            <X aria-hidden="true" size={18} />
          </button>
        </header>

        <div className="review-single-photo-stage">
          {item.availability !== 'available' ? (
            <div className="viewer-media-placeholder">
              <ImageOff aria-hidden="true" size={30} />
              <span>当前照片不可在本机读取</span>
            </div>
          ) : preview.status === 'cloudRequired' ? (
            <div className="viewer-cloud-preview review-cloud-preview" role="status">
              <CloudDownload aria-hidden="true" size={32} />
              <strong>预览仍在 iCloud</strong>
              <p>{cloudPreview.state.message}</p>
              {cloudPreview.state.status === 'downloading' ||
              cloudPreview.state.status === 'cancelling' ? (
                <div className="viewer-cloud-progress">
                  <progress
                    aria-label="iCloud 预览下载进度"
                    max="1"
                    value={cloudPreview.state.progress}
                  />
                  <span aria-live="polite">{Math.round(cloudPreview.state.progress * 100)}%</span>
                </div>
              ) : null}
              {cloudPreview.state.status === 'downloading' ||
              cloudPreview.state.status === 'cancelling' ? (
                <button
                  className="button"
                  disabled={cloudPreview.state.status === 'cancelling'}
                  onClick={() => void cloudPreview.cancel()}
                  type="button"
                >
                  {cloudPreview.state.status === 'cancelling'
                    ? '正在停止…'
                    : '取消获取 iCloud 预览'}
                </button>
              ) : (
                <button
                  className="button"
                  disabled={connection.phase !== 'online'}
                  onClick={() => void cloudPreview.start()}
                  type="button"
                >
                  {cloudPreview.state.status === 'failed'
                    ? '重新获取 iCloud 预览'
                    : '从 iCloud 获取预览'}
                </button>
              )}
            </div>
          ) : preview.status === 'loading' ? (
            <div className="viewer-media-placeholder" role="status">
              <span>正在载入预览…</span>
            </div>
          ) : preview.status === 'failed' || !preview.url ? (
            <div className="viewer-media-placeholder" role="alert">
              <ImageOff aria-hidden="true" size={30} />
              <span>{preview.message ?? '当前无法显示预览'}</span>
            </div>
          ) : (
            <img alt={title} src={preview.url} />
          )}
          <button
            aria-label="上一条建议"
            className="icon-button review-single-photo-previous"
            disabled={!canMovePrevious || pending}
            onClick={() => onMove(-1)}
            type="button"
          >
            <ChevronLeft aria-hidden="true" size={22} />
          </button>
          <button
            aria-label="下一条建议"
            className="icon-button review-single-photo-next"
            disabled={!canMoveNext || pending}
            onClick={() => onMove(1)}
            type="button"
          >
            <ChevronRight aria-hidden="true" size={22} />
          </button>
          {message ? (
            <div className="review-single-photo-feedback" role="status">
              {message}
            </div>
          ) : null}
        </div>

        <footer className="review-single-photo-actions" aria-label="单图审核操作">
          <button
            className="button review-decision-accept"
            disabled={pending}
            onClick={() => onDecision('accept')}
            type="button"
          >
            <Check aria-hidden="true" size={17} /> 属于 <kbd>P</kbd>
          </button>
          <button
            className="button review-decision-reject"
            disabled={pending}
            onClick={() => onDecision('reject')}
            type="button"
          >
            <X aria-hidden="true" size={17} /> 不属于 <kbd>X</kbd>
          </button>
          <button className="button" disabled={pending} onClick={onDefer} type="button">
            <SkipForward aria-hidden="true" size={17} /> 稍后 <kbd>U</kbd>
          </button>
        </footer>
      </div>
    </dialog>
  );
}
