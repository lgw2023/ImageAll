import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { assetIDs, installSyntheticAuthenticatedHost, sourceID, tagIDs } from './syntheticHost';

async function expectAccessible(page: import('@playwright/test').Page) {
  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
}

async function expectNoHorizontalOverflow(page: import('@playwright/test').Page) {
  const widths = await page.locator('#main-content').evaluate((element) => ({
    client: element.clientWidth,
    scroll: element.scrollWidth,
  }));
  expect(widths.scroll).toBeLessThanOrEqual(widths.client);
}

test('slimming saves Host thresholds, maintains selected sources, and launches a catalog job', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('slimming');
  await expect(page.getByRole('heading', { name: '图库精简', level: 2 })).toBeVisible();
  await expect(page.getByText('Synthetic Library', { exact: true }).first()).toBeVisible();

  const maintenanceRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/source-maintenance' &&
      request.method() === 'POST',
  );
  await page.getByRole('button', { name: '准备相似度索引' }).click();
  expect((await maintenanceRequest).postDataJSON()).toMatchObject({
    action: 'initializeSimilarityIndex',
    mediaKind: 'image',
    sourceIDs: [sourceID],
  });
  await expect(page.getByText('Mac 已开始准备所选来源的相似度索引。')).toBeVisible();

  await page.getByLabel('候选 Top K').fill('32');
  const thresholdRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/thresholds' &&
      request.method() === 'PUT',
  );
  await page.getByRole('button', { name: '保存阈值' }).click();
  expect((await thresholdRequest).postDataJSON()).toMatchObject({
    thresholds: { featurePrintRecallTopK: 32 },
  });
  await expect(page.getByText('Mac 已保存新的分析阈值。')).toBeVisible();

  const launchRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/launch' &&
      request.method() === 'POST',
  );
  await page.getByRole('button', { name: '开始分析' }).click();
  expect((await launchRequest).postDataJSON()).toMatchObject({
    mediaKind: 'image',
    mode: 'catalog',
    sourceIDs: null,
    seedAssetIDs: [],
    filter: null,
  });
  await expect(page.getByText('Mac 已接受 120 项分析范围。')).toBeVisible();
  await expect(page.locator('.slimming-job-card').first()).toContainText('进行中');
});

test('cluster review protects representative and favorite members before Host removal', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('slimming?section=review&media=image');
  await expect(page.getByRole('heading', { name: '组内审查' })).toBeVisible();
  await expect(page.getByText('保留代表项')).toBeVisible();
  await expect(page.getByRole('checkbox', { name: '收藏项受保护' })).toBeDisabled();

  await page.getByRole('checkbox', { name: '加入清理选择' }).check();
  await expectNoHorizontalOverflow(page);
  await expectAccessible(page);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/slimming/imageall-react-slimming-review-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  const removalRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/removals' &&
      request.method() === 'POST',
  );
  page.once('dialog', (dialog) => void dialog.accept());
  await page.getByRole('button', { name: '提交 1 项' }).click();
  expect((await removalRequest).postDataJSON()).toMatchObject({
    scope: 'analysisCluster',
    mediaKind: 'image',
    assetIDs: [assetIDs[1]],
    mode: 'recoverableRecycle',
  });
  await expect(
    page.getByText('Mac 已冻结 1 项选择并进入确认队列；这不代表清理已经完成。'),
  ).toBeVisible();
  await expect(page.getByText('等待 Mac', { exact: true })).toBeVisible();

  const reviewRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/cluster-review' &&
      request.method() === 'POST',
  );
  await page.getByRole('button', { name: '确认相似' }).click();
  expect((await reviewRequest).postDataJSON()).toMatchObject({ disposition: 'confirmed' });
  await expect(page.getByText('已确认此相似组。')).toBeVisible();
});

test('gallery selection drafts seed analysis and submits Host-authoritative deletion only after confirmation', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery?media=image');
  await page.getByRole('button', { name: '选择 IMG_0001.jpg' }).click();
  await page.getByRole('button', { name: '查找相似项' }).click();
  await expect(page).toHaveURL(/slimming.*mode=seeds/);
  await expect(page.getByText('1 个种子，仅在确认后启动')).toBeVisible();

  const seedRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/launch' &&
      request.method() === 'POST',
  );
  await page.getByRole('button', { name: '开始分析' }).click();
  expect((await seedRequest).postDataJSON()).toMatchObject({
    mode: 'seeds',
    sourceIDs: null,
    seedAssetIDs: [assetIDs[0]],
    filter: { mediaKinds: ['image'] },
  });

  await page.goto('gallery?media=image');
  await page.getByRole('button', { name: '选择 IMG_0001.jpg' }).click();
  const recycleRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/removals' &&
      request.method() === 'POST',
  );
  const deleteSelection = page.getByRole('button', { name: '删除所选项目' });
  await deleteSelection.click();
  let deletion = page.getByRole('alertdialog', { name: '删除 1 个所选项目？' });
  await expect(deletion).toBeVisible();
  await deletion.getByRole('button', { name: '取消' }).click();
  await expect(deletion).toBeHidden();
  await expect(deleteSelection).toBeFocused();
  await expect(page.getByText('已选择 1 项')).toBeVisible();

  await deleteSelection.click();
  deletion = page.getByRole('alertdialog', { name: '删除 1 个所选项目？' });
  await expect(deletion).toBeVisible();
  await deletion.getByRole('button', { name: '提交给 Mac 确认删除' }).click();
  expect((await recycleRequest).postDataJSON()).toMatchObject({
    scope: 'gallerySelection',
    jobID: null,
    clusterID: null,
    mediaKind: 'image',
    assetIDs: [assetIDs[0]],
    mode: 'releaseSourceSpace',
  });
  await expect(page.getByText(/已冻结 1 项选择.*不代表删除已完成/)).toBeVisible();
});

