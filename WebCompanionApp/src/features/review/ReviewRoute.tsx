import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';

import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  Check,
  ChevronLeft,
  Grid3X3,
  Minus,
  Plus,
  Ratio,
  RotateCcw,
  ScanSearch,
  SkipForward,
  X,
} from 'lucide-react';
import { Link, useSearchParams } from 'react-router-dom';

import { fetchSources } from '@/api/assets';
import { fetchCapabilities } from '@/api/capabilities';
import type { ReviewDecisionAction } from '@/api/contracts/review';
import { errorMessage } from '@/api/errors';
import { fetchGeneralSettings, updateGeneralSettings } from '@/api/management';
import {
  applyReviewDecision,
  fetchReviewOverview,
  fetchReviewQueue,
  undoReviewDecision,
} from '@/api/review';

import { ReviewLocalModelPanel } from './ReviewLocalModelPanel';
import { ReviewSinglePhotoDialog } from './ReviewSinglePhotoDialog';
import { ReviewSourceScope } from './ReviewSourceScope';

const originLabels = {
  featurePrint: '视觉相似',
  standardModel: '标准模型',
  personalModel: '个人模型',
  personalAdamW: '个人 AdamW',
} as const;

const emptySelection = new Set<string>();

const reviewDensityOptions = [
  { value: 0, label: '微缩' },
  { value: 1, label: '精细' },
  { value: 2, label: '紧凑' },
  { value: 3, label: '标准' },
  { value: 4, label: '大图' },
  { value: 5, label: '较大' },
  { value: 6, label: '很大' },
  { value: 7, label: '特大' },
  { value: 8, label: '巨大' },
] as const;

function reviewDensity(parameters: URLSearchParams): number {
  const rawValue = parameters.get('density');
  if (rawValue === null) return 3;
  const value = Number(rawValue);
  return Number.isInteger(value) && value >= 0 && value <= 8 ? value : 3;
}

function useScopedSet(scopeKey: string) {
  const [state, setState] = useState({ scopeKey, values: new Set<string>() });
  const values = state.scopeKey === scopeKey ? state.values : emptySelection;
  const setValues = useCallback(
    (update: Set<string> | ((current: Set<string>) => Set<string>)) => {
      setState((current) => {
        const currentValues = current.scopeKey === scopeKey ? current.values : emptySelection;
        return {
          scopeKey,
          values: typeof update === 'function' ? update(currentValues) : update,
        };
      });
    },
    [scopeKey],
  );
  return [values, setValues] as const;
}

function reviewSourceIDs(parameters: URLSearchParams): string[] | null {
  if (parameters.get('sourceScope') === 'none') return [];
  const sourceIDs = [...new Set(parameters.getAll('source').filter(Boolean))];
  return sourceIDs.length ? sourceIDs : null;
}

function scopeKey(sourceIDs: string[] | null) {
  return sourceIDs === null ? 'all' : `sources:${sourceIDs.join(',')}`;
}

function queueHref(tagID: string, search: string) {
  const parameters = new URLSearchParams(search);
  parameters.set('tag', tagID);
  return `/review/queue?${parameters.toString()}`;
}

function overviewHref(search: string) {
  const parameters = new URLSearchParams(search);
  parameters.delete('tag');
  const query = parameters.toString();
  return query ? `/review?${query}` : '/review';
}

type ReviewWorkspaceProps = {
  sourceIDs: string[] | null;
  sourceScope: ReactNode;
  search: string;
};

