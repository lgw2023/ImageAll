import { useState } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Database, Download, HardDrive, ShieldCheck, Trash2 } from 'lucide-react';

import type { StorageMaintenanceAction } from '@/api/contracts/management';
import { errorMessage } from '@/api/errors';
import { fetchStorageMaintenance, submitStorageMaintenance } from '@/api/management';
import {
  StorageCleanupDialog,
  type StorageCleanupAction,
} from '@/features/management/StorageCleanupDialog';

function bytes(value: number) {
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MiB`;
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GiB`;
}

const storageLabels: Record<StorageMaintenanceAction, string> = {
  exportPortableData: '导出便携数据',
  chooseExternalStorage: '选择外部存储',
  clearPreviewCache: '清理预览缓存',
  clearPhotosOriginals: '清理 Photos 原片缓存',
};

const storagePhaseLabels = {
  awaitingMac: '等待 Mac 操作',
  running: '正在执行',
  completed: '已完成',
  cancelled: '已取消',
  failed: '失败',
} as const;

export function StorageRoute() {
  const queryClient = useQueryClient();
  const [pending, setPending] = useState<StorageMaintenanceAction | null>(null);
  const [cleanupRequest, setCleanupRequest] = useState<{
    action: StorageCleanupAction;
    operationID: string;
  } | null>(null);
  const [message, setMessage] = useState('');
  const [messageIsError, setMessageIsError] = useState(false);
  const snapshot = useQuery({
    queryKey: ['storage-maintenance'],
    queryFn: ({ signal }) => fetchStorageMaintenance(signal),
    refetchInterval: (query) =>
      query.state.data?.requests.some((request) =>
        ['awaitingMac', 'running'].includes(request.phase),
      )
        ? 2_000
        : false,
  });

  async function submit(action: StorageMaintenanceAction, operationID?: string) {
    setPending(action);
    setMessage('');
    setMessageIsError(false);
    try {
      const request = await submitStorageMaintenance(action, operationID);
      setMessage(request.message);
      await queryClient.invalidateQueries({ queryKey: ['storage-maintenance'] });
    } finally {
      setPending(null);
    }
  }

  async function run(action: StorageMaintenanceAction) {
    try {
      await submit(action);
    } catch (error) {
      setMessage(errorMessage(error));
      setMessageIsError(true);
    }
  }

  if (snapshot.isPending)
    return (
      <div className="workspace-state" role="status">
        正在读取存储状态…
      </div>
    );
  if (snapshot.isError)
    return (
      <div className="workspace-state workspace-state-error" role="alert">
        <strong>无法读取存储状态</strong>
        <p>{errorMessage(snapshot.error)}</p>
        <button className="button" onClick={() => void snapshot.refetch()} type="button">
          重试
        </button>
      </div>
    );

  const previewAvailable = snapshot.data.clearPreviewCacheAvailability?.isAvailable ?? true;
  const originalsAvailable = snapshot.data.clearPhotosOriginalsAvailability?.isAvailable ?? true;
  const previewUnavailableReason = snapshot.data.clearPreviewCacheAvailability?.reason;
  const originalsUnavailableReason = snapshot.data.clearPhotosOriginalsAvailability?.reason;
  const activeRequest = snapshot.data.requests.find((request) =>
    ['awaitingMac', 'running'].includes(request.phase),
  );
  const commandsLocked = pending !== null || activeRequest !== undefined;
  return (
    <section className="domain-workspace storage-workspace" aria-labelledby="storage-title">
      <header className="domain-heading storage-domain-heading">
        <div>
          <p className="eyebrow">Storage operations</p>
          <h2 id="storage-title">存储与维护</h2>
          <p>查看 ImageAll 自有数据的占用、导出和迁移状态；路径选择与实际写入始终由 Mac 执行。</p>
        </div>
      </header>
      <section className="storage-vault" aria-labelledby="storage-vault-title">
        <header className="storage-vault-heading">
          <div aria-hidden="true" className="storage-vault-mark">
            <Database size={22} />
          </div>
          <div>
            <p className="eyebrow">Host-authoritative ledger</p>
            <h3 id="storage-vault-title">存储命令台</h3>
            <p>这里只展示脱敏状态。浏览器不会获得磁盘路径，也不会直接操作文件。</p>
          </div>
          <span className="storage-vault-lock" data-active={Boolean(activeRequest)}>
            {activeRequest ? storagePhaseLabels[activeRequest.phase] : 'Mac 可接受新任务'}
          </span>
        </header>
        <div className="storage-ledger">
          <article className="storage-ledger-card" data-accent="cyan">
            <span className="storage-ledger-index">01</span>
            <div>
              <HardDrive aria-hidden="true" size={17} />
              <span>预览缓存</span>
            </div>
            <strong>{bytes(snapshot.data.previewCache.registeredBytes)}</strong>
            <small>
              {snapshot.data.previewCache.entryCount.toLocaleString('zh-CN')} 项可重建预览
            </small>
          </article>
          <article className="storage-ledger-card" data-accent="coral">
            <span className="storage-ledger-index">02</span>
            <div>
              <HardDrive aria-hidden="true" size={17} />
              <span>Photos 原片副本</span>
            </div>
            <strong>{bytes(snapshot.data.photosOriginals.registeredBytes)}</strong>
            <small>
              {snapshot.data.photosOriginals.entryCount.toLocaleString('zh-CN')} 项长期副本
            </small>
          </article>
          <article className="storage-ledger-card" data-accent="amber">
            <span className="storage-ledger-index">03</span>
            <div>
              <HardDrive aria-hidden="true" size={17} />
              <span>应用资料根</span>
            </div>
            <strong>
              {snapshot.data.appStorage.kind === 'internalStorage' ? '内部存储' : '外置存储'}
            </strong>
            {snapshot.data.appStorage.pendingExternalRootName ? (
              <span className="storage-pending-root">
                {snapshot.data.appStorage.pendingExternalRootName}
              </span>
            ) : null}
            <small>
              {snapshot.data.appStorage.requiresRestart
                ? '重启 ImageAll 后迁移并生效'
                : '当前已生效'}
            </small>
          </article>
        </div>
      </section>

      <div aria-label="可用操作" className="storage-operations" role="region">
        <div className="storage-operations-heading">
          <div>
            <p className="eyebrow">Operations</p>
            <h3>Mac 协同操作</h3>
          </div>
          {activeRequest ? (
            <span className="state-pill" data-state={activeRequest.phase}>
              {storagePhaseLabels[activeRequest.phase]}
            </span>
          ) : null}
        </div>
        <section className="storage-command-section" aria-labelledby="storage-exit-title">
          <header className="storage-section-heading">
            <span>01 / EXIT &amp; ROOT</span>
            <div>
              <h3 id="storage-exit-title">数据出口</h3>
              <p>导出可迁移资料，或把 ImageAll 自有数据根迁移到外置磁盘。</p>
            </div>
          </header>
          <div className="storage-command-grid">
            <article className="storage-command-card" data-accent="cyan">
              <div aria-hidden="true" className="storage-command-icon">
                <Download size={20} />
              </div>
              <div>
                <span>PORTABLE EXPORT</span>
                <h4>便携数据包</h4>
                <p>由 Mac 选择与来源隔离的目标位置；校验完成后才发布结果。</p>
              </div>
              <button
                className="button"
                disabled={commandsLocked}
                onClick={() => void run('exportPortableData')}
                type="button"
              >
                <Download aria-hidden="true" size={15} /> 导出便携数据
              </button>
            </article>
            <article className="storage-command-card" data-accent="amber">
              <div aria-hidden="true" className="storage-command-icon">
                <HardDrive size={20} />
              </div>
              <div>
                <span>STORAGE ROOT</span>
                <h4>外置应用存储</h4>
                <p>保存授权后需重启，Mac 会在目录库打开前完成整包迁移。</p>
              </div>
              <button
                className="button"
                disabled={commandsLocked}
                onClick={() => void run('chooseExternalStorage')}
                type="button"
              >
                选择外部存储
              </button>
            </article>
          </div>
        </section>

        <section className="storage-reclaim-zone" aria-labelledby="storage-reclaim-title">
          <header className="storage-section-heading">
            <span>02 / RECLAIM</span>
            <div>
              <h3 id="storage-reclaim-title">空间回收</h3>
              <p>只处理 ImageAll 自有副本；每次清理仍需 Web 与 Mac 两层确认。</p>
            </div>
          </header>
          <div className="storage-retention-note">
            <ShieldCheck aria-hidden="true" size={20} />
            <p>
              <strong>长期 Photos 原图默认保留，不自动过期。</strong>
              <span>清理不会修改 Apple Photos、人工标签、Feature Print 或个人模型。</span>
            </p>
          </div>
          <div className="storage-reclaim-grid">
            <article className="storage-reclaim-card">
              <div>
                <span>REBUILDABLE</span>
                <h4>预览缓存</h4>
                <p>网格缩略图与单图预览可按需重建；iCloud 预览之后需要再次手动获取。</p>
              </div>
              <button
                className="button button-danger"
                disabled={commandsLocked || !previewAvailable}
                onClick={() =>
                  setCleanupRequest({
                    action: 'clearPreviewCache',
                    operationID: crypto.randomUUID(),
                  })
                }
                type="button"
              >
                <Trash2 aria-hidden="true" size={15} /> 清理预览缓存
              </button>
              {!previewAvailable ? (
                <p className="storage-action-note">
                  {previewUnavailableReason === 'empty'
                    ? '没有可清理的预览缓存'
                    : '当前不能清理预览缓存'}
                </p>
              ) : null}
            </article>
            <article className="storage-reclaim-card">
              <div>
                <span>LONG-LIVED COPY</span>
                <h4>Photos 原片副本</h4>
                <p>释放 ImageAll 长期副本；后续相同检测可能需要重新从 iCloud 下载。</p>
              </div>
              <button
                className="button button-danger"
                disabled={commandsLocked || !originalsAvailable}
                onClick={() =>
                  setCleanupRequest({
                    action: 'clearPhotosOriginals',
                    operationID: crypto.randomUUID(),
                  })
                }
                type="button"
              >
                <Trash2 aria-hidden="true" size={15} /> 清理原片缓存
              </button>
              {!originalsAvailable ? (
                <p className="storage-action-note">
                  {originalsUnavailableReason === 'librarySlimmingAnalysisInProgress'
                    ? '图库精简正在使用原片副本'
                    : '没有可清理的 Photos 原片副本'}
                </p>
              ) : null}
            </article>
          </div>
        </section>
      </div>
      {snapshot.data.requests.length ? (
        <section
          className="activity-panel storage-history-panel"
          aria-labelledby="storage-requests-title"
        >
          <header className="storage-section-heading">
            <span>03 / LEDGER</span>
            <div>
              <h3 id="storage-requests-title">最近请求</h3>
              <p>阶段与结果均来自 Mac；不会在浏览器里乐观完成。</p>
            </div>
          </header>
          {snapshot.data.requests.map((request) => (
            <article className="activity-row storage-activity-row" key={request.id}>
              <div>
                <strong>{storageLabels[request.action]}</strong>
                <span>{request.message}</span>
              </div>
              <span className="state-pill" data-state={request.phase}>
                {storagePhaseLabels[request.phase]}
              </span>
              {request.result ? (
                <div className="storage-request-results">
                  {request.result.bundleName ? <span>{request.result.bundleName}</span> : null}
                  {request.result.totalRecordCount !== null ? (
                    <span>{request.result.totalRecordCount.toLocaleString('zh-CN')} 条记录</span>
                  ) : null}
                  {request.result.affectedEntryCount !== null ? (
                    <span>{request.result.affectedEntryCount.toLocaleString('zh-CN')} 项</span>
                  ) : null}
                  {request.result.affectedBytes !== null ? (
                    <span>{bytes(request.result.affectedBytes)}</span>
                  ) : null}
                  {request.result.requiresRestart ? <span>重启后生效</span> : null}
                  {request.result.partialReclaim ? <span>部分空间待后续重试</span> : null}
                </div>
              ) : null}
            </article>
          ))}
        </section>
      ) : null}
      {message ? (
        <div className="action-toast" role={messageIsError ? 'alert' : 'status'}>
          <span>{message}</span>
          <button
            aria-label="关闭消息"
            className="icon-button"
            onClick={() => {
              setMessage('');
              setMessageIsError(false);
            }}
            type="button"
          >
            ×
          </button>
        </div>
      ) : null}
      {cleanupRequest ? (
        <StorageCleanupDialog
          action={cleanupRequest.action}
          onCancel={() => setCleanupRequest(null)}
          onConfirm={() => submit(cleanupRequest.action, cleanupRequest.operationID)}
        />
      ) : null}
    </section>
  );
}
