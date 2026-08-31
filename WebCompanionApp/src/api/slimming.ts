import type { AssetMediaKind } from './contracts/asset';
import {
  identicalCleanupPlanSchema,
  identicalCleanupRequestSchema,
  identicalCleanupSnapshotSchema,
  slimmingClusterReviewResponseSchema,
  slimmingJobActionResponseSchema,
  slimmingLaunchResponseSchema,
  slimmingRecycleRequestSchema,
  slimmingRecycleSnapshotSchema,
  slimmingRemovalModeSchema,
  slimmingRemovalRequestSchema,
  slimmingRemovalSnapshotSchema,
  slimmingSetupSchema,
  slimmingSourceMaintenanceResponseSchema,
  slimmingThresholdUpdateResponseSchema,
  slimmingWorkspaceSchema,
  type SlimmingAnalyzeMode,
  type SlimmingClusterDisposition,
  type SlimmingClusterScope,
  type SlimmingRecycleAction,
  type SlimmingRemovalMode,
  type SlimmingThresholds,
} from './contracts/slimming';
import { requestJSON } from './client';

export function fetchSlimmingSetup(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(`/v1/library-slimming/setup?mediaKind=${mediaKind}`, slimmingSetupSchema, {
    signal: signal ?? null,
  });
}

export function maintainSlimmingSources(input: {
  mediaKind: AssetMediaKind;
  sourceIDs: string[];
  action: 'refreshCatalog' | 'initializeSimilarityIndex';
}) {
  return requestJSON(
    '/v1/library-slimming/source-maintenance',
    slimmingSourceMaintenanceResponseSchema,
    { method: 'POST', body: JSON.stringify({ operationID: crypto.randomUUID(), ...input }) },
  );
}

export function updateSlimmingThresholds(thresholds: SlimmingThresholds) {
  return requestJSON('/v1/library-slimming/thresholds', slimmingThresholdUpdateResponseSchema, {
    method: 'PUT',
    body: JSON.stringify({ operationID: crypto.randomUUID(), thresholds }),
  });
}

export function launchSlimmingAnalysis(input: {
  mediaKind: AssetMediaKind;
  mode: SlimmingAnalyzeMode;
  sourceIDs: string[] | null;
  seedAssetIDs: string[];
  filter?: Record<string, unknown> | null;
}) {
  return requestJSON('/v1/library-slimming/launch', slimmingLaunchResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), filter: null, ...input }),
  });
}

export function fetchSlimmingWorkspace(
  input: {
    mediaKind: AssetMediaKind;
    clusterScope: SlimmingClusterScope;
    jobID?: string | null;
    clusterID?: string | null;
  },
  signal?: AbortSignal,
) {
  const query = new URLSearchParams({
    mediaKind: input.mediaKind,
    clusterScope: input.clusterScope,
    jobLimit: '100',
    clusterLimit: '80',
    memberLimit: '200',
  });
  if (input.jobID) query.set('jobID', input.jobID);
  if (input.clusterID) query.set('clusterID', input.clusterID);
  return requestJSON(`/v1/library-slimming/workspace?${query}`, slimmingWorkspaceSchema, {
    signal: signal ?? null,
  });
}

export function applySlimmingJobAction(jobID: string, action: 'pause' | 'resume' | 'deleteRecord') {
  return requestJSON(
    `/v1/library-slimming/jobs/${jobID}/actions`,
    slimmingJobActionResponseSchema,
    {
      method: 'POST',
      body: JSON.stringify({ operationID: crypto.randomUUID(), action }),
    },
  );
}

export function reviewSlimmingCluster(input: {
  jobID: string;
  clusterID: string;
  disposition: SlimmingClusterDisposition | null;
}) {
  return requestJSON('/v1/library-slimming/cluster-review', slimmingClusterReviewResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), ...input }),
  });
}

export function fetchSlimmingRemovals(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(
    `/v1/library-slimming/removals?mediaKind=${mediaKind}`,
    slimmingRemovalSnapshotSchema,
    { signal: signal ?? null },
  );
}

export function submitSlimmingRemoval(input: {
  scope: 'analysisCluster' | 'gallerySelection';
  jobID: string | null;
  clusterID: string | null;
  mediaKind: AssetMediaKind;
  assetIDs: string[];
  mode: SlimmingRemovalMode;
}) {
  return requestJSON('/v1/library-slimming/removals', slimmingRemovalRequestSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), ...input }),
  });
}

export function fetchSlimmingRecycle(
  input: {
    mediaKind: AssetMediaKind;
    scope: 'all' | 'photos' | 'files' | 'attention';
    search?: string;
  },
  signal?: AbortSignal,
) {
  const query = new URLSearchParams({
    mediaKind: input.mediaKind,
    scope: input.scope,
    limit: '60',
  });
  if (input.search) query.set('search', input.search);
  return requestJSON(`/v1/library-slimming/recycle?${query}`, slimmingRecycleSnapshotSchema, {
    signal: signal ?? null,
  });
}

export function submitRecycleAction(entryID: string, action: SlimmingRecycleAction) {
  return requestJSON('/v1/library-slimming/recycle/requests', slimmingRecycleRequestSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), entryID, action }),
  });
}

export function prepareIdenticalCleanup(jobID: string, mediaKind: AssetMediaKind) {
  return requestJSON('/v1/library-slimming/identical-cleanup/plans', identicalCleanupPlanSchema, {
    method: 'POST',
    body: JSON.stringify({ jobID, mediaKind }),
  });
}

export function fetchIdenticalCleanup(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(
    `/v1/library-slimming/identical-cleanup/requests?mediaKind=${mediaKind}`,
    identicalCleanupSnapshotSchema,
    { signal: signal ?? null },
  );
}

export function submitIdenticalCleanup(planID: string, mode: SlimmingRemovalMode) {
  slimmingRemovalModeSchema.parse(mode);
  return requestJSON(
    '/v1/library-slimming/identical-cleanup/requests',
    identicalCleanupRequestSchema,
    {
      method: 'POST',
      body: JSON.stringify({ operationID: crypto.randomUUID(), planID, mode }),
    },
  );
}
