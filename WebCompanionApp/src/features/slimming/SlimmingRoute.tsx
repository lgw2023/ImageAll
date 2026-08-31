import { useMemo, useState } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import {
  ArchiveRestore,
  CheckCircle2,
  DatabaseZap,
  Heart,
  Pause,
  Play,
  RefreshCw,
  RotateCcw,
  Search,
  ShieldCheck,
  Trash2,
} from 'lucide-react';
import { useSearchParams } from 'react-router-dom';

import type { AssetMediaKind } from '@/api/contracts/asset';
import type {
  IdenticalCleanupPlan,
  SlimmingAnalyzeMode,
  SlimmingClusterDisposition,
  SlimmingClusterScope,
  SlimmingMember,
  SlimmingRecycleAction,
  SlimmingRemovalMode,
  SlimmingThresholds,
} from '@/api/contracts/slimming';
import { errorMessage } from '@/api/errors';
import {
  applySlimmingJobAction,
  fetchIdenticalCleanup,
  fetchSlimmingRecycle,
  fetchSlimmingRemovals,
  fetchSlimmingSetup,
  fetchSlimmingWorkspace,
  launchSlimmingAnalysis,
  maintainSlimmingSources,
  prepareIdenticalCleanup,
  reviewSlimmingCluster,
  submitIdenticalCleanup,
  submitRecycleAction,
  submitSlimmingRemoval,
  updateSlimmingThresholds,
} from '@/api/slimming';

type SlimmingSection = 'analyze' | 'review' | 'cleanup' | 'recycle';
type RecycleScope = 'all' | 'photos' | 'files' | 'attention';

const sectionLabels: Record<SlimmingSection, string> = {
  analyze: '分析',
  review: '审查',
  cleanup: '完全相同项',
  recycle: '回收与恢复',
};
const modeLabels: Record<SlimmingAnalyzeMode, string> = {
  catalog: '来源目录',
  currentFilter: '当前筛选',
  seeds: '所选种子',
};
const stateLabels: Record<string, string> = {
  pending: '等待中',
  running: '进行中',
  paused: '已暂停',
  retryableFailed: '可重试失败',
  completed: '已完成',
  terminalFailed: '已失败',
  cancelled: '已取消',
  confirmed: '已确认',
  ignored: '已忽略',
  recycled: '在回收区',
  restoring: '正在恢复',
  purging: '正在永久清理',
  restored: '已恢复',
  purged: '已永久清理',
  failed: '失败',
  awaitingMac: '等待 Mac',
};
const clusterLabels: Record<string, string> = {
  byteIdentical: '字节完全相同',
  perceptualDuplicate: '视觉重复',
  nearDuplicateScene: '近似场景',
};
const removalModeLabels: Record<SlimmingRemovalMode, string> = {
  recoverableRecycle: '可恢复回收',
  releaseSourceSpace: '释放来源空间',
};

function dateTime(value: number) {
  return new Intl.DateTimeFormat('zh-CN', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value));
}

function PanelError({ error, retry }: { error: unknown; retry: () => void }) {
  return (
    <div className="slimming-state slimming-error" role="alert">
      <strong>无法取得 Mac 上的图库精简状态</strong>
      <span>{errorMessage(error)}</span>
      <button className="button" onClick={retry} type="button">
        重试
      </button>
    </div>
  );
}

function Progress({
  completed,
  total,
  label,
}: {
  completed: number;
  total: number | null;
  label: string;
}) {
  if (total === null) return <span>{completed.toLocaleString('zh-CN')} 项已处理</span>;
  return (
    <div className="slimming-progress">
      <span>
        {label} · {completed.toLocaleString('zh-CN')} / {total.toLocaleString('zh-CN')}
      </span>
      <progress aria-label={label} max={Math.max(1, total)} value={completed} />
    </div>
  );
}

function favoriteProtected(member: SlimmingMember) {
  return member.favorite?.isFavorite === true;
}

