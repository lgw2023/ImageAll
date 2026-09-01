import { describe, expect, it } from 'vitest';

import {
  assetDetailSchema,
  assetPageSchema,
  cloudPreviewSnapshotSchema,
  favoriteMutationResponseSchema,
  sourceFolderPageSchema,
  sourceSummarySchema,
} from './asset';
import { batchTagDecisionResponseSchema, tagSelectionAggregateSchema } from './tag';

const assetID = '88a75486-6dca-465a-8260-7e4587ea9446';
const sourceID = '9de47499-1ca0-4cc2-84bc-a881018e8b0c';
const tagID = '55220ca2-8800-4cea-a6b9-9f9e148d2adc';
const groupID = '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0';

describe('gallery protocol contracts', () => {
  it('decodes a Host asset page and normalizes omitted nullable fields', () => {
    const page = assetPageSchema.parse({
      items: [
        {
          id: assetID,
          sourceID,
          sourceName: 'Synthetic source',
          mediaType: 'image/jpeg',
          availability: 'available',
          contentRevision: 3,
          acceptedTagCount: 1,
          rejectedTagCount: 0,
          favorite: {
            assetID,
            isFavorite: false,
            syncStatus: 'synced',
          },
        },
      ],
    });

    expect(page.nextCursor).toBeNull();
    expect(page.items[0]).toMatchObject({
      id: assetID,
      fileName: null,
      relativePath: null,
      mediaCreatedAtMs: null,
      width: null,
      height: null,
    });
    expect(page.items[0]?.favorite).toMatchObject({
      photosObservedValue: null,
      lastErrorCode: null,
    });
  });

  it('decodes detail, favorite, selection, and undo-bearing tag responses', () => {
    const detail = assetDetailSchema.parse({
      assetID,
      sourceID,
      sourceName: 'Synthetic source',
      mediaType: 'image/jpeg',
      availability: 'available',
      contentRevision: 3,
      acceptedTagCount: 1,
      rejectedTagCount: 0,
      tags: [{ tagID, displayName: '风景', decision: 'accepted' }],
      pendingSuggestions: [{ tagID, displayName: '风景', suggestionOrigin: 'standardModel' }],
    });
    const favorite = favoriteMutationResponseSchema.parse({
      operationID: groupID,
      changedCount: 1,
      localOnlyCount: 0,
      syncedCount: 1,
      pendingCount: 0,
      failedCount: 0,
      states: [{ assetID, isFavorite: true, syncStatus: 'synced' }],
      replayed: false,
    });
    const aggregate = tagSelectionAggregateSchema.parse({
      tagID,
      acceptedCount: 1,
      rejectedCount: 0,
      unknownCount: 2,
    });
    const decision = batchTagDecisionResponseSchema.parse({
      operationID: groupID,
      appliedAssetCount: 3,
      replayed: false,
      undoID: sourceID,
    });

    expect(detail.pendingSuggestions?.[0]?.suggestionOrigin).toBe('standardModel');
    expect(favorite.states[0]?.isFavorite).toBe(true);
    expect(aggregate.unknownCount).toBe(2);
    expect(decision.undoID).toBe(sourceID);
  });

  it('fails closed for unknown Host enum values', () => {
    expect(() =>
      assetPageSchema.parse({
        items: [
          {
            id: assetID,
            sourceID,
            sourceName: 'Synthetic source',
            mediaType: 'image/jpeg',
            availability: 'temporarilyRemote',
            contentRevision: 1,
            acceptedTagCount: 0,
            rejectedTagCount: 0,
          },
        ],
      }),
    ).toThrow();
  });

  it('decodes bounded Host cloud-preview lifecycle snapshots', () => {
    const snapshot = cloudPreviewSnapshotSchema.parse({
      operationID: groupID,
      assetID,
      phase: 'downloading',
      progress: 0.42,
      updatedAtMs: 1_787_820_000_000,
    });

    expect(snapshot).toMatchObject({
      operationID: groupID,
      assetID,
      phase: 'downloading',
      progress: 0.42,
      message: null,
    });
    expect(() =>
      cloudPreviewSnapshotSchema.parse({
        ...snapshot,
        phase: 'queued',
      }),
    ).toThrow();
    expect(() =>
      cloudPreviewSnapshotSchema.parse({
        ...snapshot,
        progress: 1.1,
      }),
    ).toThrow();
  });

  it('decodes source and relative-folder projections without accepting absolute-path fields', () => {
    const source = sourceSummarySchema.parse({
      id: sourceID,
      kind: 'folder',
      displayName: 'Synthetic source',
      state: 'active',
    });
    const folderPage = sourceFolderPageSchema.parse({
      folders: [
        {
          sourceID,
          relativePath: 'Trips/2026',
          parentRelativePath: 'Trips',
          name: '2026',
        },
      ],
      totalCount: 1,
      nextOffset: null,
    });

    expect(source.displayName).toBe('Synthetic source');
    expect(folderPage.folders[0]?.relativePath).toBe('Trips/2026');
    expect(() =>
      sourceFolderPageSchema.parse({
        folders: [{ sourceID, relativePath: '', parentRelativePath: null, name: 'Root' }],
        totalCount: 1,
        nextOffset: null,
      }),
    ).toThrow();
  });
});
