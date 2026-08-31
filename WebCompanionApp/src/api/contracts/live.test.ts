import { describe, expect, it } from 'vitest';

import { remoteEventSchema } from './events';
import { workspaceNoticeSnapshotSchema } from './workspaceNotice';

const sourceID = '9de47499-1ca0-4cc2-84bc-a881018e8b0c';

describe('live Host contracts', () => {
  it('accepts an invalidation event and a recoverable workspace notice', () => {
    const event = remoteEventSchema.parse({
      id: '88a75486-6dca-465a-8260-7e4587ea9446',
      kind: 'assetsChanged',
      emittedAtMs: 1_788_000_000_000,
      sourceID,
      tagID: null,
      jobID: null,
    });
    const snapshot = workspaceNoticeSnapshotSchema.parse({
      notice: {
        id: 'notice-1',
        severity: 'warning',
        message: '来源删除被回收区项目阻止。',
        actions: [{ id: 'open-recycle', kind: 'openRecycleBin', title: '打开回收区', sourceID }],
      },
    });

    expect(event.kind).toBe('assetsChanged');
    expect(snapshot.notice?.actions[0]?.kind).toBe('openRecycleBin');
  });

  it('rejects unknown event and notice actions', () => {
    expect(() =>
      remoteEventSchema.parse({
        id: sourceID,
        kind: 'deleteEverything',
        emittedAtMs: 1,
        sourceID: null,
        tagID: null,
        jobID: null,
      }),
    ).toThrow();
    expect(() =>
      workspaceNoticeSnapshotSchema.parse({
        notice: {
          id: 'notice-2',
          severity: 'warning',
          message: 'Synthetic',
          actions: [{ id: 'unsafe', kind: 'delete', title: 'Delete', sourceID }],
        },
      }),
    ).toThrow();
  });
});
