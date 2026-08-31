import { z } from 'zod';

import { assetAvailabilitySchema, favoriteStateSchema } from './asset';
import { nullishToNull, uuidSchema } from './common';

export const suggestionOriginSchema = z.enum([
  'featurePrint',
  'standardModel',
  'personalModel',
  'personalAdamW',
]);

export const suggestionTaskStatusSchema = z.enum([
  'notReady',
  'ready',
  'waiting',
  'running',
  'paused',
  'retryableFailure',
  'completed',
  'terminalFailure',
  'cancelled',
]);

const originCountsSchema = z.object({
  featurePrint: z.int().nonnegative(),
  standardModel: z.int().nonnegative(),
  personalModel: z.int().nonnegative(),
  personalAdamW: z.int().nonnegative(),
});

export const reviewTagOverviewSchema = z.object({
  id: uuidSchema,
  displayName: z.string().min(1),
  acceptedSampleCount: z.int().nonnegative(),
  rejectedSampleCount: z.int().nonnegative(),
  pendingSuggestionCount: z.int().nonnegative(),
  pendingSuggestionCounts: originCountsSchema,
  taskStatus: suggestionTaskStatusSchema,
  checkedCount: z.int().nonnegative(),
  totalCount: nullishToNull(z.int().nonnegative()),
  skippedCount: z.int().nonnegative(),
  missingPositiveCount: z.int().nonnegative(),
  missingNegativeCount: z.int().nonnegative(),
  canGenerate: z.boolean(),
  canUpdate: z.boolean(),
  canGeneratePersonalModel: z.boolean(),
  canReview: z.boolean(),
  canPause: z.boolean(),
  canResume: z.boolean(),
  canCancel: z.boolean(),
  activeJobID: nullishToNull(uuidSchema),
});

export const reviewOverviewSchema = z.object({
  totalPendingSuggestionCount: z.int().nonnegative(),
  tags: z.array(reviewTagOverviewSchema),
});

export const reviewQueueItemSchema = z.object({
  assetID: uuidSchema,
  fileName: nullishToNull(z.string()),
  availability: assetAvailabilitySchema,
  contentRevision: nullishToNull(z.int().nonnegative()),
  acceptedTagCount: z.int().nonnegative(),
  rejectedTagCount: z.int().nonnegative(),
  suggestionOrigin: suggestionOriginSchema,
  score: nullishToNull(z.number()),
  width: nullishToNull(z.int().nonnegative()),
  height: nullishToNull(z.int().nonnegative()),
  favorite: nullishToNull(favoriteStateSchema),
});

export const reviewQueuePageSchema = z.object({
  items: z.array(reviewQueueItemSchema),
  nextCursor: nullishToNull(z.string()),
});

export const reviewDecisionResponseSchema = z.object({
  operationID: uuidSchema,
  appliedAssetCount: z.int().nonnegative(),
  replayed: z.boolean(),
  undoID: nullishToNull(uuidSchema),
});

export const reviewUndoResponseSchema = z.object({
  operationID: uuidSchema,
  restoredAssetCount: z.int().nonnegative(),
  replayed: z.boolean(),
});

export type ReviewOverview = z.infer<typeof reviewOverviewSchema>;
export type ReviewTagOverview = z.infer<typeof reviewTagOverviewSchema>;
export type ReviewQueueItem = z.infer<typeof reviewQueueItemSchema>;
export type ReviewQueuePage = z.infer<typeof reviewQueuePageSchema>;
export type ReviewDecisionAction = 'accept' | 'reject' | 'clear';
