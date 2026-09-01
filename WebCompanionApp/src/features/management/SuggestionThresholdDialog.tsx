import { useEffect, useMemo, useRef, useState } from 'react';

import { ListX, Search, Sparkles, X } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';

import type { GeneralSettings, SuggestionThresholdMethod } from '@/api/contracts/management';
import { errorMessage } from '@/api/errors';
import { updateGeneralSettings } from '@/api/management';

import { SuggestionPruneDialog } from './SuggestionPruneDialog';

const methodCopy: Record<SuggestionThresholdMethod, { short: string; detail: string }> = {
  featureKnn: { short: '特征向量', detail: 'Feature Print 近邻' },
  personalCentroid: { short: '个人模型', detail: '个人标签质心' },
  personalAdamW: { short: '超级个人模型', detail: 'AdamW 个人模型' },
};

type Thresholds = NonNullable<GeneralSettings['suggestionThresholds']>;
type PruneTarget = {
  tagID: string;
  tagName: string;
  method: SuggestionThresholdMethod;
  methodName: string;
  effectiveMinScore: number;
};

export function SuggestionThresholdDialog({
  thresholds,
  onClose,
}: {
  thresholds: Thresholds;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const dialogRef = useRef<HTMLDialogElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);
  const [search, setSearch] = useState('');
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [pendingKey, setPendingKey] = useState('');
  const [message, setMessage] = useState('');
  const [pruneTarget, setPruneTarget] = useState<PruneTarget | null>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    returnFocusRef.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (!dialog.open) dialog.showModal();
    const frame = requestAnimationFrame(() => closeRef.current?.focus());
    return () => {
      cancelAnimationFrame(frame);
      if (dialog.open) dialog.close();
      const target = returnFocusRef.current;
      requestAnimationFrame(() => {
        if (target?.isConnected) target.focus({ preventScroll: true });
      });
    };
  }, []);

  const filteredTags = useMemo(() => {
    const query = search.trim().toLocaleLowerCase('zh-CN');
    if (!query) return thresholds.tags;
    return thresholds.tags.filter((tag) =>
      tag.displayName.toLocaleLowerCase('zh-CN').includes(query),
    );
  }, [search, thresholds.tags]);

  async function mutate(
    key: string,
    mutation: {
      action: 'setOverride' | 'clearOverride';
      method: SuggestionThresholdMethod;
      tagID: string;
      minScore?: number;
    },
    success: string,
  ) {
    setPendingKey(key);
    setMessage('');
    try {
      const response = await updateGeneralSettings({ suggestionThresholdMutation: mutation });
      queryClient.setQueryData(['general-settings'], response.settings);
      const draftKey = key.split(':').slice(0, 2).join(':');
      setDrafts((current) =>
        Object.fromEntries(Object.entries(current).filter(([entryKey]) => entryKey !== draftKey)),
      );
      setMessage(success);
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPendingKey('');
    }
  }

  async function prune(target: PruneTarget, operationID: string) {
    const key = `${target.tagID}:${target.method}:prune`;
    setPendingKey(key);
    setMessage('');
    try {
      const response = await updateGeneralSettings(
        {
          suggestionThresholdMutation: {
            action: 'prune',
            method: target.method,
            tagID: target.tagID,
          },
        },
        operationID,
      );
      queryClient.setQueryData(['general-settings'], response.settings);
      setMessage(`Mac 已按${target.tagName}的${target.methodName}有效门槛清理低分待审项。`);
    } finally {
      setPendingKey('');
    }
  }

  return (
    <dialog
      aria-describedby="threshold-dialog-description"
      aria-labelledby="threshold-dialog-title"
      className="threshold-dialog"
      onCancel={(event) => {
        event.preventDefault();
        if (!pendingKey) onClose();
      }}
      ref={dialogRef}
    >
      <div className="threshold-dialog-panel">
        <header>
          <div>
            <p className="eyebrow">每个标签、每条建议轨道独立设置</p>
            <h2 id="threshold-dialog-title">按标签覆盖</h2>
            <p id="threshold-dialog-description">
              清除覆盖后继承全局默认；参考值由 Mac 根据近期可追溯的确认与拒绝样本计算。
            </p>
          </div>
          <button
            aria-label="关闭按标签覆盖"
            className="icon-button"
            disabled={Boolean(pendingKey)}
            onClick={onClose}
            ref={closeRef}
            type="button"
          >
            <X aria-hidden="true" size={18} />
          </button>
        </header>
        <label className="threshold-search">
          <Search aria-hidden="true" size={16} />
          <span className="visually-hidden">搜索标签</span>
          <input
            onChange={(event) => setSearch(event.target.value)}
            placeholder="搜索标签"
            role="searchbox"
            type="search"
            value={search}
          />
        </label>
        <div className="threshold-tag-list">
          {filteredTags.length ? (
            filteredTags.map((tag) => (
              <article className="threshold-tag-card" key={tag.tagID}>
                <h3>{tag.displayName}</h3>
                <div className="threshold-method-list">
                  {tag.methods.map((row) => {
                    const copy = methodCopy[row.method];
                    const reference = row.reference;
                    const key = `${tag.tagID}:${row.method}`;
                    const draft = drafts[key] ?? row.effectiveMinScore.toFixed(2);
                    const parsed = Number(draft);
                    const dirty = Number.isFinite(parsed) && parsed !== row.effectiveMinScore;
                    return (
                      <fieldset
                        aria-label={`${tag.displayName} · ${copy.short}`}
                        className="threshold-method-row"
                        key={row.method}
                      >
                        <legend>
                          <strong>{copy.short}</strong>
                          <span>{copy.detail}</span>
                        </legend>
                        <div className="threshold-method-editor">
                          <label>
                            <span className="visually-hidden">覆盖门槛</span>
                            <input
                              inputMode="decimal"
                              onChange={(event) =>
                                setDrafts((current) => ({ ...current, [key]: event.target.value }))
                              }
                              step="0.01"
                              type="number"
                              value={draft}
                            />
                          </label>
                          <button
                            className="button"
                            disabled={!dirty || Boolean(pendingKey)}
                            onClick={() =>
                              void mutate(
                                `${key}:save`,
                                {
                                  action: 'setOverride',
                                  method: row.method,
                                  tagID: tag.tagID,
                                  minScore: parsed,
                                },
                                `${tag.displayName}的${copy.short}门槛已更新为 ${parsed.toFixed(2)}。`,
                              )
                            }
                            type="button"
                          >
                            保存覆盖
                          </button>
                        </div>
                        <div className="threshold-method-meta">
                          <span>
                            {row.overrideMinScore === null
                              ? `继承默认 ${row.effectiveMinScore.toFixed(2)}`
                              : `当前覆盖 ${row.overrideMinScore.toFixed(2)}`}
                          </span>
                          {reference ? (
                            <button
                              className="button button-quiet"
                              disabled={Boolean(pendingKey)}
                              onClick={() =>
                                void mutate(
                                  `${key}:reference`,
                                  {
                                    action: 'setOverride',
                                    method: row.method,
                                    tagID: tag.tagID,
                                    minScore: reference.minScore,
                                  },
                                  `${tag.displayName}的${copy.short}门槛已采用参考值 ${reference.minScore.toFixed(2)}。`,
                                )
                              }
                              type="button"
                            >
                              <Sparkles aria-hidden="true" size={14} />
                              采用参考值 {reference.minScore.toFixed(2)}
                            </button>
                          ) : (
                            <span>样本不足，暂无参考值</span>
                          )}
                          {row.overrideMinScore !== null ? (
                            <button
                              className="button button-quiet"
                              disabled={Boolean(pendingKey)}
                              onClick={() =>
                                void mutate(
                                  `${key}:clear`,
                                  {
                                    action: 'clearOverride',
                                    method: row.method,
                                    tagID: tag.tagID,
                                  },
                                  `${tag.displayName}的${copy.short}门槛已恢复继承默认。`,
                                )
                              }
                              type="button"
                            >
                              恢复继承默认
                            </button>
                          ) : null}
                          <button
                            className="button button-quiet threshold-prune-button"
                            disabled={Boolean(pendingKey)}
                            onClick={() =>
                              setPruneTarget({
                                tagID: tag.tagID,
                                tagName: tag.displayName,
                                method: row.method,
                                methodName: copy.short,
                                effectiveMinScore: row.effectiveMinScore,
                              })
                            }
                            type="button"
                          >
                            <ListX aria-hidden="true" size={14} />
                            清理低分待审项
                          </button>
                        </div>
                      </fieldset>
                    );
                  })}
                </div>
              </article>
            ))
          ) : (
            <p className="workspace-state" role="status">
              没有匹配的活动标签。
            </p>
          )}
        </div>
        <footer>
          <p aria-live="polite" className="form-status">
            {message}
          </p>
          <button
            className="button button-primary"
            disabled={Boolean(pendingKey)}
            onClick={onClose}
            type="button"
          >
            完成
          </button>
        </footer>
        {pruneTarget ? (
          <SuggestionPruneDialog
            effectiveMinScore={pruneTarget.effectiveMinScore}
            methodName={pruneTarget.methodName}
            onCancel={() => setPruneTarget(null)}
            onConfirm={(operationID) => prune(pruneTarget, operationID)}
            tagName={pruneTarget.tagName}
          />
        ) : null}
      </div>
    </dialog>
  );
}
