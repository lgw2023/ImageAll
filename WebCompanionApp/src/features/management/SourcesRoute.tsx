import { useState } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import {
  Eye,
  Folder,
  FolderPlus,
  Gauge,
  ImagePlus,
  Images,
  Layers3,
  MoreHorizontal,
  RefreshCw,
  ScanLine,
  ShieldCheck,
  Sparkles,
  Trash2,
} from 'lucide-react';
import { Link } from 'react-router-dom';

import type { SourceManagement, SourceManagementAction } from '@/api/contracts/management';
import { errorMessage } from '@/api/errors';
import { fetchSourceManagement, submitSourceManagement } from '@/api/management';

import { SourceDeletionDialog } from './SourceDeletionDialog';

const actionLabels: Partial<Record<SourceManagementAction, string>> = {
  refreshAll: '刷新全部',
  prewarmAllThumbnails: '预热缩略图',
  prewarmAllOriginalAspect: '预热原始比例',
  reauthorizeAll: '重新授权待处理来源',
  refreshAllFolderMutationAuthorizations: '更新全部回收权限',
  rebindPhotos: '连接当前系统图库',
  rescan: '重新扫描',
  syncPhotos: '同步 Photos',
  fullRepair: '完整修复扫描',
  openPhotosPrivacySettings: '打开照片权限设置',
  requestPhotosWriteAuthorization: '请求照片写入权限',
  refreshFolderMutationAuthorization: '更新回收权限',
  prewarmThumbnails: '预热缩略图',
  prewarmOriginalAspect: '预热原始比例',
  cancelPrewarm: '取消预热',
  reauthorize: '重新授权',
  delete: '移除来源',
};

const requestPhaseLabels = {
  awaitingMac: '等待 Mac',
  running: '进行中',
  completed: '已完成',
  cancelled: '已取消',
  failed: '失败',
} as const;

function isPrewarmAction(action: SourceManagementAction) {
  return [
    'prewarmAllThumbnails',
    'prewarmAllOriginalAspect',
    'prewarmThumbnails',
    'prewarmOriginalAspect',
  ].includes(action);
}

function sourceStateLabel(source: SourceManagement['sources'][number]) {
  switch (source.state) {
    case 'active':
      return '可用';
    case 'disabled':
      return '已停用';
    case 'authorizationRequired':
      return '需要授权';
    case 'unavailable':
      return source.kind === 'photos' ? '历史图库' : '位置不可用';
  }
}

