import { useMemo, useState } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import {
  BrainCircuit,
  CheckCircle2,
  DatabaseZap,
  Pause,
  Play,
  RotateCcw,
  Sparkles,
  X,
} from 'lucide-react';
import { Link } from 'react-router-dom';

import type { AssetMediaKind } from '@/api/contracts/asset';
import type {
  EmbeddingPreparationActivity,
  LibrarySuggestionSnapshot,
  SampleSuggestionActivity,
  TagLibrarySuggestionActivity,
  TrainingActivity,
  TrainingMethod,
} from '@/api/contracts/training';
import { errorMessage } from '@/api/errors';
import { applyJobAction } from '@/api/management';
import {
  cancelEmbeddingPreparation,
  cancelSampleSuggestions,
  cancelTagLibrarySuggestions,
  cancelTraining,
  fetchEmbeddingPreparation,
  fetchLibrarySuggestions,
  fetchSampleSuggestions,
  fetchTagLibrarySuggestions,
  fetchTrainingActivities,
  fetchTrainingSetup,
  fetchTrainingWorkspace,
  generateLibrarySuggestions,
  generateSampleSuggestions,
  generateTagLibrarySuggestions,
  launchTraining,
} from '@/api/training';

type TrainingSection = 'models' | 'preparation' | 'suggestions';

const methodLabels: Record<TrainingMethod, string> = {
  featureKnn: '相似内容模型',
  personalCentroid: '快速个人模型',
  personalAdamW: '增强个人模型',
};
const phaseLabels: Record<TrainingActivity['phase'], string> = {
  preparingSamples: '准备样本',
  preparingEmbeddings: '准备嵌入',
  trainingAndPublishing: '训练并发布',
  completed: '已完成',
  failed: '失败',
  cancelled: '已取消',
};
const tagPhaseLabels: Record<string, string> = {
  pending: '等待中',
  preparingSamples: '准备样本',
  preparingEmbeddings: '准备嵌入',
  trainingAndPublishing: '训练并发布',
  succeeded: '已完成',
  skipped: '已跳过',
  failed: '失败',
  cancelled: '已取消',
};

function isActive(phase: string) {
  return [
    'preparingSamples',
    'preparingEmbeddings',
    'trainingAndPublishing',
    'running',
    'preparingCandidates',
    'scoring',
    'publishing',
  ].includes(phase);
}

function dateTime(value: number) {
  if (!value) return '尚未记录';
  return new Intl.DateTimeFormat('zh-CN', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value));
}

function ProgressBar({
  completed,
  total,
  label,
}: {
  completed: number;
  total: number;
  label: string;
}) {
  const value = total > 0 ? Math.min(1, completed / total) : 0;
  return (
    <div className="training-progress">
      <div>
        <span>{label}</span>
        <span>
          {completed.toLocaleString('zh-CN')} / {total.toLocaleString('zh-CN')}
        </span>
      </div>
      <progress aria-label={label} max={1} value={value} />
    </div>
  );
}

function PanelError({ label, error, retry }: { label: string; error: unknown; retry: () => void }) {
  return (
    <div className="training-panel-state training-panel-error" role="alert">
      <strong>{label}</strong>
      <span>{errorMessage(error)}</span>
      <button className="button" onClick={retry} type="button">
        重试
      </button>
    </div>
  );
}

function ActivityCard({
  activity,
  pending,
  cancel,
}: {
  activity: TrainingActivity;
  pending: boolean;
  cancel: (operationID: string) => void;
}) {
  return (
    <article className="training-activity-card">
      <div className="training-card-heading">
        <div>
          <strong>{methodLabels[activity.method]}</strong>
          <span>{dateTime(activity.updatedAtMs || activity.acceptedAtMs)}</span>
        </div>
        <span className="state-pill" data-state={activity.phase}>
          {phaseLabels[activity.phase]}
        </span>
      </div>
      <ProgressBar
        completed={activity.completedUnitCount}
        label="训练进度"
        total={activity.totalUnitCount}
      />
      {activity.sampleCount !== null ? (
        <p>样本 {activity.sampleCount.toLocaleString('zh-CN')} 项</p>
      ) : null}
      {activity.tagActivities.length ? (
        <ul className="training-tag-activity-list">
          {activity.tagActivities.map((tag) => (
            <li key={tag.tagID}>
              <span>{tag.displayName}</span>
              <span>{tagPhaseLabels[tag.phase] ?? tag.phase}</span>
            </li>
          ))}
        </ul>
      ) : null}
      {activity.errorCode ? <p className="inline-error">错误代码：{activity.errorCode}</p> : null}
      {activity.availableActions.includes('cancel') ? (
        <button
          className="button button-danger"
          disabled={pending}
          onClick={() => cancel(activity.operationID)}
          type="button"
        >
          <X aria-hidden="true" size={14} /> 停止训练
        </button>
      ) : null}
    </article>
  );
}

