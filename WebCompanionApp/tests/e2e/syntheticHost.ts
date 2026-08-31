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
  capabilities: ['assetPages', 'assetDetail', 'thumbnails', 'favorites', 'tagDecisions', 'pairing'],
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
  await page.route('**/web/session', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: session }),
  );
  await page.route('**/v1/capabilities', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: capabilities }),
  );
  await page.route('**/v1/tags', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: tags }),
  );
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
