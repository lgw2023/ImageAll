import { expect, test } from '@playwright/test';
import { installSyntheticAuthenticatedHost } from './syntheticHost';

test('video map preserves scope through selection and gallery navigation', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route('**/v1/capabilities', (route) =>
    route.fulfill({
      json: {
        protocolVersion: 2,
        hostAppVersion: 'Synthetic map Host',
        minimumClientProtocolVersion: 1,
        capabilities: ['assetPages', 'assetDetail', 'tags'],
        listenPort: 4173,
        usesTLS: false,
        hostID: null,
        certificateFingerprintSHA256: null,
        worldMapMediaScopeVersion: 1,
      },
    }),
  );
  const snapshots: string[] = [];
  const selections: unknown[] = [];
  await page.route('**/v1/world-map/snapshot?*', (route) => {
    const mediaScope = new URL(route.request().url()).searchParams.get('mediaScope') ?? 'photos';
    snapshots.push(mediaScope);
    return route.fulfill({
      json: {
        eligiblePhotoCount: 2,
        locatedPhotoCount: 2,
        unlocatedPhotoCount: 0,
        clusters: [
          {
            id: 'fixture',
            displayName: '合成地点',
            longitude: 120,
            latitude: 30,
            photoCount: 2,
            gpsCount: 2,
            tagCount: 0,
            selectionQuery: {
              cellDegrees: 7.5,
              longitudeBucket: 40,
              latitudeBucket: 16,
              bounds: null,
              maximumAssets: 36,
              mediaScope,
            },
          },
        ],
      },
    });
  });
  await page.route('**/v1/world-map/selection', (route) => {
    selections.push(route.request().postDataJSON());
    return route.fulfill({ json: { assets: [], totalPhotoCount: 2 } });
  });
  await page.goto('map');
  await page.getByRole('combobox', { name: '地图媒体' }).selectOption('videos');
  await expect.poll(() => snapshots.at(-1)).toBe('videos');
  await expect.poll(() => selections.at(-1)).toMatchObject({ query: { mediaScope: 'videos' } });
  const request = page.waitForRequest(
    (r) =>
      new URL(r.url()).pathname === '/v1/assets' &&
      new URL(r.url()).searchParams.get('worldMapMediaScope') === 'videos',
  );
  await page.getByRole('button', { name: '在图库查看全部 2 项' }).click();
  const query = new URL((await request).url()).searchParams;
  expect(query.get('worldMapLongitudeBucket')).toBe('40');
  expect(query.get('worldMapLatitudeBucket')).toBe('16');
  await page.getByRole('button', { name: '返回世界地图' }).click();
  await expect(page.getByRole('combobox', { name: '地图媒体' })).toHaveValue('videos');
});

test('legacy Host refuses saved video map and recovers to photos', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  let mapRequests = 0;
  page.on('request', (request) => {
    if (new URL(request.url()).pathname === '/v1/world-map/snapshot') mapRequests += 1;
  });
  await page.goto('map?mediaScope=videos');
  await expect(page.getByRole('alert')).toContainText('此 Mac 尚不支持视频地图');
  expect(mapRequests).toBe(0);
  await expect(page.getByRole('combobox', { name: '地图媒体' })).toHaveCount(0);
  await page.getByRole('button', { name: '切回照片地图' }).click();
  await expect.poll(() => mapRequests).toBe(1);
});
