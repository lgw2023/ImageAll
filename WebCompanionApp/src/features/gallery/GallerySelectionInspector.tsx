import { useEffect, useState } from 'react';

import { useQuery } from '@tanstack/react-query';
import { Heart, Maximize2, Trash2, X } from 'lucide-react';

import { fetchAssetDetail } from '@/api/assets';
import type { AssetAvailability, AssetSummary } from '@/api/contracts/asset';
import type {
  TagDecisionAction,
  TagGroupSummary,
  TagSelectionAggregate,
  TagSummary,
} from '@/api/contracts/tag';
import { errorMessage } from '@/api/errors';
import { groupTagsByHostCatalog } from '@/features/tags/tagGrouping';

const availabilityCopy: Record<AssetAvailability, string> = {
  available: '可用',
  missing: '文件缺失',
  unreadable: '无法读取',
  unsupported: '格式不支持',
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

function formatDuration(value: number | null): string {
  if (value === null) return '—';
  const totalSeconds = Math.floor(value / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${String(minutes)}:${String(seconds).padStart(2, '0')}`;
}

function aggregateState(
  aggregate: TagSelectionAggregate | undefined,
  selectionCount: number,
): '已确认' | '已拒绝' | '未决定' | '状态不一致' {
  if (!aggregate) return '未决定';
  if (aggregate.acceptedCount === selectionCount) return '已确认';
  if (aggregate.rejectedCount === selectionCount) return '已拒绝';
  if (aggregate.unknownCount === selectionCount) return '未决定';
  return '状态不一致';
}

type GallerySelectionInspectorProps = {
  aggregates: TagSelectionAggregate[];
  assets: AssetSummary[];
  mutationPending: boolean;
  onClear: () => void;
  onDelete: () => void;
  onFavorite: (assetIDs: string[], isFavorite: boolean) => Promise<void>;
  onOpen: (assetID: string) => void;
  onTagDecision: (
    tagID: string,
    assetIDs: string[],
    action: TagDecisionAction,
    operationID: string,
  ) => Promise<boolean>;
  statusMessage: string;
  tagCatalog: TagSummary[];
  tagGroups: TagGroupSummary[];
};

export function GallerySelectionInspector({
  aggregates,
  assets,
  mutationPending,
  onClear,
  onDelete,
  onFavorite,
  onOpen,
  onTagDecision,
  statusMessage,
  tagCatalog,
  tagGroups,
}: GallerySelectionInspectorProps) {
  const [returnFocusTagID, setReturnFocusTagID] = useState<string | null>(null);
  const [retryDecision, setRetryDecision] = useState<{
    tagID: string;
    action: TagDecisionAction;
    operationID: string;
  } | null>(null);
  const singleAsset = assets.length === 1 ? assets[0] : null;
  const detail = useQuery({
    queryKey: ['asset', singleAsset?.id],
    queryFn: ({ signal }) => fetchAssetDetail(singleAsset?.id ?? '', signal),
    enabled: singleAsset !== null,
  });
  const aggregateByTagID = new Map(aggregates.map((aggregate) => [aggregate.tagID, aggregate]));
  const groupedTags = groupTagsByHostCatalog(tagCatalog, tagGroups, tagCatalog, (tag) => tag.id);
  const assetIDs = assets.map((asset) => asset.id);
  const allFavorited = assets.every((asset) => asset.favorite?.isFavorite === true);

  useEffect(() => {
    if (mutationPending || !returnFocusTagID) return;
    const frame = requestAnimationFrame(() => {
      document
        .querySelector<HTMLButtonElement>(`[data-context-tag-id="${CSS.escape(returnFocusTagID)}"]`)
        ?.focus({ preventScroll: true });
      setReturnFocusTagID(null);
    });
    return () => cancelAnimationFrame(frame);
  }, [mutationPending, returnFocusTagID]);

  async function decide(
    tagID: string,
    action: TagDecisionAction,
    operationID: string = crypto.randomUUID(),
  ) {
    setReturnFocusTagID(tagID);
    const succeeded = await onTagDecision(tagID, assetIDs, action, operationID);
    setRetryDecision(succeeded ? null : { tagID, action, operationID });
  }

  function handleTagKeyboard(tagID: string, event: React.KeyboardEvent<HTMLButtonElement>) {
    if (mutationPending) return;
    if (event.key.toLowerCase() === 'x') {
      event.preventDefault();
      void decide(tagID, 'reject');
    } else if (event.key === 'Backspace' || event.key === 'Delete') {
      event.preventDefault();
      void decide(tagID, 'clear');
    }
  }

  return (
    <section className="gallery-selection-inspector" aria-label="所选照片信息">
      {singleAsset ? (
        detail.isPending ? (
          <div className="context-inspector-state" role="status">
            正在读取照片信息…
          </div>
        ) : detail.isError ? (
          <div className="context-inspector-state context-inspector-error" role="alert">
            <strong>无法读取照片信息</strong>
            <p>{errorMessage(detail.error)}</p>
            <button className="button" onClick={() => void detail.refetch()} type="button">
              重试
            </button>
          </div>
        ) : (
          <>
            <div className="context-inspector-identity">
              <span>{detail.data.mediaType.startsWith('video') ? '视频' : '照片'}</span>
              <strong>
                {detail.data.fileName ??
                  detail.data.relativePath ??
                  detail.data.assetID.slice(0, 8)}
              </strong>
              <small>{detail.data.sourceName}</small>
            </div>
            <dl className="metadata-list context-metadata-list">
              <div>
                <dt>文件名</dt>
                <dd>{detail.data.fileName ?? '—'}</dd>
              </div>
              <div>
                <dt>来源</dt>
                <dd>{detail.data.sourceName}</dd>
              </div>
              <div>
                <dt>相对位置</dt>
                <dd>{detail.data.relativePath ?? '—'}</dd>
              </div>
              <div>
                <dt>媒体</dt>
                <dd>{detail.data.mediaType.startsWith('video') ? '视频' : '照片'}</dd>
              </div>
              <div>
                <dt>格式</dt>
                <dd>{detail.data.mediaType}</dd>
              </div>
              <div>
                <dt>尺寸</dt>
                <dd>
                  {detail.data.width !== null && detail.data.height !== null
                    ? `${String(detail.data.width)} × ${String(detail.data.height)}`
                    : '—'}
                </dd>
              </div>
              {detail.data.durationMs !== null ? (
                <div>
                  <dt>时长</dt>
                  <dd>{formatDuration(detail.data.durationMs)}</dd>
                </div>
              ) : null}
              <div>
                <dt>文件大小</dt>
                <dd>{formatBytes(detail.data.fingerprintSizeBytes)}</dd>
              </div>
              <div>
                <dt>拍摄时间</dt>
                <dd>{formatDate(detail.data.mediaCreatedAtMs)}</dd>
              </div>
              <div>
                <dt>修改时间</dt>
                <dd>{formatDate(detail.data.mediaModifiedAtMs)}</dd>
              </div>
              <div>
                <dt>状态</dt>
                <dd>{availabilityCopy[detail.data.availability]}</dd>
              </div>
            </dl>
          </>
        )
      ) : (
        <div className="context-inspector-identity">
          <span>冻结选择</span>
          <strong>{assets.length.toLocaleString('zh-CN')} 个项目</strong>
          <small>{new Set(assets.map((asset) => asset.sourceID)).size} 个来源</small>
        </div>
      )}

      <div className="context-selection-actions" aria-label="所选照片操作">
        {singleAsset ? (
          <button className="button" onClick={() => onOpen(singleAsset.id)} type="button">
            <Maximize2 aria-hidden="true" size={14} /> 打开大图
          </button>
        ) : null}
        <button
          aria-disabled={mutationPending}
          aria-label={`${allFavorited ? '取消收藏' : '收藏'}所选 ${assets.length.toLocaleString('zh-CN')} 项`}
          className="button"
          onClick={() => {
            if (!mutationPending) void onFavorite(assetIDs, !allFavorited);
          }}
          type="button"
        >
          <Heart aria-hidden="true" fill={allFavorited ? 'currentColor' : 'none'} size={14} />
          {allFavorited ? '取消收藏' : '收藏'}
        </button>
        <button
          aria-label={`删除所选 ${assets.length.toLocaleString('zh-CN')} 项`}
          className="button button-danger"
          onClick={onDelete}
          type="button"
        >
          <Trash2 aria-hidden="true" size={14} /> 删除
        </button>
        <button className="button" onClick={onClear} type="button">
          <X aria-hidden="true" size={14} /> 清除选择
        </button>
      </div>

      {groupedTags.length ? (
        <div className="context-tag-catalog" aria-label="所选照片标签">
          <div className="context-section-heading">
            <h3>标签</h3>
            <span>点击确认 · X 拒绝 · Delete 清除</span>
          </div>
          {groupedTags.map(({ group, tags }) => (
            <section aria-label={group.displayName} key={group.id}>
              <h4>{group.displayName}</h4>
              <div className="context-tag-list">
                {tags.map((tag) => {
                  const state = aggregateState(aggregateByTagID.get(tag.id), assets.length);
                  return (
                    <button
                      aria-disabled={mutationPending}
                      aria-label={`标签 ${tag.displayName}，${state}`}
                      className="context-tag-chip"
                      data-context-tag-id={tag.id}
                      data-state={state}
                      key={tag.id}
                      onClick={() => {
                        if (!mutationPending) void decide(tag.id, 'accept');
                      }}
                      onContextMenu={(event) => {
                        event.preventDefault();
                        if (!mutationPending) void decide(tag.id, 'clear');
                      }}
                      onKeyDown={(event) => handleTagKeyboard(tag.id, event)}
                      type="button"
                    >
                      <span>{tag.displayName}</span>
                      <small>{state}</small>
                    </button>
                  );
                })}
              </div>
            </section>
          ))}
        </div>
      ) : null}

      {statusMessage ? <p className="context-inspector-message">{statusMessage}</p> : null}
      {retryDecision ? (
        <button
          className="button"
          disabled={mutationPending}
          onClick={() =>
            void decide(retryDecision.tagID, retryDecision.action, retryDecision.operationID)
          }
          type="button"
        >
          重试标签决定
        </button>
      ) : null}
    </section>
  );
}
