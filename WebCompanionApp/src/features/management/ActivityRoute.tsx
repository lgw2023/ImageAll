import { useState } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Pause, Play, RotateCcw, X } from 'lucide-react';
import { Link } from 'react-router-dom';

import type { JobAction } from '@/api/contracts/management';
import { errorMessage } from '@/api/errors';
import { applyJobAction, fetchJobs } from '@/api/management';

const jobKindLabels = {
  folderReconcile: '文件夹同步',
  photosReconcile: 'Photos 同步',
  personalizationSuggestions: '个人建议',
  standardSuggestions: '标准建议',
  librarySlimmingAnalysis: '图库精简分析',
  librarySlimmingSourceIndex: '精简来源索引',
  background: '后台任务',
  other: '其他任务',
} as const;
const jobActionLabels: Record<JobAction, string> = {
  pause: '暂停',
  resume: '继续',
  cancel: '取消',
};

export function ActivityRoute() {
  const queryClient = useQueryClient();
  const [pending, setPending] = useState('');
  const [message, setMessage] = useState('');
  const jobs = useQuery({
    queryKey: ['jobs'],
    queryFn: ({ signal }) => fetchJobs(signal),
    refetchInterval: (query) =>
      query.state.data?.some((job) => ['pending', 'running'].includes(job.state)) ? 2_000 : false,
  });
  async function run(jobID: string, action: JobAction) {
    setPending(`${jobID}:${action}`);
    setMessage('');
    try {
      await applyJobAction(jobID, action);
      setMessage(`已请求${jobActionLabels[action]}任务。`);
      await queryClient.invalidateQueries({ queryKey: ['jobs'] });
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPending('');
    }
  }
  if (jobs.isPending)
    return (
      <div className="workspace-state" role="status">
        正在载入活动…
      </div>
    );
  if (jobs.isError)
    return (
      <div className="workspace-state workspace-state-error" role="alert">
        <strong>无法载入活动</strong>
        <p>{errorMessage(jobs.error)}</p>
        <button className="button" onClick={() => void jobs.refetch()} type="button">
          重试
        </button>
      </div>
    );
  return (
    <section className="domain-workspace" aria-labelledby="activity-title">
      <header className="domain-heading">
        <div>
          <p className="eyebrow">管理</p>
          <h2 id="activity-title">活动</h2>
          <p>任务状态来自 Mac；页面保持轮询直到活动进入稳定状态。</p>
        </div>
        <button className="button" onClick={() => void jobs.refetch()} type="button">
          <RotateCcw aria-hidden="true" size={15} /> 刷新
        </button>
      </header>
      {jobs.data.length ? (
        <div className="job-list">
          {jobs.data.map((job) => {
            const total = job.progress.totalUnitCount;
            const fraction = total && total > 0 ? job.progress.completedUnitCount / total : null;
            return (
              <article className="job-card" key={job.id}>
                <div className="management-card-heading">
                  <div>
                    <strong>{jobKindLabels[job.kind]}</strong>
                    <span>{job.sourceDisplayName ?? '全局任务'}</span>
                  </div>
                  <span className="state-pill" data-state={job.state}>
                    {job.state}
                  </span>
                </div>
                {fraction !== null ? (
                  <progress max={1} value={fraction} />
                ) : (
                  <div className="indeterminate-progress" aria-label="进度未知" />
                )}
                <p>
                  {job.progress.completedUnitCount.toLocaleString('zh-CN')}
                  {total === null ? ' 项已完成' : ` / ${total.toLocaleString('zh-CN')}`}
                </p>
                <div className="card-actions">
                  {job.availableActions.map((action) => (
                    <button
                      className={`button${action === 'cancel' ? ' button-danger' : ''}`}
                      disabled={Boolean(pending)}
                      key={action}
                      onClick={() => void run(job.id, action)}
                      type="button"
                    >
                      {action === 'pause' ? (
                        <Pause aria-hidden="true" size={14} />
                      ) : action === 'resume' ? (
                        <Play aria-hidden="true" size={14} />
                      ) : (
                        <X aria-hidden="true" size={14} />
                      )}
                      {jobActionLabels[action]}
                    </button>
                  ))}
                  {job.navigationTarget ? (
                    <Link className="button" to="/slimming">
                      查看工作区
                    </Link>
                  ) : null}
                </div>
              </article>
            );
          })}
        </div>
      ) : (
        <div className="workspace-state">
          <strong>没有活动任务</strong>
          <p>同步、训练、建议与精简任务会出现在这里。</p>
        </div>
      )}
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
