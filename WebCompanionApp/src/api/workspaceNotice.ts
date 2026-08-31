import { requestJSON } from './client';
import {
  workspaceNoticeActionResponseSchema,
  workspaceNoticeDismissResponseSchema,
  workspaceNoticeSnapshotSchema,
  type WorkspaceNotice,
} from './contracts/workspaceNotice';

export async function fetchWorkspaceNotice(signal?: AbortSignal): Promise<WorkspaceNotice | null> {
  const snapshot = signal
    ? await requestJSON('/v1/workspace-notice', workspaceNoticeSnapshotSchema, { signal })
    : await requestJSON('/v1/workspace-notice', workspaceNoticeSnapshotSchema);
  return snapshot.notice;
}

export async function dismissWorkspaceNotice(noticeID: string): Promise<WorkspaceNotice | null> {
  const response = await requestJSON(
    '/v1/workspace-notice/dismiss',
    workspaceNoticeDismissResponseSchema,
    { method: 'POST', body: JSON.stringify({ noticeID }) },
  );
  return response.notice;
}

export async function performWorkspaceNoticeAction(
  noticeID: string,
  actionID: string,
): Promise<{ performed: boolean; notice: WorkspaceNotice | null }> {
  return requestJSON('/v1/workspace-notice/action', workspaceNoticeActionResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ noticeID, actionID }),
  });
}
