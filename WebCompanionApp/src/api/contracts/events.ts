import { z } from 'zod';

export const remoteEventSchema = z.object({
  id: z.uuid(),
  kind: z.enum([
    'ping',
    'sourcesChanged',
    'tagsChanged',
    'assetsChanged',
    'jobsChanged',
    'reviewChanged',
  ]),
  emittedAtMs: z.int(),
  sourceID: z.uuid().nullable(),
  tagID: z.uuid().nullable(),
  jobID: z.uuid().nullable(),
});

export type RemoteEvent = z.infer<typeof remoteEventSchema>;
