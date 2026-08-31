import { z } from 'zod';

import { assetAvailabilitySchema, assetMediaKindSchema, favoriteStateSchema } from './asset';
import { nullishToNull, uuidSchema } from './common';
import { jobActionSchema } from './management';

export const slimmingAnalyzeModeSchema = z.enum(['catalog', 'currentFilter', 'seeds']);
export const slimmingClusterScopeSchema = z.enum(['pending', 'confirmed', 'ignored']);
export const slimmingClusterDispositionSchema = z.enum(['confirmed', 'ignored']);
export const slimmingRemovalModeSchema = z.enum(['recoverableRecycle', 'releaseSourceSpace']);

export const slimmingThresholdsSchema = z.object({
  featurePrintRecallTopK: z.int().positive(),
  featurePrintMaxL2Distance: z.number().nonnegative(),
  dinoCosineMinSimilarity: z.number().min(-1).max(1),
  sceneBucketActivationAssetCount: z.int().nonnegative(),
  featurePrintRecallMode: z.enum(['topK', 'allCandidates']),
  featurePrintL2Mode: z.enum(['radius', 'unlimited']),
  dinoCosineMode: z.enum(['minimum', 'unlimited']),
  sceneBucketingMode: z.enum(['always', 'automatic', 'never']),
});

const sourceIndexSchema = z.object({
  state: z.enum(['building', 'ready', 'stale', 'failed']),
  assetCount: z.int().nonnegative(),
  indexedCount: z.int().nonnegative(),
  clusterCount: z.int().nonnegative(),
  pendingCount: z.int().nonnegative(),
  updatedAtMs: z.int(),
});

export const slimmingSetupSchema = z.object({
  mediaKind: assetMediaKindSchema,
  sources: z.array(
    z.object({
      id: uuidSchema,
      displayName: z.string().min(1),
      kind: z.enum(['folder', 'photos']),
      similarityIndex: nullishToNull(sourceIndexSchema),
    }),
  ),
  thresholds: slimmingThresholdsSchema,
  factoryThresholds: slimmingThresholdsSchema,
  sourceSimilarityIndexAvailable: nullishToNull(z.boolean()),
});

const slimmingJobStateSchema = z.enum([
  'pending',
  'running',
  'paused',
  'retryableFailed',
  'completed',
  'terminalFailed',
  'cancelled',
]);

export const slimmingJobSchema = z.object({
  id: uuidSchema,
  mode: slimmingAnalyzeModeSchema,
  mediaKind: assetMediaKindSchema,
  state: slimmingJobStateSchema,
  progress: z.object({
    completedUnitCount: z.int().nonnegative(),
    totalUnitCount: nullishToNull(z.int().nonnegative()),
  }),
  attempts: z.int().nonnegative(),
  maxAttempts: z.int().nonnegative(),
  memberCount: z.int().nonnegative(),
  seedCount: z.int().nonnegative(),
  clusterCount: z.int().nonnegative(),
  hasResult: z.boolean(),
  createdAtMs: z.int(),
  updatedAtMs: z.int(),
  sourceNames: z.array(z.string()),
  availableActions: z.array(jobActionSchema),
  controlRequest: z.enum(['none', 'pause', 'cancel']),
  scanProgress: nullishToNull(
    z.object({
      phase: z.enum([
        'preparingFingerprints',
        'loadingFeaturePrints',
        'loadingEmbeddings',
        'clustering',
      ]),
      completedUnitCount: z.int().nonnegative(),
      totalUnitCount: z.int().nonnegative(),
    }),
  ),
  lastErrorCode: nullishToNull(z.string()),
});

export const slimmingClusterSchema = z.object({
  id: uuidSchema,
  kind: z.enum(['byteIdentical', 'perceptualDuplicate', 'nearDuplicateScene']),
  memberCount: z.int().nonnegative(),
  representativeAssetID: uuidSchema,
  score: z.number(),
  isSeedOnlyResult: z.boolean().default(false),
  technicalSummary: nullishToNull(z.string()),
  reviewDisposition: nullishToNull(slimmingClusterDispositionSchema),
  originalMemberCount: nullishToNull(z.int().nonnegative()),
  isHistoricalProcessedRecord: nullishToNull(z.boolean()),
});

