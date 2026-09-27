import { expect, test } from '@playwright/test';
import { installSyntheticAuthenticatedHost } from './syntheticHost';

test('video filters reach Host, survive reload and clear when switching to photos', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route('**/v1/capabilities', (route) =>
    route.fulfill({
      json: {
        protocolVersion: 2,
        hostAppVersion: 'Synthetic video query Host',
        minimumClientProtocolVersion: 1,
        capabilities: ['assetPages', 'assetDetail', 'tags'],
        listenPort: 4173,
        usesTLS: false,
        hostID: null,
        certificateFingerprintSHA256: null,
        videoQueryVersion: 1,
      },
    }),
  );
  const queries: URLSearchParams[] = [];
  await page.route(/\/v1\/assets\?/, (route) => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: { items: [], nextCursor: null } });
  });
  await page.goto('gallery');
  await page.getByRole('button', { name: '筛选', exact: true }).click();
  await page.getByRole('combobox', { name: '视频时长', exact: true }).selectOption('oneToTenMinutes');
  await page.getByRole('combobox', { name: '视频方向', exact: true }).selectOption('portrait');
  await page.getByRole('combobox', { name: '排序', exact: true }).selectOption('durationLongest');
  await expect.poll(() => queries.at(-1)?.get('sort')).toBe('durationLongest');
  expect(queries.at(-1)?.get('mediaKinds')).toBe('video');
  expect(queries.at(-1)?.get('videoDuration')).toBe('oneToTenMinutes');
  expect(queries.at(-1)?.get('videoOrientation')).toBe('portrait');
  await page.reload();
  await expect.poll(() => queries.at(-1)?.get('videoOrientation')).toBe('portrait');
  await page.getByRole('button', { name: '筛选', exact: true }).click();
  await expect(page.getByRole('combobox', { name: '视频时长', exact: true })).toHaveValue('oneToTenMinutes');
  await page.getByRole('combobox', { name: '媒体', exact: true }).selectOption('image');
  await expect.poll(() => queries.at(-1)?.get('mediaKinds')).toBe('image');
  expect(queries.at(-1)?.has('videoDuration')).toBe(false);
  expect(queries.at(-1)?.has('videoOrientation')).toBe(false);
  expect(queries.at(-1)?.get('sort')).toBe('newest');
});

test('legacy Host rejects saved video conditions without sending an unfiltered query', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  let requests = 0;
  await page.route(/\/v1\/assets\?/, (route) => {
    requests += 1;
    return route.fulfill({ json: { items: [], nextCursor: null } });
  });
  await page.goto('gallery?media=video&videoDuration=underMinute&sort=durationShortest');
  await expect(page.getByRole('alert')).toContainText('此 Mac 尚不支持视频条件');
  expect(requests).toBe(0);
  await page.getByRole('button', { name: '筛选', exact: true }).click();
  await expect(page.getByRole('combobox', { name: '视频时长', exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: '重置视频条件与排序' }).click();
  await expect.poll(() => requests).toBe(1);
  await expect(page.getByRole('alert')).toHaveCount(0);
});
