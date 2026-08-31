import { z } from 'zod';

export const workspaceNoticeActionSchema = z.object({
  id: z.string().min(1),
  kind: z.enum(['undoTagMutation', 'openRecycleBin']),
  title: z.string().min(1),
  sourceID: z.uuid().nullable(),
});

export const workspaceNoticeSchema = z.object({
  id: z.string().min(1),
  severity: z.enum(['information', 'success', 'warning']),
  message: z.string().min(1),
  actions: z.array(workspaceNoticeActionSchema),
});

export const workspaceNoticeSnapshotSchema = z.object({
  notice: workspaceNoticeSchema.nullable(),
});

export const workspaceNoticeDismissResponseSchema = z.object({
  dismissed: z.boolean(),
  notice: workspaceNoticeSchema.nullable(),
});

export const workspaceNoticeActionResponseSchema = z.object({
  performed: z.boolean(),
  notice: workspaceNoticeSchema.nullable(),
});

export type WorkspaceNoticeAction = z.infer<typeof workspaceNoticeActionSchema>;
export type WorkspaceNotice = z.infer<typeof workspaceNoticeSchema>;
