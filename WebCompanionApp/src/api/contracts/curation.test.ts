import { describe, expect, it } from 'vitest';

import { galleryOverviewSchema } from './overview';
import { reviewOverviewSchema } from './review';
import { tagGroupMutationResponseSchema } from './tag';

describe('curation contracts', () => {
  it('normalizes optional gallery favorites to null', () => {
    const result = galleryOverviewSchema.parse({
      media: [],
      sources: [],
      positiveTags: [],
      years: [],
      availability: [],
      undatedCount: 0,
      positiveLabeledAssetCount: 0,
      acceptedDecisionCount: 0,
    });
    expect(result.favorites).toBeNull();
  });

  it('rejects an incomplete review tag projection', () => {
    const result = reviewOverviewSchema.safeParse({
      totalPendingSuggestionCount: 1,
      tags: [{ id: '55220ca2-8800-4cea-a6b9-9f9e148d2adc', displayName: '风景' }],
    });
    expect(result.success).toBe(false);
  });

  it('accepts a deleted tag group response with a null group', () => {
    const result = tagGroupMutationResponseSchema.parse({
      operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
      group: null,
      replayed: false,
    });
    expect(result.group).toBeNull();
  });
});
