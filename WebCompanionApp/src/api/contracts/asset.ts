import { z } from 'zod';

import { nullishToNull, uuidSchema } from './common';

export const assetSortSchema = z.enum(['newest', 'oldest', 'fileNameAscending']);
export const assetAvailabilitySchema = z.enum([
  'available',
  'missing',
  'unreadable',
  'unsupported',
]);
export const assetMediaKindSchema = z.enum(['image', 'video']);
export const favoriteSyncStatusSchema = z.enum(['localOnly', 'synced', 'pending', 'failed']);

export const favoriteStateSchema = z.object({
  assetID: uuidSchema,
  isFavorite: z.boolean(),
  photosObservedValue: nullishToNull(z.boolean()),
  syncStatus: favoriteSyncStatusSchema,
  lastErrorCode: nullishToNull(z.string()),
});

export const assetSummarySchema = z.object({
  id: uuidSchema,
  sourceID: uuidSchema,
  sourceName: z.string(),
  fileName: nullishToNull(z.string()),
  mediaType: z.string().min(1),
  availability: assetAvailabilitySchema,
  contentRevision: z.int().nonnegative(),
  acceptedTagCount: z.int().nonnegative(),
  rejectedTagCount: z.int().nonnegative(),
  mediaCreatedAtMs: nullishToNull(z.int()),
  width: nullishToNull(z.int().nonnegative()),
  height: nullishToNull(z.int().nonnegative()),
  favorite: nullishToNull(favoriteStateSchema),
  relativePath: nullishToNull(z.string()),
  mediaModifiedAtMs: nullishToNull(z.int()),
  durationMs: nullishToNull(z.int().nonnegative()),
});

export const assetPageSchema = z.object({
  items: z.array(assetSummarySchema),
  nextCursor: nullishToNull(z.string()),
});

export const sourceSummarySchema = z.object({
  id: uuidSchema,
  kind: z.enum(['folder', 'photos']),
  displayName: z.string().min(1),
  state: z.enum(['active', 'disabled', 'unavailable', 'authorizationRequired']),
});

export const sourceFolderSchema = z.object({
  sourceID: uuidSchema,
  relativePath: z.string().min(1),
  parentRelativePath: nullishToNull(z.string()),
  name: z.string().min(1),
});

export const sourceFolderPageSchema = z.object({
  folders: z.array(sourceFolderSchema),
  totalCount: z.int().nonnegative(),
  nextOffset: nullishToNull(z.int().nonnegative()),
});

export const inspectorTagDecisionSchema = z.enum(['unknown', 'accepted', 'rejected']);
export const inspectorTagStateSchema = z.object({
  tagID: uuidSchema,
  displayName: z.string(),
  decision: inspectorTagDecisionSchema,
});

export const pendingSuggestionSchema = z.object({
  tagID: uuidSchema,
  displayName: z.string(),
  suggestionOrigin: z.enum(['featurePrint', 'standardModel', 'personalModel', 'personalAdamW']),
});

export const assetDetailSchema = z.object({
  assetID: uuidSchema,
  sourceID: uuidSchema,
  sourceName: z.string(),
  fileName: nullishToNull(z.string()),
  relativePath: nullishToNull(z.string()),
  mediaType: z.string().min(1),
  availability: assetAvailabilitySchema,
  contentRevision: z.int().nonnegative(),
  acceptedTagCount: z.int().nonnegative(),
  rejectedTagCount: z.int().nonnegative(),
  mediaCreatedAtMs: nullishToNull(z.int()),
  mediaModifiedAtMs: nullishToNull(z.int()),
  width: nullishToNull(z.int().nonnegative()),
  height: nullishToNull(z.int().nonnegative()),
  durationMs: nullishToNull(z.int().nonnegative()),
  fingerprintSizeBytes: nullishToNull(z.int().nonnegative()),
  favorite: nullishToNull(favoriteStateSchema),
  tags: z.array(inspectorTagStateSchema),
  pendingSuggestions: nullishToNull(z.array(pendingSuggestionSchema)),
});

export const favoriteMutationResponseSchema = z.object({
  operationID: uuidSchema,
  changedCount: z.int().nonnegative(),
  localOnlyCount: z.int().nonnegative(),
  syncedCount: z.int().nonnegative(),
  pendingCount: z.int().nonnegative(),
  failedCount: z.int().nonnegative(),
  states: z.array(favoriteStateSchema),
  replayed: z.boolean(),
});

export const cloudPreviewPhaseSchema = z.enum(['downloading', 'completed', 'cancelled', 'failed']);

export const cloudPreviewSnapshotSchema = z.object({
  operationID: uuidSchema,
  assetID: uuidSchema,
  phase: cloudPreviewPhaseSchema,
  progress: z.number().min(0).max(1),
  message: nullishToNull(z.string()),
  updatedAtMs: z.int(),
});

export type AssetSort = z.infer<typeof assetSortSchema>;
export type AssetMediaKind = z.infer<typeof assetMediaKindSchema>;
export type AssetSummary = z.infer<typeof assetSummarySchema>;
export type AssetPage = z.infer<typeof assetPageSchema>;
export type AssetDetail = z.infer<typeof assetDetailSchema>;
export type FavoriteState = z.infer<typeof favoriteStateSchema>;
export type FavoriteMutationResponse = z.infer<typeof favoriteMutationResponseSchema>;
export type SourceSummary = z.infer<typeof sourceSummarySchema>;
export type SourceFolder = z.infer<typeof sourceFolderSchema>;
export type SourceFolderPage = z.infer<typeof sourceFolderPageSchema>;
export type CloudPreviewSnapshot = z.infer<typeof cloudPreviewSnapshotSchema>;
