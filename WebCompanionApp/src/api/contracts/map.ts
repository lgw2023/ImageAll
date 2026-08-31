import { z } from 'zod';

import { assetAvailabilitySchema, favoriteStateSchema } from './asset';
import { nullishToNull, uuidSchema } from './common';

export const worldMapBoundsSchema = z.object({
  west: z.number(),
  south: z.number().min(-90).max(90),
  east: z.number(),
  north: z.number().min(-90).max(90),
});

export const worldMapSelectionQuerySchema = z.object({
  cellDegrees: z.number().positive(),
  longitudeBucket: z.int(),
  latitudeBucket: z.int(),
  bounds: nullishToNull(worldMapBoundsSchema),
  maximumAssets: z.int().positive(),
});

export const worldMapClusterSchema = z.object({
  id: z.string().min(1),
  longitude: z.number().min(-180).max(180),
  latitude: z.number().min(-90).max(90),
  photoCount: z.int().nonnegative(),
  gpsCount: z.int().nonnegative(),
  tagCount: z.int().nonnegative(),
  displayName: z.string().min(1),
  selectionQuery: worldMapSelectionQuerySchema,
});

export const worldMapSnapshotSchema = z.object({
  clusters: z.array(worldMapClusterSchema),
  eligiblePhotoCount: z.int().nonnegative(),
  locatedPhotoCount: z.int().nonnegative(),
  unlocatedPhotoCount: z.int().nonnegative(),
});

export const worldMapAssetSchema = z.object({
  id: uuidSchema,
  fileName: nullishToNull(z.string()),
  availability: assetAvailabilitySchema,
  contentRevision: z.int().nonnegative(),
  favorite: nullishToNull(favoriteStateSchema),
});

export const worldMapSelectionSchema = z.object({
  assets: z.array(worldMapAssetSchema),
  totalPhotoCount: z.int().nonnegative(),
});

const jobProgressSchema = z.object({
  completedUnitCount: z.int().nonnegative(),
  totalUnitCount: nullishToNull(z.int().nonnegative()),
});

export const locationBackfillPhaseSchema = z.enum([
  'ready',
  'queued',
  'running',
  'cancelling',
  'retryableFailed',
  'completed',
  'cancelled',
  'terminalFailed',
  'unavailable',
]);

export const locationBackfillSchema = z.object({
  sourceID: uuidSchema,
  sourceKind: z.enum(['folder', 'photos']),
  sourceDisplayName: z.string().min(1),
  sourceState: z.enum(['active', 'disabled', 'unavailable', 'authorizationRequired']),
  phase: locationBackfillPhaseSchema,
  totalPhotoCount: z.int().nonnegative(),
  inspectedPhotoCount: z.int().nonnegative(),
  locatedPhotoCount: z.int().nonnegative(),
  activeJobID: nullishToNull(uuidSchema),
  scanProgress: nullishToNull(jobProgressSchema),
  canStart: z.boolean(),
  canCancel: z.boolean(),
});

export const locationBackfillResponseSchema = z.object({
  operationID: uuidSchema,
  snapshot: locationBackfillSchema,
  replayed: z.boolean(),
});

export const worldMapPlaceCandidateSchema = z.object({
  placeID: z.string().min(1),
  displayName: z.string().min(1),
  subtitle: nullishToNull(z.string()),
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  kind: z.enum(['poi', 'city', 'region', 'country']),
});

export const worldMapPlaceResolutionSchema = z.object({
  tagID: uuidSchema,
  tagName: z.string().min(1),
  groupName: z.string().min(1),
  acceptedPhotoCount: z.int().nonnegative(),
  status: z.enum(['unresolved', 'resolved', 'ambiguous', 'ignored', 'failed']),
  confirmedPlaceID: nullishToNull(z.string()),
  candidates: z.array(worldMapPlaceCandidateSchema),
});

export const worldMapPlaceSnapshotSchema = z.object({
  items: z.array(worldMapPlaceResolutionSchema),
  maximumQueryLength: z.int().positive(),
});

export const worldMapPlaceResponseSchema = z.object({
  operationID: uuidSchema,
  resolution: worldMapPlaceResolutionSchema,
  replayed: z.boolean(),
});

export type WorldMapBounds = z.infer<typeof worldMapBoundsSchema>;
export type WorldMapSelectionQuery = z.infer<typeof worldMapSelectionQuerySchema>;
export type WorldMapCluster = z.infer<typeof worldMapClusterSchema>;
export type WorldMapAsset = z.infer<typeof worldMapAssetSchema>;
export type LocationBackfill = z.infer<typeof locationBackfillSchema>;
export type WorldMapPlaceResolution = z.infer<typeof worldMapPlaceResolutionSchema>;
