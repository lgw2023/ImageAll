import { useState } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Cpu, Pause, Play, RefreshCw, X } from 'lucide-react';

import type { LibrarySuggestionSnapshot } from '@/api/contracts/training';
import { errorMessage } from '@/api/errors';
import { applyJobAction } from '@/api/management';
import { fetchLibrarySuggestions, generateLibrarySuggestions } from '@/api/training';

type ReviewLocalModelPanelProps = {
  sourceIDs: string[] | null;
};

type SuggestionTrack = 'standard' | 'personal';
type SuggestionJob = NonNullable<LibrarySuggestionSnapshot['standardJob']>;

const activeJobStates = new Set(['pending', 'running', 'paused', 'retryableFailed']);

const serviceLabels: Record<LibrarySuggestionSnapshot['service']['state'], string> = {
  unchecked: '尚未检查',
  ready: '服务就绪',
  degraded: '模型未加载',
  unavailable: '服务不可用',
};

const jobLabels: Record<SuggestionJob['state'], string> = {
  pending: '等待中',
  running: '运行中',
  paused: '已暂停',
  retryableFailed: '等待重试',
  completed: '已完成',
  terminalFailed: '失败',
  cancelled: '已取消',
};

const actionLabels = { pause: '暂停', resume: '继续', cancel: '取消' } as const;

function trackJob(snapshot: LibrarySuggestionSnapshot, track: SuggestionTrack) {
  return track === 'standard' ? snapshot.standardJob : snapshot.personalJob;
}

