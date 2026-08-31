import { useState } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, HardDrive, Trash2 } from 'lucide-react';

import type { StorageMaintenanceAction } from '@/api/contracts/management';
import { errorMessage } from '@/api/errors';
import { fetchStorageMaintenance, submitStorageMaintenance } from '@/api/management';

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

export function StorageRoute() {
  const queryClient = useQueryClient();
  const [pending, setPending] = useState<StorageMaintenanceAction | null>(null);
  const [message, setMessage] = useState('');
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

  async function run(action: StorageMaintenanceAction) {
    if (
      action.startsWith('clear') &&
      !window.confirm(`${storageLabels[action]}？结果将以 Mac Host 回读为准。`)
    )
      return;
    setPending(action);
    setMessage('');
    try {
      const request = await submitStorageMaintenance(action);
      setMessage(request.message || '已向 Mac 提交请求。');
      await queryClient.invalidateQueries({ queryKey: ['storage-maintenance'] });
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPending(null);
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
  return (
    <section className="domain-workspace" aria-labelledby="storage-title">
      <header className="domain-heading">
        <div>
          <p className="eyebrow">管理</p>
          <h2 id="storage-title">存储与维护</h2>
          <p>路径保持脱敏；清理和导出由 Mac 选择并执行。</p>
        </div>
      </header>
      <div className="metric-grid storage-metrics">
        <article className="metric-card">
          <HardDrive aria-hidden="true" size={18} />
          <span>预览缓存</span>
          <strong>{bytes(snapshot.data.previewCache.registeredBytes)}</strong>
          <small>{snapshot.data.previewCache.entryCount.toLocaleString('zh-CN')} 项</small>
        </article>
        <article className="metric-card">
          <HardDrive aria-hidden="true" size={18} />
          <span>Photos 原片缓存</span>
          <strong>{bytes(snapshot.data.photosOriginals.registeredBytes)}</strong>
          <small>{snapshot.data.photosOriginals.entryCount.toLocaleString('zh-CN')} 项</small>
        </article>
        <article className="metric-card">
          <HardDrive aria-hidden="true" size={18} />
          <span>应用存储</span>
          <strong>{snapshot.data.appStorage.kind === 'internalStorage' ? '内部' : '外部'}</strong>
          <small>{snapshot.data.appStorage.requiresRestart ? '需要重启 Mac App' : '已生效'}</small>
        </article>
      </div>
      <section className="maintenance-actions" aria-labelledby="maintenance-actions-title">
        <h3 id="maintenance-actions-title">可用操作</h3>
        <div>
          <button
            className="button"
            disabled={Boolean(pending)}
            onClick={() => void run('exportPortableData')}
            type="button"
          >
            <Download aria-hidden="true" size={15} /> 导出便携数据
          </button>
          <button
            className="button"
            disabled={Boolean(pending)}
            onClick={() => void run('chooseExternalStorage')}
            type="button"
          >
            选择外部存储
          </button>
          <button
            className="button button-danger"
            disabled={Boolean(pending) || !previewAvailable}
            onClick={() => void run('clearPreviewCache')}
            type="button"
          >
            <Trash2 aria-hidden="true" size={15} /> 清理预览缓存
          </button>
          <button
            className="button button-danger"
            disabled={Boolean(pending) || !originalsAvailable}
            onClick={() => void run('clearPhotosOriginals')}
            type="button"
          >
            <Trash2 aria-hidden="true" size={15} /> 清理原片缓存
          </button>
        </div>
      </section>
      {snapshot.data.requests.length ? (
        <section className="activity-panel" aria-labelledby="storage-requests-title">
          <h3 id="storage-requests-title">最近请求</h3>
          {snapshot.data.requests.map((request) => (
            <div className="activity-row" key={request.id}>
              <div>
                <strong>{storageLabels[request.action]}</strong>
                <span>{request.message}</span>
              </div>
              <span className="state-pill" data-state={request.phase}>
                {request.phase}
              </span>
              {request.result?.affectedBytes !== null &&
              request.result?.affectedBytes !== undefined ? (
                <small>影响 {bytes(request.result.affectedBytes)}</small>
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