function PreparationActivityCard({
  activity,
  kind,
  pending,
  cancel,
}: {
  activity: EmbeddingPreparationActivity | SampleSuggestionActivity;
  kind: 'embedding' | 'sample';
  pending: boolean;
  cancel: (operationID: string) => void;
}) {
  const embedding = kind === 'embedding' ? (activity as EmbeddingPreparationActivity) : null;
  const sample = kind === 'sample' ? (activity as SampleSuggestionActivity) : null;
  return (
    <article className="training-activity-card">
      <div className="training-card-heading">
        <strong>{kind === 'embedding' ? '所选项目特征' : '个人建议抽检'}</strong>
        <span className="state-pill" data-state={activity.phase}>
          {activity.phase}
        </span>
      </div>
      <ProgressBar
        completed={activity.completedUnitCount}
        label={kind === 'embedding' ? '特征准备进度' : '建议抽检进度'}
        total={activity.totalUnitCount}
      />
      <div className="training-count-row">
        {embedding ? (
          <>
            <span>新准备 {embedding.preparedCount}</span>
            <span>已有缓存 {embedding.cachedCount}</span>
            <span>仅云端 {embedding.cloudOnlyCount}</span>
            <span>失败 {embedding.failedCount}</span>
          </>
        ) : (
          <>
            <span>已建议 {sample?.suggestedCount ?? 0}</span>
            <span>已跳过 {sample?.skippedCount ?? 0}</span>
          </>
        )}
      </div>
      {activity.errorCode ? <p className="inline-error">错误代码：{activity.errorCode}</p> : null}
      {activity.availableActions.includes('cancel') ? (
        <button
          className="button button-danger"
          disabled={pending}
          onClick={() => cancel(activity.operationID)}
          type="button"
        >
          <X aria-hidden="true" size={14} /> 停止
        </button>
      ) : null}
    </article>
  );
}

