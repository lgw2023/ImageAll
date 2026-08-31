import { z } from 'zod';

import { assetMediaKindSchema } from './asset';
import { jobActionSchema } from './management';
import { nullishToNull, uuidSchema } from './common';

export const trainingMethodSchema = z.enum(['featureKnn', 'personalCentroid', 'personalAdamW']);
export const trainingActivityPhaseSchema = z.enum([
  'preparingSamples',
  'preparingEmbeddings',
  'trainingAndPublishing',
  'completed',
  'failed',
  'cancelled',
]);

export const trainingSetupSchema = z.object({
  mediaKind: assetMediaKindSchema,
  tags: z.array(
    z.object({
      id: uuidSchema,
      displayName: z.string().min(1),
      acceptedSampleCount: z.int().nonnegative(),
      rejectedSampleCount: z.int().nonnegative(),
      featureMode: nullishToNull(z.enum(['generate', 'update'])),
      personalEligible: z.boolean(),
    }),
  ),
  sources: z.array(z.object({ id: uuidSchema, displayName: z.string().min(1) })),
  methods: z.array(z.object({ method: trainingMethodSchema, isAvailable: z.boolean() })),
});

const trainingTagActivitySchema = z.object({
  tagID: uuidSchema,
  displayName: z.string(),
  phase: z.enum([
    'pending',
    'preparingSamples',
    'preparingEmbeddings',
    'trainingAndPublishing',
    'succeeded',
    'skipped',
    'failed',
    'cancelled',
  ]),
  sampleCount: nullishToNull(z.int().nonnegative()),
  errorCode: nullishToNull(z.string()),
});

export const trainingActivitySchema = z.object({
  operationID: uuidSchema,
  mediaKind: assetMediaKindSchema,
  method: trainingMethodSchema,
  phase: trainingActivityPhaseSchema,
  completedUnitCount: z.int().nonnegative(),
  totalUnitCount: z.int().nonnegative(),
  sampleCount: nullishToNull(z.int().nonnegative()),
  errorCode: nullishToNull(z.string()),
  availableActions: z.array(z.literal('cancel')).default([]),
  tagActivities: z.array(trainingTagActivitySchema).default([]),
  acceptedAtMs: z.int().default(0),
  updatedAtMs: z.int().default(0),
});

const recoveryContextSchema = z.object({
  tagIDs: z.array(uuidSchema).default([]),
  sourceIDs: z.array(uuidSchema).default([]),
  scope: z.enum(['allSources', 'selectedSources', 'unresolved']),
  isExact: z.boolean(),
  note: nullishToNull(z.string()),
});

export const trainingRunSchema = z.object({
  id: uuidSchema,
  mediaKind: assetMediaKindSchema,
  method: trainingMethodSchema,
  state: z.enum(['queued', 'running', 'succeeded', 'failed', 'cancelled']),
  createdAtMs: z.int(),
  startedAtMs: nullishToNull(z.int()),
  finishedAtMs: nullishToNull(z.int()),
  catalogScopeID: z.string(),
  jobID: nullishToNull(uuidSchema),
  tagID: nullishToNull(uuidSchema),
  tagDisplayName: nullishToNull(z.string()),
  batchID: nullishToNull(uuidSchema),
  batchTagIndex: nullishToNull(z.int().nonnegative()),
  batchTagCount: nullishToNull(z.int().nonnegative()),
  sampleCount: nullishToNull(z.int().nonnegative()),
  positiveSampleCount: nullishToNull(z.int().nonnegative()),
  negativeSampleCount: nullishToNull(z.int().nonnegative()),
  artifactKind: nullishToNull(z.string()),
  artifactRef: nullishToNull(z.string()),
  artifactSHA256: nullishToNull(z.string()),
  errorCode: nullishToNull(z.string()),
  recoveryContext: nullishToNull(recoveryContextSchema),
  failureGuidance: nullishToNull(
    z.object({ title: z.string(), message: z.string(), suggestedAction: z.string() }),
  ),
});

export const trainingWorkspaceSchema = z.object({
  mediaKind: assetMediaKindSchema,
  methodFilter: nullishToNull(trainingMethodSchema),
  runs: z.array(trainingRunSchema),
  slots: z.array(
    z.object({
      method: trainingMethodSchema,
      isPublished: z.boolean(),
      publishedRunID: nullishToNull(uuidSchema),
      artifactRef: nullishToNull(z.string()),
    }),
  ),
  activities: z.array(trainingActivitySchema).default([]),
});

export const trainingLaunchResponseSchema = z.object({
  operationID: uuidSchema,
  method: trainingMethodSchema,
  acceptedAtMs: z.int(),
  scheduledTagCount: z.int().nonnegative(),
  jobID: nullishToNull(uuidSchema),
  replayed: z.boolean(),
});
export const trainingActivityActionResponseSchema = z.object({ activity: trainingActivitySchema });