test('gallery current filter becomes an exact analysis request', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto(`gallery?media=image&q=IMG_00&tag=${tagIDs[0]}&sort=oldest`);
  await page.getByRole('button', { name: '分析当前筛选' }).click();
  await expect(page).toHaveURL(/mode=currentFilter/);
  const request = page.waitForRequest(
    (candidate) =>
      new URL(candidate.url()).pathname === '/v1/library-slimming/launch' &&
      candidate.method() === 'POST',
  );
  await page.getByRole('button', { name: '开始分析' }).click();
  expect((await request).postDataJSON()).toMatchObject({
    mode: 'currentFilter',
    sourceIDs: null,
    seedAssetIDs: [],
    filter: {
      searchText: 'IMG_00',
      sort: 'oldest',
      tagDecisionFilters: [{ tagID: tagIDs[0], decision: 'accepted' }],
      mediaKinds: ['image'],
    },
  });
});

test('identical cleanup separates read-only planning from confirmed execution and verification', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('slimming?section=cleanup&media=image');
  await page.getByRole('button', { name: '准备只读计划' }).click();
  await expect(page.getByText('Mac 已生成只读清理计划；尚未移动或删除任何项目。')).toBeVisible();
  await expect(page.getByText('计划已准备')).toBeVisible();
  await expect(page.getByText('2', { exact: true }).first()).toBeVisible();

  const cleanupRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/identical-cleanup/requests' &&
      request.method() === 'POST',
  );
  page.once('dialog', (dialog) => void dialog.accept());
  await page.getByRole('button', { name: '确认执行计划' }).click();
  expect((await cleanupRequest).postDataJSON()).toMatchObject({
    planID: '54ba0aa1-e0c3-4421-bb0f-4f7edab5c354',
    mode: 'recoverableRecycle',
  });
  await expect(page.getByText('Host 已完成结果验证')).toBeVisible();
  await expect(page.getByText(/剩余冗余 0/)).toBeVisible();
  await expectAccessible(page);
});

test('recycle restores Photos items and requires a second confirmation before purge', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('slimming?section=recycle&media=image');
  const photosCard = page.locator('.slimming-recycle-card').filter({ hasText: 'IMG_0005.jpg' });
  const restoreRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/recycle/requests' &&
      request.method() === 'POST',
  );
  await photosCard.getByRole('button', { name: '恢复' }).click();
  expect((await restoreRequest).postDataJSON()).toMatchObject({ action: 'restore' });
  await expect(page.getByText('Mac 已恢复合成项目。', { exact: true }).first()).toBeVisible();

  const fileCard = page.locator('.slimming-recycle-card').filter({ hasText: 'IMG_0004.jpg' });
  const purgeRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-slimming/recycle/requests' &&
      request.method() === 'POST' &&
      (request.postDataJSON() as { action?: string }).action === 'purge',
  );
  page.once('dialog', (dialog) => void dialog.accept());
  await fileCard.getByRole('button', { name: '永久清理' }).click();
  expect((await purgeRequest).postDataJSON()).toMatchObject({ action: 'purge' });
  await expect(fileCard.getByText('已永久清理')).toBeVisible();
});

test('slimming explains a setup failure and recovers on explicit retry', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  let attempts = 0;
  await page.route('**/v1/library-slimming/setup?*', (route) => {
    attempts += 1;
    if (attempts <= 2) {
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        json: { message: '合成图库精简配置暂时不可用', retryable: true },
      });
    }
    return route.fallback();
  });
  await page.goto('slimming');
  const failure = page.getByText('合成图库精简配置暂时不可用').locator('..');
  await expect(failure).toBeVisible();
  await failure.getByRole('button', { name: '重试' }).click();
  await expect(page.getByRole('heading', { name: '分析范围' })).toBeVisible();
});
