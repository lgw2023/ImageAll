import { useState, type SyntheticEvent } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import { MonitorCog, Smartphone, Trash2 } from 'lucide-react';

import type { GeneralSettings } from '@/api/contracts/management';
import { errorMessage } from '@/api/errors';
import {
  fetchGeneralSettings,
  fetchPairedDevices,
  revokePairedDevice,
  updateGeneralSettings,
  type GeneralSettingsPatch,
} from '@/api/management';
import { useSession } from '@/features/session/SessionContext';

function SettingsForm({
  initial,
  message,
  setMessage,
}: {
  initial: GeneralSettings;
  message: string;
  setMessage: (message: string) => void;
}) {
  const queryClient = useQueryClient();
  const [modelEnabled, setModelEnabled] = useState(initial.localModel.isEnabled);
  const [prewarmEnabled, setPrewarmEnabled] = useState(initial.idleThumbnailPrewarmEnabled);
  const [toolbarMode, setToolbarMode] = useState(initial.toolbarDisplayMode);
  const [maxPending, setMaxPending] = useState(initial.maxPendingSuggestionsPerTag ?? 200);
  const [saving, setSaving] = useState(false);
  const dirty =
    modelEnabled !== initial.localModel.isEnabled ||
    prewarmEnabled !== initial.idleThumbnailPrewarmEnabled ||
    toolbarMode !== initial.toolbarDisplayMode ||
    maxPending !== (initial.maxPendingSuggestionsPerTag ?? 200);

  async function save(event: SyntheticEvent<HTMLFormElement, SubmitEvent>) {
    event.preventDefault();
    setSaving(true);
    setMessage('');
    try {
      const patch: GeneralSettingsPatch = {};
      if (modelEnabled !== initial.localModel.isEnabled) patch.modelEnabled = modelEnabled;
      if (prewarmEnabled !== initial.idleThumbnailPrewarmEnabled)
        patch.idleThumbnailPrewarmEnabled = prewarmEnabled;
      if (toolbarMode !== initial.toolbarDisplayMode) patch.toolbarDisplayMode = toolbarMode;
      if (maxPending !== (initial.maxPendingSuggestionsPerTag ?? 200))
        patch.maxPendingSuggestionsPerTag = maxPending;
      const response = await updateGeneralSettings(patch);
      setModelEnabled(response.settings.localModel.isEnabled);
      setPrewarmEnabled(response.settings.idleThumbnailPrewarmEnabled);
      setToolbarMode(response.settings.toolbarDisplayMode);
      setMaxPending(response.settings.maxPendingSuggestionsPerTag ?? 200);
      queryClient.setQueryData(['general-settings'], response.settings);
      setMessage(
        response.replayed ? '设置请求已重放，Host 状态未重复写入。' : '设置已由 Mac 保存。',
      );
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setSaving(false);
    }
  }

  return (
    <form className="settings-form" onSubmit={(event) => void save(event)}>
      <section className="settings-panel" aria-labelledby="settings-model-title">
        <div className="settings-panel-heading">
          <div>
            <MonitorCog aria-hidden="true" size={18} />
            <div>
              <h3 id="settings-model-title">本地模型</h3>
              <p>
                {initial.localModel.modelName} · {initial.localModel.runtimeName}
              </p>
            </div>
          </div>
          <span className="state-pill" data-state={initial.localModel.state}>
            {initial.localModel.state}
          </span>
        </div>
        <label className="switch-row">
          <span>
            <strong>启用本地模型</strong>
            <small>{initial.localModel.detail}</small>
          </span>
          <input
            checked={modelEnabled}
            onChange={(event) => setModelEnabled(event.target.checked)}
            type="checkbox"
          />
        </label>
      </section>
      <section className="settings-panel" aria-labelledby="settings-behavior-title">
        <h3 id="settings-behavior-title">界面与后台行为</h3>
        <label className="switch-row">
          <span>
            <strong>空闲时预热缩略图</strong>
            <small>Host 空闲 {initial.idleThresholdSeconds} 秒后开始。</small>
          </span>
          <input
            checked={prewarmEnabled}
            onChange={(event) => setPrewarmEnabled(event.target.checked)}
            type="checkbox"
          />
        </label>
        <label className="settings-field">
          <span>Mac 工具栏显示</span>
          <select
            onChange={(event) => setToolbarMode(event.target.value as 'iconOnly' | 'iconAndTitle')}
            value={toolbarMode}
          >
            <option value="iconOnly">仅图标</option>
            <option value="iconAndTitle">图标与标题</option>
          </select>
        </label>
        <label className="settings-field">
          <span>每标签最多待处理建议</span>
          <input
            max={10000}
            min={1}
            onChange={(event) => setMaxPending(event.target.valueAsNumber)}
            type="number"
            value={maxPending}
          />
        </label>
      </section>
      {initial.suggestionThresholds ? (
        <section className="settings-panel" aria-labelledby="threshold-summary-title">
          <h3 id="threshold-summary-title">建议阈值摘要</h3>
          <div className="threshold-summary">
            {initial.suggestionThresholds.defaults.map((row) => (
              <div key={row.method}>
                <span>{row.method}</span>
                <strong>{row.minScore.toFixed(2)}</strong>
              </div>
            ))}
          </div>
          <p className="panel-note">逐标签阈值在训练与精简工作区按 Host 回读编辑。</p>
        </section>
      ) : null}
      <div className="form-actions">
        <button
          className="button"
          disabled={!dirty || saving}
          onClick={() => {
            setModelEnabled(initial.localModel.isEnabled);
            setPrewarmEnabled(initial.idleThumbnailPrewarmEnabled);
            setToolbarMode(initial.toolbarDisplayMode);
            setMaxPending(initial.maxPendingSuggestionsPerTag ?? 200);
          }}
          type="button"
        >
          还原
        </button>
        <button
          className="button button-primary"
          disabled={!dirty || saving || !Number.isInteger(maxPending) || maxPending < 1}
          type="submit"
        >
          {saving ? '正在保存…' : '保存设置'}
        </button>
      </div>
      <p aria-live="polite" className="form-status">
        {message}
      </p>
    </form>
  );
}

