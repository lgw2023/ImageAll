import { describe, expect, it } from 'vitest';

import {
  identicalCleanupRequestSchema,
  slimmingRemovalRequestSchema,
  slimmingSetupSchema,
  slimmingWorkspaceSchema,
} from './slimming';

const id = '10000000-0000-4000-8000-000000000001';

const thresholds = {
  featurePrintRecallTopK: 24,
  featurePrintMaxL2Distance: 0.18,
  dinoCosineMinSimilarity: 0.88,
  sceneBucketActivationAssetCount: 2500,
  featurePrintRecallMode: 'topK',
  featurePrintL2Mode: 'radius',
  dinoCosineMode: 'minimum',
  sceneBucketingMode: 'automatic',
};

describe('library slimming contracts', () => {
  it('normalizes setup fields omitted by older Hosts', () => {
    const setup = slimmingSetupSchema.parse({
      mediaKind: 'image',
      sources: [{ id, displayName: 'Synthetic', kind: 'folder' }],
      thresholds,
      factoryThresholds: thresholds,
    });
    expect(setup.sourceSimilarityIndexAvailable).toBeNull();
    expect(setup.sources[0]?.similarityIndex).toBeNull();
  });

  it('preserves historical cluster evidence when current members are unavailable', () => {
    const workspace = slimmingWorkspaceSchema.parse({
      mediaKind: 'image',
      jobs: [],
      selectedJobID: null,
      clusters: [
        {
          id,
          kind: 'byteIdentical',
          memberCount: 0,
          representativeAssetID: id,
          score: 1,
          reviewDisposition: 'confirmed',
          originalMemberCount: 3,
          isHistoricalProcessedRecord: true,
        },
      ],
      selectedClusterID: id,
      members: [],
      pendingAnalysisCount: 0,
      analyzedAssetCount: 3,
      policyVersion: 'synthetic-v1',
    });
    expect(workspace.clusters[0]).toMatchObject({
      originalMemberCount: 3,
      isHistoricalProcessedRecord: true,
    });
    expect(workspace.clusterScopeCounts).toBeNull();
  });

  it('keeps Host-authoritative favorite protection and cleanup verification', () => {
    const removal = slimmingRemovalRequestSchema.parse({
      id,
      operationID: id,
      scope: 'gallerySelection',
      mediaKind: 'image',
      assetIDs: [id],
      favoriteProtectedAssetIDs: [id],
      mode: 'recoverableRecycle',
      phase: 'awaitingMac',
      message: 'Waiting for Mac',
      updatedAtMs: 1,
    });
    expect(removal.favoriteProtectedAssetIDs).toEqual([id]);
    expect(removal.jobID).toBeNull();

    const cleanup = identicalCleanupRequestSchema.parse({
      id,
      operationID: id,
      planID: id,
      jobID: id,
      mediaKind: 'image',
      mode: 'recoverableRecycle',
      phase: 'completed',
      verification: {
        verifiedGroupCount: 1,
        targetGroupCount: 1,
        targetRetainedAssetCount: 1,
        observedAssetCount: 2,
        currentAvailableAssetCount: 1,
        retainedNonredundantAssetCount: 1,
        recycledRedundantAssetCount: 1,
        remainingRedundantAssetCount: 0,
        unresolvedAssetCount: 0,
        unresolvedGroupCount: 0,
        isComplete: true,
      },
      message: 'Verified',
      updatedAtMs: 2,
    });
    expect(cleanup.verification?.isComplete).toBe(true);
    expect(cleanup.audit).toBeNull();
  });
});