export function ReviewLocalModelPanel({ sourceIDs }: ReviewLocalModelPanelProps) {
  const queryClient = useQueryClient();
  const [pending, setPending] = useState('');
  const [message, setMessage] = useState('');
  const [failure, setFailure] = useState('');
  const library = useQuery({
    queryKey: ['library-suggestions', 'image'],
    queryFn: ({ signal }) => fetchLibrarySuggestions('image', false, signal),
    refetchInterval: (query) => {
      const snapshot = query.state.data;
      return [snapshot?.standardJob, snapshot?.personalJob].some(
        (job) => job && activeJobStates.has(job.state),
      )
        ? 2_000
        : false;
    },
  });

  async function refreshProjections() {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ['library-suggestions', 'image'] }),
      queryClient.invalidateQueries({ queryKey: ['review-overview'] }),
      queryClient.invalidateQueries({ queryKey: ['jobs'] }),
    ]);
  }

  async function perform(key: string, action: () => Promise<unknown>, success: string) {
    setPending(key);
    setMessage('');
    setFailure('');
    try {
      await action();
      await refreshProjections();
      setMessage(success);
    } catch (error) {
      setFailure(errorMessage(error));
    } finally {
      setPending('');
    }
  }

  async function refreshHealth() {
    setPending('health');
    setMessage('');
    setFailure('');
    try {
      const snapshot = await fetchLibrarySuggestions('image', true);
      queryClient.setQueryData(['library-suggestions', 'image'], snapshot);
      setMessage('Mac 已重新检查本地模型服务。');
    } catch (error) {
      setFailure(errorMessage(error));
    } finally {
      setPending('');
    }
  }

  function renderTrack(snapshot: LibrarySuggestionSnapshot, track: SuggestionTrack) {
    const job = trackJob(snapshot, track);
    const title = track === 'standard' ? '标准模型' : '个人模型';
    const available =
      track === 'standard' ? snapshot.standardAvailable : snapshot.personalMode !== 'unavailable';
    const anotherJobActive = [snapshot.standardJob, snapshot.personalJob].some(
      (candidate) =>
        candidate && candidate.jobID !== job?.jobID && activeJobStates.has(candidate.state),
    );
    const currentJobActive = Boolean(job && activeJobStates.has(job.state));
    const canGenerate =
      available && sourceIDs?.length !== 0 && !currentJobActive && !anotherJobActive && !pending;

    return (
      <article aria-label={title} className="review-model-card">
        <header>
          <div>
            <strong>{title}</strong>
            <span>
              {track === 'personal'
                ? snapshot.personalMode === 'sample'
                  ? '全量扫描'
                  : '全库模式'
                : '全库扫描'}
            </span>
          </div>
          {job ? (
            <span className="state-pill" data-state={job.state}>
              {jobLabels[job.state]}
            </span>
          ) : null}
        </header>

        {job ? (
          <div className="review-model-progress">
            <div>
              <span>
                {job.checkedCount.toLocaleString('zh-CN')} /{' '}
                {job.totalCount?.toLocaleString('zh-CN') ?? '—'}
              </span>
              <span>
                建议 {job.suggestedCount.toLocaleString('zh-CN')} · 跳过{' '}
                {job.skippedCount.toLocaleString('zh-CN')}
              </span>
            </div>
            <progress
              aria-label={`${title}进度`}
              max={job.totalCount ?? Math.max(job.checkedCount, 1)}
              value={job.checkedCount}
            />
            {job.lastErrorCode ? <p>{job.lastErrorCode}</p> : null}
          </div>
        ) : (
          <p>{available ? '尚未启动任务。' : '当前模型不可用。'}</p>
        )}

        <div className="review-model-actions">
          {job?.availableActions.map((action) => (
            <button
              className={`button${action === 'cancel' ? ' button-danger' : ''}`}
              disabled={Boolean(pending)}
              key={action}
              onClick={() =>
                void perform(
                  `job:${job.jobID}:${action}`,
                  () => applyJobAction(job.jobID, action),
                  `Mac 已接受${actionLabels[action]}请求。`,
                )
              }
              type="button"
            >
              {action === 'pause' ? (
                <Pause aria-hidden="true" size={14} />
              ) : action === 'resume' ? (
                <Play aria-hidden="true" size={14} />
              ) : (
                <X aria-hidden="true" size={14} />
              )}
              {actionLabels[action]}
            </button>
          ))}
          {!currentJobActive ? (
            <button
              className="button button-primary"
              disabled={!canGenerate}
              onClick={() =>
                void perform(
                  `generate:${track}`,
                  () => generateLibrarySuggestions('image', track, sourceIDs),
                  `Mac 已接受${title}建议任务。`,
                )
              }
              type="button"
            >
              <Play aria-hidden="true" size={14} /> 开始生成
            </button>
          ) : null}
        </div>
      </article>
    );
  }

  return (
    <aside aria-label="本地模型" className="review-local-model-panel" role="region">
      <header className="review-model-panel-heading">
        <div>
          <Cpu aria-hidden="true" size={19} />
          <div>
            <h3>本地模型</h3>
            <p>建议只进入待审队列，不会自动确认标签。</p>
          </div>
        </div>
        <button
          aria-label="检查服务"
          className="icon-button"
          disabled={Boolean(pending)}
          onClick={() => void refreshHealth()}
          title="重新检查本地模型服务"
          type="button"
        >
          <RefreshCw aria-hidden="true" size={15} />
        </button>
      </header>

      {library.isPending ? (
        <div className="review-model-panel-state" role="status">
          正在读取模型状态…
        </div>
      ) : library.isError ? (
        <div className="review-model-panel-state" role="alert">
          <strong>无法读取本地模型状态</strong>
          <p>{errorMessage(library.error)}</p>
          <button className="button" onClick={() => void library.refetch()} type="button">
            重试
          </button>
        </div>
      ) : (
        <>
          <div className="review-model-service">
            <span className="state-pill" data-state={library.data.service.state}>
              {serviceLabels[library.data.service.state]}
            </span>
            <strong>{library.data.service.provider ?? '提供方未报告'}</strong>
            <span>
              {library.data.service.modelID ?? '模型未报告'}
              {library.data.service.serviceVersion
                ? ` · v${library.data.service.serviceVersion}`
                : ''}
            </span>
          </div>
          <div className="review-model-tracks">
            {renderTrack(library.data, 'standard')}
            {renderTrack(library.data, 'personal')}
          </div>
        </>
      )}

      {sourceIDs?.length === 0 ? (
        <p className="review-model-scope-note">当前未选择来源，任务启动已禁用。</p>
      ) : null}
      {message ? (
        <div className="review-model-message" role="status">
          {message}
        </div>
      ) : null}
      {failure ? (
        <div className="review-model-message review-model-message-error" role="alert">
          {failure}
        </div>
      ) : null}
    </aside>
  );
}
