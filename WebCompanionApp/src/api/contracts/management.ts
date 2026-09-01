import { z } from 'zod';

import { assetMediaKindSchema } from './asset';
import { nullishToNull, uuidSchema } from './common';

export const sourceSummarySchema = z.object({
  id: uuidSchema,
  kind: z.enum(['folder', 'photos']),
  displayName: z.string().min(1),
  state: z.enum(['active', 'disabled', 'unavailable', 'authorizationRequired']),
});

export const sourceManagementActionSchema = z.enum([
  'connectFolder',
  'connectPhotos',
  'refreshAll',
  'prewarmAllThumbnails',
  'prewarmAllOriginalAspect',
  'reauthorizeAll',
  'refreshAllFolderMutationAuthorizations',
  'rebindPhotos',
  'reauthorize',
  'rescan',
  'syncPhotos',
  'fullRepair',
  'openPhotosPrivacySettings',
  'requestPhotosWriteAuthorization',
  'refreshFolderMutationAuthorization',
  'prewarmThumbnails',
  'prewarmOriginalAspect',
  'cancelPrewarm',
  'delete',
]);

export const sourceRequestSchema = z.object({
  id: uuidSchema,
  operationID: uuidSchema,
  action: sourceManagementActionSchema,
  sourceID: nullishToNull(uuidSchema),
  sourceDisplayName: nullishToNull(z.string()),
  phase: z.enum(['awaitingMac', 'running', 'completed', 'cancelled', 'failed']),
  message: z.string(),
  completedCount: nullishToNull(z.int().nonnegative()),
  totalCount: nullishToNull(z.int().nonnegative()),
  warmedCount: nullishToNull(z.int().nonnegative()),
  failedCount: nullishToNull(z.int().nonnegative()),
  reusedCount: nullishToNull(z.int().nonnegative()),
  ineligibleCount: nullishToNull(z.int().nonnegative()),
  completedSourceCount: nullishToNull(z.int().nonnegative()),
  totalSourceCount: nullishToNull(z.int().nonnegative()),
  updatedAtMs: z.int(),
});

export const sourceManagementSchema = z.object({
  sources: z.array(sourceSummarySchema),
  canConnectPhotos: z.boolean(),
  requests: z.array(sourceRequestSchema),
});

const usageSchema = z.object({
  entryCount: z.int().nonnegative(),
  registeredBytes: z.int().nonnegative(),
});
const availabilitySchema = z.object({
  isAvailable: z.boolean(),
  reason: nullishToNull(z.enum(['empty', 'librarySlimmingAnalysisInProgress'])),
});
const storageResultSchema = z.object({
  affectedEntryCount: nullishToNull(z.int().nonnegative()),
  affectedBytes: nullishToNull(z.int().nonnegative()),
  bundleName: nullishToNull(z.string()),
  totalRecordCount: nullishToNull(z.int().nonnegative()),
  requiresRestart: nullishToNull(z.boolean()),
  partialReclaim: nullishToNull(z.boolean()),
});

export const storageActionSchema = z.enum([
  'exportPortableData',
  'chooseExternalStorage',
  'clearPreviewCache',
  'clearPhotosOriginals',
]);
export const storageRequestSchema = z.object({
  id: uuidSchema,
  operationID: uuidSchema,
  action: storageActionSchema,
  phase: z.enum(['awaitingMac', 'running', 'completed', 'cancelled', 'failed']),
  message: z.string(),
  updatedAtMs: z.int(),
  result: nullishToNull(storageResultSchema),
});
export const storageMaintenanceSchema = z.object({
  previewCache: usageSchema,
  photosOriginals: usageSchema,
  clearPreviewCacheAvailability: nullishToNull(availabilitySchema),
  clearPhotosOriginalsAvailability: nullishToNull(availabilitySchema),
  appStorage: z.object({
    kind: z.enum(['internalStorage', 'externalStorage']),
    requiresRestart: z.boolean(),
    pendingExternalRootName: nullishToNull(z.string()),
  }),
  requests: z.array(storageRequestSchema),
});

