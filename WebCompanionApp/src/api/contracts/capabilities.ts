import { z } from 'zod';

export const remoteCapabilitySchema = z.enum([
  'sources',
  'tags',
  'assetPages',
  'folderHierarchy',
  'assetDetail',
  'assetLocalSuggestions',
  'cloudPreviewLifecycle',
  'thumbnails',
  'previews',
  'favorites',
  'tagDecisions',
  'tagSelection',
  'reviewQueue',
  'reviewDecisions',
  'librarySuggestions',
  'trainingActivities',
  'librarySlimming',
  'sourceManagement',
  'generalSettings',
  'workspaceNotices',
  'jobs',
  'pairing',
  'events',
]);

export const capabilitiesSchema = z.object({
  protocolVersion: z.int().nonnegative(),
  hostAppVersion: z.string(),
  minimumClientProtocolVersion: z.int().nonnegative(),
  capabilities: z.array(remoteCapabilitySchema),
  listenPort: z.int().positive().nullable(),
  usesTLS: z.boolean(),
  hostID: z.uuid().nullable(),
  certificateFingerprintSHA256: z.string().nullable(),
});

export type Capabilities = z.infer<typeof capabilitiesSchema>;
