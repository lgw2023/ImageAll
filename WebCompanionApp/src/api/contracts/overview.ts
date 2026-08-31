import { z } from 'zod';

import { assetAvailabilitySchema, assetMediaKindSchema } from './asset';
import { nullishToNull, uuidSchema } from './common';

const countedMediaSchema = z.object({
  mediaKind: assetMediaKindSchema,
  totalCount: z.int().nonnegative(),
  exactUniqueCount: z.int().nonnegative(),
  exactRedundantCount: z.int().nonnegative(),
  exactFingerprintCount: z.int().nonnegative(),
});

const sourceOverviewSchema = z.object({
  id: uuidSchema,
  displayName: z.string().min(1),
  kind: z.enum(['folder', 'photos']),
  state: z.enum(['active', 'disabled', 'unavailable', 'authorizationRequired']),
  imageCount: z.int().nonnegative(),
  videoCount: z.int().nonnegative(),
});

const tagOverviewSchema = z.object({
  id: uuidSchema,
  displayName: z.string().min(1),
  imageCount: z.int().nonnegative(),
  videoCount: z.int().nonnegative(),
});

const yearOverviewSchema = z.object({
  year: z.int(),
  imageCount: z.int().nonnegative(),
  videoCount: z.int().nonnegative(),
});

const availabilityOverviewSchema = z.object({
  availability: assetAvailabilitySchema,
  imageCount: z.int().nonnegative(),
  videoCount: z.int().nonnegative(),
});

const favoriteOverviewSchema = z.object({
  mediaKind: assetMediaKindSchema,
  count: z.int().nonnegative(),
});

export const galleryOverviewSchema = z.object({
  media: z.array(countedMediaSchema),
  sources: z.array(sourceOverviewSchema),
  positiveTags: z.array(tagOverviewSchema),
  years: z.array(yearOverviewSchema),
  availability: z.array(availabilityOverviewSchema),
  undatedCount: z.int().nonnegative(),
  positiveLabeledAssetCount: z.int().nonnegative(),
  acceptedDecisionCount: z.int().nonnegative(),
  favorites: nullishToNull(z.array(favoriteOverviewSchema)),
});

export type GalleryOverview = z.infer<typeof galleryOverviewSchema>;