const thresholdReferenceSchema = z.object({
  minScore: z.number(),
  acceptedSampleCount: z.int().nonnegative(),
  rejectedSampleCount: z.int().nonnegative(),
});
export const thresholdMethodSchema = z.enum(['featureKnn', 'personalCentroid', 'personalAdamW']);
const thresholdRowSchema = z.object({
  method: thresholdMethodSchema,
  effectiveMinScore: z.number(),
  overrideMinScore: nullishToNull(z.number()),
  reference: nullishToNull(thresholdReferenceSchema),
});
export const generalSettingsSchema = z.object({
  localModel: z.object({
    isEnabled: z.boolean(),
    state: z.enum(['disabled', 'validating', 'ready', 'unavailable']),
    modelName: z.string(),
    runtimeName: z.string(),
    detail: z.string(),
  }),
  idleThumbnailPrewarmEnabled: z.boolean(),
  idleThresholdSeconds: z.int().nonnegative(),
  toolbarDisplayMode: z.enum(['iconOnly', 'iconAndTitle']),
  suggestionThresholds: nullishToNull(
    z.object({
      defaults: z.array(z.object({ method: thresholdMethodSchema, minScore: z.number() })),
      tags: z.array(
        z.object({
          tagID: uuidSchema,
          displayName: z.string(),
          methods: z.array(thresholdRowSchema),
        }),
      ),
    }),
  ),
  maxPendingSuggestionsPerTag: nullishToNull(z.int().positive()),
});
export const generalSettingsUpdateResponseSchema = z.object({
  settings: generalSettingsSchema,
  replayed: z.boolean(),
});

export const jobActionSchema = z.enum(['pause', 'resume', 'cancel']);
export const jobSummarySchema = z.object({
  id: uuidSchema,
  sourceID: nullishToNull(uuidSchema),
  sourceDisplayName: nullishToNull(z.string()),
  kind: z.enum([
    'folderReconcile',
    'photosReconcile',
    'personalizationSuggestions',
    'standardSuggestions',
    'librarySlimmingAnalysis',
    'librarySlimmingSourceIndex',
    'background',
    'other',
  ]),
  state: z.enum([
    'pending',
    'running',
    'paused',
    'retryableFailed',
    'completed',
    'terminalFailed',
    'cancelled',
  ]),
  progress: z.object({
    completedUnitCount: z.int().nonnegative(),
    totalUnitCount: nullishToNull(z.int().nonnegative()),
  }),
  availableActions: z.array(jobActionSchema),
  controlRequest: nullishToNull(z.enum(['none', 'pause', 'cancel'])),
  attempts: nullishToNull(z.int().nonnegative()),
  maxAttempts: nullishToNull(z.int().nonnegative()),
  lastErrorCode: nullishToNull(z.string()),
  navigationTarget: nullishToNull(
    z.object({
      workspace: z.literal('librarySlimming'),
      recordID: uuidSchema,
      mediaKind: nullishToNull(assetMediaKindSchema),
    }),
  ),
});

export const pairedDeviceSchema = z.object({
  deviceID: uuidSchema,
  deviceName: z.string().min(1),
  pairedAtMs: z.int(),
  lastSeenAtMs: nullishToNull(z.int()),
});

export type SourceManagement = z.infer<typeof sourceManagementSchema>;
export type SourceManagementAction = z.infer<typeof sourceManagementActionSchema>;
export type StorageMaintenanceAction = z.infer<typeof storageActionSchema>;
export type GeneralSettings = z.infer<typeof generalSettingsSchema>;
export type SuggestionThresholdMethod = z.infer<typeof thresholdMethodSchema>;
export type JobSummary = z.infer<typeof jobSummarySchema>;
export type JobAction = z.infer<typeof jobActionSchema>;
export type PairedDevice = z.infer<typeof pairedDeviceSchema>;
