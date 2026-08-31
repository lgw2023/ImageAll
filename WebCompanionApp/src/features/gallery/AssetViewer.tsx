import { useEffect, useRef, useState } from 'react';

import { useQuery } from '@tanstack/react-query';
import { Check, ExternalLink, Heart, ImageOff, RotateCcw, X } from 'lucide-react';

import { assetMediaURL, assetPreviewURL, fetchAssetDetail, openOriginalAsset } from '@/api/assets';
import type { AssetDetail } from '@/api/contracts/asset';
import type { TagDecisionAction } from '@/api/contracts/tag';
import { errorMessage } from '@/api/errors';

type AssetViewerProps = {
  assetID: string;
  mutationPending: boolean;
  onClose: () => void;
  onFavorite: (assetID: string, isFavorite: boolean) => Promise<void>;
  onTagDecision: (tagID: string, assetIDs: string[], action: TagDecisionAction) => Promise<void>;
};

function formatDate(value: number | null): string {
  if (value === null) return '—';
  return new Intl.DateTimeFormat('zh-CN', { dateStyle: 'medium', timeStyle: 'short' }).format(
    value,
  );
}

function formatBytes(value: number | null): string {
  if (value === null) return '—';
  if (value < 1024) return `${String(value)} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / 1024 / 1024).toFixed(1)} MiB`;
}

function viewerTitle(detail: AssetDetail): string {
  return detail.fileName ?? detail.relativePath ?? `照片 ${detail.assetID.slice(0, 8)}`;
}