export const slimmingMemberSchema = z.object({
  id: uuidSchema,
  sourceID: nullishToNull(uuidSchema),
  sourceName: nullishToNull(z.string()),
  fileName: nullishToNull(z.string()),
  mediaType: nullishToNull(z.string()),
  availability: assetAvailabilitySchema,
  contentRevision: z.int().nonnegative(),
  width: nullishToNull(z.int().nonnegative()),
  height: nullishToNull(z.int().nonnegative()),
  durationMs: nullishToNull(z.int().nonnegative()),
  favorite: nullishToNull(favoriteStateSchema),
});

export const slimmingWorkspaceSchema = z.object({
  mediaKind: assetMediaKindSchema,
  jobs: z.array(slimmingJobSchema),
  totalJobCount: nullishToNull(z.int().nonnegative()),
  selectedJobID: nullishToNull(uuidSchema),
  clusters: z.array(slimmingClusterSchema),
  selectedClusterID: nullishToNull(uuidSchema),
  members: z.array(slimmingMemberSchema),
  pendingAnalysisCount: z.int().nonnegative(),
  analyzedAssetCount: z.int().nonnegative(),
  policyVersion: nullishToNull(z.string()),
  clusterScopeCounts: nullishToNull(
    z.object({
      pending: z.int().nonnegative(),
      confirmed: z.int().nonnegative(),
      ignored: z.int().nonnegative(),
    }),
  ),
});

export const slimmingSourceMaintenanceResponseSchema = z.object({
  operationID: uuidSchema,
  action: z.enum(['refreshCatalog', 'initializeSimilarityIndex']),
  mediaKind: assetMediaKindSchema,
  sourceIDs: z.array(uuidSchema),
  setup: slimmingSetupSchema,
  replayed: z.boolean(),
});
export const slimmingLaunchResponseSchema = z.object({
  operationID: uuidSchema,
  jobID: uuidSchema,
  acceptedAtMs: z.int(),
  memberCount: z.int().nonnegative(),
  replayed: z.boolean(),
});
export const slimmingJobActionResponseSchema = z.object({
  job: nullishToNull(slimmingJobSchema),
  deleted: z.boolean(),
  replayed: z.boolean(),
});
export const slimmingThresholdUpdateResponseSchema = z.object({
  thresholds: slimmingThresholdsSchema,
  replayed: z.boolean(),
});
export const slimmingClusterReviewResponseSchema = z.object({
  operationID: uuidSchema,
  jobID: uuidSchema,
  clusterID: uuidSchema,
  disposition: nullishToNull(slimmingClusterDispositionSchema),
  replayed: z.boolean(),
});

const removalProgressSchema = z.object({
  phase: z.enum([
    'waitingForBackgroundIO',
    'preparing',
    'copying',
    'syncingDestination',
    'verifyingDestination',
    'verifyingSource',
    'deletingSource',
    'syncingSourceDirectory',
    'photosSystemMutation',
    'completedAsset',
  ]),
  completedAssetCount: z.int().nonnegative(),
  totalAssetCount: z.int().nonnegative(),
  copiedBytes: z.int().nonnegative(),
  totalFileBytes: z.int().nonnegative(),
});

const removalAuditSchema = z.object({
  hiddenAssetIDs: z.array(uuidSchema),
  recycledEntryIDs: z.array(uuidSchema),
  permanentlyDeletedAssetIDs: z.array(uuidSchema),
  durabilityPendingAssetIDs: z.array(uuidSchema),
  failedAssetIDs: z.array(uuidSchema),
  authorizationRequiredSourceIDs: z.array(uuidSchema),
  authorizationRequiredAssetIDs: z.array(uuidSchema),
  authorizationDeniedPhotosAssetIDs: z.array(uuidSchema),
  mutationAuthorizationInvalidAssetIDs: z.array(uuidSchema),
  photosMutationFailedAssetIDs: z.array(uuidSchema),
  photosMutationFailureCategories: z.array(z.string()),
  photosMutationFailureCodes: z.array(z.string()),
  sourceChangedAssetIDs: z.array(uuidSchema),
});

