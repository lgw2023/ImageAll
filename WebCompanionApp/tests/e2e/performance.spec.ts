import { createHash } from 'node:crypto';

import { expect, test, type Page } from '@playwright/test';

import { installSyntheticAuthenticatedHost, sourceID } from './syntheticHost';

const fixtureContract = {
  version: 1,
  count: 10_000,
  sourceID,
  idPrefix: '20000000-0000-4000-8000-',
  mediaType: 'image/jpeg',
};
const fixtureHash = createHash('sha256').update(JSON.stringify(fixtureContract)).digest('hex');

function performanceAsset(index: number) {
  const id = `20000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`;
  return {
    id,
    sourceID,
    sourceName: '10k Synthetic Library',
    fileName: `PERF_${String(index + 1).padStart(5, '0')}.jpg`,
    mediaType: 'image/jpeg',
    availability: 'available',
    contentRevision: 1,
    acceptedTagCount: 0,
    rejectedTagCount: 0,
    mediaCreatedAtMs: 1_787_820_000_000 - index * 1_000,
    width: 1600,
    height: 1200,
    favorite: null,
    relativePath: `perf/PERF_${String(index + 1).padStart(5, '0')}.jpg`,
    mediaModifiedAtMs: 1_787_820_000_000 - index * 1_000,
    durationMs: null,
  };
}

async function install10kFixture(page: Page) {
  const assets = Array.from({ length: fixtureContract.count }, (_, index) =>
    performanceAsset(index),
  );
  await page.route(/\/v1\/assets\?.*/, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: { items: assets, nextCursor: null },
    }),
  );
  await page.route(/\/v1\/assets\/20000000-[0-9a-f-]+$/i, (route) => {
    const firstAsset = assets[0];
    if (!firstAsset) throw new Error('10k fixture unexpectedly empty');
    const id = new URL(route.request().url()).pathname.split('/').at(-1) ?? firstAsset.id;
    const summary = assets.find((asset) => asset.id === id) ?? firstAsset;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        assetID: summary.id,
        sourceID: summary.sourceID,
        sourceName: summary.sourceName,
        fileName: summary.fileName,
        relativePath: summary.relativePath,
        mediaType: summary.mediaType,
        availability: summary.availability,
        contentRevision: summary.contentRevision,
        acceptedTagCount: 0,
        rejectedTagCount: 0,
        mediaCreatedAtMs: summary.mediaCreatedAtMs,
        mediaModifiedAtMs: summary.mediaModifiedAtMs,
        width: summary.width,
        height: summary.height,
        durationMs: null,
        fingerprintSizeBytes: 1024,
        favorite: null,
        tags: [],
        pendingSuggestions: [],
      },
    });
  });
}

function percentile95(values: number[]): number {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * 0.95) - 1)] ?? Number.POSITIVE_INFINITY;
}

test('10k production fixture stays virtual, responsive, and anchored', async ({
  page,
}, testInfo) => {
  test.skip(testInfo.project.name !== 'chromium-desktop', 'Desktop production performance gate');
  await installSyntheticAuthenticatedHost(page);
  await install10kFixture(page);
  await page.addInitScript(() => {
    const entries: number[] = [];
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) entries.push(entry.duration);
    }).observe({ type: 'longtask', buffered: true });
    Object.assign(window, { __imageAllLongTasks: entries });
  });

  const routeStartedAt = performance.now();
  await page.goto('gallery');
  const firstAsset = page.getByRole('button', { name: '查看 PERF_00001.jpg' });
  await expect(firstAsset).toBeVisible();
  const routeInteractiveMs = performance.now() - routeStartedAt;

  const domNodes = await page.locator('*').count();
  const assetCards = await page.getByRole('gridcell').count();
  expect(domNodes).toBeLessThan(2_500);
  expect(assetCards).toBeLessThan(300);
  expect(routeInteractiveMs).toBeLessThan(1_500);

  const selectionSamples = await page.evaluate(async () => {
    const button = document.querySelector<HTMLButtonElement>('[aria-label="选择 PERF_00001.jpg"]');
    if (!button) throw new Error('selection target missing');
    const values: number[] = [];
    for (let index = 0; index < 20; index += 1) {
      const startedAt = performance.now();
      button.click();
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      values.push(performance.now() - startedAt);
    }
    return values;
  });
  const selectionP95Ms = percentile95(selectionSamples);
  expect(selectionP95Ms).toBeLessThan(100);

  const grid = page.getByRole('grid', { name: '照片网格' });
  await grid.evaluate(async (element) => {
    for (let step = 0; step <= 20; step += 1) {
      element.scrollTop = (element.scrollHeight - element.clientHeight) * (step / 20);
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    }
  });
  expect(await page.getByRole('gridcell').count()).toBeGreaterThan(0);
  const longTasks = await page.evaluate(
    () =>
      (window as typeof window & { __imageAllLongTasks?: number[] }).__imageAllLongTasks?.filter(
        (duration) => duration > 50,
      ) ?? [],
  );
  expect(longTasks.length).toBeLessThanOrEqual(3);

  await grid.evaluate((element) => {
    element.scrollTop = 1_800;
  });
  await page.waitForTimeout(50);
  const anchorBefore = await grid.evaluate((element) => element.scrollTop);
  const visibleLabel = await page.locator('[data-grid-asset-index]').evaluateAll((elements) => {
    const gridBounds = document.querySelector('[aria-label="照片网格"]')?.getBoundingClientRect();
    if (!gridBounds) return null;
    return (
      elements
        .find((element) => {
          const bounds = element.getBoundingClientRect();
          return bounds.top >= gridBounds.top && bounds.bottom <= gridBounds.bottom;
        })
        ?.getAttribute('aria-label') ?? null
    );
  });
  if (!visibleLabel) throw new Error('visible anchor missing');
  const viewerSamples: number[] = [];
  for (let index = 0; index < 8; index += 1) {
    const startedAt = performance.now();
    await page.getByRole('button', { name: visibleLabel }).click();
    await expect(page.getByRole('dialog')).toBeVisible();
    viewerSamples.push(performance.now() - startedAt);
    await page.getByRole('button', { name: '关闭照片详情' }).click();
    await expect(page.getByRole('dialog')).toBeHidden();
  }
  const viewerP95Ms = percentile95(viewerSamples);
  expect(viewerP95Ms).toBeLessThan(250);
  const anchorAfter = await grid.evaluate((element) => element.scrollTop);
  expect(Math.abs(anchorAfter - anchorBefore)).toBeLessThan(360);
  await expect(page.getByRole('button', { name: visibleLabel })).toBeFocused();

  console.log(
    `[10k-performance] ${JSON.stringify({
      fixtureHash,
      routeInteractiveMs: Math.round(routeInteractiveMs),
      domNodes,
      assetCards,
      selectionP95Ms: Math.round(selectionP95Ms * 10) / 10,
      viewerP95Ms: Math.round(viewerP95Ms * 10) / 10,
      longTaskCount: longTasks.length,
      anchorDelta: Math.round(Math.abs(anchorAfter - anchorBefore)),
    })}`,
  );
});
