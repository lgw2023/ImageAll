import { describe, expect, it } from 'vitest';

import { locationBackfillSchema, worldMapPlaceSnapshotSchema, worldMapSnapshotSchema } from './map';

describe('world map contracts', () => {
  it('decodes a bounded cluster snapshot', () => {
    const result = worldMapSnapshotSchema.parse({
      clusters: [
        {
          id: 'shanghai',
          longitude: 121.47,
          latitude: 31.23,
          photoCount: 18,
          gpsCount: 12,
          tagCount: 6,
          displayName: '上海',
          selectionQuery: {
            cellDegrees: 0.25,
            longitudeBucket: 485,
            latitudeBucket: 124,
            maximumAssets: 36,
          },
        },
      ],
      eligiblePhotoCount: 80,
      locatedPhotoCount: 62,
      unlocatedPhotoCount: 18,
    });
    expect(result.clusters[0]?.selectionQuery.bounds).toBeNull();
  });

  it('normalizes optional backfill state from the Host', () => {
    const result = locationBackfillSchema.parse({
      sourceID: '9de47499-1ca0-4cc2-84bc-a881018e8b0c',
      sourceKind: 'folder',
      sourceDisplayName: 'Synthetic Library',
      sourceState: 'active',
      phase: 'ready',
      totalPhotoCount: 120,
      inspectedPhotoCount: 42,
      locatedPhotoCount: 30,
      canStart: true,
      canCancel: false,
    });
    expect(result.activeJobID).toBeNull();
    expect(result.scanProgress).toBeNull();
  });

  it('rejects invalid place coordinates', () => {
    expect(() =>
      worldMapPlaceSnapshotSchema.parse({
        maximumQueryLength: 160,
        items: [
          {
            tagID: '55220ca2-8800-4cea-a6b9-9f9e148d2adc',
            tagName: '上海',
            groupName: '地点',
            acceptedPhotoCount: 8,
            status: 'ambiguous',
            candidates: [
              {
                placeID: 'bad',
                displayName: '错误地点',
                latitude: 120,
                longitude: 121,
                kind: 'city',
              },
            ],
          },
        ],
      }),
    ).toThrow();
  });
});
