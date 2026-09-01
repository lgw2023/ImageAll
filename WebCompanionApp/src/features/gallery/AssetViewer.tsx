import { useCallback, useEffect, useRef, useState } from 'react';

import { useQuery } from '@tanstack/react-query';
import {
  Check,
  ChevronLeft,
  ChevronRight,
  CloudDownload,
  ExternalLink,
  Heart,
  ImageOff,
  Maximize2,
  Minus,
  Minimize2,
  Plus,
  RotateCcw,
  X,
} from 'lucide-react';

import { assetMediaURL, assetPreviewURL, fetchAssetDetail, openOriginalAsset } from '@/api/assets';
import { fetchCapabilities } from '@/api/capabilities';
import type { AssetDetail, AssetSummary } from '@/api/contracts/asset';
import type { TagDecisionAction } from '@/api/contracts/tag';
import { errorMessage } from '@/api/errors';
import { useConnection } from '@/features/session/ConnectionContext';

import { useAssetPreview } from './useAssetPreview';
import { useCloudPreview } from './useCloudPreview';

type AssetViewerProps = {
  assetID: string;
  mutationPending: boolean;
  onClose: () => void;
  onFavorite: (assetID: string, isFavorite: boolean) => Promise<void>;
  onTagDecision: (tagID: string, assetIDs: string[], action: TagDecisionAction) => Promise<void>;
  previousAsset: AssetSummary | null;
  nextAsset: AssetSummary | null;
  onNavigate: (assetID: string) => void;
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

function suggestionOriginLabel(
  origin: NonNullable<AssetDetail['pendingSuggestions']>[number]['suggestionOrigin'],
) {
  return {
    featurePrint: '特征向量',
    standardModel: '标准模型',
    personalModel: '个人模型',
    personalAdamW: '超级个人模型',
  }[origin];
}

export function AssetViewer({
  assetID,
  mutationPending,
  onClose,
  onFavorite,
  onTagDecision,
  previousAsset,
  nextAsset,
  onNavigate,
}: AssetViewerProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const mediaRef = useRef<HTMLDivElement>(null);
  const suggestionListRef = useRef<HTMLDivElement>(null);
  const panStart = useRef<{ x: number; y: number; left: number; top: number } | null>(null);
  const [zoom, setZoom] = useState(1);
  const [failedPreviewAssetID, setFailedPreviewAssetID] = useState<string | null>(null);
  const [openingOriginal, setOpeningOriginal] = useState(false);
  const [localMessage, setLocalMessage] = useState('');
  const [fullscreen, setFullscreen] = useState(false);
  const [previewReloadGeneration, setPreviewReloadGeneration] = useState(0);
  const [expandedSuggestionAssetID, setExpandedSuggestionAssetID] = useState<string | null>(null);
  const connection = useConnection();
  const detail = useQuery({
    queryKey: ['asset', assetID],
    queryFn: ({ signal }) => fetchAssetDetail(assetID, signal),
  });
  const capabilities = useQuery({
    queryKey: ['capabilities'],
    queryFn: ({ signal }) => fetchCapabilities(signal),
    staleTime: 60_000,
  });
  const imagePreviewEnabled =
    detail.data?.availability === 'available' && detail.data.mediaType.startsWith('image');
  const imagePreview = useAssetPreview(
    assetID,
    detail.data?.contentRevision ?? 0,
    imagePreviewEnabled,
    previewReloadGeneration,
  );
  const handleCloudPreviewCompleted = useCallback(() => {
    setPreviewReloadGeneration((value) => value + 1);
  }, []);
  const cloudPreview = useCloudPreview({
    assetID,
    active: imagePreview.status === 'cloudRequired',
    supportsLifecycle: capabilities.data?.capabilities.includes('cloudPreviewLifecycle') === true,
    online: connection.phase === 'online',
    onCompleted: handleCloudPreviewCompleted,
  });
  const previewFailed = failedPreviewAssetID === assetID;
  const pendingSuggestions = detail.data?.pendingSuggestions ?? [];
  const suggestionsExpanded = expandedSuggestionAssetID === assetID;
  const visibleSuggestions = suggestionsExpanded
    ? pendingSuggestions
    : pendingSuggestions.slice(0, 5);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (!dialog.open && typeof dialog.showModal === 'function') dialog.showModal();
    return () => {
      if (dialog.open) dialog.close();
    };
  }, []);

  useEffect(() => {
    const update = () => setFullscreen(document.fullscreenElement === mediaRef.current);
    document.addEventListener('fullscreenchange', update);
    return () => document.removeEventListener('fullscreenchange', update);
  }, []);

  useEffect(() => {
    const adjacent = [previousAsset, nextAsset].filter(
      (asset): asset is AssetSummary => asset?.mediaType.startsWith('image') === true,
    );
    const preloaders = adjacent.map((asset) => {
      const image = new Image();
      image.src = assetPreviewURL(asset.id, asset.contentRevision);
      return image;
    });
    return () => {
      for (const image of preloaders) image.src = '';
    };
  }, [nextAsset, previousAsset]);

  useEffect(() => {
    const handleNavigation = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'ArrowLeft' && previousAsset) {
        event.preventDefault();
        onNavigate(previousAsset.id);
      } else if (event.key === 'ArrowRight' && nextAsset) {
        event.preventDefault();
        onNavigate(nextAsset.id);
      } else if (event.key === '+' || event.key === '=') {
        event.preventDefault();
        setZoom((value) => Math.min(4, value + 0.25));
      } else if (event.key === '-') {
        event.preventDefault();
        setZoom((value) => Math.max(1, value - 0.25));
      }
    };
    window.addEventListener('keydown', handleNavigation);
    return () => window.removeEventListener('keydown', handleNavigation);
  }, [nextAsset, onNavigate, previousAsset]);

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

  async function toggleFullscreen() {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else await mediaRef.current?.requestFullscreen();
    } catch {
      setLocalMessage('浏览器未允许进入全屏；可继续使用当前大图视图。');
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
          <div className="asset-viewer-header-actions">
            <button
              aria-label={fullscreen ? '退出全屏预览' : '进入全屏预览'}
              className="icon-button"
              disabled={!document.fullscreenEnabled}
              onClick={() => void toggleFullscreen()}
              type="button"
            >
              {fullscreen ? (
                <Minimize2 aria-hidden="true" size={18} />
              ) : (
                <Maximize2 aria-hidden="true" size={18} />
              )}
            </button>
            <button
              aria-label="关闭照片详情"
              className="icon-button"
              onClick={onClose}
              type="button"
            >
              <X aria-hidden="true" size={18} />
            </button>
          </div>
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
            <div
              className="asset-viewer-media"
              data-pannable={zoom > 1}
              onPointerDown={(event) => {
                if (
                  zoom <= 1 ||
                  event.button !== 0 ||
                  (event.target instanceof Element && event.target.closest('button'))
                )
                  return;
                const media = mediaRef.current;
                if (!media) return;
                media.setPointerCapture(event.pointerId);
                panStart.current = {
                  x: event.clientX,
                  y: event.clientY,
                  left: media.scrollLeft,
                  top: media.scrollTop,
                };
              }}
              onPointerMove={(event) => {
                const start = panStart.current;
                const media = mediaRef.current;
                if (!start || !media) return;
                media.scrollLeft = start.left - (event.clientX - start.x);
                media.scrollTop = start.top - (event.clientY - start.y);
              }}
              onPointerUp={() => {
                panStart.current = null;
              }}
              ref={mediaRef}
            >
              {detail.data.availability !== 'available' || previewFailed ? (
                <div className="viewer-media-placeholder">
                  <ImageOff aria-hidden="true" size={30} />
                  <span>当前无法显示预览</span>
                </div>
              ) : detail.data.mediaType.startsWith('video') ? (
                <video
                  controls
                  onError={() => setFailedPreviewAssetID(assetID)}
                  src={assetMediaURL(detail.data.assetID, detail.data.contentRevision)}
                />
              ) : imagePreview.status === 'cloudRequired' ? (
                <div className="viewer-cloud-preview" role="status">
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
                      <span aria-live="polite">
                        {Math.round(cloudPreview.state.progress * 100)}%
                      </span>
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
              ) : imagePreview.status === 'loading' ? (
                <div className="viewer-media-placeholder" role="status">
                  <span>正在载入预览…</span>
                </div>
              ) : imagePreview.status === 'failed' || !imagePreview.url ? (
                <div className="viewer-media-placeholder" role="alert">
                  <ImageOff aria-hidden="true" size={30} />
                  <span>{imagePreview.message ?? '当前无法显示预览'}</span>
                </div>
              ) : (
                <img
                  alt={viewerTitle(detail.data)}
                  onError={() => setFailedPreviewAssetID(assetID)}
                  src={imagePreview.url}
                  style={{
                    width: `${String(zoom * 100)}%`,
                    height: `${String(zoom * 100)}%`,
                    maxWidth: 'none',
                    maxHeight: 'none',
                  }}
                />
              )}
              {!detail.data.mediaType.startsWith('video') && imagePreview.status === 'ready' ? (
                <div className="viewer-media-controls" aria-label="预览缩放">
                  <button
                    aria-label="缩小预览"
                    className="icon-button"
                    disabled={zoom <= 1}
                    onClick={() => setZoom((value) => Math.max(1, value - 0.25))}
                    type="button"
                  >
                    <Minus aria-hidden="true" size={15} />
                  </button>
                  <span aria-live="polite">{Math.round(zoom * 100)}%</span>
                  <button
                    aria-label="放大预览"
                    className="icon-button"
                    disabled={zoom >= 4}
                    onClick={() => setZoom((value) => Math.min(4, value + 0.25))}
                    type="button"
                  >
                    <Plus aria-hidden="true" size={15} />
                  </button>
                  <button
                    aria-label="重置预览缩放"
                    className="icon-button"
                    disabled={zoom === 1}
                    onClick={() => setZoom(1)}
                    type="button"
                  >
                    <RotateCcw aria-hidden="true" size={14} />
                  </button>
                </div>
              ) : null}
              <button
                aria-label="上一张照片"
                className="icon-button viewer-previous"
                disabled={!previousAsset}
                onClick={() => previousAsset && onNavigate(previousAsset.id)}
                type="button"
              >
                <ChevronLeft aria-hidden="true" size={20} />
              </button>
              <button
                aria-label="下一张照片"
                className="icon-button viewer-next"
                disabled={!nextAsset}
                onClick={() => nextAsset && onNavigate(nextAsset.id)}
                type="button"
              >
                <ChevronRight aria-hidden="true" size={20} />
              </button>
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

              {pendingSuggestions.length > 0 ? (
                <section className="asset-suggestions" aria-labelledby="asset-suggestions-title">
                  <div className="asset-tags-heading">
                    <h3 id="asset-suggestions-title">待审 AI 建议</h3>
                    <span>{String(pendingSuggestions.length)} 条</span>
                  </div>
                  <div className="asset-suggestion-list" ref={suggestionListRef}>
                    {visibleSuggestions.map((suggestion, index) => (
                      <article
                        className="asset-suggestion-row"
                        key={`${suggestion.tagID}:${suggestion.suggestionOrigin}`}
                      >
                        <div>
                          <strong>{suggestion.displayName}</strong>
                          <span>{suggestionOriginLabel(suggestion.suggestionOrigin)}</span>
                        </div>
                        <div aria-label={`${suggestion.displayName} AI 建议`} role="group">
                          <button
                            aria-label={`属于 ${suggestion.displayName}`}
                            className="button"
                            data-action="accept"
                            data-suggestion-index={index}
                            disabled={mutationPending || connection.phase !== 'online'}
                            onClick={() =>
                              void onTagDecision(suggestion.tagID, [detail.data.assetID], 'accept')
                            }
                            type="button"
                          >
                            属于
                          </button>
                          <button
                            aria-label={`不属于 ${suggestion.displayName}`}
                            className="button"
                            data-action="reject"
                            data-suggestion-index={index}
                            disabled={mutationPending || connection.phase !== 'online'}
                            onClick={() =>
                              void onTagDecision(suggestion.tagID, [detail.data.assetID], 'reject')
                            }
                            type="button"
                          >
                            不属于
                          </button>
                        </div>
                      </article>
                    ))}
                  </div>
                  {!suggestionsExpanded && pendingSuggestions.length > 5 ? (
                    <button
                      className="button asset-suggestion-expand"
                      onClick={() => {
                        setExpandedSuggestionAssetID(assetID);
                        requestAnimationFrame(() => {
                          suggestionListRef.current
                            ?.querySelector<HTMLElement>('[data-suggestion-index="5"]')
                            ?.focus();
                        });
                      }}
                      type="button"
                    >
                      另外 {String(pendingSuggestions.length - 5)} 条建议
                    </button>
                  ) : null}
                </section>
              ) : null}

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
