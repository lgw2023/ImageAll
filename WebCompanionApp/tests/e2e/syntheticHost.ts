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
    'trainingActivities',
    'librarySuggestions',
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

const syntheticWorldMapHTML = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; font-family: system-ui, sans-serif; }
    body { position: relative; background: #dfe8e5; }
    svg { position: absolute; inset: 0; width: 100%; height: 100%; }
    .ocean { fill: #dfe8e5; }
    .land { fill: #f5f3eb; stroke: #aeb8b2; stroke-width: 1.2; }
    #clusters { position: absolute; inset: 0; }
    button { position: absolute; display: grid; width: 44px; height: 44px; place-items: center; border: 2px solid white; border-radius: 50%; color: white; background: #156aa3; box-shadow: 0 2px 8px rgb(20 40 50 / 28%); font: 700 12px system-ui; transform: translate(-50%, -50%); }
    button[aria-pressed="true"] { outline: 3px solid #101820; outline-offset: 2px; background: #101820; }
    button span { position: absolute; top: 48px; width: max-content; max-width: 120px; padding: 3px 6px; border-radius: 4px; color: #101820; background: rgb(255 255 255 / 92%); font-size: 11px; }
  </style>
</head>
<body>
  <svg viewBox="0 0 900 440" aria-hidden="true">
    <rect class="ocean" width="900" height="440"/>
    <path class="land" d="M72 112l64-58 115 12 60 55-13 57-48 30-55-8-33 39-64-26-31-55z"/>
    <path class="land" d="M240 234l50 21 24 54-29 98-35-53-20-78z"/>
    <path class="land" d="M405 96l95-49 190 22 138 71-39 56-98-7-72 49-49-18-62 30-71-36-49-69z"/>
    <path class="land" d="M493 245l76 5 48 65-37 98-61-31-29-76z"/>
    <path class="land" d="M731 311l76-20 50 42-40 54-78-11z"/>
  </svg>
  <div id="clusters"></div>
  <script>
    const root = document.getElementById('clusters');
    let selected = null;
    let data = [];
    function render() {
      root.replaceChildren(...data.map((cluster) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.style.left = ((cluster.longitude + 180) / 360 * 100) + '%';
        button.style.top = ((90 - cluster.latitude) / 180 * 100) + '%';
        button.setAttribute('aria-label', cluster.displayName + '，' + cluster.photoCount + ' 张照片');
        button.setAttribute('aria-pressed', String(cluster.id === selected));
        button.textContent = String(cluster.photoCount);
        const label = document.createElement('span');
        label.textContent = cluster.displayName;
        button.append(label);
        button.addEventListener('click', () => parent.postMessage({ type: 'imageall-world-map-event', payload: { type: 'clusterClicked', clusterID: cluster.id } }, location.origin));
        return button;
      }));
    }
    window.ImageAllWorldMap = {
      updateClusters(payload) { data = payload.clusters || []; render(); },
      restoreSelection(clusterID) { selected = clusterID; render(); },
      restoreViewport() {}
    };
    parent.postMessage({ type: 'imageall-world-map-event', payload: { type: 'ready' } }, location.origin);
    parent.postMessage({ type: 'imageall-world-map-event', payload: { type: 'cameraChanged', viewport: { west: 70, south: 10, east: 140, north: 55, centerLongitude: 105, centerLatitude: 32, zoom: 2.2, bearing: 0, pitch: 20 } } }, location.origin);
  </script>
</body>
</html>`;

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
  const trainingRunID = '41ba0aa1-e0c3-4421-bb0f-4f7edab5c341';
  const trainingJobID = '42ba0aa1-e0c3-4421-bb0f-4f7edab5c342';
  const standardSuggestionJobID = '43ba0aa1-e0c3-4421-bb0f-4f7edab5c343';
  const personalSuggestionJobID = '44ba0aa1-e0c3-4421-bb0f-4f7edab5c344';
  let trainingActivities: Record<string, unknown>[] = [];
  let embeddingActivities: Record<string, unknown>[] = [];
  let sampleSuggestionActivities: Record<string, unknown>[] = [];
  let tagSuggestionActivities: Record<string, unknown>[] = [];
  let standardSuggestionJob: Record<string, unknown> | null = null;
  let personalSuggestionJob: Record<string, unknown> | null = null;
  const mapClusters = [
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
        bounds: { west: 121.25, south: 31, east: 121.75, north: 31.5 },
        maximumAssets: 36,
      },
    },
    {
      id: 'taiyuan',
      longitude: 112.55,
      latitude: 37.87,
      photoCount: 12,
      gpsCount: 9,
      tagCount: 3,
      displayName: '太原',
      selectionQuery: {
        cellDegrees: 0.25,
        longitudeBucket: 450,
        latitudeBucket: 151,
        bounds: null,
        maximumAssets: 36,
      },
    },
    {
      id: 'shenzhen',
      longitude: 114.06,
      latitude: 22.54,
      photoCount: 9,
      gpsCount: 7,
      tagCount: 2,
      displayName: '深圳',
      selectionQuery: {
        cellDegrees: 0.25,
        longitudeBucket: 456,
        latitudeBucket: 90,
        bounds: null,
        maximumAssets: 36,
      },
    },
  ];
  let backfills: {
    sourceID: string;
    sourceKind: 'folder' | 'photos';
    sourceDisplayName: string;
    sourceState: 'active' | 'disabled' | 'unavailable' | 'authorizationRequired';
    phase: string;
    totalPhotoCount: number;
    inspectedPhotoCount: number;
    locatedPhotoCount: number;
    activeJobID: string | null;
    scanProgress: { completedUnitCount: number; totalUnitCount: number | null } | null;
    canStart: boolean;
    canCancel: boolean;
  }[] = [
    {
      sourceID,
      sourceKind: 'folder',
      sourceDisplayName: 'Synthetic Library',
      sourceState: 'active',
      phase: 'ready',
      totalPhotoCount: 120,
      inspectedPhotoCount: 42,
      locatedPhotoCount: 30,
      activeJobID: null,
      scanProgress: null,
      canStart: true,
      canCancel: false,
    },
  ];
  const placeCandidate = {
    placeID: 'shanghai-cn',
    displayName: '上海市',
    subtitle: '中国上海市',
    latitude: 31.23,
    longitude: 121.47,
    kind: 'city',
  };
  let placeResolution = {
    tagID: tagIDs[0],
    tagName: '上海',
    groupName: '地点与场景',
    acceptedPhotoCount: 8,
    status: 'unresolved',
    confirmedPlaceID: null as string | null,
    candidates: [] as (typeof placeCandidate)[],
  };
  await page.route('**/world-map/index.html', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'text/html; charset=utf-8',
      body: syntheticWorldMapHTML,
    }),
  );
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
    const updateSuggestionJob = (job: Record<string, unknown> | null) =>
      job?.jobID === jobID
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
        : job;
    standardSuggestionJob = updateSuggestionJob(standardSuggestionJob);
    personalSuggestionJob = updateSuggestionJob(personalSuggestionJob);
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
  await page.route('**/v1/world-map/snapshot?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        clusters: mapClusters,
        eligiblePhotoCount: 80,
        locatedPhotoCount: 62,
        unlocatedPhotoCount: 18,
      },
    }),
  );
  await page.route('**/v1/world-map/selection', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        assets: assetIDs.slice(0, 6).map((id, index) => {
          const item = asset(index);
          return {
            id,
            fileName: item.fileName,
            availability: item.availability,
            contentRevision: item.contentRevision,
            favorite: item.favorite,
          };
        }),
        totalPhotoCount: 18,
      },
    }),
  );
  await page.route('**/v1/world-map/location-backfill', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: backfills }),
  );
  await page.route('**/v1/world-map/location-backfill/requests', (route) => {
    const body = route.request().postDataJSON() as {
      operationID: string;
      sourceID: string;
      action: 'start' | 'cancel';
    };
    backfills = backfills.map((row) =>
      row.sourceID === body.sourceID
        ? {
            ...row,
            phase: body.action === 'start' ? 'running' : 'cancelled',
            activeJobID: body.action === 'start' ? '6cba0aa1-e0c3-4421-bb0f-4f7edab5c3b6' : null,
            scanProgress:
              body.action === 'start' ? { completedUnitCount: 42, totalUnitCount: 120 } : null,
            canStart: body.action !== 'start',
            canCancel: body.action === 'start',
          }
        : row,
    );
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        snapshot: backfills[0],
        replayed: false,
      },
    });
  });
  await page.route('**/v1/world-map/place-tags', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { items: [placeResolution], maximumQueryLength: 160 },
    }),
  );
  await page.route('**/v1/world-map/place-tags/requests', (route) => {
    const body = route.request().postDataJSON() as {
      operationID: string;
      action: 'search' | 'confirm';
      placeID?: string;
    };
    placeResolution = {
      ...placeResolution,
      status: body.action === 'confirm' ? 'resolved' : 'ambiguous',
      confirmedPlaceID: body.action === 'confirm' ? (body.placeID ?? null) : null,
      candidates: [placeCandidate],
    };
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { operationID: body.operationID, resolution: placeResolution, replayed: false },
    });
  });
  await page.route('**/v1/training/setup?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        mediaKind: new URL(route.request().url()).searchParams.get('mediaKind') ?? 'image',
        tags: [
          {
            id: tagIDs[0],
            displayName: '风景',
            acceptedSampleCount: 18,
            rejectedSampleCount: 6,
            featureMode: 'update',
            personalEligible: true,
          },
          {
            id: tagIDs[1],
            displayName: '家人',
            acceptedSampleCount: 12,
            rejectedSampleCount: 5,
            featureMode: 'generate',
            personalEligible: true,
          },
        ],
        sources: [{ id: sourceID, displayName: 'Synthetic Library' }],
        methods: [
          { method: 'featureKnn', isAvailable: true },
          { method: 'personalCentroid', isAvailable: true },
          { method: 'personalAdamW', isAvailable: true },
        ],
      },
    }),
  );
  await page.route('**/v1/training/workspace?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        mediaKind: new URL(route.request().url()).searchParams.get('mediaKind') ?? 'image',
        methodFilter: null,
        runs: [
          {
            id: trainingRunID,
            mediaKind: 'image',
            method: 'personalCentroid',
            state: 'succeeded',
            createdAtMs: 1_787_800_000_000,
            catalogScopeID: 'synthetic-catalog',
            tagID: tagIDs[0],
            tagDisplayName: '风景',
            sampleCount: 24,
          },
        ],
        slots: [
          {
            method: 'personalCentroid',
            isPublished: true,
            publishedRunID: trainingRunID,
            artifactRef: 'synthetic://personal-centroid',
          },
          { method: 'personalAdamW', isPublished: false },
        ],
        activities: trainingActivities,
      },
    }),
  );
  await page.route('**/v1/training/activities?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: trainingActivities,
    }),
  );
  await page.route('**/v1/training/launch', (route) => {
    const body = route.request().postDataJSON() as {
      operationID: string;
      mediaKind: 'image' | 'video';
      method: 'featureKnn' | 'personalCentroid' | 'personalAdamW';
      tagIDs: string[];
    };
    const activity = {
      operationID: body.operationID,
      mediaKind: body.mediaKind,
      method: body.method,
      phase: 'preparingEmbeddings',
      completedUnitCount: 1,
      totalUnitCount: body.tagIDs.length,
      sampleCount: 24,
      errorCode: null,
      availableActions: ['cancel'],
      tagActivities: body.tagIDs.map((tagID) => ({
        tagID,
        displayName: tagID === tagIDs[0] ? '风景' : '家人',
        phase: 'preparingEmbeddings',
        sampleCount: 24,
        errorCode: null,
      })),
      acceptedAtMs: 1_787_820_000_000,
      updatedAtMs: 1_787_820_001_000,
    };
    trainingActivities = [activity];
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        method: body.method,
        acceptedAtMs: 1_787_820_000_000,
        scheduledTagCount: body.tagIDs.length,
        jobID: trainingJobID,
        replayed: false,
      },
    });
  });
  await page.route(/\/v1\/training\/activities\/[0-9a-f-]+\/actions$/i, (route) => {
    const operationID = new URL(route.request().url()).pathname.split('/').at(-2) ?? '';
    trainingActivities = trainingActivities.map((activity) =>
      activity.operationID === operationID
        ? { ...activity, phase: 'cancelled', availableActions: [] }
        : activity,
    );
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { activity: trainingActivities.find((item) => item.operationID === operationID) },
    });
  });
  await page.route('**/v1/embedding-preparation?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        mediaKind: new URL(route.request().url()).searchParams.get('mediaKind') ?? 'image',
        isAvailable: true,
        activities: embeddingActivities,
      },
    }),
  );
  await page.route('**/v1/embedding-preparation/requests', (route) => {
    const body = route.request().postDataJSON() as {
      operationID: string;
      mediaKind: 'image' | 'video';
      assetIDs: string[];
    };
    const activity = {
      operationID: body.operationID,
      mediaKind: body.mediaKind,
      phase: 'running',
      completedUnitCount: 0,
      totalUnitCount: body.assetIDs.length,
      preparedCount: 0,
      cachedCount: 0,
      cloudOnlyCount: 0,
      failedCount: 0,
      errorCode: null,
      availableActions: ['cancel'],
    };
    embeddingActivities = [activity];
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: { activity, replayed: false },
    });
  });
  await page.route(/\/v1\/embedding-preparation\/requests\/[0-9a-f-]+\/actions$/i, (route) => {
    const operationID = new URL(route.request().url()).pathname.split('/').at(-2) ?? '';
    embeddingActivities = embeddingActivities.map((activity) =>
      activity.operationID === operationID
        ? { ...activity, phase: 'cancelled', availableActions: [] }
        : activity,
    );
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { activity: embeddingActivities.find((item) => item.operationID === operationID) },
    });
  });
  await page.route('**/v1/sample-suggestions?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        mediaKind: new URL(route.request().url()).searchParams.get('mediaKind') ?? 'image',
        isAvailable: true,
        maximumSampleCount: 500,
        activities: sampleSuggestionActivities,
      },
    }),
  );
  await page.route('**/v1/sample-suggestions/requests', (route) => {
    const body = route.request().postDataJSON() as {
      operationID: string;
      mediaKind: 'image' | 'video';
    };
    const activity = {
      operationID: body.operationID,
      mediaKind: body.mediaKind,
      phase: 'running',
      completedUnitCount: 18,
      totalUnitCount: 120,
      suggestedCount: 7,
      skippedCount: 3,
      errorCode: null,
      availableActions: ['cancel'],
    };
    sampleSuggestionActivities = [activity];
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: { activity, replayed: false },
    });
  });
  await page.route(/\/v1\/sample-suggestions\/requests\/[0-9a-f-]+\/actions$/i, (route) => {
    const operationID = new URL(route.request().url()).pathname.split('/').at(-2) ?? '';
    sampleSuggestionActivities = sampleSuggestionActivities.map((activity) =>
      activity.operationID === operationID
        ? { ...activity, phase: 'cancelled', availableActions: [] }
        : activity,
    );
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        activity: sampleSuggestionActivities.find((item) => item.operationID === operationID),
      },
    });
  });
  await page.route('**/v1/library-suggestions?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        mediaKind: new URL(route.request().url()).searchParams.get('mediaKind') ?? 'image',
        service: {
          state: 'ready',
          serviceVersion: '1.0.0',
          provider: 'Synthetic Core ML',
          modelID: 'synthetic-vision-v1',
        },
        standardAvailable: true,
        personalMode: 'fullLibrary',
        standardJob: standardSuggestionJob,
        personalJob: personalSuggestionJob,
      },
    }),
  );
  await page.route('**/v1/library-suggestions/requests', (route) => {
    const body = route.request().postDataJSON() as {
      operationID: string;
      track: 'standard' | 'personal';
    };
    const jobID = body.track === 'standard' ? standardSuggestionJobID : personalSuggestionJobID;
    const job = {
      jobID,
      state: 'running',
      checkedCount: 24,
      totalCount: 120,
      suggestedCount: 9,
      skippedCount: 2,
      lastErrorCode: null,
      availableActions: ['pause', 'cancel'],
    };
    if (body.track === 'standard') standardSuggestionJob = job;
    else personalSuggestionJob = job;
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: { operationID: body.operationID, track: body.track, jobID, replayed: false },
    });
  });
  await page.route('**/v1/tag-library-suggestions?*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        mediaKind: new URL(route.request().url()).searchParams.get('mediaKind') ?? 'image',
        maximumPendingCount: 200,
        personalCentroidAvailable: true,
        personalAdamWAvailable: true,
        tags: [
          {
            tagID: tagIDs[0],
            personalEligible: true,
            personalCentroidMinScore: 0.82,
            personalAdamWMinScore: 0.86,
          },
          {
            tagID: tagIDs[1],
            personalEligible: true,
            personalCentroidMinScore: 0.8,
            personalAdamWMinScore: 0.85,
          },
        ],
        activities: tagSuggestionActivities,
      },
    }),
  );
  await page.route('**/v1/tag-library-suggestions/requests', (route) => {
    const body = route.request().postDataJSON() as {
      operationID: string;
      mediaKind: 'image' | 'video';
      method: 'personalCentroid' | 'personalAdamW';
      tagID: string;
    };
    const activity = {
      operationID: body.operationID,
      mediaKind: body.mediaKind,
      method: body.method,
      tagID: body.tagID,
      phase: 'scoring',
      completedUnitCount: 42,
      totalUnitCount: 120,
      aboveThresholdCount: 11,
      insertedCount: 4,
      skippedCount: 2,
      errorCode: null,
      availableActions: ['cancel'],
    };
    tagSuggestionActivities = [activity];
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: { activity, replayed: false },
    });
  });
  await page.route(/\/v1\/tag-library-suggestions\/requests\/[0-9a-f-]+\/actions$/i, (route) => {
    const operationID = new URL(route.request().url()).pathname.split('/').at(-2) ?? '';
    tagSuggestionActivities = tagSuggestionActivities.map((activity) =>
      activity.operationID === operationID
        ? { ...activity, phase: 'cancelled', availableActions: [] }
        : activity,
    );
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { activity: tagSuggestionActivities.find((item) => item.operationID === operationID) },
    });
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
    const parameters = new URL(route.request().url()).searchParams;
    const cursor = parameters.get('cursor');
    const mapSelection = parameters.has('worldMapCellDegrees');
    const start = cursor === 'page-2' ? 72 : 0;
    const end = mapSelection ? 18 : cursor === 'page-2' ? 120 : 72;
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
        nextCursor: !mapSelection && end < 120 ? 'page-2' : null,
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