function ReviewOverview({ sourceIDs, sourceScope, search }: ReviewWorkspaceProps) {
  const queryClient = useQueryClient();
  const sourceScopeKey = scopeKey(sourceIDs);
  const overview = useQuery({
    queryKey: ['review-overview', sourceScopeKey],
    queryFn: ({ signal }) => fetchReviewOverview(sourceIDs, signal),
    placeholderData: (previous) => previous,
  });
  const settings = useQuery({
    queryKey: ['general-settings'],
    queryFn: ({ signal }) => fetchGeneralSettings(signal),
    staleTime: 60_000,
  });
  const capabilities = useQuery({
    queryKey: ['capabilities'],
    queryFn: ({ signal }) => fetchCapabilities(signal),
    staleTime: 60_000,
  });
  const updateLimit = useMutation({
    mutationFn: (value: number) => updateGeneralSettings({ maxPendingSuggestionsPerTag: value }),
    onSuccess: (response) => {
      queryClient.setQueryData(['general-settings'], response.settings);
    },
  });
  const suggestionLimit = settings.data?.maxPendingSuggestionsPerTag ?? null;
  const supportsLibrarySuggestions =
    capabilities.data?.capabilities.includes('librarySuggestions') === true;
  const adjustSuggestionLimit = (delta: number) => {
    if (suggestionLimit === null || updateLimit.isPending) return;
    const next = Math.min(10_000, Math.max(1, suggestionLimit + delta));
    if (next !== suggestionLimit) updateLimit.mutate(next);
  };

  if (overview.isPending)
    return (
      <div className="workspace-state" role="status">
        正在载入审查概览…
      </div>
    );
  if (overview.isError) {
    return (
      <div className="workspace-state workspace-state-error" role="alert">
        <strong>无法载入审查概览</strong>
        <p>{errorMessage(overview.error)}</p>
        <button className="button" onClick={() => void overview.refetch()} type="button">
          重试
        </button>
      </div>
    );
  }

  return (
    <section className="domain-workspace" aria-labelledby="review-title">
      <header className="domain-heading">
        <div>
          <p className="eyebrow">照片</p>
          <h2 id="review-title">审查</h2>
          <p>按标签处理 Host 生成的待确认建议。</p>
        </div>
        <div className="review-heading-actions">
          {sourceScope}
          <div className="review-suggestion-limit-stack">
            <div
              aria-busy={settings.isPending || updateLimit.isPending}
              aria-label="每标签上限"
              className="review-suggestion-limit-control"
              role="group"
            >
              <span className="review-suggestion-limit-label">每标签上限</span>
              <button
                aria-label="减少每标签上限"
                className="icon-button"
                disabled={suggestionLimit === null || suggestionLimit <= 1 || updateLimit.isPending}
                onClick={() => adjustSuggestionLimit(-50)}
                type="button"
              >
                <Minus aria-hidden="true" size={14} />
              </button>
              <output aria-live="polite">
                {suggestionLimit ?? (settings.isPending ? '…' : '只读')}
              </output>
              <button
                aria-label="增加每标签上限"
                className="icon-button"
                disabled={
                  suggestionLimit === null || suggestionLimit >= 10_000 || updateLimit.isPending
                }
                onClick={() => adjustSuggestionLimit(50)}
                type="button"
              >
                <Plus aria-hidden="true" size={14} />
              </button>
            </div>
            {settings.isError || updateLimit.isError ? (
              <span className="review-suggestion-limit-error" role="alert">
                {errorMessage(updateLimit.error ?? settings.error)}
              </span>
            ) : null}
          </div>
          <strong className="large-count">
            {overview.data.totalPendingSuggestionCount.toLocaleString('zh-CN')} 待处理
          </strong>
        </div>
      </header>

      <div className="review-overview-layout" data-models={supportsLibrarySuggestions}>
        {supportsLibrarySuggestions ? <ReviewLocalModelPanel sourceIDs={sourceIDs} /> : null}
        <div className="review-overview-content">
          {overview.data.tags.length ? (
            <div className="review-tag-grid">
              {overview.data.tags.map((tag) => (
                <article className="review-tag-card" key={tag.id}>
                  <div>
                    <h3>{tag.displayName}</h3>
                    <span data-status={tag.taskStatus}>{tag.taskStatus}</span>
                  </div>
                  <strong>{tag.pendingSuggestionCount.toLocaleString('zh-CN')}</strong>
                  <p>
                    已确认 {tag.acceptedSampleCount.toLocaleString('zh-CN')} · 已拒绝{' '}
                    {tag.rejectedSampleCount.toLocaleString('zh-CN')}
                  </p>
                  {tag.canReview && tag.pendingSuggestionCount > 0 ? (
                    <Link className="button button-primary" to={queueHref(tag.id, search)}>
                      开始审查
                    </Link>
                  ) : (
                    <span className="muted-label">当前没有可审查项目</span>
                  )}
                </article>
              ))}
            </div>
          ) : (
            <div className="workspace-state">
              <ScanSearch aria-hidden="true" size={26} />
              <strong>还没有审查标签</strong>
              <p>先在标签库建立样本或运行建议任务。</p>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}

function ReviewQueue({
  tagID,
  sourceIDs,
  sourceScope,
  search,
}: ReviewWorkspaceProps & { tagID: string }) {
  const [viewParameters, setViewParameters] = useSearchParams();
  const queryClient = useQueryClient();
  const gridRef = useRef<HTMLDivElement>(null);
  const hasFocusedGrid = useRef(false);
  const sourceScopeKey = scopeKey(sourceIDs);
  const density = reviewDensity(viewParameters);
  const aspect = viewParameters.get('aspect') === 'original' ? 'original' : 'square';
  const [selected, setSelected] = useScopedSet(sourceScopeKey);
  const [dismissed, setDismissed] = useScopedSet(sourceScopeKey);
  const [message, setMessage] = useState('');
  const [undoID, setUndoID] = useState<string | null>(null);
  const [activeAssetID, setActiveAssetID] = useState<string | null>(null);
  const [previewAssetID, setPreviewAssetID] = useState<string | null>(null);
  const queue = useInfiniteQuery({
    queryKey: ['review-queue', tagID, sourceScopeKey],
    queryFn: ({ pageParam, signal }) => fetchReviewQueue(tagID, sourceIDs, pageParam, signal),
    initialPageParam: null as string | null,
    getNextPageParam: (page) => page.nextCursor ?? undefined,
    placeholderData: (previous) => previous,
  });
  const items = useMemo(
    () =>
      (queue.data?.pages.flatMap((page) => page.items) ?? []).filter(
        (item) => !dismissed.has(item.assetID),
      ),
    [dismissed, queue.data],
  );
  const resolvedActiveAssetID = items.some((item) => item.assetID === activeAssetID)
    ? activeAssetID
    : (items[0]?.assetID ?? null);
  const activeIndex = resolvedActiveAssetID
    ? items.findIndex((item) => item.assetID === resolvedActiveAssetID)
    : -1;
  const previewIndex = previewAssetID
    ? items.findIndex((item) => item.assetID === previewAssetID)
    : -1;
  const previewItem = previewIndex >= 0 ? items[previewIndex] : null;
  const decision = useMutation({
    mutationFn: ({ assetIDs, action }: { assetIDs: string[]; action: ReviewDecisionAction }) =>
      applyReviewDecision(tagID, assetIDs, action),
    onSuccess: (response, variables) => {
      setDismissed((current) => new Set([...current, ...variables.assetIDs]));
      setSelected(new Set());
      setUndoID(response.undoID);
      setMessage(`已处理 ${String(response.appliedAssetCount)} 项建议。`);
      void queryClient.invalidateQueries({ queryKey: ['review-overview'] });
    },
  });
  const undo = useMutation({
    mutationFn: (id: string) => undoReviewDecision(id),
    onSuccess: (response) => {
      setDismissed(new Set());
      setUndoID(null);
      setMessage(`已撤销并恢复 ${String(response.restoredAssetCount)} 项。`);
      void queryClient.invalidateQueries({ queryKey: ['review-queue', tagID] });
      void queryClient.invalidateQueries({ queryKey: ['review-overview'] });
    },
  });

  const apply = useCallback(
    async (
      assetIDs: string[],
      action: ReviewDecisionAction,
      continueFromAssetID: string | null = null,
      keepPreviewOpen = false,
    ) => {
      if (!assetIDs.length) return;
      const currentIndex = continueFromAssetID
        ? items.findIndex((item) => item.assetID === continueFromAssetID)
        : -1;
      const remaining = items.filter((item) => !assetIDs.includes(item.assetID));
      const continuation =
        currentIndex >= 0
          ? (items.slice(currentIndex + 1).find((item) => !assetIDs.includes(item.assetID)) ??
            items.slice(0, currentIndex).find((item) => !assetIDs.includes(item.assetID)) ??
            null)
          : null;
      setMessage('');
      try {
        await decision.mutateAsync({ assetIDs, action });
        const nextAssetID = continuation?.assetID ?? remaining[0]?.assetID ?? null;
        setActiveAssetID(nextAssetID);
        if (keepPreviewOpen) setPreviewAssetID(nextAssetID);
      } catch (error) {
        setMessage(errorMessage(error));
      }
    },
    [decision, items],
  );

  const moveActive = useCallback(
    (offset: number, showPreview = false) => {
      if (!items.length) return;
      const currentIndex = showPreview ? previewIndex : activeIndex;
      const start = currentIndex >= 0 ? currentIndex : 0;
      const nextIndex = Math.min(Math.max(start + offset, 0), items.length - 1);
      const nextAssetID = items[nextIndex]?.assetID ?? null;
      setActiveAssetID(nextAssetID);
      if (showPreview) setPreviewAssetID(nextAssetID);
    },
    [activeIndex, items, previewIndex],
  );

  const deferAsset = useCallback(
    (assetID: string | null, showPreview = false) => {
      if (!items.length) return;
      const currentIndex = assetID
        ? items.findIndex((item) => item.assetID === assetID)
        : activeIndex;
      const nextIndex = currentIndex >= 0 ? (currentIndex + 1) % items.length : 0;
      const nextAssetID = items[nextIndex]?.assetID ?? null;
      setActiveAssetID(nextAssetID);
      if (showPreview) setPreviewAssetID(nextAssetID);
      setMessage('已将当前项目留到稍后处理。');
    },
    [activeIndex, items],
  );

  useEffect(() => {
    if (!items.length || hasFocusedGrid.current) return;
    hasFocusedGrid.current = true;
    gridRef.current?.focus({ preventScroll: true });
  }, [items.length]);

  useEffect(() => {
    function handleShortcut(event: KeyboardEvent) {
      if (previewAssetID) return;
      const target = event.target as HTMLElement | null;
      if (target?.matches('input, select, textarea, button, a')) return;
      const key = event.key.toLowerCase();
      const current =
        items.find((item) => item.assetID === resolvedActiveAssetID) ?? items[0] ?? null;
      const currentIDs = selected.size ? [...selected] : current ? [current.assetID] : [];
      if ((key === 'p' || key === 'a') && !event.metaKey && !event.ctrlKey) {
        void apply(currentIDs, 'accept', current?.assetID ?? null);
      } else if (key === 'x' || key === 'r') {
        void apply(currentIDs, 'reject', current?.assetID ?? null);
      } else if (key === 'u' || key === 's') deferAsset(current?.assetID ?? null);
      else if ((event.metaKey || event.ctrlKey) && key === 'a') {
        setSelected(new Set(items.map((item) => item.assetID)));
      } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') moveActive(-1);
      else if (event.key === 'ArrowRight' || event.key === 'ArrowDown') moveActive(1);
      else if ((event.key === ' ' || event.key === 'Enter') && current) {
        setPreviewAssetID(current.assetID);
      } else return;
      event.preventDefault();
    }
    window.addEventListener('keydown', handleShortcut);
    return () => window.removeEventListener('keydown', handleShortcut);
  }, [
    apply,
    deferAsset,
    items,
    moveActive,
    previewAssetID,
    resolvedActiveAssetID,
    selected,
    setSelected,
  ]);

  if (queue.isPending)
    return (
      <div className="workspace-state" role="status">
        正在载入审查队列…
      </div>
    );
  if (queue.isError) {
    return (
      <div className="workspace-state workspace-state-error" role="alert">
        <strong>无法载入审查队列</strong>
        <p>{errorMessage(queue.error)}</p>
        <button className="button" onClick={() => void queue.refetch()} type="button">
          重试
        </button>
      </div>
    );
  }

  const refreshingScope = queue.isFetching && !queue.isFetchingNextPage;
  const pending = decision.isPending || undo.isPending || refreshingScope;
  const updateView = (key: 'density' | 'aspect', value: string | null) => {
    const next = new URLSearchParams(viewParameters);
    if (value === null) next.delete(key);
    else next.set(key, value);
    setViewParameters(next, { replace: true });
  };
  return (
    <section
      className="domain-workspace review-queue-workspace"
      aria-labelledby="review-queue-title"
    >
      <header className="domain-heading">
        <div>
          <Link className="back-link" to={overviewHref(search)}>
            <ChevronLeft aria-hidden="true" size={15} /> 审查概览
          </Link>
          <h2 id="review-queue-title">审查队列</h2>
          <p>
            <kbd>Space</kbd> 单图 · <kbd>P</kbd> 属于 · <kbd>X</kbd> 不属于 · <kbd>U</kbd> 稍后
          </p>
        </div>
        <div className="review-heading-actions">
          {sourceScope}
          <div className="review-view-summary">
            <span>{items.length.toLocaleString('zh-CN')} 项已载入</span>
            <div className="review-view-controls" role="group" aria-label="待审查网格显示">
              <label className="review-density-control">
                <Grid3X3 aria-hidden="true" size={15} />
                <span className="visually-hidden">缩略图大小</span>
                <select
                  aria-label="缩略图大小"
                  onChange={(event) =>
                    updateView('density', event.target.value === '3' ? null : event.target.value)
                  }
                  value={String(density)}
                >
                  {reviewDensityOptions.map((option) => (
                    <option key={option.value} value={option.value}>
                      {option.label}
                    </option>
                  ))}
                </select>
              </label>
              <button
                aria-label={`缩略图比例：${aspect === 'original' ? '原比例' : '正方形'}`}
                aria-pressed={aspect === 'original'}
                className="review-aspect-control"
                onClick={() => updateView('aspect', aspect === 'original' ? null : 'original')}
                title={
                  aspect === 'original'
                    ? '优先显示已手动缓存的原比例缩略图；未缓存项保持正方形'
                    : '全部使用正方形缩略图'
                }
                type="button"
              >
                <Ratio aria-hidden="true" size={15} />
                <span>{aspect === 'original' ? '原比例' : '正方形'}</span>
              </button>
            </div>
          </div>
        </div>
      </header>

      {refreshingScope ? (
        <p className="review-scope-refresh" role="status">
          正在切换来源范围…
        </p>
      ) : null}

      {items.length ? (
        <div
          aria-label="待审查照片"
          className="review-queue-grid"
          data-aspect={aspect}
          data-density={density}
          ref={gridRef}
          role="list"
          tabIndex={0}
        >
          {items.map((item) => {
            const title = item.fileName ?? `照片 ${item.assetID.slice(0, 8)}`;
            const checked = selected.has(item.assetID);
            const revision = item.contentRevision ?? 0;
            return (
              <article
                aria-current={resolvedActiveAssetID === item.assetID ? 'true' : undefined}
                className="review-card"
                key={`${item.assetID}:${item.suggestionOrigin}`}
                onClick={(event) => {
                  if ((event.target as Element).closest('button, input, label, a')) return;
                  setActiveAssetID(item.assetID);
                }}
                onDoubleClick={(event) => {
                  if ((event.target as Element).closest('button, input, label, a')) return;
                  setActiveAssetID(item.assetID);
                  setPreviewAssetID(item.assetID);
                }}
                role="listitem"
              >
                <label className="review-select">
                  <input
                    checked={checked}
                    onChange={() =>
                      setSelected((current) => {
                        const next = new Set(current);
                        if (next.has(item.assetID)) next.delete(item.assetID);
                        else next.add(item.assetID);
                        return next;
                      })
                    }
                    type="checkbox"
                  />
                  <span className="visually-hidden">选择 {title}</span>
                </label>
                <img
                  alt=""
                  src={`/v1/assets/${encodeURIComponent(item.assetID)}/thumbnail?w=560&revision=${String(revision)}${aspect === 'original' ? '&aspect=original' : ''}`}
                />
                <div className="review-card-copy">
                  <strong>{title}</strong>
                  <span>
                    {originLabels[item.suggestionOrigin]}
                    {item.score === null ? '' : ` · ${(item.score * 100).toFixed(1)}%`}
                  </span>
                </div>
                <div className="review-card-actions">
                  <button
                    aria-label={`接受 ${title}`}
                    className="icon-button decision-accept"
                    disabled={pending}
                    onClick={() => void apply([item.assetID], 'accept')}
                    type="button"
                  >
                    <Check aria-hidden="true" size={16} />
                  </button>
                  <button
                    aria-label={`拒绝 ${title}`}
                    className="icon-button decision-reject"
                    disabled={pending}
                    onClick={() => void apply([item.assetID], 'reject')}
                    type="button"
                  >
                    <X aria-hidden="true" size={16} />
                  </button>
                  <button
                    aria-label={`稍后处理 ${title}`}
                    className="icon-button"
                    disabled={pending}
                    onClick={() => deferAsset(item.assetID)}
                    type="button"
                  >
                    <SkipForward aria-hidden="true" size={15} />
                  </button>
                </div>
              </article>
            );
          })}
        </div>
      ) : (
        <div className="workspace-state">
          <Check aria-hidden="true" size={26} />
          <strong>当前队列已处理完</strong>
          <p>返回概览选择其他标签，或刷新 Host 状态。</p>
        </div>
      )}

      {queue.hasNextPage ? (
        <button
          className="button load-more-button"
          disabled={queue.isFetchingNextPage}
          onClick={() => void queue.fetchNextPage()}
          type="button"
        >
          {queue.isFetchingNextPage ? '正在载入…' : '载入更多'}
        </button>
      ) : null}

      {selected.size ? (
        <section className="selection-bar" aria-label="审查批量操作">
          <strong>已选择 {selected.size.toLocaleString('zh-CN')} 项</strong>
          <button
            className="button"
            disabled={pending}
            onClick={() => void apply([...selected], 'accept')}
            type="button"
          >
            <Check aria-hidden="true" size={15} /> 接受
          </button>
          <button
            className="button"
            disabled={pending}
            onClick={() => void apply([...selected], 'reject')}
            type="button"
          >
            <X aria-hidden="true" size={15} /> 拒绝
          </button>
          <button
            className="button"
            disabled={pending}
            onClick={() => void apply([...selected], 'clear')}
            type="button"
          >
            清除决定
          </button>
          <button className="button" onClick={() => setSelected(new Set())} type="button">
            取消选择
          </button>
        </section>
      ) : null}

      {message ? (
        <div className="action-toast" role="status">
          <span>{message}</span>
          {undoID ? (
            <button
              className="button"
              disabled={undo.isPending}
              onClick={() =>
                void undo
                  .mutateAsync(undoID)
                  .catch((error: unknown) => setMessage(errorMessage(error)))
              }
              type="button"
            >
              <RotateCcw aria-hidden="true" size={14} /> 撤销
            </button>
          ) : null}
          <button
            aria-label="关闭消息"
            className="icon-button"
            onClick={() => setMessage('')}
            type="button"
          >
            ×
          </button>
        </div>
      ) : null}

      {previewItem ? (
        <ReviewSinglePhotoDialog
          canMoveNext={previewIndex < items.length - 1}
          canMovePrevious={previewIndex > 0}
          item={previewItem}
          message={message}
          onClose={() => setPreviewAssetID(null)}
          onDecision={(action) =>
            void apply([previewItem.assetID], action, previewItem.assetID, true)
          }
          onDefer={() => deferAsset(previewItem.assetID, true)}
          onMove={(offset) => moveActive(offset, true)}
          pending={pending}
          position={previewIndex + 1}
          total={items.length}
        />
      ) : null}
    </section>
  );
}

export function ReviewRoute() {
  const [parameters, setParameters] = useSearchParams();
  const search = parameters.toString();
  const tagID = parameters.get('tag');
  const sourceIDs = useMemo(() => reviewSourceIDs(new URLSearchParams(search)), [search]);
  const sources = useQuery({
    queryKey: ['sources'],
    queryFn: ({ signal }) => fetchSources(signal),
  });
  const activeSources = useMemo(
    () => (sources.data ?? []).filter((source) => source.state === 'active'),
    [sources.data],
  );

  const changeSourceScope = useCallback(
    (nextSourceIDs: string[] | null) => {
      const next = new URLSearchParams(search);
      next.delete('source');
      next.delete('sourceScope');
      if (nextSourceIDs?.length === 0) next.set('sourceScope', 'none');
      else nextSourceIDs?.forEach((sourceID) => next.append('source', sourceID));
      setParameters(next, { replace: true });
    },
    [search, setParameters],
  );
  const sourceScope = (
    <ReviewSourceScope
      isError={sources.isError}
      isPending={sources.isPending}
      onChange={changeSourceScope}
      sourceIDs={sourceIDs}
      sources={activeSources}
    />
  );

  return tagID ? (
    <ReviewQueue search={search} sourceIDs={sourceIDs} sourceScope={sourceScope} tagID={tagID} />
  ) : (
    <ReviewOverview search={search} sourceIDs={sourceIDs} sourceScope={sourceScope} />
  );
}