function PairedDevicesPanel() {
  const session = useSession();
  const queryClient = useQueryClient();
  const [pendingID, setPendingID] = useState('');
  const [message, setMessage] = useState('');
  const devices = useQuery({
    queryKey: ['pairing-devices'],
    queryFn: ({ signal }) => fetchPairedDevices(signal),
  });
  async function revoke(deviceID: string, name: string) {
    if (!window.confirm(`撤销设备“${name}”？该设备需要重新配对。`)) return;
    setPendingID(deviceID);
    setMessage('');
    try {
      await revokePairedDevice(deviceID);
      setMessage(`已撤销设备“${name}”。`);
      await queryClient.invalidateQueries({ queryKey: ['pairing-devices'] });
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPendingID('');
    }
  }
  return (
    <section className="settings-panel" aria-labelledby="paired-devices-title">
      <h3 id="paired-devices-title">
        <Smartphone aria-hidden="true" size={18} /> 已配对设备
      </h3>
      {devices.isPending ? (
        <p role="status">正在载入设备…</p>
      ) : devices.isError ? (
        <div role="alert">
          <p>{errorMessage(devices.error)}</p>
          <button className="button" onClick={() => void devices.refetch()} type="button">
            重试
          </button>
        </div>
      ) : (
        <div className="device-list">
          {devices.data.map((device) => {
            const current = device.deviceID === session.session?.deviceID;
            return (
              <div className="device-row" key={device.deviceID}>
                <div>
                  <strong>{device.deviceName}</strong>
                  <span>
                    {current
                      ? '当前设备'
                      : `上次使用 ${device.lastSeenAtMs === null ? '—' : new Intl.DateTimeFormat('zh-CN').format(device.lastSeenAtMs)}`}
                  </span>
                </div>
                <button
                  className="button button-danger"
                  disabled={current || Boolean(pendingID)}
                  onClick={() => void revoke(device.deviceID, device.deviceName)}
                  type="button"
                >
                  <Trash2 aria-hidden="true" size={14} /> 撤销
                </button>
              </div>
            );
          })}
        </div>
      )}
      <p aria-live="polite" className="form-status">
        {message}
      </p>
    </section>
  );
}

export function SettingsRoute() {
  const [formMessage, setFormMessage] = useState('');
  const settings = useQuery({
    queryKey: ['general-settings'],
    queryFn: ({ signal }) => fetchGeneralSettings(signal),
  });
  if (settings.isPending)
    return (
      <div className="workspace-state" role="status">
        正在载入设置…
      </div>
    );
  if (settings.isError)
    return (
      <div className="workspace-state workspace-state-error" role="alert">
        <strong>无法载入设置</strong>
        <p>{errorMessage(settings.error)}</p>
        <button className="button" onClick={() => void settings.refetch()} type="button">
          重试
        </button>
      </div>
    );
  return (
    <section className="domain-workspace settings-workspace" aria-labelledby="settings-title">
      <header className="domain-heading">
        <div>
          <p className="eyebrow">管理</p>
          <h2 id="settings-title">设置</h2>
          <p>保存使用部分更新，避免覆盖 Mac 端同时发生的其他设置变更。</p>
        </div>
      </header>
      <SettingsForm initial={settings.data} message={formMessage} setMessage={setFormMessage} />
      <PairedDevicesPanel />
    </section>
  );
}