export const slimmingRemovalRequestSchema = z.object({
  id: uuidSchema,
  operationID: uuidSchema,
  scope: nullishToNull(z.enum(['analysisCluster', 'gallerySelection'])),
  jobID: nullishToNull(uuidSchema),
  clusterID: nullishToNull(uuidSchema),
  mediaKind: assetMediaKindSchema,
  assetIDs: z.array(uuidSchema),
  favoriteProtectedAssetIDs: nullishToNull(z.array(uuidSchema)),
  mode: slimmingRemovalModeSchema,
  phase: z.enum(['awaitingMac', 'running', 'completed', 'cancelled', 'failed']),
  progress: nullishToNull(removalProgressSchema),
  audit: nullishToNull(removalAuditSchema),
  message: z.string(),
  updatedAtMs: z.int(),
});
export const slimmingRemovalSnapshotSchema = z.object({
  mediaKind: assetMediaKindSchema,
  requests: z.array(slimmingRemovalRequestSchema),
});

const recycleActionSchema = z.enum([
  'restore',
  'discardPreflightFailure',
  'retryInterruptedOperation',
  'purge',
]);
export const slimmingRecycleEntrySchema = z.object({
  id: uuidSchema,
  assetID: uuidSchema,
  sourceID: uuidSchema,
  sourceDisplayName: z.string(),
  sourceKind: z.enum(['file', 'photos']),
  mediaKind: assetMediaKindSchema,
  fileName: nullishToNull(z.string()),
  trashedAtMs: z.int(),
  purgeAfterMs: z.int(),
  state: z.enum(['pending', 'recycled', 'restoring', 'purging', 'restored', 'purged', 'failed']),
  errorCode: nullishToNull(z.string()),
  problem: nullishToNull(
    z.enum([
      'sourceAuthorizationRequired',
      'sourceAuthorizationInvalid',
      'sourceChanged',
      'photosAuthorizationRequired',
      'photosAssetNotFound',
      'photosUserCancelled',
      'photosMutationFailed',
      'fileIO',
      'locationConflict',
      'locationMissing',
      'unknown',
    ]),
  ),
  resolution: z.enum([
    'restoreOrPurge',
    'discardPreflightFailure',
    'retryInterruptedOperation',
    'reinspectFileLocations',
    'updateFolderAuthorization',
    'refreshSourceBeforeRetry',
    'requestPhotosAuthorization',
    'retryFromAnalysis',
    'inspect',
    'photosManagedBySystem',
  ]),
  availableActions: z.array(recycleActionSchema),
  stateMessage: nullishToNull(z.string()),
  policyMessage: nullishToNull(z.string()),
  explanationMessage: nullishToNull(z.string()),
  favorite: nullishToNull(favoriteStateSchema),
});
export const slimmingRecycleRequestSchema = z.object({
  id: uuidSchema,
  operationID: uuidSchema,
  entryID: uuidSchema,
  action: recycleActionSchema,
  fileName: nullishToNull(z.string()),
  phase: z.enum(['awaitingMac', 'running', 'completed', 'cancelled', 'failed']),
  message: z.string(),
  updatedAtMs: z.int(),
});
export const slimmingRecycleSnapshotSchema = z.object({
  mediaKind: assetMediaKindSchema,
  entries: z.array(slimmingRecycleEntrySchema),
  totalCount: z.int().nonnegative(),
  requests: z.array(slimmingRecycleRequestSchema),
  scopeCounts: nullishToNull(
    z.object({
      all: z.int().nonnegative(),
      photos: z.int().nonnegative(),
      files: z.int().nonnegative(),
      attention: z.int().nonnegative(),
    }),
  ),
});