export const embeddingPreparationActivitySchema = z.object({
  operationID: uuidSchema,
  mediaKind: assetMediaKindSchema,
  phase: z.enum(['running', 'completed', 'failed', 'cancelled']),
  completedUnitCount: z.int().nonnegative(),
  totalUnitCount: z.int().nonnegative(),
  preparedCount: z.int().nonnegative(),
  cachedCount: z.int().nonnegative(),
  cloudOnlyCount: z.int().nonnegative(),
  failedCount: z.int().nonnegative(),
  errorCode: nullishToNull(z.string()),
  availableActions: z.array(z.literal('cancel')).default([]),
});
export const embeddingPreparationSnapshotSchema = z.object({
  mediaKind: assetMediaKindSchema,
  isAvailable: z.boolean(),
  activities: z.array(embeddingPreparationActivitySchema),
});
export const embeddingPreparationResponseSchema = z.object({
  activity: embeddingPreparationActivitySchema,
  replayed: z.boolean().default(false),
});
export const embeddingPreparationActionResponseSchema = z.object({
  activity: embeddingPreparationActivitySchema,
});

export const sampleSuggestionActivitySchema = z.object({
  operationID: uuidSchema,
  mediaKind: assetMediaKindSchema,
  phase: z.enum(['running', 'completed', 'failed', 'cancelled']),
  completedUnitCount: z.int().nonnegative(),
  totalUnitCount: z.int().nonnegative(),
  suggestedCount: z.int().nonnegative(),
  skippedCount: z.int().nonnegative(),
  errorCode: nullishToNull(z.string()),
  availableActions: z.array(z.literal('cancel')).default([]),
});
export const sampleSuggestionSnapshotSchema = z.object({
  mediaKind: assetMediaKindSchema,
  isAvailable: z.boolean(),
  maximumSampleCount: z.int().positive(),
  activities: z.array(sampleSuggestionActivitySchema),
});
export const sampleSuggestionResponseSchema = z.object({
  activity: sampleSuggestionActivitySchema,
  replayed: z.boolean().default(false),
});
export const sampleSuggestionActionResponseSchema = z.object({
  activity: sampleSuggestionActivitySchema,
});

const librarySuggestionJobSchema = z.object({
  jobID: uuidSchema,
  state: z.enum([
    'pending',
    'running',
    'paused',
    'retryableFailed',
    'completed',
    'terminalFailed',
    'cancelled',
  ]),
  checkedCount: z.int().nonnegative(),
  totalCount: nullishToNull(z.int().nonnegative()),
  suggestedCount: z.int().nonnegative(),
  skippedCount: z.int().nonnegative(),
  lastErrorCode: nullishToNull(z.string()),
  availableActions: z.array(jobActionSchema).default([]),
});
export const librarySuggestionSnapshotSchema = z.object({
  mediaKind: assetMediaKindSchema,
  service: z.object({
    state: z.enum(['unchecked', 'ready', 'degraded', 'unavailable']),
    serviceVersion: nullishToNull(z.string()),
    provider: nullishToNull(z.string()),
    modelID: nullishToNull(z.string()),
  }),
  standardAvailable: z.boolean(),
  personalMode: z.enum(['unavailable', 'sample', 'fullLibrary']),
  standardJob: nullishToNull(librarySuggestionJobSchema),
  personalJob: nullishToNull(librarySuggestionJobSchema),
});
export const librarySuggestionResponseSchema = z.object({
  operationID: uuidSchema,
  track: z.enum(['standard', 'personal']),
  jobID: uuidSchema,
  replayed: z.boolean(),
});

export const tagLibrarySuggestionActivitySchema = z.object({
  operationID: uuidSchema,
  mediaKind: assetMediaKindSchema,
  method: z.enum(['personalCentroid', 'personalAdamW']),
  tagID: uuidSchema,
  phase: z.enum([
    'preparingCandidates',
    'scoring',
    'publishing',
    'completed',
    'failed',
    'cancelled',
  ]),
  completedUnitCount: z.int().nonnegative(),
  totalUnitCount: z.int().nonnegative(),
  aboveThresholdCount: z.int().nonnegative(),
  insertedCount: z.int().nonnegative(),
  skippedCount: z.int().nonnegative(),
  errorCode: nullishToNull(z.string()),
  availableActions: z.array(z.literal('cancel')).default([]),
});
export const tagLibrarySuggestionSnapshotSchema = z.object({
  mediaKind: assetMediaKindSchema,
  maximumPendingCount: z.int().positive(),
  personalCentroidAvailable: z.boolean(),
  personalAdamWAvailable: z.boolean(),
  tags: z.array(
    z.object({
      tagID: uuidSchema,
      personalEligible: z.boolean(),
      personalCentroidMinScore: z.number(),
      personalAdamWMinScore: z.number(),
    }),
  ),
  activities: z.array(tagLibrarySuggestionActivitySchema),
});
export const tagLibrarySuggestionResponseSchema = z.object({
  activity: tagLibrarySuggestionActivitySchema,
  replayed: z.boolean().default(false),
});
export const tagLibrarySuggestionActionResponseSchema = z.object({
  activity: tagLibrarySuggestionActivitySchema,
});

export type TrainingMethod = z.infer<typeof trainingMethodSchema>;
export type TrainingSetup = z.infer<typeof trainingSetupSchema>;
export type TrainingActivity = z.infer<typeof trainingActivitySchema>;
export type TrainingWorkspace = z.infer<typeof trainingWorkspaceSchema>;
export type EmbeddingPreparationActivity = z.infer<typeof embeddingPreparationActivitySchema>;
export type SampleSuggestionActivity = z.infer<typeof sampleSuggestionActivitySchema>;
export type LibrarySuggestionSnapshot = z.infer<typeof librarySuggestionSnapshotSchema>;
export type TagLibrarySuggestionActivity = z.infer<typeof tagLibrarySuggestionActivitySchema>;
