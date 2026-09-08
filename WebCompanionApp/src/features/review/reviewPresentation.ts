import type { ReviewQueueItem, ReviewTagOverview } from '@/api/contracts/review';

export const reviewOriginLabels: Record<ReviewQueueItem['suggestionOrigin'], string> = {
  featurePrint: '特征向量',
  standardModel: '标准模型',
  personalModel: '个人模型',
  personalAdamW: '超级个人模型',
};

export const reviewTaskStatusLabels: Record<ReviewTagOverview['taskStatus'], string> = {
  notReady: '样本不足',
  ready: '可生成建议',
  waiting: '等待运行',
  running: '正在分析',
  paused: '已暂停',
  retryableFailure: '暂时失败，将重试',
  completed: '本轮已完成',
  terminalFailure: '任务失败',
  cancelled: '已取消',
};

export function reviewItemKey(item: ReviewQueueItem): string {
  return `${item.assetID}:${item.suggestionOrigin}`;
}

export function formatSuggestionScore(score: number | null): string {
  return score === null ? '' : ` · 分数 ${score.toFixed(2)}`;
}

export function reviewTaskStatusText(tag: ReviewTagOverview): string {
  if (tag.taskStatus === 'running' && tag.totalCount && tag.totalCount > 0) {
    return `正在分析 ${tag.checkedCount.toLocaleString('zh-CN')} / ${tag.totalCount.toLocaleString('zh-CN')}，跳过 ${tag.skippedCount.toLocaleString('zh-CN')}`;
  }
  if (tag.taskStatus === 'completed' && tag.pendingSuggestionCount > 0) {
    return '有待审核建议';
  }
  return reviewTaskStatusLabels[tag.taskStatus];
}