export function TrainingRoute() {
  const queryClient = useQueryClient();
  const [mediaKind, setMediaKind] = useState<AssetMediaKind>('image');
  const [section, setSection] = useState<TrainingSection>('models');
  const [method, setMethod] = useState<TrainingMethod>('featureKnn');
  const [selectedTags, setSelectedTags] = useState<Set<string>>(new Set());
  const [sourceSelection, setSourceSelection] = useState<{
    mediaKind: AssetMediaKind;
    ids: Set<string>;
  } | null>(null);
  const [tagSuggestionMethod, setTagSuggestionMethod] = useState<
    'personalCentroid' | 'personalAdamW'
  >('personalCentroid');
  const [tagSuggestionTagID, setTagSuggestionTagID] = useState('');
  const [pending, setPending] = useState('');
  const [message, setMessage] = useState('');

  const setup = useQuery({
    queryKey: ['training-setup', mediaKind],
    queryFn: ({ signal }) => fetchTrainingSetup(mediaKind, signal),
  });
  const workspace = useQuery({
    queryKey: ['training-workspace', mediaKind],
    queryFn: ({ signal }) => fetchTrainingWorkspace(mediaKind, signal),
  });
  const activities = useQuery({
    queryKey: ['training-activities', mediaKind],
    queryFn: ({ signal }) => fetchTrainingActivities(mediaKind, signal),
    refetchInterval: (query) =>
      query.state.data?.some((activity) => isActive(activity.phase)) ? 1_500 : false,
  });
  const embedding = useQuery({
    queryKey: ['embedding-preparation', mediaKind],
    queryFn: ({ signal }) => fetchEmbeddingPreparation(mediaKind, signal),
    refetchInterval: (query) =>
      query.state.data?.activities.some((activity) => activity.phase === 'running') ? 1_500 : false,
  });
  const samples = useQuery({
    queryKey: ['sample-suggestions', mediaKind],
    queryFn: ({ signal }) => fetchSampleSuggestions(mediaKind, signal),
    refetchInterval: (query) =>
      query.state.data?.activities.some((activity) => activity.phase === 'running') ? 1_500 : false,
  });
  const library = useQuery({
    queryKey: ['library-suggestions', mediaKind],
    queryFn: ({ signal }) => fetchLibrarySuggestions(mediaKind, false, signal),
    refetchInterval: (query) => {
      const data = query.state.data;
      return [data?.standardJob, data?.personalJob].some((job) =>
        job ? ['pending', 'running', 'paused', 'retryableFailed'].includes(job.state) : false,
      )
        ? 2_000
        : false;
    },
  });
  const tagSuggestions = useQuery({
    queryKey: ['tag-library-suggestions', mediaKind],
    queryFn: ({ signal }) => fetchTagLibrarySuggestions(mediaKind, signal),
    refetchInterval: (query) =>
      query.state.data?.activities.some((activity) => isActive(activity.phase)) ? 1_500 : false,
  });

  const selectedSources = useMemo(
    () =>
      sourceSelection?.mediaKind === mediaKind
        ? sourceSelection.ids
        : new Set((setup.data?.sources ?? []).map((source) => source.id)),
    [mediaKind, setup.data?.sources, sourceSelection],
  );
  const effectiveMethod =
    setup.data?.methods.find((item) => item.method === method && item.isAvailable)?.method ??
    setup.data?.methods.find((item) => item.isAvailable)?.method ??
    method;
  function setSelectedSources(ids: Set<string>) {
    setSourceSelection({ mediaKind, ids });
  }

  const eligibleTags = useMemo(
    () =>
      (setup.data?.tags ?? []).filter((tag) =>
        effectiveMethod === 'featureKnn' ? tag.featureMode !== null : tag.personalEligible,
      ),
    [effectiveMethod, setup.data?.tags],
  );
  const tagNames = useMemo(
    () => new Map((setup.data?.tags ?? []).map((tag) => [tag.id, tag.displayName])),
    [setup.data?.tags],
  );

  async function perform(key: string, action: () => Promise<unknown>, success: string) {
    setPending(key);
    setMessage('');
    try {
      await action();
      setMessage(success);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['training-workspace', mediaKind] }),
        queryClient.invalidateQueries({ queryKey: ['training-activities', mediaKind] }),
        queryClient.invalidateQueries({ queryKey: ['embedding-preparation', mediaKind] }),
        queryClient.invalidateQueries({ queryKey: ['sample-suggestions', mediaKind] }),
        queryClient.invalidateQueries({ queryKey: ['library-suggestions', mediaKind] }),
        queryClient.invalidateQueries({ queryKey: ['tag-library-suggestions', mediaKind] }),
        queryClient.invalidateQueries({ queryKey: ['jobs'] }),
      ]);
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPending('');
    }
  }

  function toggle(setter: (value: Set<string>) => void, current: Set<string>, id: string) {
    const next = new Set(current);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setter(next);
  }

  function launch() {
    if (!selectedTags.size) return;
    const sourceIDs = effectiveMethod === 'featureKnn' ? [...selectedSources] : [];
    void perform(
      'launch',
      () =>
        launchTraining({
          mediaKind,
          method: effectiveMethod,
          tagIDs: [...selectedTags],
          sourceIDs,
        }),
      `Mac 已接受 ${String(selectedTags.size)} 个标签的${methodLabels[effectiveMethod]}任务。`,
    );
  }

  function renderModels() {
    if (setup.isError)
      return (
        <PanelError
          error={setup.error}
          label="无法载入训练配置"
          retry={() => void setup.refetch()}
        />
      );
    if (setup.isPending)
      return (
        <div className="training-panel-state" role="status">
          正在读取训练配置…
        </div>
      );
    const methodAvailable = setup.data.methods.find(
      (item) => item.method === effectiveMethod,
    )?.isAvailable;
    const featureScopeValid = effectiveMethod !== 'featureKnn' || selectedSources.size > 0;
    return (
      <div className="training-workbench-grid">
        <section
          className="training-panel training-launch-panel"
          aria-labelledby="training-launch-title"
        >
          <div className="panel-title-row">
            <div>
              <h3 id="training-launch-title">新建训练</h3>
              <p>标签、方法与范围在提交前保持本地草稿；Mac 接受后才创建任务。</p>
            </div>
            <BrainCircuit aria-hidden="true" size={20} />
          </div>
          <fieldset className="training-choice-group">
            <legend>方法</legend>
            {setup.data.methods.map((item) => (
              <label key={item.method}>
                <input
                  checked={effectiveMethod === item.method}
                  disabled={!item.isAvailable || Boolean(pending)}
                  name="training-method"
                  onChange={() => {
                    setMethod(item.method);
                    setSelectedTags(new Set());
                  }}
                  type="radio"
                />
                <span>
                  <strong>{methodLabels[item.method]}</strong>
                  <small>{item.isAvailable ? '当前可用' : '当前 Host 不可用'}</small>
                </span>
              </label>
            ))}
          </fieldset>
          <fieldset className="training-choice-group training-scroll-choices">
            <legend>训练标签</legend>
            {eligibleTags.length ? (
              eligibleTags.map((tag) => (
                <label key={tag.id}>
                  <input
                    checked={selectedTags.has(tag.id)}
                    disabled={Boolean(pending)}
                    onChange={() => toggle(setSelectedTags, selectedTags, tag.id)}
                    type="checkbox"
                  />
                  <span>
                    <strong>{tag.displayName}</strong>
                    <small>
                      确认 {tag.acceptedSampleCount} · 拒绝 {tag.rejectedSampleCount}
                    </small>
                  </span>
                </label>
              ))
            ) : (
              <p className="panel-note">当前方法没有满足 Host 前置条件的标签。</p>
            )}
          </fieldset>
          {effectiveMethod === 'featureKnn' ? (
            <fieldset className="training-choice-group training-scroll-choices">
              <legend>来源范围</legend>
              {setup.data.sources.map((source) => (
                <label key={source.id}>
                  <input
                    checked={selectedSources.has(source.id)}
                    disabled={Boolean(pending)}
                    onChange={() => toggle(setSelectedSources, selectedSources, source.id)}
                    type="checkbox"
                  />
                  <span>{source.displayName}</span>
                </label>
              ))}
            </fieldset>
          ) : (
            <p className="training-scope-note">
              范围：全部合格样本；个人模型的来源解析由 Mac 执行。
            </p>
          )}
          <div className="training-submit-row">
            <span>
              {selectedTags.size} 个标签
              {effectiveMethod === 'featureKnn'
                ? ` · ${String(selectedSources.size)} 个来源`
                : ' · 全部合格样本'}
            </span>
            <button
              className="button button-primary"
              disabled={
                Boolean(pending) || !methodAvailable || !selectedTags.size || !featureScopeValid
              }
              onClick={launch}
              type="button"
            >
              <Play aria-hidden="true" size={14} />{' '}
              {pending === 'launch' ? '正在提交…' : '开始训练'}
            </button>
          </div>
        </section>

        <section className="training-panel" aria-labelledby="training-live-title">
          <div className="panel-title-row">
            <div>
              <h3 id="training-live-title">当前活动</h3>
              <p>活动时自动轮询；取消结果以 Mac 返回为准。</p>
            </div>
            <button
              className="icon-button"
              onClick={() => void activities.refetch()}
              type="button"
              aria-label="刷新训练活动"
            >
              <RotateCcw aria-hidden="true" size={15} />
            </button>
          </div>
          {activities.isError ? (
            <PanelError
              error={activities.error}
              label="无法载入训练活动"
              retry={() => void activities.refetch()}
            />
          ) : activities.data?.length ? (
            <div className="training-activity-list">
              {activities.data.map((activity) => (
                <ActivityCard
                  activity={activity}
                  cancel={(id) =>
                    void perform(`training:${id}`, () => cancelTraining(id), 'Mac 已确认停止训练。')
                  }
                  key={activity.operationID}
                  pending={Boolean(pending)}
                />
              ))}
            </div>
          ) : (
            <div className="training-panel-state">当前没有训练活动。</div>
          )}
        </section>

        <section
          className="training-panel training-history-panel"
          aria-labelledby="training-history-title"
        >
          <div className="panel-title-row">
            <div>
              <h3 id="training-history-title">发布槽位与历史</h3>
              <p>这里只展示 Host 记录，不把完成状态推断为模型质量。</p>
            </div>
          </div>
          {workspace.isError ? (
            <PanelError
              error={workspace.error}
              label="无法载入训练历史"
              retry={() => void workspace.refetch()}
            />
          ) : workspace.isPending ? (
            <div className="training-panel-state" role="status">
              正在读取历史…
            </div>
          ) : (
            <>
              <div className="training-slot-grid">
                {workspace.data.slots.map((slot) => (
                  <div key={slot.method}>
                    <span>{methodLabels[slot.method]}</span>
                    <strong>{slot.isPublished ? '已发布' : '未发布'}</strong>
                  </div>
                ))}
              </div>
              <div className="training-run-list">
                {workspace.data.runs.slice(0, 12).map((run) => (
                  <article key={run.id}>
                    <div>
                      <strong>{run.tagDisplayName ?? methodLabels[run.method]}</strong>
                      <span>{dateTime(run.createdAtMs)}</span>
                    </div>
                    <span className="state-pill" data-state={run.state}>
                      {run.state}
                    </span>
                    <span>
                      {run.sampleCount === null
                        ? '样本未记录'
                        : `${run.sampleCount.toLocaleString('zh-CN')} 个样本`}
                    </span>
                    {run.failureGuidance ? (
                      <p className="inline-error">
                        {run.failureGuidance.title}：{run.failureGuidance.message}
                      </p>
                    ) : null}
                  </article>
                ))}
                {!workspace.data.runs.length ? (
                  <p className="panel-note">还没有训练记录。</p>
                ) : null}
              </div>
            </>
          )}
        </section>
      </div>
    );
  }

  function renderPreparation() {
    return (
      <div className="training-workbench-grid">
        <section className="training-panel" aria-labelledby="embedding-title">
          <div className="panel-title-row">
            <div>
              <h3 id="embedding-title">所选项目特征</h3>
              <p>从图库明确选择项目后交给 Mac 准备；这里跟踪或停止任务。</p>
            </div>
            <DatabaseZap aria-hidden="true" size={20} />
          </div>
          {embedding.isError ? (
            <PanelError
              error={embedding.error}
              label="无法载入特征准备"
              retry={() => void embedding.refetch()}
            />
          ) : embedding.data ? (
            <>
              <div className="training-availability-row">
                <span
                  className="state-pill"
                  data-state={embedding.data.isAvailable ? 'ready' : 'unavailable'}
                >
                  {embedding.data.isAvailable ? 'Mac 已就绪' : '当前不可用'}
                </span>
                <Link className="button" to={`/gallery?media=${mediaKind}`}>
                  前往图库选择
                </Link>
              </div>
              <div className="training-activity-list">
                {embedding.data.activities.map((activity) => (
                  <PreparationActivityCard
                    activity={activity}
                    cancel={(id) =>
                      void perform(
                        `embedding:${id}`,
                        () => cancelEmbeddingPreparation(id),
                        'Mac 已停止特征准备。',
                      )
                    }
                    key={activity.operationID}
                    kind="embedding"
                    pending={Boolean(pending)}
                  />
                ))}
              </div>
            </>
          ) : (
            <div className="training-panel-state" role="status">
              正在读取特征准备状态…
            </div>
          )}
        </section>

        <section className="training-panel" aria-labelledby="sample-title">
          <div className="panel-title-row">
            <div>
              <h3 id="sample-title">个人建议抽检</h3>
              <p>扫描明确来源中的全部可用项目；结果进入审核队列。</p>
            </div>
            <Sparkles aria-hidden="true" size={20} />
          </div>
          {samples.isError ? (
            <PanelError
              error={samples.error}
              label="无法载入抽检状态"
              retry={() => void samples.refetch()}
            />
          ) : samples.data ? (
            <>
              <div className="training-source-summary">
                <span>本次范围：{selectedSources.size} 个来源</span>
                <button
                  className="button button-primary"
                  disabled={!samples.data.isAvailable || !selectedSources.size || Boolean(pending)}
                  onClick={() =>
                    void perform(
                      'sample',
                      () => generateSampleSuggestions(mediaKind, [...selectedSources]),
                      'Mac 已接受个人建议抽检任务。',
                    )
                  }
                  type="button"
                >
                  <Play aria-hidden="true" size={14} />{' '}
                  {pending === 'sample' ? '正在提交…' : '开始抽检'}
                </button>
              </div>
              <div className="training-activity-list">
                {samples.data.activities.map((activity) => (
                  <PreparationActivityCard
                    activity={activity}
                    cancel={(id) =>
                      void perform(
                        `sample:${id}`,
                        () => cancelSampleSuggestions(id),
                        'Mac 已停止个人建议抽检。',
                      )
                    }
                    key={activity.operationID}
                    kind="sample"
                    pending={Boolean(pending)}
                  />
                ))}
              </div>
            </>
          ) : (
            <div className="training-panel-state" role="status">
              正在读取抽检状态…
            </div>
          )}
        </section>

        <section
          className="training-panel training-source-panel"
          aria-labelledby="preparation-sources-title"
        >
          <div className="panel-title-row">
            <div>
              <h3 id="preparation-sources-title">建议来源范围</h3>
              <p>抽检、全库建议和按标签建议共用这一明确选择。</p>
            </div>
          </div>
          <fieldset className="training-choice-group training-source-grid">
            <legend className="visually-hidden">选择建议来源</legend>
            {(setup.data?.sources ?? []).map((source) => (
              <label key={source.id}>
                <input
                  checked={selectedSources.has(source.id)}
                  disabled={Boolean(pending)}
                  onChange={() => toggle(setSelectedSources, selectedSources, source.id)}
                  type="checkbox"
                />
                <span>{source.displayName}</span>
              </label>
            ))}
          </fieldset>
        </section>
      </div>
    );
  }

  function libraryJobCard(snapshot: LibrarySuggestionSnapshot, track: 'standard' | 'personal') {
    const job = track === 'standard' ? snapshot.standardJob : snapshot.personalJob;
    const title = track === 'standard' ? '标准模型建议' : '个人模型全库建议';
    const available =
      track === 'standard' ? snapshot.standardAvailable : snapshot.personalMode !== 'unavailable';
    return (
      <article className="training-suggestion-card">
        <div className="training-card-heading">
          <div>
            <strong>{title}</strong>
            <span>
              {track === 'personal'
                ? `模式：${snapshot.personalMode}`
                : `服务：${snapshot.service.state}`}
            </span>
          </div>
          {job ? (
            <span className="state-pill" data-state={job.state}>
              {job.state}
            </span>
          ) : null}
        </div>
        {job ? (
          <>
            <ProgressBar
              completed={job.checkedCount}
              label={`${title}进度`}
              total={job.totalCount ?? job.checkedCount}
            />
            <div className="training-count-row">
              <span>建议 {job.suggestedCount}</span>
              <span>跳过 {job.skippedCount}</span>
            </div>
            <div className="card-actions">
              {job.availableActions.map((action) => (
                <button
                  className={`button${action === 'cancel' ? ' button-danger' : ''}`}
                  disabled={Boolean(pending)}
                  key={action}
                  onClick={() =>
                    void perform(
                      `job:${job.jobID}:${action}`,
                      () => applyJobAction(job.jobID, action),
                      `Mac 已接受${action === 'pause' ? '暂停' : action === 'resume' ? '继续' : '取消'}请求。`,
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
                  {action === 'pause' ? '暂停' : action === 'resume' ? '继续' : '取消'}
                </button>
              ))}
            </div>
          </>
        ) : (
          <button
            className="button button-primary"
            disabled={!available || !selectedSources.size || Boolean(pending)}
            onClick={() =>
              void perform(
                `library:${track}`,
                () => generateLibrarySuggestions(mediaKind, track, [...selectedSources]),
                `Mac 已接受${title}任务。`,
              )
            }
            type="button"
          >
            <Play aria-hidden="true" size={14} /> 开始生成
          </button>
        )}
      </article>
    );
  }

  function renderTagActivity(activity: TagLibrarySuggestionActivity) {
    return (
      <article className="training-activity-card" key={activity.operationID}>
        <div className="training-card-heading">
          <div>
            <strong>{tagNames.get(activity.tagID) ?? '标签建议'}</strong>
            <span>{methodLabels[activity.method]}</span>
          </div>
          <span className="state-pill" data-state={activity.phase}>
            {activity.phase}
          </span>
        </div>
        <ProgressBar
          completed={activity.completedUnitCount}
          label="按标签建议进度"
          total={activity.totalUnitCount}
        />
        <div className="training-count-row">
          <span>达阈值 {activity.aboveThresholdCount}</span>
          <span>写入 {activity.insertedCount}</span>
          <span>跳过 {activity.skippedCount}</span>
        </div>
        {activity.availableActions.includes('cancel') ? (
          <button
            className="button button-danger"
            disabled={Boolean(pending)}
            onClick={() =>
              void perform(
                `tag-suggestion:${activity.operationID}`,
                () => cancelTagLibrarySuggestions(activity.operationID),
                'Mac 已停止按标签建议任务。',
              )
            }
            type="button"
          >
            <X aria-hidden="true" size={14} /> 停止
          </button>
        ) : null}
      </article>
    );
  }

  function renderSuggestions() {
    const selectedTagOption = tagSuggestions.data?.tags.find(
      (tag) => tag.tagID === tagSuggestionTagID,
    );
    const tagMethodAvailable =
      tagSuggestionMethod === 'personalCentroid'
        ? tagSuggestions.data?.personalCentroidAvailable
        : tagSuggestions.data?.personalAdamWAvailable;
    const threshold =
      tagSuggestionMethod === 'personalCentroid'
        ? selectedTagOption?.personalCentroidMinScore
        : selectedTagOption?.personalAdamWMinScore;
    return (
      <div className="training-workbench-grid">
        <section className="training-panel" aria-labelledby="library-suggestions-title">
          <div className="panel-title-row">
            <div>
              <h3 id="library-suggestions-title">全库建议</h3>
              <p>扫描 {selectedSources.size} 个明确来源；结果进入待审核建议，不会自动确认标签。</p>
            </div>
            <Sparkles aria-hidden="true" size={20} />
          </div>
          {library.isError ? (
            <PanelError
              error={library.error}
              label="无法载入全库建议"
              retry={() => void library.refetch()}
            />
          ) : library.data ? (
            <>
              <div className="training-service-row">
                <span className="state-pill" data-state={library.data.service.state}>
                  {library.data.service.state}
                </span>
                <span>
                  {library.data.service.provider ?? '服务提供方未报告'} ·{' '}
                  {library.data.service.modelID ?? '模型未报告'}
                </span>
                <button
                  className="button"
                  disabled={Boolean(pending)}
                  onClick={() =>
                    void perform(
                      'health',
                      async () => {
                        const snapshot = await fetchLibrarySuggestions(mediaKind, true);
                        queryClient.setQueryData(['library-suggestions', mediaKind], snapshot);
                      },
                      'Mac 已重新检查建议服务。',
                    )
                  }
                  type="button"
                >
                  检查服务
                </button>
              </div>
              <div className="training-suggestion-grid">
                {libraryJobCard(library.data, 'standard')}
                {libraryJobCard(library.data, 'personal')}
              </div>
            </>
          ) : (
            <div className="training-panel-state" role="status">
              正在读取全库建议…
            </div>
          )}
        </section>

        <section className="training-panel" aria-labelledby="tag-suggestions-title">
          <div className="panel-title-row">
            <div>
              <h3 id="tag-suggestions-title">按标签生成建议</h3>
              <p>阈值和可用性来自 Mac；保留门槛以上的全部建议。</p>
            </div>
          </div>
          {tagSuggestions.isError ? (
            <PanelError
              error={tagSuggestions.error}
              label="无法载入标签建议"
              retry={() => void tagSuggestions.refetch()}
            />
          ) : tagSuggestions.data ? (
            <>
              <div className="training-tag-suggestion-form">
                <label className="settings-field">
                  <span>个人模型</span>
                  <select
                    disabled={Boolean(pending)}
                    onChange={(event) =>
                      setTagSuggestionMethod(
                        event.target.value as 'personalCentroid' | 'personalAdamW',
                      )
                    }
                    value={tagSuggestionMethod}
                  >
                    <option
                      disabled={!tagSuggestions.data.personalCentroidAvailable}
                      value="personalCentroid"
                    >
                      快速个人模型
                    </option>
                    <option
                      disabled={!tagSuggestions.data.personalAdamWAvailable}
                      value="personalAdamW"
                    >
                      增强个人模型
                    </option>
                  </select>
                </label>
                <label className="settings-field">
                  <span>标签</span>
                  <select
                    disabled={Boolean(pending)}
                    onChange={(event) => setTagSuggestionTagID(event.target.value)}
                    value={tagSuggestionTagID}
                  >
                    <option value="">选择标签</option>
                    {tagSuggestions.data.tags
                      .filter((tag) => tag.personalEligible)
                      .map((tag) => (
                        <option key={tag.tagID} value={tag.tagID}>
                          {tagNames.get(tag.tagID) ?? tag.tagID}
                        </option>
                      ))}
                  </select>
                </label>
                <div className="training-submit-row">
                  <span>
                    阈值 {threshold === undefined ? '—' : threshold.toFixed(3)} ·{' '}
                    {selectedSources.size} 个来源
                  </span>
                  <button
                    className="button button-primary"
                    disabled={
                      !tagMethodAvailable ||
                      !selectedTagOption?.personalEligible ||
                      !selectedSources.size ||
                      Boolean(pending)
                    }
                    onClick={() =>
                      void perform(
                        'tag-suggestion',
                        () =>
                          generateTagLibrarySuggestions({
                            mediaKind,
                            method: tagSuggestionMethod,
                            tagID: tagSuggestionTagID,
                            sourceIDs: [...selectedSources],
                          }),
                        'Mac 已接受按标签建议任务。',
                      )
                    }
                    type="button"
                  >
                    <Play aria-hidden="true" size={14} /> 开始扫描
                  </button>
                </div>
              </div>
              <div className="training-activity-list">
                {tagSuggestions.data.activities.map(renderTagActivity)}
              </div>
            </>
          ) : (
            <div className="training-panel-state" role="status">
              正在读取标签建议…
            </div>
          )}
        </section>

        <section
          className="training-panel training-source-panel"
          aria-labelledby="suggestion-sources-title"
        >
          <div className="panel-title-row">
            <div>
              <h3 id="suggestion-sources-title">本轮来源</h3>
              <p>取消选择不会修改 Mac 来源配置，只影响下一次建议请求。</p>
            </div>
          </div>
          <fieldset className="training-choice-group training-source-grid">
            <legend className="visually-hidden">选择建议来源</legend>
            {(setup.data?.sources ?? []).map((source) => (
              <label key={source.id}>
                <input
                  checked={selectedSources.has(source.id)}
                  disabled={Boolean(pending)}
                  onChange={() => toggle(setSelectedSources, selectedSources, source.id)}
                  type="checkbox"
                />
                <span>{source.displayName}</span>
              </label>
            ))}
          </fieldset>
        </section>
      </div>
    );
  }

  return (
    <section className="domain-workspace training-workspace" aria-labelledby="training-title">
      <header className="domain-heading training-heading">
        <div>
          <p className="eyebrow">工具</p>
          <h2 id="training-title">训练与建议</h2>
          <p>配置个人模型、准备嵌入并跟踪 Host 权威活动。</p>
        </div>
        <div className="training-media-switch" aria-label="媒体类型">
          {(['image', 'video'] as const).map((kind) => (
            <button
              aria-pressed={mediaKind === kind}
              className="button"
              disabled={Boolean(pending)}
              key={kind}
              onClick={() => {
                setMediaKind(kind);
                setSelectedTags(new Set());
                setTagSuggestionTagID('');
              }}
              type="button"
            >
              {kind === 'image' ? '照片' : '视频'}
            </button>
          ))}
        </div>
      </header>
      <nav className="training-section-tabs" aria-label="训练工作台">
        {(
          [
            ['models', '模型训练', BrainCircuit],
            ['preparation', '准备与抽检', DatabaseZap],
            ['suggestions', '全库建议', Sparkles],
          ] as const
        ).map(([key, label, Icon]) => (
          <button
            aria-current={section === key ? 'page' : undefined}
            key={key}
            onClick={() => setSection(key)}
            type="button"
          >
            <Icon aria-hidden="true" size={16} /> {label}
          </button>
        ))}
      </nav>
      {section === 'models'
        ? renderModels()
        : section === 'preparation'
          ? renderPreparation()
          : renderSuggestions()}
      {message ? (
        <div className="action-toast" role="status">
          <CheckCircle2 aria-hidden="true" size={16} />
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
