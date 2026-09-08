import { describe, expect, it } from 'vitest';

import type { ReviewQueueItem } from '@/api/contracts/review';

import { formatSuggestionScore, reviewItemKey, reviewOriginLabels } from './reviewPresentation';

function item(suggestionOrigin: ReviewQueueItem['suggestionOrigin']): ReviewQueueItem {
  return {
    assetID: '55220ca2-8800-4cea-a6b9-9f9e148d2adc',
    fileName: 'photo.jpg',
    availability: 'available',
    contentRevision: 1,
    acceptedTagCount: 0,
    rejectedTagCount: 0,
    suggestionOrigin,
    score: 1.75,
    width: 100,
    height: 100,
    favorite: null,
  };
}

describe('review presentation', () => {
  it('uses the suggestion origin as part of row identity', () => {
    expect(reviewItemKey(item('featurePrint'))).not.toBe(reviewItemKey(item('personalAdamW')));
  });

  it('renders incomparable model scores as raw values', () => {
    expect(formatSuggestionScore(1.75)).toBe(' · 分数 1.75');
    expect(formatSuggestionScore(null)).toBe('');
  });

  it('keeps origin names consistent across queue and single-photo views', () => {
    expect(reviewOriginLabels.featurePrint).toBe('特征向量');
    expect(reviewOriginLabels.personalAdamW).toBe('超级个人模型');
  });
});
