import { z } from 'zod';

import { nullishToNull, uuidSchema } from './common';

export const tagSummarySchema = z.object({
  id: uuidSchema,
  displayName: z.string().min(1),
  state: z.enum(['active', 'archived']),
  groupID: uuidSchema,
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

export type TagSummary = z.infer<typeof tagSummarySchema>;
export type TagSelectionAggregate = z.infer<typeof tagSelectionAggregateSchema>;
export type TagDecisionAction = 'accept' | 'reject' | 'clear';
export type BatchTagDecisionResponse = z.infer<typeof batchTagDecisionResponseSchema>;
