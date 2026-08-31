import { useState } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import { FolderPlus, ImagePlus, RefreshCw, ScanLine, Trash2 } from 'lucide-react';

import type { SourceManagementAction } from '@/api/contracts/management';
import { errorMessage } from '@/api/errors';
import { fetchSourceManagement, submitSourceManagement } from '@/api/management';

const actionLabels: Partial<Record<SourceManagementAction, string>> = {
  refreshAll: '刷新全部',
  prewarmAllThumbnails: '预热缩略图',
  prewarmAllOriginalAspect: '预热原始比例',
  rescan: '重新扫描',
  syncPhotos: '同步 Photos',
  reauthorize: '重新授权',
  refreshFolderMutationAuthorization: '刷新写入授权',
  delete: '移除来源',
};

export function SourcesRoute() {
  const queryClient = useQueryClient();
  const [pendingAction, setPendingAction] = useState('');
  const [message, setMessage] = useState('');
  const snapshot = useQuery({
    queryKey: ['source-management'],
    queryFn: ({ signal }) => fetchSourceManagement(signal),
    refetchInterval: (query) =>
      query.state.data?.requests.some((request) =>
        ['awaitingMac', 'running'].includes(request.phase),
      )
        ? 2_000
        : false,
  });

  async function run(action: SourceManagementAction, sourceID?: string) {
    const key = `${action}:${sourceID ?? ''}`;
    setPendingAction(key);
    setMessage('');
    try {
      const request = await submitSourceManagement(action, sourceID);
      setMessage(request.message || '已向 Mac 提交请求。');
      await queryClient.invalidateQueries({ queryKey: ['source-management'] });
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPendingAction('');
    }
  }

  if (snapshot.isPending)
    return (
      <div className="workspace-state" role="status">
        正在载入照片来源…
      </div>
    );
  if (snapshot.isError) {
    return (
      <div className="workspace-state workspace-state-error" role="alert">
        <strong>无法载入照片来源</strong>
        <p>{errorMessage(snapshot.error)}</p>
        <button className="button" onClick={() => void snapshot.refetch()} type="button">
          重试
        </button>
      </div>
    );
  }

  return (
    <section className="domain-workspace" aria-labelledby="sources-title">
      <header className="domain-heading">
        <div>
          <p className="eyebrow">管理</p>
          <h2 id="sources-title">照片来源</h2>
          <p>连接动作在 Mac 上完成；网页不会获得文件系统路径。</p>
        </div>
        <div className="heading-actions">
          <button
            className="button"
            disabled={Boolean(pendingAction)}
            onClick={() => void run('connectFolder')}
            type="button"
          >
            <FolderPlus aria-hidden="true" size={15} /> 连接文件夹
          </button>
          <button
            className="button button-primary"
            disabled={Boolean(pendingAction) || !snapshot.data.canConnectPhotos}
            onClick={() => void run('connectPhotos')}
            type="button"
          >
            <ImagePlus aria-hidden="true" size={15} /> 连接 Photos
          </button>
        </div>
      </header>

      <div className="management-toolbar" aria-label="来源全局操作">
        <button
          className="button"
          disabled={Boolean(pendingAction)}
          onClick={() => void run('refreshAll')}
          type="button"
        >
          <RefreshCw aria-hidden="true" size={15} /> 刷新全部
        </button>
        <button
          className="button"
          disabled={Boolean(pendingAction)}
          onClick={() => void run('prewarmAllThumbnails')}
          type="button"
        >
          预热缩略图
        </button>
        <button
          className="button"
          disabled={Boolean(pendingAction)}
          onClick={() => void run('prewarmAllOriginalAspect')}
          type="button"
        >
          预热原始比例
        </button>
      </div>

      <div className="management-card-grid">
        {snapshot.data.sources.map((source) => (
          <article className="management-card" key={source.id}>
            <div className="management-card-heading">
              <div>
                <strong>{source.displayName}</strong>
                <span>{source.kind === 'photos' ? 'Apple Photos' : '文件夹'}</span>
              </div>
              <span className="state-pill" data-state={source.state}>
                {source.state === 'active' ? '可用' : '需要处理'}
              </span>
            </div>
            <div className="card-actions">
              <button
                className="button"
                disabled={Boolean(pendingAction)}
                onClick={() =>
                  void run(source.kind === 'photos' ? 'syncPhotos' : 'rescan', source.id)
                }
                type="button"
              >
                <ScanLine aria-hidden="true" size={14} />{' '}
                {source.kind === 'photos' ? '同步' : '扫描'}
              </button>
              <button
                className="button"
                disabled={Boolean(pendingAction)}
                onClick={() =>
                  void run(
                    source.kind === 'photos' ? 'reauthorize' : 'refreshFolderMutationAuthorization',
                    source.id,
                  )
                }
                type="button"
              >
                授权
              </button>
              <button
                className="button button-danger"
                disabled={Boolean(pendingAction)}
                onClick={() => {
                  if (
                    !window.confirm(
                      `移除来源“${source.displayName}”？Host 将保留其安全与一致性约束。`,
                    )
                  )
                    return;
                  void run('delete', source.id);
                }}
                type="button"
              >
                <Trash2 aria-hidden="true" size={14} /> 移除
              </button>
            </div>
          </article>
        ))}
      </div>

      {snapshot.data.requests.length ? (
        <section className="activity-panel" aria-labelledby="source-requests-title">
          <h3 id="source-requests-title">最近请求</h3>
          {snapshot.data.requests.map((request) => (
            <div className="activity-row" key={request.id}>
              <div>
                <strong>{actionLabels[request.action] ?? request.action}</strong>
                <span>
                  {request.sourceDisplayName ?? '全部来源'} · {request.message}
                </span>
              </div>
              <span className="state-pill" data-state={request.phase}>
                {request.phase}
              </span>
              {request.totalCount !== null ? (
                <progress max={request.totalCount} value={request.completedCount ?? 0} />
              ) : null}
            </div>
          ))}
        </section>
      ) : null}

      {message ? (
        <div className="action-toast" role="status">
          <span>{message}</span>
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