export function SlimmingRoute() {
  const queryClient = useQueryClient();
  const [searchParameters, setSearchParameters] = useSearchParams();
  const initialMedia = searchParameters.get('media') === 'video' ? 'video' : 'image';
  const requestedMode = searchParameters.get('mode');
  const initialMode: SlimmingAnalyzeMode =
    requestedMode === 'currentFilter' || requestedMode === 'seeds' ? requestedMode : 'catalog';
  const requestedSection = searchParameters.get('section');
  const initialSection: SlimmingSection =
    requestedSection === 'review' ||
    requestedSection === 'cleanup' ||
    requestedSection === 'recycle'
      ? requestedSection
      : 'analyze';

  const [mediaKind, setMediaKind] = useState<AssetMediaKind>(initialMedia);
  const [section, setSection] = useState<SlimmingSection>(initialSection);
  const [analyzeMode, setAnalyzeMode] = useState<SlimmingAnalyzeMode>(initialMode);
  const [sourceSelection, setSourceSelection] = useState<{
    mediaKind: AssetMediaKind;
    ids: Set<string>;
  } | null>(null);
  const [thresholdDraft, setThresholdDraft] = useState<SlimmingThresholds | null>(null);
  const [clusterScope, setClusterScope] = useState<SlimmingClusterScope>('pending');
  const [selectedJobID, setSelectedJobID] = useState<string | null>(null);
  const [selectedClusterID, setSelectedClusterID] = useState<string | null>(null);
  const [selectedMembers, setSelectedMembers] = useState<Set<string>>(new Set());
  const [removalMode, setRemovalMode] = useState<SlimmingRemovalMode>('recoverableRecycle');
  const [cleanupPlan, setCleanupPlan] = useState<IdenticalCleanupPlan | null>(null);
  const [cleanupMode, setCleanupMode] = useState<SlimmingRemovalMode>('recoverableRecycle');
  const [recycleScope, setRecycleScope] = useState<RecycleScope>('all');
  const [recycleSearch, setRecycleSearch] = useState('');
  const [pending, setPending] = useState('');
  const [message, setMessage] = useState('');

  const seedAssetIDs = useMemo(
    () =>
      (searchParameters.get('seedAssetIDs') ?? '')
        .split(',')
        .map((value) => value.trim())
        .filter(Boolean),
    [searchParameters],
  );

  const setup = useQuery({
    queryKey: ['slimming-setup', mediaKind],
    queryFn: ({ signal }) => fetchSlimmingSetup(mediaKind, signal),
  });
  const workspace = useQuery({
    queryKey: ['slimming-workspace', mediaKind, clusterScope, selectedJobID, selectedClusterID],
    queryFn: ({ signal }) =>
      fetchSlimmingWorkspace(
        { mediaKind, clusterScope, jobID: selectedJobID, clusterID: selectedClusterID },
        signal,
      ),
    refetchInterval: (query) =>
      query.state.data?.jobs.some((job) => job.state === 'running' || job.state === 'pending')
        ? 1_500
        : false,
  });
  const removals = useQuery({
    queryKey: ['slimming-removals', mediaKind],
    queryFn: ({ signal }) => fetchSlimmingRemovals(mediaKind, signal),
    enabled: section === 'review',
    refetchInterval: (query) =>
      query.state.data?.requests.some(
        (request) => request.phase === 'awaitingMac' || request.phase === 'running',
      )
        ? 1_500
        : false,
  });
  const recycle = useQuery({
    queryKey: ['slimming-recycle', mediaKind, recycleScope, recycleSearch],
    queryFn: ({ signal }) =>
      fetchSlimmingRecycle({ mediaKind, scope: recycleScope, search: recycleSearch }, signal),
    enabled: section === 'recycle',
    refetchInterval: (query) =>
      query.state.data?.requests.some(
        (request) => request.phase === 'awaitingMac' || request.phase === 'running',
      )
        ? 1_500
        : false,
  });
  const cleanup = useQuery({
    queryKey: ['slimming-identical-cleanup', mediaKind],
    queryFn: ({ signal }) => fetchIdenticalCleanup(mediaKind, signal),
    enabled: section === 'cleanup',
    refetchInterval: (query) =>
      query.state.data?.requests.some(
        (request) => request.phase === 'awaitingMac' || request.phase === 'running',
      )
        ? 1_500
        : false,
  });

  const effectiveSourceIDs = useMemo(() => {
    const all = setup.data?.sources.map((source) => source.id) ?? [];
    return sourceSelection?.mediaKind === mediaKind ? [...sourceSelection.ids] : all;
  }, [mediaKind, setup.data?.sources, sourceSelection]);
  const effectiveJobID = selectedJobID ?? workspace.data?.selectedJobID ?? null;
  const effectiveClusterID = selectedClusterID ?? workspace.data?.selectedClusterID ?? null;
  const selectedCluster = workspace.data?.clusters.find((item) => item.id === effectiveClusterID);
  const removableMembers = workspace.data?.members.filter(
    (member) =>
      member.id !== selectedCluster?.representativeAssetID &&
      !favoriteProtected(member) &&
      member.availability === 'available',
  );

  function setRouteSection(next: SlimmingSection) {
    setSection(next);
    const nextParameters = new URLSearchParams(searchParameters);
    nextParameters.set('section', next);
    nextParameters.set('media', mediaKind);
    setSearchParameters(nextParameters, { replace: true });
  }

  function switchMedia(next: AssetMediaKind) {
    setMediaKind(next);
    setThresholdDraft(null);
    setSelectedJobID(null);
    setSelectedClusterID(null);
    setSelectedMembers(new Set());
    setCleanupPlan(null);
    const nextParameters = new URLSearchParams(searchParameters);
    nextParameters.set('media', next);
    setSearchParameters(nextParameters, { replace: true });
  }

  async function perform(key: string, action: () => Promise<unknown>, success: string) {
    setPending(key);
    setMessage('');
    try {
      await action();
      setMessage(success);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['slimming-setup'] }),
        queryClient.invalidateQueries({ queryKey: ['slimming-workspace'] }),
        queryClient.invalidateQueries({ queryKey: ['slimming-removals'] }),
        queryClient.invalidateQueries({ queryKey: ['slimming-recycle'] }),
        queryClient.invalidateQueries({ queryKey: ['slimming-identical-cleanup'] }),
      ]);
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPending('');
    }
  }

  function currentFilter() {
    const tagID = searchParameters.get('filterTag');
    const sort = searchParameters.get('filterSort');
    const sourceID = searchParameters.get('filterSource');
    const folderRelativePath = searchParameters.get('filterFolder');
    return {
      sourceIDs: sourceID ? [sourceID] : [],
      searchText: searchParameters.get('filterQ'),
      sort: sort === 'oldest' || sort === 'fileNameAscending' ? sort : 'newest',
      limit: 200,
      cursor: null,
      tagDecisionFilters: tagID ? [{ tagID, decision: 'accepted' }] : [],
      excludedTagIDs: [],
      tagMatchMode: 'all',
      availabilities: [],
      mediaKinds: [mediaKind],
      mediaTypes: [],
      tagPresence: 'any',
      favorite: searchParameters.get('filterFavorite') === 'favorited' ? 'favorited' : null,
      worldMapSelection: null,
      folderScope:
        sourceID && folderRelativePath ? { sourceID, relativePath: folderRelativePath } : null,
    };
  }

  async function launchAnalysis() {
    if (analyzeMode === 'catalog' && effectiveSourceIDs.length === 0) {
      setMessage('请至少选择一个来源。');
      return;
    }
    if (analyzeMode === 'seeds' && seedAssetIDs.length === 0) {
      setMessage('请先在图库中选择种子项目。');
      return;
    }
    const allSelected = effectiveSourceIDs.length === (setup.data?.sources.length ?? 0);
    setPending('launch');
    setMessage('');
    try {
      const response = await launchSlimmingAnalysis({
        mediaKind,
        mode: analyzeMode,
        sourceIDs: analyzeMode === 'catalog' ? (allSelected ? null : effectiveSourceIDs) : null,
        seedAssetIDs: analyzeMode === 'seeds' ? seedAssetIDs : [],
        filter: analyzeMode === 'catalog' ? null : currentFilter(),
      });
      setSelectedJobID(response.jobID);
      setSelectedClusterID(null);
      setMessage(`Mac 已接受 ${response.memberCount.toLocaleString('zh-CN')} 项分析范围。`);
      await queryClient.invalidateQueries({ queryKey: ['slimming-workspace'] });
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPending('');
    }
  }

  async function submitRemoval() {
    if (!effectiveJobID || !effectiveClusterID || selectedMembers.size === 0) return;
    const destructive = removalMode === 'releaseSourceSpace';
    const accepted = window.confirm(
      destructive
        ? `将 ${String(selectedMembers.size)} 项交给 Mac 释放来源空间？这可能永久删除来源文件；收藏项仍由 Host 强制保护。`
        : `将 ${String(selectedMembers.size)} 项交给 Mac 放入可恢复回收区？收藏项仍由 Host 强制保护。`,
    );
    if (!accepted) return;
    const ids = [...selectedMembers];
    await perform(
      'remove',
      () =>
        submitSlimmingRemoval({
          scope: 'analysisCluster',
          jobID: effectiveJobID,
          clusterID: effectiveClusterID,
          mediaKind,
          assetIDs: ids,
          mode: removalMode,
        }),
      `Mac 已冻结 ${String(ids.length)} 项选择并进入确认队列；这不代表清理已经完成。`,
    );
    setSelectedMembers(new Set());
  }

  async function preparePlan(jobID: string) {
    setPending('plan');
    setMessage('');
    try {
      const plan = await prepareIdenticalCleanup(jobID, mediaKind);
      setCleanupPlan(plan);
      setMessage('Mac 已生成只读清理计划；尚未移动或删除任何项目。');
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPending('');
    }
  }

  async function executePlan() {
    if (!cleanupPlan) return;
    const accepted = window.confirm(
      cleanupMode === 'releaseSourceSpace'
        ? `执行计划并释放 ${String(cleanupPlan.removalAssetCount)} 项来源空间？此模式可能永久删除来源文件。`
        : `执行计划并将 ${String(cleanupPlan.removalAssetCount)} 个冗余项放入可恢复回收区？`,
    );
    if (!accepted) return;
    await perform(
      'cleanup',
      () => submitIdenticalCleanup(cleanupPlan.id, cleanupMode),
      '计划已提交给 Mac；请以完成阶段和验证结果为准。',
    );
  }

  async function recycleAction(entryID: string, action: SlimmingRecycleAction) {
    if (
      action === 'purge' &&
      !window.confirm('永久清理后无法从 ImageAll 回收区恢复。继续交给 Mac 确认？')
    ) {
      return;
    }
    await perform(
      `recycle:${entryID}`,
      () => submitRecycleAction(entryID, action),
      '请求已进入 Mac 队列；请以 Host 返回的最终状态为准。',
    );
  }

  return (
    <section className="domain-workspace slimming-workspace" aria-labelledby="slimming-title">
      <header className="domain-heading slimming-heading">
        <div>
          <p className="eyebrow">工具</p>
          <h2 id="slimming-title">图库精简</h2>
          <p>先分析与审查，再由 Mac 冻结选择、保护收藏项并执行恢复或空间释放。</p>
        </div>
        <div className="slimming-media-switch" aria-label="媒体类型">
          {(['image', 'video'] as const).map((kind) => (
            <button
              aria-pressed={mediaKind === kind}
              className="segment"
              key={kind}
              onClick={() => switchMedia(kind)}
              type="button"
            >
              {kind === 'image' ? '照片' : '视频'}
            </button>
          ))}
        </div>
      </header>

      <nav className="slimming-section-tabs" aria-label="图库精简工作台">
        {(Object.keys(sectionLabels) as SlimmingSection[]).map((key) => (
          <button
            aria-current={section === key ? 'page' : undefined}
            className="button"
            key={key}
            onClick={() => setRouteSection(key)}
            type="button"
          >
            {sectionLabels[key]}
          </button>
        ))}
      </nav>

      {message ? (
        <div className="slimming-message" role="status">
          <ShieldCheck aria-hidden="true" size={17} />
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

      {section === 'analyze' ? (
        <AnalyzeSection
          analyzeMode={analyzeMode}
          effectiveSourceIDs={effectiveSourceIDs}
          launch={() => void launchAnalysis()}
          mediaKind={mediaKind}
          pending={pending}
          seedAssetIDs={seedAssetIDs}
          setAnalyzeMode={setAnalyzeMode}
          setSourceSelection={setSourceSelection}
          setThresholdDraft={setThresholdDraft}
          setup={setup}
          sourceSelection={sourceSelection}
          thresholdDraft={thresholdDraft ?? setup.data?.thresholds ?? null}
          workspace={workspace}
          perform={perform}
        />
      ) : null}

      {section === 'review' ? (
        <ReviewSection
          clusterScope={clusterScope}
          effectiveClusterID={effectiveClusterID}
          effectiveJobID={effectiveJobID}
          mediaKind={mediaKind}
          pending={pending}
          removableMembers={removableMembers ?? []}
          removalMode={removalMode}
          removals={removals}
          selectedMembers={selectedMembers}
          setClusterScope={(scope) => {
            setClusterScope(scope);
            setSelectedClusterID(null);
            setSelectedMembers(new Set());
          }}
          setRemovalMode={setRemovalMode}
          setSelectedClusterID={(id) => {
            setSelectedClusterID(id);
            setSelectedMembers(new Set());
          }}
          setSelectedJobID={(id) => {
            setSelectedJobID(id);
            setSelectedClusterID(null);
            setSelectedMembers(new Set());
          }}
          setSelectedMembers={setSelectedMembers}
          submitRemoval={() => void submitRemoval()}
          workspace={workspace}
          perform={perform}
        />
      ) : null}

      {section === 'cleanup' ? (
        <CleanupSection
          cleanup={cleanup}
          cleanupMode={cleanupMode}
          cleanupPlan={cleanupPlan}
          executePlan={() => void executePlan()}
          pending={pending}
          preparePlan={(jobID) => void preparePlan(jobID)}
          setCleanupMode={setCleanupMode}
          workspace={workspace}
        />
      ) : null}

      {section === 'recycle' ? (
        <RecycleSection
          pending={pending}
          recycle={recycle}
          recycleAction={(entryID, action) => void recycleAction(entryID, action)}
          recycleScope={recycleScope}
          recycleSearch={recycleSearch}
          setRecycleScope={setRecycleScope}
          setRecycleSearch={setRecycleSearch}
        />
      ) : null}
    </section>
  );
}

type QueryResult<T> = {
  data: T | undefined;
  isPending: boolean;
  isError: boolean;
  error: unknown;
  refetch: () => Promise<unknown>;
};

function AnalyzeSection({
  analyzeMode,
  effectiveSourceIDs,
  launch,
  mediaKind,
  pending,
  seedAssetIDs,
  setAnalyzeMode,
  setSourceSelection,
  setThresholdDraft,
  setup,
  sourceSelection,
  thresholdDraft,
  workspace,
  perform,
}: {
  analyzeMode: SlimmingAnalyzeMode;
  effectiveSourceIDs: string[];
  launch: () => void;
  mediaKind: AssetMediaKind;
  pending: string;
  seedAssetIDs: string[];
  setAnalyzeMode: (mode: SlimmingAnalyzeMode) => void;
  setSourceSelection: React.Dispatch<
    React.SetStateAction<{ mediaKind: AssetMediaKind; ids: Set<string> } | null>
  >;
  setThresholdDraft: (thresholds: SlimmingThresholds | null) => void;
  setup: QueryResult<import('@/api/contracts/slimming').SlimmingSetup>;
  sourceSelection: { mediaKind: AssetMediaKind; ids: Set<string> } | null;
  thresholdDraft: SlimmingThresholds | null;
  workspace: QueryResult<import('@/api/contracts/slimming').SlimmingWorkspace>;
  perform: (key: string, action: () => Promise<unknown>, success: string) => Promise<void>;
}) {
  if (setup.isPending)
    return (
      <div className="slimming-state" role="status">
        正在读取分析配置…
      </div>
    );
  if (setup.isError) return <PanelError error={setup.error} retry={() => void setup.refetch()} />;
  const setupData = setup.data;
  if (!setupData) return null;
  const setupSources = setupData.sources;

  function toggleSource(id: string) {
    const all = setupSources.map((source) => source.id);
    setSourceSelection((current) => {
      const next = new Set(current?.mediaKind === mediaKind ? current.ids : all);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return { mediaKind, ids: next };
    });
  }

  function changeNumber(key: keyof SlimmingThresholds, raw: string) {
    if (!thresholdDraft) return;
    const value = Number(raw);
    if (Number.isFinite(value)) setThresholdDraft({ ...thresholdDraft, [key]: value });
  }

  const activeSelection = sourceSelection?.mediaKind === mediaKind ? sourceSelection.ids : null;
  return (
    <div className="slimming-analyze-grid">
      <section className="slimming-panel" aria-labelledby="slimming-source-title">
        <div className="slimming-panel-heading">
          <div>
            <h3 id="slimming-source-title">分析范围</h3>
            <p>目录分析可选来源；筛选与种子模式使用图库带来的精确范围。</p>
          </div>
          <span>{effectiveSourceIDs.length} 个来源</span>
        </div>
        <fieldset className="slimming-mode-list">
          <legend>分析方式</legend>
          {(Object.keys(modeLabels) as SlimmingAnalyzeMode[]).map((mode) => (
            <label key={mode}>
              <input
                checked={analyzeMode === mode}
                name="slimming-mode"
                onChange={() => setAnalyzeMode(mode)}
                type="radio"
              />
              <span>
                <strong>{modeLabels[mode]}</strong>
                <small>
                  {mode === 'catalog'
                    ? '扫描所选来源中的可用项目'
                    : mode === 'currentFilter'
                      ? '复用从图库带来的搜索、标签与收藏筛选'
                      : `${String(seedAssetIDs.length)} 个种子，仅在确认后启动`}
                </small>
              </span>
            </label>
          ))}
        </fieldset>
        <div className="slimming-source-list">
          {setupData.sources.map((source) => {
            const selected = activeSelection ? activeSelection.has(source.id) : true;
            return (
              <label className="slimming-source-card" key={source.id}>
                <input
                  checked={selected}
                  disabled={analyzeMode !== 'catalog' || Boolean(pending)}
                  onChange={() => toggleSource(source.id)}
                  type="checkbox"
                />
                <span>
                  <strong>{source.displayName}</strong>
                  <small>{source.kind === 'photos' ? 'Apple Photos' : '文件夹来源'}</small>
                </span>
                <span
                  className="state-pill"
                  data-state={source.similarityIndex?.state ?? 'unknown'}
                >
                  {source.similarityIndex?.state ?? '未初始化'}
                </span>
              </label>
            );
          })}
        </div>
        <div className="slimming-action-row">
          <button
            className="button"
            disabled={!effectiveSourceIDs.length || Boolean(pending)}
            onClick={() =>
              void perform(
                'refresh',
                () =>
                  maintainSlimmingSources({
                    mediaKind,
                    sourceIDs: effectiveSourceIDs,
                    action: 'refreshCatalog',
                  }),
                'Mac 已刷新所选来源目录。',
              )
            }
            type="button"
          >
            <RefreshCw aria-hidden="true" size={15} /> 刷新目录
          </button>
          {setupData.sourceSimilarityIndexAvailable ? (
            <button
              className="button"
              disabled={!effectiveSourceIDs.length || Boolean(pending)}
              onClick={() =>
                void perform(
                  'index',
                  () =>
                    maintainSlimmingSources({
                      mediaKind,
                      sourceIDs: effectiveSourceIDs,
                      action: 'initializeSimilarityIndex',
                    }),
                  'Mac 已开始准备所选来源的相似度索引。',
                )
              }
              type="button"
            >
              <DatabaseZap aria-hidden="true" size={15} /> 准备相似度索引
            </button>
          ) : null}
          <button
            className="button button-primary"
            disabled={Boolean(pending)}
            onClick={launch}
            type="button"
          >
            <Search aria-hidden="true" size={15} /> 开始分析
          </button>
        </div>
      </section>

      <section className="slimming-panel" aria-labelledby="slimming-threshold-title">
        <div className="slimming-panel-heading">
          <div>
            <h3 id="slimming-threshold-title">相似度阈值</h3>
            <p>更改只在明确保存后交给 Host；可随时恢复出厂值。</p>
          </div>
        </div>
        {thresholdDraft ? (
          <div className="slimming-threshold-grid">
            <label>
              <span>候选 Top K</span>
              <input
                min="1"
                onChange={(event) => changeNumber('featurePrintRecallTopK', event.target.value)}
                type="number"
                value={thresholdDraft.featurePrintRecallTopK}
              />
            </label>
            <label>
              <span>视觉距离上限</span>
              <input
                min="0"
                onChange={(event) => changeNumber('featurePrintMaxL2Distance', event.target.value)}
                step="0.01"
                type="number"
                value={thresholdDraft.featurePrintMaxL2Distance}
              />
            </label>
            <label>
              <span>DINO 相似度下限</span>
              <input
                max="1"
                min="-1"
                onChange={(event) => changeNumber('dinoCosineMinSimilarity', event.target.value)}
                step="0.01"
                type="number"
                value={thresholdDraft.dinoCosineMinSimilarity}
              />
            </label>
            <label>
              <span>场景分桶启动数量</span>
              <input
                min="0"
                onChange={(event) =>
                  changeNumber('sceneBucketActivationAssetCount', event.target.value)
                }
                type="number"
                value={thresholdDraft.sceneBucketActivationAssetCount}
              />
            </label>
            <label>
              <span>候选召回</span>
              <select
                onChange={(event) =>
                  setThresholdDraft({
                    ...thresholdDraft,
                    featurePrintRecallMode: event.target.value as 'topK' | 'allCandidates',
                  })
                }
                value={thresholdDraft.featurePrintRecallMode}
              >
                <option value="topK">Top K</option>
                <option value="allCandidates">全部候选</option>
              </select>
            </label>
            <label>
              <span>视觉距离</span>
              <select
                onChange={(event) =>
                  setThresholdDraft({
                    ...thresholdDraft,
                    featurePrintL2Mode: event.target.value as 'radius' | 'unlimited',
                  })
                }
                value={thresholdDraft.featurePrintL2Mode}
              >
                <option value="radius">使用上限</option>
                <option value="unlimited">不限</option>
              </select>
            </label>
            <label>
              <span>DINO 筛选</span>
              <select
                onChange={(event) =>
                  setThresholdDraft({
                    ...thresholdDraft,
                    dinoCosineMode: event.target.value as 'minimum' | 'unlimited',
                  })
                }
                value={thresholdDraft.dinoCosineMode}
              >
                <option value="minimum">使用下限</option>
                <option value="unlimited">不限</option>
              </select>
            </label>
            <label>
              <span>场景分桶</span>
              <select
                onChange={(event) =>
                  setThresholdDraft({
                    ...thresholdDraft,
                    sceneBucketingMode: event.target.value as 'always' | 'automatic' | 'never',
                  })
                }
                value={thresholdDraft.sceneBucketingMode}
              >
                <option value="automatic">自动</option>
                <option value="always">始终</option>
                <option value="never">从不</option>
              </select>
            </label>
          </div>
        ) : null}
        <div className="slimming-action-row">
          <button
            className="button"
            disabled={Boolean(pending)}
            onClick={() => setThresholdDraft(setupData.factoryThresholds)}
            type="button"
          >
            <RotateCcw aria-hidden="true" size={15} /> 恢复出厂值
          </button>
          <button
            className="button button-primary"
            disabled={!thresholdDraft || Boolean(pending)}
            onClick={() =>
              thresholdDraft
                ? void perform(
                    'thresholds',
                    () => updateSlimmingThresholds(thresholdDraft),
                    'Mac 已保存新的分析阈值。',
                  )
                : undefined
            }
            type="button"
          >
            保存阈值
          </button>
        </div>
      </section>

      <section
        className="slimming-panel slimming-history-panel"
        aria-labelledby="slimming-job-title"
      >
        <div className="slimming-panel-heading">
          <div>
            <h3 id="slimming-job-title">分析历史</h3>
            <p>进度与结果均来自 Host；完成分析不等于已经清理资产。</p>
          </div>
          <span>{workspace.data?.totalJobCount ?? workspace.data?.jobs.length ?? 0} 个任务</span>
        </div>
        {workspace.isError ? (
          <PanelError error={workspace.error} retry={() => void workspace.refetch()} />
        ) : null}
        <div className="slimming-job-list">
          {workspace.data?.jobs.map((job) => (
            <article className="slimming-job-card" key={job.id}>
              <div className="slimming-card-heading">
                <div>
                  <strong>{modeLabels[job.mode]}</strong>
                  <span>{dateTime(job.updatedAtMs)}</span>
                </div>
                <span className="state-pill" data-state={job.state}>
                  {stateLabels[job.state] ?? job.state}
                </span>
              </div>
              <Progress
                completed={job.progress.completedUnitCount}
                label="分析进度"
                total={job.progress.totalUnitCount}
              />
              <p>
                {job.memberCount} 项 · {job.clusterCount} 组 ·{' '}
                {job.sourceNames.join('、') || '当前筛选'}
              </p>
              <div className="slimming-action-row">
                {job.availableActions.includes('pause') ? (
                  <button
                    className="button"
                    disabled={Boolean(pending)}
                    onClick={() =>
                      void perform(
                        `job:${job.id}`,
                        () => applySlimmingJobAction(job.id, 'pause'),
                        'Mac 已暂停分析。',
                      )
                    }
                    type="button"
                  >
                    <Pause aria-hidden="true" size={14} /> 暂停
                  </button>
                ) : null}
                {job.availableActions.includes('resume') ? (
                  <button
                    className="button"
                    disabled={Boolean(pending)}
                    onClick={() =>
                      void perform(
                        `job:${job.id}`,
                        () => applySlimmingJobAction(job.id, 'resume'),
                        'Mac 已继续分析。',
                      )
                    }
                    type="button"
                  >
                    <Play aria-hidden="true" size={14} /> 继续
                  </button>
                ) : null}
              </div>
            </article>
          ))}
          {!workspace.isPending && !workspace.data?.jobs.length ? (
            <div className="slimming-state">还没有分析任务。</div>
          ) : null}
        </div>
      </section>
    </div>
  );
}

function ReviewSection({
  clusterScope,
  effectiveClusterID,
  effectiveJobID,
  mediaKind,
  pending,
  removalMode,
  removals,
  selectedMembers,
  setClusterScope,
  setRemovalMode,
  setSelectedClusterID,
  setSelectedJobID,
  setSelectedMembers,
  submitRemoval,
  workspace,
  perform,
}: {
  clusterScope: SlimmingClusterScope;
  effectiveClusterID: string | null;
  effectiveJobID: string | null;
  mediaKind: AssetMediaKind;
  pending: string;
  removableMembers: SlimmingMember[];
  removalMode: SlimmingRemovalMode;
  removals: QueryResult<import('@/api/contracts/slimming').SlimmingRemovalSnapshot>;
  selectedMembers: Set<string>;
  setClusterScope: (scope: SlimmingClusterScope) => void;
  setRemovalMode: (mode: SlimmingRemovalMode) => void;
  setSelectedClusterID: (id: string) => void;
  setSelectedJobID: (id: string) => void;
  setSelectedMembers: React.Dispatch<React.SetStateAction<Set<string>>>;
  submitRemoval: () => void;
  workspace: QueryResult<import('@/api/contracts/slimming').SlimmingWorkspace>;
  perform: (key: string, action: () => Promise<unknown>, success: string) => Promise<void>;
}) {
  void mediaKind;
  if (workspace.isPending)
    return (
      <div className="slimming-state" role="status">
        正在载入相似组…
      </div>
    );
  if (workspace.isError)
    return <PanelError error={workspace.error} retry={() => void workspace.refetch()} />;
  const data = workspace.data;
  if (!data) return null;
  const currentCluster = data.clusters.find((cluster) => cluster.id === effectiveClusterID);

  function disposition(next: SlimmingClusterDisposition | null) {
    if (!effectiveJobID || !effectiveClusterID) return;
    const label =
      next === 'confirmed'
        ? '已确认此相似组。'
        : next === 'ignored'
          ? '已忽略此相似组。'
          : '已恢复为待审查。';
    void perform(
      'review',
      () =>
        reviewSlimmingCluster({
          jobID: effectiveJobID,
          clusterID: effectiveClusterID,
          disposition: next,
        }),
      label,
    );
  }

  return (
    <div className="slimming-review-layout">
      <aside className="slimming-panel slimming-review-sidebar" aria-label="分析任务和相似组">
        <label className="compact-field">
          <span>分析任务</span>
          <select
            onChange={(event) => setSelectedJobID(event.target.value)}
            value={effectiveJobID ?? ''}
          >
            {!effectiveJobID ? <option value="">选择任务</option> : null}
            {data.jobs
              .filter((job) => job.hasResult)
              .map((job) => (
                <option key={job.id} value={job.id}>
                  {modeLabels[job.mode]} · {job.clusterCount} 组
                </option>
              ))}
          </select>
        </label>
        <div className="slimming-scope-tabs" aria-label="审查状态">
          {(['pending', 'confirmed', 'ignored'] as const).map((scope) => (
            <button
              aria-pressed={clusterScope === scope}
              className="segment"
              key={scope}
              onClick={() => setClusterScope(scope)}
              type="button"
            >
              {scope === 'pending' ? '待审查' : scope === 'confirmed' ? '已确认' : '已忽略'}
              <span>{data.clusterScopeCounts?.[scope] ?? 0}</span>
            </button>
          ))}
        </div>
        <div className="slimming-cluster-list">
          {data.clusters.map((cluster) => (
            <button
              aria-current={effectiveClusterID === cluster.id ? 'true' : undefined}
              className="slimming-cluster-button"
              key={cluster.id}
              onClick={() => setSelectedClusterID(cluster.id)}
              type="button"
            >
              <span>
                <strong>{clusterLabels[cluster.kind]}</strong>
                <small>
                  {cluster.memberCount > 0
                    ? cluster.memberCount
                    : (cluster.originalMemberCount ?? 0)}{' '}
                  项
                </small>
              </span>
              <span>{Math.round(cluster.score * 100)}%</span>
            </button>
          ))}
          {!data.clusters.length ? (
            <div className="slimming-state">此状态下没有相似组。</div>
          ) : null}
        </div>
      </aside>

      <section
        className="slimming-panel slimming-members-panel"
        aria-labelledby="slimming-members-title"
      >
        <div className="slimming-panel-heading">
          <div>
            <h3 id="slimming-members-title">组内审查</h3>
            <p>
              {currentCluster?.technicalSummary ??
                '选择相似组后逐项比较；代表项和收藏项不可加入清理选择。'}
            </p>
          </div>
          {currentCluster ? <span>{clusterLabels[currentCluster.kind]}</span> : null}
        </div>
        {currentCluster?.isHistoricalProcessedRecord && !data.members.length ? (
          <div className="slimming-state">
            <ShieldCheck aria-hidden="true" size={20} />
            此组保留为历史审计记录，当前成员已不再可见。
          </div>
        ) : null}
        <div className="slimming-member-grid">
          {data.members.map((member) => {
            const representative = member.id === currentCluster?.representativeAssetID;
            const protectedFavorite = favoriteProtected(member);
            const selectable =
              !representative && !protectedFavorite && member.availability === 'available';
            return (
              <article className="slimming-member-card" key={member.id}>
                <div className="slimming-member-preview">
                  <img
                    alt=""
                    loading="lazy"
                    src={`/v1/assets/${encodeURIComponent(member.id)}/thumbnail?w=480&revision=${String(member.contentRevision)}`}
                  />
                  {representative ? (
                    <span>保留代表项</span>
                  ) : protectedFavorite ? (
                    <span>
                      <Heart aria-hidden="true" size={13} /> 收藏保护
                    </span>
                  ) : null}
                </div>
                <div className="slimming-member-meta">
                  <strong>{member.fileName ?? '未命名项目'}</strong>
                  <span>
                    {member.sourceName ?? '未知来源'} · {member.width ?? '—'} ×{' '}
                    {member.height ?? '—'}
                  </span>
                  <label>
                    <input
                      checked={selectedMembers.has(member.id)}
                      disabled={!selectable || Boolean(pending)}
                      onChange={() =>
                        setSelectedMembers((current) => {
                          const next = new Set(current);
                          if (next.has(member.id)) next.delete(member.id);
                          else next.add(member.id);
                          return next;
                        })
                      }
                      type="checkbox"
                    />
                    {selectable
                      ? '加入清理选择'
                      : representative
                        ? '始终保留'
                        : protectedFavorite
                          ? '收藏项受保护'
                          : '当前不可用'}
                  </label>
                </div>
              </article>
            );
          })}
        </div>
        {currentCluster ? (
          <div className="slimming-review-actions">
            <div className="slimming-action-row">
              <button
                className="button"
                disabled={Boolean(pending)}
                onClick={() => disposition('confirmed')}
                type="button"
              >
                <CheckCircle2 aria-hidden="true" size={15} /> 确认相似
              </button>
              <button
                className="button"
                disabled={Boolean(pending)}
                onClick={() => disposition('ignored')}
                type="button"
              >
                忽略此组
              </button>
              {clusterScope !== 'pending' ? (
                <button
                  className="button"
                  disabled={Boolean(pending)}
                  onClick={() => disposition(null)}
                  type="button"
                >
                  <RotateCcw aria-hidden="true" size={15} /> 恢复待审查
                </button>
              ) : null}
            </div>
            <fieldset className="slimming-removal-choice">
              <legend>清理方式</legend>
              {(Object.keys(removalModeLabels) as SlimmingRemovalMode[]).map((mode) => (
                <label key={mode}>
                  <input
                    checked={removalMode === mode}
                    name="removal-mode"
                    onChange={() => setRemovalMode(mode)}
                    type="radio"
                  />
                  {removalModeLabels[mode]}
                </label>
              ))}
            </fieldset>
            <button
              className={
                removalMode === 'releaseSourceSpace'
                  ? 'button button-danger'
                  : 'button button-primary'
              }
              disabled={!selectedMembers.size || Boolean(pending)}
              onClick={submitRemoval}
              type="button"
            >
              <Trash2 aria-hidden="true" size={15} /> 提交 {selectedMembers.size} 项
            </button>
          </div>
        ) : (
          <div className="slimming-state">请选择一个有结果的任务和相似组。</div>
        )}
      </section>

      <section
        className="slimming-panel slimming-request-panel"
        aria-labelledby="slimming-removal-title"
      >
        <div className="slimming-panel-heading">
          <div>
            <h3 id="slimming-removal-title">Mac 清理队列</h3>
            <p>“等待 Mac”只表示选择已冻结，不代表文件已经移动或删除。</p>
          </div>
        </div>
        {removals.isError ? (
          <PanelError error={removals.error} retry={() => void removals.refetch()} />
        ) : null}
        <div className="slimming-request-list">
          {removals.data?.requests.map((request) => (
            <article key={request.id}>
              <div className="slimming-card-heading">
                <strong>
                  {removalModeLabels[request.mode]} · {request.assetIDs.length} 项
                </strong>
                <span className="state-pill" data-state={request.phase}>
                  {stateLabels[request.phase] ?? request.phase}
                </span>
              </div>
              <p>{request.message}</p>
              {request.progress ? (
                <Progress
                  completed={request.progress.completedAssetCount}
                  label="Mac 清理进度"
                  total={request.progress.totalAssetCount}
                />
              ) : null}
              {request.favoriteProtectedAssetIDs?.length ? (
                <p className="slimming-protection-note">
                  <Heart aria-hidden="true" size={14} /> Host 已保护{' '}
                  {request.favoriteProtectedAssetIDs.length} 个收藏项
                </p>
              ) : null}
            </article>
          ))}
          {!removals.isPending && !removals.data?.requests.length ? (
            <div className="slimming-state">当前没有清理请求。</div>
          ) : null}
        </div>
      </section>
    </div>
  );
}

function CleanupSection({
  cleanup,
  cleanupMode,
  cleanupPlan,
  executePlan,
  pending,
  preparePlan,
  setCleanupMode,
  workspace,
}: {
  cleanup: QueryResult<import('@/api/contracts/slimming').IdenticalCleanupSnapshot>;
  cleanupMode: SlimmingRemovalMode;
  cleanupPlan: IdenticalCleanupPlan | null;
  executePlan: () => void;
  pending: string;
  preparePlan: (jobID: string) => void;
  setCleanupMode: (mode: SlimmingRemovalMode) => void;
  workspace: QueryResult<import('@/api/contracts/slimming').SlimmingWorkspace>;
}) {
  const eligibleJobs =
    workspace.data?.jobs.filter((job) => job.hasResult && job.state === 'completed') ?? [];
  return (
    <div className="slimming-cleanup-grid">
      <section className="slimming-panel" aria-labelledby="cleanup-plan-title">
        <div className="slimming-panel-heading">
          <div>
            <h3 id="cleanup-plan-title">完全相同项清理计划</h3>
            <p>Mac 先计算保留项、收藏保护和删除候选；准备计划不会改动图库。</p>
          </div>
        </div>
        <div className="slimming-job-list">
          {eligibleJobs.map((job) => (
            <article className="slimming-job-card" key={job.id}>
              <div className="slimming-card-heading">
                <strong>
                  {modeLabels[job.mode]} · {job.clusterCount} 组
                </strong>
                <span>{dateTime(job.updatedAtMs)}</span>
              </div>
              <button
                className="button"
                disabled={Boolean(pending)}
                onClick={() => preparePlan(job.id)}
                type="button"
              >
                准备只读计划
              </button>
            </article>
          ))}
          {!eligibleJobs.length ? (
            <div className="slimming-state">需要一个已完成且有结果的分析任务。</div>
          ) : null}
        </div>
        {cleanupPlan ? (
          <article className="slimming-plan-card">
            <div className="slimming-card-heading">
              <strong>计划已准备</strong>
              <span>{dateTime(cleanupPlan.preparedAtMs)}</span>
            </div>
            <dl>
              <div>
                <dt>完全相同组</dt>
                <dd>{cleanupPlan.groupCount}</dd>
              </div>
              <div>
                <dt>已验证资产</dt>
                <dd>{cleanupPlan.verifiedAssetCount}</dd>
              </div>
              <div>
                <dt>计划保留</dt>
                <dd>{cleanupPlan.retainedAssetCount}</dd>
              </div>
              <div>
                <dt>收藏保留</dt>
                <dd>{cleanupPlan.favoriteRetainedAssetCount ?? 0}</dd>
              </div>
              <div>
                <dt>清理候选</dt>
                <dd>{cleanupPlan.removalAssetCount}</dd>
              </div>
              <div>
                <dt>保护跳过</dt>
                <dd>{cleanupPlan.protectedSkippedAssetCount ?? 0}</dd>
              </div>
            </dl>
            <fieldset className="slimming-removal-choice">
              <legend>执行方式</legend>
              {(Object.keys(removalModeLabels) as SlimmingRemovalMode[]).map((mode) => (
                <label key={mode}>
                  <input
                    checked={cleanupMode === mode}
                    name="cleanup-mode"
                    onChange={() => setCleanupMode(mode)}
                    type="radio"
                  />
                  {removalModeLabels[mode]}
                </label>
              ))}
            </fieldset>
            <button
              className={
                cleanupMode === 'releaseSourceSpace'
                  ? 'button button-danger'
                  : 'button button-primary'
              }
              disabled={cleanupPlan.removalAssetCount === 0 || Boolean(pending)}
              onClick={executePlan}
              type="button"
            >
              确认执行计划
            </button>
          </article>
        ) : null}
      </section>
      <section className="slimming-panel" aria-labelledby="cleanup-status-title">
        <div className="slimming-panel-heading">
          <div>
            <h3 id="cleanup-status-title">执行与验证</h3>
            <p>只有 Host 的完成阶段和验证结果才能证明清理闭环。</p>
          </div>
        </div>
        {cleanup.isError ? (
          <PanelError error={cleanup.error} retry={() => void cleanup.refetch()} />
        ) : null}
        <div className="slimming-request-list">
          {cleanup.data?.requests.map((request) => (
            <article key={request.id}>
              <div className="slimming-card-heading">
                <strong>{removalModeLabels[request.mode]}</strong>
                <span className="state-pill" data-state={request.phase}>
                  {stateLabels[request.phase] ?? request.phase}
                </span>
              </div>
              <p>{request.message}</p>
              {request.progress ? (
                <Progress
                  completed={request.progress.completedAssetCount}
                  label="完全相同项清理进度"
                  total={request.progress.totalAssetCount}
                />
              ) : null}
              {request.verification ? (
                <div
                  className={
                    request.verification.isComplete
                      ? 'slimming-verification complete'
                      : 'slimming-verification'
                  }
                >
                  <ShieldCheck aria-hidden="true" size={18} />
                  <span>
                    {request.verification.isComplete ? 'Host 已完成结果验证' : '验证仍有未解决项'} ·
                    已回收 {request.verification.recycledRedundantAssetCount} · 剩余冗余{' '}
                    {request.verification.remainingRedundantAssetCount}
                  </span>
                </div>
              ) : null}
              {request.verificationUnavailableMessage ? (
                <p>{request.verificationUnavailableMessage}</p>
              ) : null}
            </article>
          ))}
          {!cleanup.isPending && !cleanup.data?.requests.length ? (
            <div className="slimming-state">还没有完全相同项清理请求。</div>
          ) : null}
        </div>
      </section>
    </div>
  );
}

function RecycleSection({
  pending,
  recycle,
  recycleAction,
  recycleScope,
  recycleSearch,
  setRecycleScope,
  setRecycleSearch,
}: {
  pending: string;
  recycle: QueryResult<import('@/api/contracts/slimming').SlimmingRecycleSnapshot>;
  recycleAction: (entryID: string, action: SlimmingRecycleAction) => void;
  recycleScope: RecycleScope;
  recycleSearch: string;
  setRecycleScope: (scope: RecycleScope) => void;
  setRecycleSearch: (search: string) => void;
}) {
  return (
    <div className="slimming-recycle-grid">
      <section className="slimming-panel" aria-labelledby="recycle-title">
        <div className="slimming-panel-heading">
          <div>
            <h3 id="recycle-title">可恢复回收区</h3>
            <p>恢复与永久清理都由 Mac 执行；Photos 系统项仍受系统授权约束。</p>
          </div>
          <span>{recycle.data?.totalCount ?? 0} 项</span>
        </div>
        <div className="slimming-recycle-toolbar">
          <div className="slimming-scope-tabs" aria-label="回收区范围">
            {(['all', 'photos', 'files', 'attention'] as const).map((scope) => (
              <button
                aria-pressed={recycleScope === scope}
                className="segment"
                key={scope}
                onClick={() => setRecycleScope(scope)}
                type="button"
              >
                {scope === 'all'
                  ? '全部'
                  : scope === 'photos'
                    ? 'Photos'
                    : scope === 'files'
                      ? '文件'
                      : '需处理'}{' '}
                <span>{recycle.data?.scopeCounts?.[scope] ?? 0}</span>
              </button>
            ))}
          </div>
          <label className="compact-field">
            <span>搜索回收项</span>
            <input
              onChange={(event) => setRecycleSearch(event.target.value)}
              placeholder="文件名或来源"
              type="search"
              value={recycleSearch}
            />
          </label>
        </div>
        {recycle.isError ? (
          <PanelError error={recycle.error} retry={() => void recycle.refetch()} />
        ) : null}
        <div className="slimming-recycle-list">
          {recycle.data?.entries.map((entry) => (
            <article className="slimming-recycle-card" key={entry.id}>
              <div className="slimming-card-heading">
                <div>
                  <strong>{entry.fileName ?? '未命名项目'}</strong>
                  <span>
                    {entry.sourceDisplayName} · {entry.sourceKind === 'photos' ? 'Photos' : '文件'}
                  </span>
                </div>
                <span className="state-pill" data-state={entry.state}>
                  {stateLabels[entry.state] ?? entry.state}
                </span>
              </div>
              <p>
                {entry.stateMessage ??
                  entry.explanationMessage ??
                  `计划于 ${dateTime(entry.purgeAfterMs)} 后清理`}
              </p>
              {entry.favorite?.isFavorite ? (
                <p className="slimming-protection-note">
                  <Heart aria-hidden="true" size={14} /> 收藏项
                </p>
              ) : null}
              {entry.policyMessage ? (
                <p className="slimming-policy-note">{entry.policyMessage}</p>
              ) : null}
              <div className="slimming-action-row">
                {entry.availableActions.map((action) => (
                  <button
                    className={action === 'purge' ? 'button button-danger' : 'button'}
                    disabled={Boolean(pending)}
                    key={action}
                    onClick={() => recycleAction(entry.id, action)}
                    type="button"
                  >
                    {action === 'restore' ? (
                      <ArchiveRestore aria-hidden="true" size={14} />
                    ) : action === 'purge' ? (
                      <Trash2 aria-hidden="true" size={14} />
                    ) : (
                      <RefreshCw aria-hidden="true" size={14} />
                    )}
                    {action === 'restore'
                      ? '恢复'
                      : action === 'purge'
                        ? '永久清理'
                        : action === 'discardPreflightFailure'
                          ? '丢弃失败记录'
                          : '重试'}
                  </button>
                ))}
              </div>
            </article>
          ))}
          {!recycle.isPending && !recycle.data?.entries.length ? (
            <div className="slimming-state">此范围没有回收项。</div>
          ) : null}
        </div>
      </section>
      <section className="slimming-panel" aria-labelledby="recycle-request-title">
        <div className="slimming-panel-heading">
          <div>
            <h3 id="recycle-request-title">恢复任务</h3>
            <p>保留 Mac 的请求回执，便于判断等待、完成或失败。</p>
          </div>
        </div>
        <div className="slimming-request-list">
          {recycle.data?.requests.map((request) => (
            <article key={request.id}>
              <div className="slimming-card-heading">
                <strong>
                  {request.action === 'restore'
                    ? '恢复'
                    : request.action === 'purge'
                      ? '永久清理'
                      : '恢复处理'}
                </strong>
                <span className="state-pill" data-state={request.phase}>
                  {stateLabels[request.phase] ?? request.phase}
                </span>
              </div>
              <p>{request.message}</p>
              <span>
                {request.fileName ?? '未命名项目'} · {dateTime(request.updatedAtMs)}
              </span>
            </article>
          ))}
          {!recycle.isPending && !recycle.data?.requests.length ? (
            <div className="slimming-state">当前没有恢复任务。</div>
          ) : null}
        </div>
      </section>
    </div>
  );
}
