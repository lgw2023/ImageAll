import { describe, expect, it } from 'vitest';

import { jobSummarySchema, sourceRequestSchema, storageMaintenanceSchema } from './management';

describe('management contracts', () => {
  it('normalizes omitted source request progress fields', () => {
    const request = sourceRequestSchema.parse({
      id: '5cba0aa1-e0c3-4421-bb0f-4f7edab5c3b5',
      operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
      action: 'connectFolder',
      phase: 'awaitingMac',
      message: '请在 Mac 上选择文件夹',
      updatedAtMs: 1,
    });
    expect(request.sourceID).toBeNull();
    expect(request.totalCount).toBeNull();
  });

  it('accepts an older storage snapshot without availability projections', () => {
    const snapshot = storageMaintenanceSchema.parse({
      previewCache: { entryCount: 0, registeredBytes: 0 },
      photosOriginals: { entryCount: 0, registeredBytes: 0 },
      appStorage: { kind: 'internalStorage', requiresRestart: false },
      requests: [],
    });
    expect(snapshot.clearPreviewCacheAvailability).toBeNull();
  });

  it('rejects an unknown job state', () => {
    const result = jobSummarySchema.safeParse({
      id: '6cba0aa1-e0c3-4421-bb0f-4f7edab5c3b6',
      kind: 'background',
      state: 'finishedSomehow',
      progress: { completedUnitCount: 1 },
      availableActions: [],
    });
    expect(result.success).toBe(false);
  });
});
