import { Check, DatabaseZap, Heart, ScanSearch, Trash2, RotateCcw, X } from 'lucide-react';

import type { TagSelectionAggregate, TagSummary } from '@/api/contracts/tag';

import { InlineTagCreateForm } from './InlineTagCreateForm';

type SelectionBarProps = {
  selectedCount: number;
  selectedAssetIDs: string[];
  tags: TagSummary[];
  selectedTagID: string;
  aggregate: TagSelectionAggregate | null;
  pending: boolean;
  onSelectedTagChange: (tagID: string) => void;
  onFavorite: (isFavorite: boolean) => void;
  onCreateTag: (name: string, assetIDs: string[], operationID: string) => Promise<void>;
  onTagDecision: (action: 'accept' | 'reject' | 'clear') => void;
  onPrepareEmbeddings: () => void;
  onFindSimilar: () => void;
  onRecycle: () => void;
  onClear: () => void;
};

export function SelectionBar({
  selectedCount,
  selectedAssetIDs,
  tags,
  selectedTagID,
  aggregate,
  pending,
  onSelectedTagChange,
  onFavorite,
  onCreateTag,
  onTagDecision,
  onPrepareEmbeddings,
  onFindSimilar,
  onRecycle,
  onClear,
}: SelectionBarProps) {
  return (
    <section aria-label="批量选择操作" className="selection-bar">
      <div className="selection-summary">
        <strong>已选择 {selectedCount.toLocaleString('zh-CN')} 项</strong>
        <button aria-label="清除选择" className="icon-button" onClick={onClear} type="button">
          <X aria-hidden="true" size={16} />
        </button>
      </div>
      <div className="selection-actions">
        <button
          className="button"
          disabled={pending}
          onClick={() => onFavorite(true)}
          type="button"
        >
          <Heart aria-hidden="true" size={15} /> 收藏
        </button>
        <button
          className="button"
          disabled={pending}
          onClick={() => onFavorite(false)}
          type="button"
        >
          取消收藏
        </button>
        <button className="button" disabled={pending} onClick={onPrepareEmbeddings} type="button">
          <DatabaseZap aria-hidden="true" size={15} /> 准备特征
        </button>
        <button className="button" disabled={pending} onClick={onFindSimilar} type="button">
          <ScanSearch aria-hidden="true" size={15} /> 查找相似项
        </button>
        <button className="button" disabled={pending} onClick={onRecycle} type="button">
          <Trash2 aria-hidden="true" size={15} /> 移至回收区
        </button>
        <label className="compact-field selection-tag-field">
          <span>标签</span>
          <select
            disabled={!tags.length || pending}
            onChange={(event) => onSelectedTagChange(event.target.value)}
            value={selectedTagID}
          >
            {tags.map((tag) => (
              <option key={tag.id} value={tag.id}>
                {tag.displayName}
              </option>
            ))}
          </select>
        </label>
        <span className="selection-aggregate" aria-live="polite">
          {aggregate
            ? `确认 ${String(aggregate.acceptedCount)} · 拒绝 ${String(aggregate.rejectedCount)} · 未决定 ${String(aggregate.unknownCount)}`
            : '选择标签后显示汇总'}
        </span>
        <button
          className="button"
          disabled={!selectedTagID || pending}
          onClick={() => onTagDecision('accept')}
          type="button"
        >
          <Check aria-hidden="true" size={15} /> 确认标签
        </button>
        <button
          className="button"
          disabled={!selectedTagID || pending}
          onClick={() => onTagDecision('reject')}
          type="button"
        >
          <X aria-hidden="true" size={15} /> 拒绝
        </button>
        <button
          className="button"
          disabled={!selectedTagID || pending}
          onClick={() => onTagDecision('clear')}
          type="button"
        >
          <RotateCcw aria-hidden="true" size={15} /> 清除决定
        </button>
      </div>
      <InlineTagCreateForm
        assetIDs={selectedAssetIDs}
        disabled={pending}
        inputLabel="为已选照片新建标签"
        onCreate={onCreateTag}
      />
    </section>
  );
}
