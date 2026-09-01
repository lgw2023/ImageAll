import { z } from 'zod';

import { nullishToNull, uuidSchema } from './common';

export const tagSummarySchema = z.object({
  id: uuidSchema,
  displayName: z.string().min(1),
  state: z.enum(['active', 'archived']),
  groupID: uuidSchema,
});

export const tagGroupSummarySchema = z.object({
  id: uuidSchema,
  displayName: z.string().min(1),
  sortOrder: z.int(),
  isSystem: z.boolean(),
});

export const tagSelectionAggregateSchema = z.object({
  tagID: uuidSchema,
  acceptedCount: z.int().nonnegative(),
  rejectedCount: z.int().nonnegative(),
  unknownCount: z.int().nonnegative(),
});

export const batchTagDecisionResponseSchema = z.object({
  operationID: uuidSchema,
  appliedAssetCount: z.int().nonnegative(),
  replayed: z.boolean(),
  undoID: nullishToNull(uuidSchema),
});

export const undoTagDecisionResponseSchema = z.object({
  operationID: uuidSchema,
  restoredAssetCount: z.int().nonnegative(),
  replayed: z.boolean(),
});

export const createTagAndApplyResponseSchema = z.object({
  operationID: uuidSchema,
  tagID: uuidSchema,
  displayName: z.string().min(1),
  appliedAssetCount: z.int().nonnegative(),
  replayed: z.boolean(),
  undoID: nullishToNull(uuidSchema),
});

export const tagMutationResponseSchema = z.object({
  operationID: uuidSchema,
  tag: nullishToNull(tagSummarySchema),
  replayed: z.boolean(),
});

export const tagGroupMutationResponseSchema = z.object({
  operationID: uuidSchema,
  group: nullishToNull(tagGroupSummarySchema),
  replayed: z.boolean(),
});

export const installPresetTagsResponseSchema = z.object({
  operationID: uuidSchema,
  createdTags: z.array(tagSummarySchema),
  replayed: z.boolean(),
});

export type TagSummary = z.infer<typeof tagSummarySchema>;
export type TagGroupSummary = z.infer<typeof tagGroupSummarySchema>;
export type TagSelectionAggregate = z.infer<typeof tagSelectionAggregateSchema>;
export type TagDecisionAction = 'accept' | 'reject' | 'clear';
export type BatchTagDecisionResponse = z.infer<typeof batchTagDecisionResponseSchema>;
export type CreateTagAndApplyResponse = z.infer<typeof createTagAndApplyResponseSchema>;
