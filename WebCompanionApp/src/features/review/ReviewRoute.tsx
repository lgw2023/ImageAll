import { useCallback, useEffect, useMemo, useState } from 'react';

import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Check, ChevronLeft, RotateCcw, ScanSearch, SkipForward, X } from 'lucide-react';
import { Link, useSearchParams } from 'react-router-dom';

import type { ReviewDecisionAction } from '@/api/contracts/review';
import { errorMessage } from '@/api/errors';
import {
  applyReviewDecision,
  fetchReviewOverview,
  fetchReviewQueue,
  undoReviewDecision,
} from '@/api/review';

const originLabels = {
  featurePrint: '视觉相似',
  standardModel: '标准模型',
  personalModel: '个人模型',
  personalAdamW: '个人 AdamW',
} as const;

function ReviewOverview() {
  const overview = useQuery({
    queryKey: ['review-overview'],
    queryFn: ({ signal }) => fetchReviewOverview(signal),
  });

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
        <strong className="large-count">
          {overview.data.totalPendingSuggestionCount.toLocaleString('zh-CN')} 待处理
        </strong>
      </header>

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
                <Link className="button button-primary" to={`/review/queue?tag=${tag.id}`}>
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
    </section>
  );
}

function ReviewQueue({ tagID }: { tagID: string }) {
  const queryClient = useQueryClient();
  const [selected, setSelected] = useState(new Set<string>());
  const [dismissed, setDismissed] = useState(new Set<string>());
  const [message, setMessage] = useState('');
  const [undoID, setUndoID] = useState<string | null>(null);
  const queue = useInfiniteQuery({
    queryKey: ['review-queue', tagID],
    queryFn: ({ pageParam, signal }) => fetchReviewQueue(tagID, pageParam, signal),
    initialPageParam: null as string | null,
    getNextPageParam: (page) => page.nextCursor ?? undefined,
  });
  const items = useMemo(
    () =>
      (queue.data?.pages.flatMap((page) => page.items) ?? []).filter(
        (item) => !dismissed.has(item.assetID),
      ),
    [dismissed, queue.data],
  );
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
    async (assetIDs: string[], action: ReviewDecisionAction) => {
      if (!assetIDs.length) return;
      setMessage('');
      try {
        await decision.mutateAsync({ assetIDs, action });
      } catch (error) {
        setMessage(errorMessage(error));
      }
    },
    [decision],
  );

  useEffect(() => {
    function handleShortcut(event: KeyboardEvent) {
      const target = event.target as HTMLElement | null;
      if (target?.matches('input, select, textarea, button, a')) return;
      const currentIDs = selected.size ? [...selected] : items[0] ? [items[0].assetID] : [];
      if (event.key.toLowerCase() === 'a') void apply(currentIDs, 'accept');
      else if (event.key.toLowerCase() === 'r') void apply(currentIDs, 'reject');
      else if (event.key.toLowerCase() === 's') {
        const firstItem = items[0];
        if (!firstItem) return;
        setDismissed((current) => new Set([...current, firstItem.assetID]));
        setMessage('已将当前项目留到稍后处理。');
      } else return;
      event.preventDefault();
    }
    window.addEventListener('keydown', handleShortcut);
    return () => window.removeEventListener('keydown', handleShortcut);
  }, [apply, items, selected]);

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

  const pending = decision.isPending || undo.isPending;
  return (
    <section
      className="domain-workspace review-queue-workspace"
      aria-labelledby="review-queue-title"
    >
      <header className="domain-heading">
        <div>
          <Link className="back-link" to="/review">
            <ChevronLeft aria-hidden="true" size={15} /> 审查概览
          </Link>
          <h2 id="review-queue-title">审查队列</h2>
          <p>
            <kbd>A</kbd> 接受 · <kbd>R</kbd> 拒绝 · <kbd>S</kbd> 稍后处理
          </p>
        </div>
        <span>{items.length.toLocaleString('zh-CN')} 项已载入</span>
      </header>

      {items.length ? (
        <div className="review-queue-grid" role="list" aria-label="待审查照片">
          {items.map((item) => {
            const title = item.fileName ?? `照片 ${item.assetID.slice(0, 8)}`;
            const checked = selected.has(item.assetID);
            const revision = item.contentRevision ?? 0;
            return (
              <article
                className="review-card"
                key={`${item.assetID}:${item.suggestionOrigin}`}
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
                  src={`/v1/assets/${item.assetID}/thumbnail?w=560&revision=${String(revision)}`}
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
                    onClick={() => setDismissed((current) => new Set([...current, item.assetID]))}
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
    </section>
  );
}

export function ReviewRoute() {
  const [parameters] = useSearchParams();
  const tagID = parameters.get('tag');
  return tagID ? <ReviewQueue tagID={tagID} /> : <ReviewOverview />;
}