export function AssetViewer({
  assetID,
  mutationPending,
  onClose,
  onFavorite,
  onTagDecision,
}: AssetViewerProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const [previewFailed, setPreviewFailed] = useState(false);
  const [openingOriginal, setOpeningOriginal] = useState(false);
  const [localMessage, setLocalMessage] = useState('');
  const detail = useQuery({
    queryKey: ['asset', assetID],
    queryFn: ({ signal }) => fetchAssetDetail(assetID, signal),
  });

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (!dialog.open && typeof dialog.showModal === 'function') dialog.showModal();
    return () => {
      if (dialog.open) dialog.close();
    };
  }, []);

  async function requestOpenOriginal() {
    setOpeningOriginal(true);
    setLocalMessage('');
    try {
      await openOriginalAsset(assetID);
      setLocalMessage('已请求 Mac 打开原片。');
    } catch (error) {
      setLocalMessage(errorMessage(error));
    } finally {
      setOpeningOriginal(false);
    }
  }

  return (
    <dialog
      aria-labelledby="asset-viewer-title"
      className="asset-viewer"
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
      ref={dialogRef}
    >
      <div className="asset-viewer-panel">
        <header className="asset-viewer-header">
          <div>
            <p className="eyebrow">照片详情</p>
            <h2 id="asset-viewer-title">
              {detail.data ? viewerTitle(detail.data) : '正在载入照片…'}
            </h2>
          </div>
          <button aria-label="关闭照片详情" className="icon-button" onClick={onClose} type="button">
            <X aria-hidden="true" size={18} />
          </button>
        </header>

        {detail.isError ? (
          <div className="viewer-error" role="alert">
            <strong>无法载入照片详情</strong>
            <p>{errorMessage(detail.error)}</p>
            <button className="button" onClick={() => void detail.refetch()} type="button">
              重试
            </button>
          </div>
        ) : null}

        {detail.data ? (
          <div className="asset-viewer-content">
            <div className="asset-viewer-media">
              {previewFailed || detail.data.availability !== 'available' ? (
                <div className="viewer-media-placeholder">
                  <ImageOff aria-hidden="true" size={30} />
                  <span>当前无法显示预览</span>
                </div>
              ) : detail.data.mediaType.startsWith('video') ? (
                <video
                  controls
                  onError={() => setPreviewFailed(true)}
                  src={assetMediaURL(detail.data.assetID, detail.data.contentRevision)}
                />
              ) : (
                <img
                  alt={viewerTitle(detail.data)}
                  onError={() => setPreviewFailed(true)}
                  src={assetPreviewURL(detail.data.assetID, detail.data.contentRevision)}
                />
              )}
            </div>

            <aside className="asset-detail-sidebar" aria-label="照片属性与标签">
              <div className="asset-detail-actions">
                {detail.data.favorite ? (
                  <button
                    aria-pressed={detail.data.favorite.isFavorite}
                    className="button"
                    disabled={mutationPending}
                    onClick={() =>
                      void onFavorite(detail.data.assetID, !detail.data.favorite?.isFavorite)
                    }
                    type="button"
                  >
                    <Heart
                      aria-hidden="true"
                      fill={detail.data.favorite.isFavorite ? 'currentColor' : 'none'}
                      size={16}
                    />
                    {detail.data.favorite.isFavorite ? '取消收藏' : '收藏'}
                  </button>
                ) : null}
                <button
                  className="button"
                  disabled={openingOriginal}
                  onClick={() => void requestOpenOriginal()}
                  type="button"
                >
                  <ExternalLink aria-hidden="true" size={16} />
                  {openingOriginal ? '正在请求…' : '在 Mac 打开'}
                </button>
              </div>

              <dl className="asset-detail-metadata">
                <div>
                  <dt>来源</dt>
                  <dd>{detail.data.sourceName}</dd>
                </div>
                <div>
                  <dt>相对路径</dt>
                  <dd>{detail.data.relativePath ?? '—'}</dd>
                </div>
                <div>
                  <dt>尺寸</dt>
                  <dd>
                    {detail.data.width !== null && detail.data.height !== null
                      ? `${String(detail.data.width)} × ${String(detail.data.height)}`
                      : '—'}
                  </dd>
                </div>
                <div>
                  <dt>拍摄时间</dt>
                  <dd>{formatDate(detail.data.mediaCreatedAtMs)}</dd>
                </div>
                <div>
                  <dt>指纹占用</dt>
                  <dd>{formatBytes(detail.data.fingerprintSizeBytes)}</dd>
                </div>
              </dl>

              <section className="asset-tags" aria-labelledby="asset-tags-title">
                <div className="asset-tags-heading">
                  <h3 id="asset-tags-title">标签</h3>
                  <span>
                    {String(detail.data.acceptedTagCount)} 确认 ·{' '}
                    {String(detail.data.rejectedTagCount)} 拒绝
                  </span>
                </div>
                <div className="asset-tag-list">
                  {detail.data.tags.map((tag) => (
                    <div className="asset-tag-row" data-decision={tag.decision} key={tag.tagID}>
                      <span>{tag.displayName}</span>
                      <div>
                        <button
                          aria-label={`确认标签 ${tag.displayName}`}
                          aria-pressed={tag.decision === 'accepted'}
                          className="icon-button"
                          disabled={mutationPending}
                          onClick={() =>
                            void onTagDecision(tag.tagID, [detail.data.assetID], 'accept')
                          }
                          type="button"
                        >
                          <Check aria-hidden="true" size={15} />
                        </button>
                        <button
                          aria-label={`拒绝标签 ${tag.displayName}`}
                          aria-pressed={tag.decision === 'rejected'}
                          className="icon-button"
                          disabled={mutationPending}
                          onClick={() =>
                            void onTagDecision(tag.tagID, [detail.data.assetID], 'reject')
                          }
                          type="button"
                        >
                          <X aria-hidden="true" size={15} />
                        </button>
                        <button
                          aria-label={`清除标签决定 ${tag.displayName}`}
                          className="icon-button"
                          disabled={mutationPending || tag.decision === 'unknown'}
                          onClick={() =>
                            void onTagDecision(tag.tagID, [detail.data.assetID], 'clear')
                          }
                          type="button"
                        >
                          <RotateCcw aria-hidden="true" size={14} />
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </section>
              <p aria-live="polite" className="viewer-local-message">
                {localMessage}
              </p>
            </aside>
          </div>
        ) : null}
      </div>
    </dialog>
  );
}