export function SourcesRoute() {
  const queryClient = useQueryClient();
  const [expandedSourceID, setExpandedSourceID] = useState<string | null>(null);
  const [sourcePendingDeletion, setSourcePendingDeletion] = useState<
    SourceManagement['sources'][number] | null
  >(null);
  const [pendingAction, setPendingAction] = useState('');
  const [message, setMessage] = useState('');
  const [messageTone, setMessageTone] = useState<'status' | 'error'>('status');
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
  const activeRequest = snapshot.data?.requests.find((request) =>
    ['awaitingMac', 'running'].includes(request.phase),
  );
  const actionsLocked = Boolean(pendingAction) || Boolean(activeRequest);

  async function submit(action: SourceManagementAction, sourceID?: string) {
    const request = await submitSourceManagement(action, sourceID);
    setMessageTone('status');
    setMessage(request.message || '已向 Mac 提交请求。');
    await queryClient.invalidateQueries({ queryKey: ['source-management'] });
  }

  async function run(action: SourceManagementAction, sourceID?: string) {
    setPendingAction(`${action}:${sourceID ?? ''}`);
    setMessage('');
    try {
      await submit(action, sourceID);
    } catch (error) {
      setMessageTone('error');
      setMessage(errorMessage(error));
    } finally {
      setPendingAction('');
    }
  }

  function sourceTools(source: SourceManagement['sources'][number]) {
    const canPrewarm = source.state === 'active' || source.state === 'unavailable';
    const canReauthorize =
      source.state === 'authorizationRequired' ||
      (source.kind === 'photos' && source.state === 'disabled') ||
      (source.kind === 'folder' && source.state === 'unavailable');

    return (
      <section className="source-command-panel" aria-label={`${source.displayName}来源工具`}>
        <header>
          <div>
            <span>TOOLS / {source.kind === 'photos' ? 'PHOTOS' : 'FOLDER'}</span>
            <strong>来源工具</strong>
          </div>
          <small>操作由 Mac 执行并回传状态</small>
        </header>
        <div className="source-command-grid">
          {canReauthorize ? (
            <button
              className="button"
              disabled={actionsLocked}
              onClick={() => void run('reauthorize', source.id)}
              type="button"
            >
              重新授权
            </button>
          ) : null}
          {source.kind === 'photos' && source.state === 'unavailable' ? (
            <button
              className="button"
              disabled={actionsLocked}
              onClick={() => void run('rebindPhotos', source.id)}
              type="button"
            >
              连接当前系统图库
            </button>
          ) : null}
          {source.kind === 'folder' && source.state === 'active' ? (
            <button
              className="button"
              disabled={actionsLocked}
              onClick={() => void run('refreshFolderMutationAuthorization', source.id)}
              type="button"
            >
              更新回收权限
            </button>
          ) : null}
          {source.kind === 'photos' && source.state === 'active' ? (
            <>
              <button
                className="button"
                disabled={actionsLocked}
                onClick={() => void run('fullRepair', source.id)}
                type="button"
              >
                完整修复扫描
              </button>
              <button
                className="button"
                disabled={actionsLocked}
                onClick={() => void run('requestPhotosWriteAuthorization', source.id)}
                type="button"
              >
                请求照片写入权限
              </button>
            </>
          ) : null}
          {source.kind === 'photos' ? (
            <button
              className="button"
              disabled={actionsLocked}
              onClick={() => void run('openPhotosPrivacySettings', source.id)}
              type="button"
            >
              打开照片权限设置
            </button>
          ) : null}
          {canPrewarm ? (
            <>
              <button
                className="button"
                disabled={actionsLocked}
                onClick={() => void run('prewarmThumbnails', source.id)}
                type="button"
              >
                预热缩略图
              </button>
              <button
                className="button"
                disabled={actionsLocked}
                onClick={() => void run('prewarmOriginalAspect', source.id)}
                type="button"
              >
                预热原始比例
              </button>
            </>
          ) : null}
          <button
            className="button button-danger source-remove-button"
            disabled={actionsLocked}
            onClick={() => setSourcePendingDeletion(source)}
            type="button"
          >
            <Trash2 aria-hidden="true" size={14} /> 移除来源
          </button>
        </div>
      </section>
    );
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

  const hasAuthorizationTargets = snapshot.data.sources.some(
    (source) =>
      source.state === 'authorizationRequired' ||
      (source.kind === 'photos' && source.state === 'disabled') ||
      (source.kind === 'folder' && source.state === 'unavailable'),
  );
  const hasActiveFolder = snapshot.data.sources.some(
    (source) => source.kind === 'folder' && source.state === 'active',
  );

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
            disabled={actionsLocked}
            onClick={() => void run('connectFolder')}
            type="button"
          >
            <FolderPlus aria-hidden="true" size={15} /> 连接文件夹
          </button>
          <button
            className="button button-primary"
            disabled={actionsLocked || !snapshot.data.canConnectPhotos}
            onClick={() => void run('connectPhotos')}
            type="button"
          >
            <ImagePlus aria-hidden="true" size={15} /> 连接 Photos
          </button>
        </div>
      </header>

      <section className="source-command-deck" aria-labelledby="source-command-deck-title">
        <header className="source-command-deck-heading">
          <div className="source-command-deck-mark" aria-hidden="true">
            <Gauge size={21} />
          </div>
          <div>
            <p className="eyebrow">SYNC ORCHESTRATOR</p>
            <h3 id="source-command-deck-title">批量维护控制台</h3>
            <p>刷新索引、准备缓存和修复访问权限；所有执行状态以 Mac 回读为准。</p>
          </div>
          <span className="source-command-lock" data-active={Boolean(activeRequest)}>
            {activeRequest ? 'MAC BUSY' : 'READY'}
          </span>
        </header>
        <div className="source-command-bands" aria-label="来源全局操作">
          <article className="source-command-band" data-accent="cyan">
            <span className="source-command-number">01</span>
            <div>
              <RefreshCw aria-hidden="true" size={17} />
              <strong>同步索引</strong>
              <small>更新所有活跃来源</small>
            </div>
            <button
              className="button"
              disabled={actionsLocked}
              onClick={() => void run('refreshAll')}
              type="button"
            >
              刷新全部
            </button>
          </article>
          <article className="source-command-band" data-accent="violet">
            <span className="source-command-number">02</span>
            <div>
              <Sparkles aria-hidden="true" size={17} />
              <strong>准备缓存</strong>
              <small>标准网格与原比例预览</small>
            </div>
            <div className="source-command-band-actions">
              <button
                className="button"
                disabled={actionsLocked}
                onClick={() => void run('prewarmAllThumbnails')}
                type="button"
              >
                预热缩略图
              </button>
              <button
                className="button"
                disabled={actionsLocked}
                onClick={() => void run('prewarmAllOriginalAspect')}
                type="button"
              >
                预热原始比例
              </button>
            </div>
          </article>
          <article className="source-command-band" data-accent="amber">
            <span className="source-command-number">03</span>
            <div>
              <ShieldCheck aria-hidden="true" size={17} />
              <strong>恢复访问</strong>
              <small>只显示当前可执行的修复</small>
            </div>
            <div className="source-command-band-actions">
              {hasAuthorizationTargets ? (
                <button
                  className="button"
                  disabled={actionsLocked}
                  onClick={() => void run('reauthorizeAll')}
                  type="button"
                >
                  重新授权待处理来源
                </button>
              ) : null}
              {hasActiveFolder ? (
                <button
                  className="button"
                  disabled={actionsLocked}
                  onClick={() => void run('refreshAllFolderMutationAuthorizations')}
                  type="button"
                >
                  更新全部回收权限
                </button>
              ) : null}
              {!hasAuthorizationTargets && !hasActiveFolder ? (
                <span className="source-command-clear">无需处理</span>
              ) : null}
            </div>
          </article>
        </div>
      </section>

      <div className="source-collection-heading">
        <div>
          <p className="eyebrow">CONNECTED SOURCES</p>
          <h3>来源目录</h3>
        </div>
        <span>{snapshot.data.sources.length.toLocaleString()} 个来源</span>
      </div>

      <div className="management-card-grid source-management-grid">
        {snapshot.data.sources.map((source) => (
          <article
            className="management-card source-management-card"
            data-expanded={expandedSourceID === source.id}
            data-kind={source.kind}
            data-state={source.state}
            key={source.id}
          >
            <div className="management-card-heading">
              <div className="source-card-identity">
                <span className="source-kind-emblem" aria-hidden="true">
                  {source.kind === 'photos' ? <Images size={19} /> : <Folder size={19} />}
                </span>
                <div>
                  <strong>{source.displayName}</strong>
                  <span>{source.kind === 'photos' ? 'APPLE PHOTOS' : 'FOLDER SOURCE'}</span>
                </div>
              </div>
              <span className="state-pill" data-state={source.state}>
                {sourceStateLabel(source)}
              </span>
            </div>
            <div className="card-actions source-card-primary-actions">
              <Link className="button" to={`/gallery?source=${encodeURIComponent(source.id)}`}>
                <Eye aria-hidden="true" size={14} /> 在图库中查看
              </Link>
              <button
                className="button"
                disabled={actionsLocked || source.state !== 'active'}
                onClick={() =>
                  void run(source.kind === 'photos' ? 'syncPhotos' : 'rescan', source.id)
                }
                type="button"
              >
                <ScanLine aria-hidden="true" size={14} />{' '}
                {source.kind === 'photos' ? '同步' : '扫描'}
              </button>
              <button
                aria-expanded={expandedSourceID === source.id}
                className="button"
                onClick={() =>
                  setExpandedSourceID((current) => (current === source.id ? null : source.id))
                }
                type="button"
              >
                <MoreHorizontal aria-hidden="true" size={14} /> 更多操作
              </button>
            </div>
            {expandedSourceID === source.id ? sourceTools(source) : null}
          </article>
        ))}
      </div>

      {snapshot.data.requests.length ? (
        <section
          className="activity-panel source-request-panel"
          aria-labelledby="source-requests-title"
        >
          <header>
            <div>
              <p className="eyebrow">MAC ACTIVITY</p>
              <h3 id="source-requests-title">最近请求</h3>
            </div>
            <Layers3 aria-hidden="true" size={20} />
          </header>
          {snapshot.data.requests.map((request) => (
            <div className="activity-row" key={request.id}>
              <div>
                <strong>{actionLabels[request.action] ?? request.action}</strong>
                <span>
                  {request.sourceDisplayName ?? '全部来源'} · {request.message}
                </span>
              </div>
              <span className="state-pill" data-state={request.phase}>
                {requestPhaseLabels[request.phase]}
              </span>
              {request.totalCount !== null ? (
                <progress max={request.totalCount} value={request.completedCount ?? 0} />
              ) : null}
              {request.totalSourceCount !== null ? (
                <span className="source-request-source-progress">
                  {request.completedSourceCount ?? 0} / {request.totalSourceCount} 个来源
                </span>
              ) : null}
              {[
                request.warmedCount === null ? null : `${String(request.warmedCount)} 新生成`,
                request.reusedCount === null ? null : `${String(request.reusedCount)} 已复用`,
                request.failedCount === null ? null : `${String(request.failedCount)} 失败`,
                request.ineligibleCount === null
                  ? null
                  : `${String(request.ineligibleCount)} 已跳过`,
              ].some(Boolean) ? (
                <div className="source-request-metrics" aria-label="缓存进度明细">
                  {request.warmedCount === null ? null : <span>{request.warmedCount} 新生成</span>}
                  {request.reusedCount === null ? null : <span>{request.reusedCount} 已复用</span>}
                  {request.failedCount === null ? null : <span>{request.failedCount} 失败</span>}
                  {request.ineligibleCount === null ? null : (
                    <span>{request.ineligibleCount} 已跳过</span>
                  )}
                </div>
              ) : null}
              {['awaitingMac', 'running'].includes(request.phase) &&
              isPrewarmAction(request.action) ? (
                <button
                  className="button"
                  disabled={Boolean(pendingAction)}
                  onClick={() => void run('cancelPrewarm', request.sourceID ?? undefined)}
                  type="button"
                >
                  取消预热
                </button>
              ) : null}
            </div>
          ))}
        </section>
      ) : null}

      {message ? (
        <div
          className="action-toast"
          data-tone={messageTone}
          role={messageTone === 'error' ? 'alert' : 'status'}
        >
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
      {sourcePendingDeletion ? (
        <SourceDeletionDialog
          onCancel={() => setSourcePendingDeletion(null)}
          onConfirm={() => submit('delete', sourcePendingDeletion.id)}
          sourceName={sourcePendingDeletion.displayName}
        />
      ) : null}
    </section>
  );
}
