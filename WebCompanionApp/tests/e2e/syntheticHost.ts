import type { Page } from '@playwright/test';

export const sourceID = '9de47499-1ca0-4cc2-84bc-a881018e8b0c';
export const tagIDs = [
  '55220ca2-8800-4cea-a6b9-9f9e148d2adc',
  '37cb4f7b-89bd-4548-80b8-ced4e1af5107',
] as const;
export const assetIDs = Array.from(
  { length: 120 },
  (_, index) => `10000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
);

const session = {
  authenticated: true,
  deviceID: '8bc2a920-f281-413b-8c4c-33c8ed7f78ca',
  authMode: 'pairedDevice',
  username: null,
};

const capabilities = {
  protocolVersion: 1,
  hostAppVersion: 'Synthetic Host',
  minimumClientProtocolVersion: 1,
  capabilities: [
    'assetPages',
    'assetDetail',
    'thumbnails',
    'favorites',
    'tagDecisions',
    'tagSelection',
    'reviewQueue',
    'reviewDecisions',
    'tags',
    'sourceManagement',
    'generalSettings',
    'jobs',
    'pairing',
  ],
  listenPort: 5173,
  usesTLS: false,
  hostID: 'a90e71ec-d641-488e-a2c4-c462c13b08ff',
  certificateFingerprintSHA256: null,
};

const tags = [
  {
    id: tagIDs[0],
    displayName: '风景',
    state: 'active',
    groupID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
  },
  {
    id: tagIDs[1],
    displayName: '家人',
    state: 'active',
    groupID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
  },
];

function asset(index: number) {
  const id = assetIDs[index];
  if (!id) throw new Error('Synthetic asset index out of range');
  return {
    id,
    sourceID,
    sourceName: 'Synthetic Library',
    fileName: `IMG_${String(index + 1).padStart(4, '0')}.jpg`,
    mediaType: (index + 1) % 11 === 0 ? 'video/mp4' : 'image/jpeg',
    availability: 'available',
    contentRevision: 1,
    acceptedTagCount: index % 3,
    rejectedTagCount: 0,
    mediaCreatedAtMs: 1_787_820_000_000 - index * 60_000,
    width: 1600,
    height: 1200,
    favorite: {
      assetID: id,
      isFavorite: false,
      photosObservedValue: false,
      syncStatus: 'synced',
      lastErrorCode: null,
    },
    relativePath: `2026/Synthetic/IMG_${String(index + 1).padStart(4, '0')}.jpg`,
    mediaModifiedAtMs: 1_787_820_000_000 - index * 60_000,
    durationMs: (index + 1) % 11 === 0 ? 9_000 : null,
  };
}

function detail(id: string) {
  const index = Math.max(0, assetIDs.indexOf(id));
  const summary = asset(index);
  return {
    assetID: summary.id,
    sourceID: summary.sourceID,
    sourceName: summary.sourceName,
    fileName: summary.fileName,
    relativePath: summary.relativePath,
    mediaType: summary.mediaType,
    availability: summary.availability,
    contentRevision: summary.contentRevision,
    acceptedTagCount: 1,
    rejectedTagCount: 0,
    mediaCreatedAtMs: summary.mediaCreatedAtMs,
    mediaModifiedAtMs: summary.mediaModifiedAtMs,
    width: summary.width,
    height: summary.height,
    durationMs: summary.durationMs,
    fingerprintSizeBytes: 1024,
    favorite: summary.favorite,
    tags: [
      { tagID: tagIDs[0], displayName: '风景', decision: 'accepted' },
      { tagID: tagIDs[1], displayName: '家人', decision: 'unknown' },
    ],
    pendingSuggestions: [],
  };
}

const previewSVG = `
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480" viewBox="0 0 640 480">
  <rect width="640" height="480" fill="#d7e5ef"/>
  <path d="M0 360L170 210l96 88 92-112 282 248v46H0z" fill="#7194a9"/>
  <circle cx="510" cy="105" r="45" fill="#f4c86b"/>
</svg>`;

export async function installSyntheticAuthenticatedHost(page: Page) {
  let firstAssetFavorite = false;
  let syntheticTags = structuredClone(tags) as {
    id: string;
    displayName: string;
    state: 'active' | 'archived';
    groupID: string;
  }[];
  let syntheticGroups = [
    {
      id: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
      displayName: '人物与地点',
      sortOrder: 0,
      isSystem: false,
    },
  ];
  const reviewedAssets = new Set<string>();
  let sourceRequests: Record<string, unknown>[] = [];
  let storageRequests: Record<string, unknown>[] = [];
  let settings = {
    localModel: {
      isEnabled: true,
      state: 'ready',
      modelName: 'Synthetic Vision',
      runtimeName: 'Core ML',
      detail: '合成本地模型已就绪',
    },
    idleThumbnailPrewarmEnabled: true,
    idleThresholdSeconds: 120,
    toolbarDisplayMode: 'iconAndTitle',
    suggestionThresholds: {
      defaults: [
        { method: 'featureKnn', minScore: 0.74 },
        { method: 'personalCentroid', minScore: 0.82 },
      ],
      tags: [],
    },
    maxPendingSuggestionsPerTag: 200,
  };
  let jobs = [
    {
      id: '6cba0aa1-e0c3-4421-bb0f-4f7edab5c3b6',
      sourceID,
      sourceDisplayName: 'Synthetic Library',
      kind: 'folderReconcile',
      state: 'running',
      progress: { completedUnitCount: 42, totalUnitCount: 120 },
      availableActions: ['pause', 'cancel'],
      controlRequest: 'none',
      attempts: 1,
      maxAttempts: 3,
      lastErrorCode: null,
      navigationTarget: null,
    },
  ];
  let devices = [
    {
      deviceID: session.deviceID,
      deviceName: '当前浏览器',
      pairedAtMs: 1_787_000_000_000,
      lastSeenAtMs: 1_787_820_000_000,
    },
    {
      deviceID: '7cba0aa1-e0c3-4421-bb0f-4f7edab5c3b7',
      deviceName: '旧 iPad',
      pairedAtMs: 1_786_000_000_000,
      lastSeenAtMs: 1_786_500_000_000,
    },
  ];
  await page.route('**/web/session', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: session }),
  );
  await page.route('**/v1/capabilities', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: capabilities }),
  );
  await page.route('**/v1/source-management', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        sources: [
          {
            id: sourceID,
            kind: 'folder',
            displayName: 'Synthetic Library',
            state: 'active',
          },
        ],
        canConnectPhotos: true,
        requests: sourceRequests,
      },
    }),
  );
  await page.route('**/v1/source-management/requests', (route) => {
    const body = route.request().postDataJSON() as {
      operationID: string;
      action: string;
      sourceID: string | null;
    };
    const request = {
      id: '5cba0aa1-e0c3-4421-bb0f-4f7edab5c3b5',
      operationID: body.operationID,
      action: body.action,
      sourceID: body.sourceID,
      sourceDisplayName: body.sourceID ? 'Synthetic Library' : null,
      phase: 'completed',
      message: 'Mac 已完成合成来源请求。',
      completedCount: 120,
      totalCount: 120,
      warmedCount: null,
      failedCount: 0,
      reusedCount: null,
      ineligibleCount: null,
      completedSourceCount: 1,
      totalSourceCount: 1,
      updatedAtMs: 1_787_820_000_000,
    };
    sourceRequests = [request];
    return route.fulfill({ status: 202, contentType: 'application/json', json: request });
  });
  await page.route('**/v1/storage-maintenance', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        previewCache: { entryCount: 120, registeredBytes: 25_165_824 },
        photosOriginals: { entryCount: 3, registeredBytes: 314_572_800 },
        clearPreviewCacheAvailability: { isAvailable: true, reason: null },
        clearPhotosOriginalsAvailability: { isAvailable: true, reason: null },
        appStorage: {
          kind: 'internalStorage',
          requiresRestart: false,
          pendingExternalRootName: null,
        },
        requests: storageRequests,
      },
    }),
  );
  await page.route('**/v1/storage-maintenance/requests', (route) => {
    const body = route.request().postDataJSON() as { operationID: string; action: string };
    const request = {
      id: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3b8',
      operationID: body.operationID,
      action: body.action,
      phase: 'completed',
      message: 'Mac 已完成合成维护请求。',
      updatedAtMs: 1_787_820_000_000,
      result: {
        affectedEntryCount: 120,
        affectedBytes: 25_165_824,
        bundleName: null,
        totalRecordCount: null,
        requiresRestart: false,
        partialReclaim: false,
      },
    };
    storageRequests = [request];
    return route.fulfill({ status: 202, contentType: 'application/json', json: request });
  });
  await page.route('**/v1/settings/general', (route) => {
    if (route.request().method() === 'GET') {
      return route.fulfill({ status: 200, contentType: 'application/json', json: settings });
    }
    const body = route.request().postDataJSON() as {
      modelEnabled?: boolean;
      idleThumbnailPrewarmEnabled?: boolean;
      toolbarDisplayMode?: 'iconOnly' | 'iconAndTitle';
      maxPendingSuggestionsPerTag?: number;
    };
    settings = {
      ...settings,
      localModel: {
        ...settings.localModel,
        isEnabled: body.modelEnabled ?? settings.localModel.isEnabled,
      },
      idleThumbnailPrewarmEnabled:
        body.idleThumbnailPrewarmEnabled ?? settings.idleThumbnailPrewarmEnabled,
      toolbarDisplayMode: body.toolbarDisplayMode ?? settings.toolbarDisplayMode,
      maxPendingSuggestionsPerTag:
        body.maxPendingSuggestionsPerTag ?? settings.maxPendingSuggestionsPerTag,
    };
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { settings, replayed: false },
    });
  });
  await page.route('**/v1/jobs', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: jobs }),
  );
  await page.route(/\/v1\/jobs\/[0-9a-f-]+\/actions$/i, (route) => {
    const jobID = new URL(route.request().url()).pathname.split('/').at(-2) ?? '';
    const body = route.request().postDataJSON() as { action: string };
    jobs = jobs.map((job) =>
      job.id === jobID
        ? {
            ...job,
            state:
              body.action === 'pause'
                ? 'paused'
                : body.action === 'resume'
                  ? 'running'
                  : 'cancelled',
            availableActions: body.action === 'pause' ? ['resume', 'cancel'] : [],
          }
        : job,
    );
    return route.fulfill({ status: 200, contentType: 'application/json', json: { jobID } });
  });
  await page.route('**/v1/pairing/devices', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: devices }),
  );
  await page.route(/\/v1\/pairing\/devices\/[0-9a-f-]+$/i, (route) => {
    const deviceID = new URL(route.request().url()).pathname.split('/').at(-1) ?? '';
    devices = devices.filter((device) => device.deviceID !== deviceID);
    return route.fulfill({ status: 204 });
  });
  await page.route('**/v1/tags', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: syntheticTags }),
  );
  await page.route('**/v1/tag-groups', async (route) => {
    if (route.request().method() === 'GET') {
      return route.fulfill({ status: 200, contentType: 'application/json', json: syntheticGroups });
    }
    const body = route.request().postDataJSON() as { operationID: string; name: string };
    const group = {
      id: '4cba0aa1-e0c3-4421-bb0f-4f7edab5c3b4',
      displayName: body.name,
      sortOrder: syntheticGroups.length,
      isSystem: false,
    };
    syntheticGroups = [...syntheticGroups, group];
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { operationID: body.operationID, group, replayed: false },
    });
  });
  await page.route('**/v1/tags/install-presets', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
        createdTags: [],
        replayed: false,
      },
    }),
  );
  await page.route(/\/v1\/tags\/[0-9a-f-]+\/(rename|move|archive)$/i, (route) => {
    const parts = new URL(route.request().url()).pathname.split('/');
    const tagID = parts.at(-2) ?? '';
    const action = parts.at(-1);
    const body = route.request().postDataJSON() as {
      operationID: string;
      name?: string;
      groupID?: string;
    };
    syntheticTags = syntheticTags.map((tag) => {
      if (tag.id !== tagID) return tag;
      if (action === 'rename' && body.name) return { ...tag, displayName: body.name };
      if (action === 'move' && body.groupID) return { ...tag, groupID: body.groupID };
      if (action === 'archive') return { ...tag, state: 'archived' as const };
      return tag;
    });
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        tag: syntheticTags.find((tag) => tag.id === tagID) ?? null,
        replayed: false,
      },
    });
  });
  await page.route(/\/v1\/tag-groups\/[0-9a-f-]+\/(rename|delete)$/i, (route) => {
    const parts = new URL(route.request().url()).pathname.split('/');
    const groupID = parts.at(-2) ?? '';
    const action = parts.at(-1);
    const body = route.request().postDataJSON() as { operationID: string; name?: string };
    let group = syntheticGroups.find((item) => item.id === groupID) ?? null;
    if (action === 'rename' && body.name) {
      syntheticGroups = syntheticGroups.map((item) =>
        item.id === groupID ? { ...item, displayName: body.name ?? item.displayName } : item,
      );
      group = syntheticGroups.find((item) => item.id === groupID) ?? null;
    } else if (action === 'delete') {
      syntheticGroups = syntheticGroups.filter((item) => item.id !== groupID);
      group = null;
    }
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { operationID: body.operationID, group, replayed: false },
    });
  });
  await page.route('**/v1/gallery-overview', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        media: [
          {
            mediaKind: 'image',
            totalCount: 109,
            exactUniqueCount: 100,
            exactRedundantCount: 9,
            exactFingerprintCount: 109,
          },
          {
            mediaKind: 'video',
            totalCount: 11,
            exactUniqueCount: 11,
            exactRedundantCount: 0,
            exactFingerprintCount: 11,
          },
        ],
        sources: [
          {
            id: sourceID,
            displayName: 'Synthetic Library',
            kind: 'folder',
            state: 'active',
            imageCount: 109,
            videoCount: 11,
          },
        ],
        positiveTags: syntheticTags.map((tag, index) => ({
          id: tag.id,
          displayName: tag.displayName,
          imageCount: 20 - index * 4,
          videoCount: index,
        })),
        years: [{ year: 2026, imageCount: 109, videoCount: 11 }],
        availability: [{ availability: 'available', imageCount: 109, videoCount: 11 }],
        undatedCount: 0,
        positiveLabeledAssetCount: 38,
        acceptedDecisionCount: 52,
        favorites: [
          { mediaKind: 'image', count: 4 },
          { mediaKind: 'video', count: 1 },
        ],
      },
    }),
  );
  await page.route('**/v1/review/overview?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        totalPendingSuggestionCount: Math.max(0, 8 - reviewedAssets.size),
        tags: [
          {
            id: tagIDs[0],
            displayName: '风景',
            acceptedSampleCount: 12,
            rejectedSampleCount: 5,
            pendingSuggestionCount: Math.max(0, 8 - reviewedAssets.size),
            pendingSuggestionCounts: {
              featurePrint: 3,
              standardModel: 5,
              personalModel: 0,
              personalAdamW: 0,
            },
            taskStatus: 'ready',
            checkedCount: 120,
            totalCount: 120,
            skippedCount: 0,
            missingPositiveCount: 0,
            missingNegativeCount: 0,
            canGenerate: true,
            canUpdate: true,
            canGeneratePersonalModel: false,
            canReview: true,
            canPause: false,
            canResume: false,
            canCancel: false,
            activeJobID: null,
          },
        ],
      },
    }),
  );
  await page.route('**/v1/review/queue?*', (route) => {
    const items = assetIDs.slice(0, 8).filter((id) => !reviewedAssets.has(id));
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        items: items.map((id, index) => ({
          assetID: id,
          fileName: `REVIEW_${String(index + 1).padStart(3, '0')}.jpg`,
          availability: 'available',
          contentRevision: 1,
          acceptedTagCount: 0,
          rejectedTagCount: 0,
          suggestionOrigin: index % 2 ? 'standardModel' : 'featurePrint',
          score: 0.91 - index * 0.02,
          width: 1600,
          height: 1200,
          favorite: null,
        })),
        nextCursor: null,
      },
    });
  });
  await page.route('**/v1/review/decisions/batch', (route) => {
    const body = route.request().postDataJSON() as { assetIDs: string[] };
    for (const id of body.assetIDs) reviewedAssets.add(id);
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
        appliedAssetCount: body.assetIDs.length,
        replayed: false,
        undoID: '9de47499-1ca0-4cc2-84bc-a881018e8b0c',
      },
    });
  });
  await page.route('**/v1/review/decisions/undo', (route) => {
    const restoredAssetCount = reviewedAssets.size;
    reviewedAssets.clear();
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
        restoredAssetCount,
        replayed: false,
      },
    });
  });
  await page.route(/\/v1\/assets\?.*/, (route) => {
    const cursor = new URL(route.request().url()).searchParams.get('cursor');
    const start = cursor === 'page-2' ? 72 : 0;
    const end = cursor === 'page-2' ? 120 : 72;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        items: Array.from({ length: end - start }, (_, offset) => {
          const index = start + offset;
          const item = asset(index);
          return index === 0
            ? { ...item, favorite: { ...item.favorite, isFavorite: firstAssetFavorite } }
            : item;
        }),
        nextCursor: end < 120 ? 'page-2' : null,
      },
    });
  });
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/thumbnail\?.*/i, (route) =>
    route.fulfill({ status: 200, contentType: 'image/svg+xml', body: previewSVG }),
  );
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/preview\?.*/i, (route) =>
    route.fulfill({ status: 200, contentType: 'image/svg+xml', body: previewSVG }),
  );
  await page.route(/\/v1\/assets\/([0-9a-f-]+)$/i, (route) => {
    const id = new URL(route.request().url()).pathname.split('/').at(-1) ?? assetIDs[0] ?? '';
    const item = detail(id);
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json:
        id === assetIDs[0]
          ? { ...item, favorite: { ...item.favorite, isFavorite: firstAssetFavorite } }
          : item,
    });
  });
  await page.route('**/v1/favorites', (route) => {
    firstAssetFavorite = route.request().postData()?.includes('"isFavorite":true') === true;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
        changedCount: 1,
        localOnlyCount: 0,
        syncedCount: 1,
        pendingCount: 0,
        failedCount: 0,
        states: [
          {
            assetID: assetIDs[0],
            isFavorite: firstAssetFavorite,
            photosObservedValue: firstAssetFavorite,
            syncStatus: 'synced',
            lastErrorCode: null,
          },
        ],
        replayed: false,
      },
    });
  });
  await page.route('**/v1/tags/selection', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: [
        { tagID: tagIDs[0], acceptedCount: 1, rejectedCount: 0, unknownCount: 1 },
        { tagID: tagIDs[1], acceptedCount: 0, rejectedCount: 0, unknownCount: 2 },
      ],
    }),
  );
  await page.route('**/v1/tag-decisions/batch', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
        appliedAssetCount: 2,
        replayed: false,
        undoID: '9de47499-1ca0-4cc2-84bc-a881018e8b0c',
      },
    }),
  );
  await page.route('**/v1/tag-decisions/undo', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
        restoredAssetCount: 2,
        replayed: false,
      },
    }),
  );
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/open-original$/i, (route) =>
    route.fulfill({ status: 204 }),
  );
}