export const identicalCleanupPlanSchema = z.object({
  id: uuidSchema,
  jobID: uuidSchema,
  mediaKind: assetMediaKindSchema,
  groupCount: z.int().nonnegative(),
  byteIdenticalGroupCount: nullishToNull(z.int().nonnegative()),
  perfectVisualGroupCount: nullishToNull(z.int().nonnegative()),
  verifiedAssetCount: z.int().nonnegative(),
  retainedAssetCount: z.int().nonnegative(),
  favoriteRetainedAssetCount: nullishToNull(z.int().nonnegative()),
  ordinaryRetainedAssetCount: nullishToNull(z.int().nonnegative()),
  protectedSkippedAssetCount: nullishToNull(z.int().nonnegative()),
  removalAssetCount: z.int().nonnegative(),
  skippedGroupCount: z.int().nonnegative(),
  photosAssetCount: z.int().nonnegative(),
  fileAssetCount: z.int().nonnegative(),
  groupSizeHistogram: z.record(z.string(), z.int().nonnegative()),
  preparedAtMs: z.int(),
});

const identicalVerificationSchema = z.object({
  verifiedGroupCount: z.int().nonnegative(),
  targetGroupCount: z.int().nonnegative(),
  targetRetainedAssetCount: z.int().nonnegative(),
  observedAssetCount: z.int().nonnegative(),
  currentAvailableAssetCount: z.int().nonnegative(),
  retainedNonredundantAssetCount: z.int().nonnegative(),
  recycledRedundantAssetCount: z.int().nonnegative(),
  remainingRedundantAssetCount: z.int().nonnegative(),
  unresolvedAssetCount: z.int().nonnegative(),
  unresolvedGroupCount: z.int().nonnegative(),
  isComplete: z.boolean(),
});
export const identicalCleanupRequestSchema = z.object({
  id: uuidSchema,
  operationID: uuidSchema,
  planID: uuidSchema,
  jobID: uuidSchema,
  mediaKind: assetMediaKindSchema,
  mode: slimmingRemovalModeSchema,
  phase: z.enum(['awaitingMac', 'running', 'completed', 'cancelled', 'failed']),
  executionStage: nullishToNull(
    z.enum([
      'validatingPlan',
      'recyclingAssets',
      'requestingAuthorization',
      'refreshingState',
      'verifyingResult',
    ]),
  ),
  progress: nullishToNull(removalProgressSchema),
  audit: nullishToNull(removalAuditSchema),
  verification: nullishToNull(identicalVerificationSchema),
  verificationUnavailableMessage: nullishToNull(z.string()),
  message: z.string(),
  updatedAtMs: z.int(),
});
export const identicalCleanupSnapshotSchema = z.object({
  mediaKind: assetMediaKindSchema,
  requests: z.array(identicalCleanupRequestSchema),
});

export type SlimmingAnalyzeMode = z.infer<typeof slimmingAnalyzeModeSchema>;
export type SlimmingClusterScope = z.infer<typeof slimmingClusterScopeSchema>;
export type SlimmingClusterDisposition = z.infer<typeof slimmingClusterDispositionSchema>;
export type SlimmingRemovalMode = z.infer<typeof slimmingRemovalModeSchema>;
export type SlimmingThresholds = z.infer<typeof slimmingThresholdsSchema>;
export type SlimmingSetup = z.infer<typeof slimmingSetupSchema>;
export type SlimmingJob = z.infer<typeof slimmingJobSchema>;
export type SlimmingCluster = z.infer<typeof slimmingClusterSchema>;
export type SlimmingMember = z.infer<typeof slimmingMemberSchema>;
export type SlimmingWorkspace = z.infer<typeof slimmingWorkspaceSchema>;
export type SlimmingRemovalRequest = z.infer<typeof slimmingRemovalRequestSchema>;
export type SlimmingRemovalSnapshot = z.infer<typeof slimmingRemovalSnapshotSchema>;
export type SlimmingRecycleEntry = z.infer<typeof slimmingRecycleEntrySchema>;
export type SlimmingRecycleAction = z.infer<typeof recycleActionSchema>;
export type SlimmingRecycleSnapshot = z.infer<typeof slimmingRecycleSnapshotSchema>;
export type IdenticalCleanupPlan = z.infer<typeof identicalCleanupPlanSchema>;
export type IdenticalCleanupSnapshot = z.infer<typeof identicalCleanupSnapshotSchema>;
