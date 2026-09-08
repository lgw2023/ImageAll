import { useMemo, useState } from 'react';

import { useQueryClient } from '@tanstack/react-query';
import { Pause, Play, RotateCcw, Sparkles, X } from 'lucide-react';

import type { GeneralSettings, SuggestionThresholdMethod } from '@/api/contracts/management';
import type { ReviewTagOverview } from '@/api/contracts/review';
import type { TagLibrarySuggestionSnapshot } from '@/api/contracts/training';
import { errorMessage } from '@/api/errors';
import { applyJobAction, updateGeneralSettings } from '@/api/management';
import {
  cancelTagLibrarySuggestions,
  generateTagLibrarySuggestions,
  launchTraining,
} from '@/api/training';

type ReviewTagControlsProps = {
  settings: GeneralSettings | undefined;
  sourceIDs: string[];
  suggestions: TagLibrarySuggestionSnapshot | undefined;
  tag: ReviewTagOverview;
};

const methodLabels: Record<SuggestionThresholdMethod, string> = {
  featureKnn: '特征向量',
  personalCentroid: '个人模型',
  personalAdamW: '超级个人模型',
};

const activeTagSuggestionPhases = new Set(['preparingCandidates', 'scoring', 'publishing']);

export function ReviewTagControls({
  settings,
  sourceIDs,
  suggestions,
  tag,
}: ReviewTagControlsProps) {
  const queryClient = useQueryClient();
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [pendingKey, setPendingKey] = useState('');
  const [message, setMessage] = useState('');
  const thresholdTag = settings?.suggestionThresholds?.tags.find((row) => row.tagID === tag.id);
  const suggestionTag = suggestions?.tags.find((row) => row.tagID === tag.id);
  const tagActivities = useMemo(
    () => suggestions?.activities.filter((activity) => activity.tagID === tag.id) ?? [],
    [suggestions?.activities, tag.id],
  );
  const activeTagActivity = tagActivities.find((activity) =>
    activeTagSuggestionPhases.has(activity.phase),
  );

  async function refresh() {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ['general-settings'] }),
      queryClient.invalidateQueries({ queryKey: ['review-overview'] }),
      queryClient.invalidateQueries({ queryKey: ['tag-library-suggestions', 'image'] }),
      queryClient.invalidateQueries({ queryKey: ['training-activities', 'image'] }),
      queryClient.invalidateQueries({ queryKey: ['jobs'] }),
    ]);
  }

  async function perform(key: string, action: () => Promise<unknown>, success: string) {
    setPendingKey(key);
    setMessage('');
    try {
      await action();
      await refresh();
      setMessage(success);
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPendingKey('');
    }
  }

  function saveThreshold(method: SuggestionThresholdMethod, minScore: number) {
    setDrafts((current) => ({ ...current, [method]: minScore.toFixed(2) }));
    void perform(
      `threshold:${method}`,
      () =>
        updateGeneralSettings({
          suggestionThresholdMutation: {
            action: 'setOverride',
            method,
            tagID: tag.id,
            minScore,
          },
        }),
      `${methodLabels[method]}门槛已更新为 ${minScore.toFixed(2)}。`,
    );
  }

  function clearThreshold(method: SuggestionThresholdMethod) {
    void perform(
      `threshold:${method}`,
      () =>
        updateGeneralSettings({
          suggestionThresholdMutation: { action: 'clearOverride', method, tagID: tag.id },
        }),
      `${methodLabels[method]}门槛已恢复继承默认。`,
    );
  }

  function generateFeatureSuggestions() {
    void perform(
      'feature',
      () =>
        launchTraining({
          mediaKind: 'image',
          method: 'featureKnn',
          tagIDs: [tag.id],
          sourceIDs,
        }),
      `Mac 已接受${tag.canUpdate ? '更新' : '生成'}特征向量建议任务。`,
    );
  }

  function generatePersonalSuggestions(method: 'personalCentroid' | 'personalAdamW') {
    void perform(
      method,
      () => generateTagLibrarySuggestions({ mediaKind: 'image', method, tagID: tag.id, sourceIDs }),
      `Mac 已接受${methodLabels[method]}建议任务。`,
    );
  }

  return (
    <details className="review-tag-controls">
      <summary>调整门槛与生成</summary>
      <div className="review-origin-counts" aria-label="待审建议来源">
        {(
          [
            ['featurePrint', '特征向量'],
            ['standardModel', '标准模型'],
            ['personalModel', '个人模型'],
            ['personalAdamW', '超级个人模型'],
          ] as const
        ).map(([origin, label]) =>
          tag.pendingSuggestionCounts[origin] > 0 ? (
            <span key={origin}>
              {label} {tag.pendingSuggestionCounts[origin].toLocaleString('zh-CN')}
            </span>
          ) : null,
        )}
      </div>

      {thresholdTag ? (
        <div className="review-tag-thresholds">
          {thresholdTag.methods.map((row) => {
            const draftKey = row.method;
            const draft = drafts[draftKey] ?? row.effectiveMinScore.toFixed(2);
            const parsed = draft.trim() === '' ? Number.NaN : Number(draft);
            const dirty =
              Number.isFinite(parsed) && Math.abs(parsed - row.effectiveMinScore) >= 0.000_001;
            return (
              <fieldset key={row.method}>
                <legend>{methodLabels[row.method]}</legend>
                <label>
                  <span className="visually-hidden">最低分数</span>
                  <input
                    inputMode="decimal"
                    onChange={(event) =>
                      setDrafts((current) => ({ ...current, [draftKey]: event.target.value }))
                    }
                    step="0.01"
                    type="number"
                    value={draft}
                  />
                </label>
                <button
                  className="button button-quiet"
                  disabled={!dirty || Boolean(pendingKey)}
                  onClick={() => saveThreshold(row.method, parsed)}
                  type="button"
                >
                  保存覆盖
                </button>
                <small>
                  {row.overrideMinScore === null
                    ? `继承默认 ${row.effectiveMinScore.toFixed(2)}`
                    : `当前覆盖 ${row.overrideMinScore.toFixed(2)}`}
                </small>
                {row.reference ? (
                  <button
                    className="button button-quiet"
                    disabled={Boolean(pendingKey)}
                    onClick={() => saveThreshold(row.method, row.reference?.minScore ?? 0)}
                    type="button"
                  >
                    <Sparkles aria-hidden="true" size={13} /> 采用参考{' '}
                    {row.reference.minScore.toFixed(2)}
                  </button>
                ) : null}
                {row.overrideMinScore !== null ? (
                  <button
                    className="button button-quiet"
                    disabled={Boolean(pendingKey)}
                    onClick={() => clearThreshold(row.method)}
                    type="button"
                  >
                    <RotateCcw aria-hidden="true" size={13} /> 恢复继承
                  </button>
                ) : null}
              </fieldset>
            );
          })}
        </div>
      ) : (
        <p className="review-tag-control-note">Host 暂未提供此标签的门槛配置。</p>
      )}

      <div className="review-tag-generate-actions">
        {tag.canGenerate || tag.canUpdate ? (
          <button
            className="button"
            disabled={!sourceIDs.length || Boolean(pendingKey)}
            onClick={generateFeatureSuggestions}
            type="button"
          >
            <Play aria-hidden="true" size={13} /> {tag.canUpdate ? '更新特征建议' : '生成特征建议'}
          </button>
        ) : null}
        {tag.canGeneratePersonalModel &&
        suggestionTag?.personalEligible &&
        suggestions?.personalCentroidAvailable ? (
          <button
            className="button"
            disabled={!sourceIDs.length || Boolean(pendingKey) || Boolean(activeTagActivity)}
            onClick={() => generatePersonalSuggestions('personalCentroid')}
            type="button"
          >
            <Play aria-hidden="true" size={13} /> 生成个人建议
          </button>
        ) : null}
        {tag.canGeneratePersonalModel &&
        suggestionTag?.personalEligible &&
        suggestions?.personalAdamWAvailable ? (
          <button
            className="button"
            disabled={!sourceIDs.length || Boolean(pendingKey) || Boolean(activeTagActivity)}
            onClick={() => generatePersonalSuggestions('personalAdamW')}
            type="button"
          >
            <Play aria-hidden="true" size={13} /> 生成超级个人建议
          </button>
        ) : null}
        {tag.activeJobID && tag.canPause ? (
          <button
            className="button"
            disabled={Boolean(pendingKey)}
            onClick={() =>
              void perform(
                'pause',
                () => applyJobAction(tag.activeJobID ?? '', 'pause'),
                '任务已暂停。',
              )
            }
            type="button"
          >
            <Pause aria-hidden="true" size={13} /> 暂停
          </button>
        ) : null}
        {tag.activeJobID && tag.canResume ? (
          <button
            className="button"
            disabled={Boolean(pendingKey)}
            onClick={() =>
              void perform(
                'resume',
                () => applyJobAction(tag.activeJobID ?? '', 'resume'),
                '任务已继续。',
              )
            }
            type="button"
          >
            <Play aria-hidden="true" size={13} /> 继续
          </button>
        ) : null}
        {tag.activeJobID && tag.canCancel ? (
          <button
            className="button button-danger"
            disabled={Boolean(pendingKey)}
            onClick={() =>
              void perform(
                'cancel',
                () => applyJobAction(tag.activeJobID ?? '', 'cancel'),
                '任务已取消。',
              )
            }
            type="button"
          >
            <X aria-hidden="true" size={13} /> 取消任务
          </button>
        ) : null}
        {activeTagActivity?.availableActions.includes('cancel') ? (
          <button
            className="button button-danger"
            disabled={Boolean(pendingKey)}
            onClick={() =>
              void perform(
                'cancel-personal',
                () => cancelTagLibrarySuggestions(activeTagActivity.operationID),
                '个人建议任务已取消。',
              )
            }
            type="button"
          >
            <X aria-hidden="true" size={13} /> 取消个人建议
          </button>
        ) : null}
      </div>

      {activeTagActivity ? (
        <p className="review-tag-control-note" role="status">
          {methodLabels[activeTagActivity.method]}：
          {activeTagActivity.completedUnitCount.toLocaleString('zh-CN')}
          {' / '}
          {activeTagActivity.totalUnitCount.toLocaleString('zh-CN')} · 达门槛{' '}
          {activeTagActivity.aboveThresholdCount.toLocaleString('zh-CN')}
        </p>
      ) : null}
      {!sourceIDs.length ? (
        <p className="review-tag-control-note">当前未选择来源，生成操作已禁用。</p>
      ) : null}
      {message ? (
        <p className="review-tag-control-note" role="status">
          {message}
        </p>
      ) : null}
    </details>
  );
}
