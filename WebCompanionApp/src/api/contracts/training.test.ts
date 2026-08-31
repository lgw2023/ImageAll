import { describe, expect, it } from 'vitest';

import {
  librarySuggestionSnapshotSchema,
  trainingActivitySchema,
  trainingSetupSchema,
} from './training';

const id = '55220ca2-8800-4cea-a6b9-9f9e148d2adc';

describe('training contracts', () => {
  it('normalizes older optional training fields without inventing activity state', () => {
    const activity = trainingActivitySchema.parse({
      operationID: id,
      mediaKind: 'image',
      method: 'personalCentroid',
      phase: 'preparingSamples',
      completedUnitCount: 0,
      totalUnitCount: 2,
    });
    expect(activity.errorCode).toBeNull();
    expect(activity.availableActions).toEqual([]);
    expect(activity.tagActivities).toEqual([]);
  });

  it('keeps method availability and tag eligibility Host-authored', () => {
    const setup = trainingSetupSchema.parse({
      mediaKind: 'image',
      tags: [
        {
          id,
          displayName: '风景',
          acceptedSampleCount: 12,
          rejectedSampleCount: 4,
          personalEligible: false,
        },
      ],
      sources: [],
      methods: [{ method: 'personalAdamW', isAvailable: false }],
    });
    expect(setup.tags[0]?.featureMode).toBeNull();
    expect(setup.methods[0]?.isAvailable).toBe(false);
  });

  it('rejects a library job state outside the Swift protocol enum', () => {
    const result = librarySuggestionSnapshotSchema.safeParse({
      mediaKind: 'image',
      service: { state: 'ready' },
      standardAvailable: true,
      personalMode: 'fullLibrary',
      standardJob: {
        jobID: id,
        state: 'doneSomehow',
        checkedCount: 1,
        suggestedCount: 1,
        skippedCount: 0,
      },
    });
    expect(result.success).toBe(false);
  });
});
