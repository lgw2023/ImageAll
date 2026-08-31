import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { installSyntheticAuthenticatedHost, sourceID, tagIDs } from './syntheticHost';

async function expectAccessible(page: import('@playwright/test').Page) {
  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
}

test('training launches an exact Host scope and renders cancellable Host activity', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('training');
  await expect(page.getByRole('heading', { name: '训练与建议', level: 2 })).toBeVisible();
  await page.getByRole('checkbox', { name: /风景/ }).check();

  const launchRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/training/launch' && request.method() === 'POST',
  );
  await page.getByRole('button', { name: '开始训练' }).click();
  const launchBody = (await launchRequest).postDataJSON() as {
    method: string;
    tagIDs: string[];
    sourceIDs: string[];
    assetIDs: string[];
  };
  expect(launchBody).toMatchObject({
    method: 'featureKnn',
    tagIDs: [tagIDs[0]],
    sourceIDs: [sourceID],
    assetIDs: [],
  });
  await expect(page.getByText('Mac 已接受 1 个标签的相似内容模型任务。')).toBeVisible();
  await expect(page.locator('.state-pill').getByText('准备嵌入', { exact: true })).toBeVisible();

  const workspaceWidths = await page.locator('#main-content').evaluate((element) => ({
    client: element.clientWidth,
    scroll: element.scrollWidth,
  }));
  expect(workspaceWidths.scroll).toBeLessThanOrEqual(workspaceWidths.client);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/training/imageall-react-training-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await expectAccessible(page);

  await page.getByRole('button', { name: '停止训练' }).click();
  await expect(page.getByText('Mac 已确认停止训练。')).toBeVisible();
  await expect(page.getByText('已取消', { exact: true })).toBeVisible();
});

test('gallery selection starts feature preparation and training can stop it', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery?media=image');
  await page.getByRole('button', { name: '选择 IMG_0001.jpg' }).click();

  const preparationRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/embedding-preparation/requests' &&
      request.method() === 'POST',
  );
  await page.getByRole('button', { name: '准备特征' }).click();
  const preparationBody = (await preparationRequest).postDataJSON() as {
    mediaKind: string;
    assetIDs: string[];
  };
  expect(preparationBody.mediaKind).toBe('image');
  expect(preparationBody.assetIDs).toHaveLength(1);
  await expect(page.getByText('已把 1 项特征准备交给 Mac；可在“训练”中跟踪。')).toBeVisible();

  await page.goto('training');
  await page.getByRole('button', { name: '准备与抽检' }).click();
  await expect(page.getByText('所选项目特征', { exact: true }).first()).toBeVisible();
  await expect(page.getByLabel('特征准备进度')).toBeVisible();
  await page
    .locator('.training-activity-card')
    .filter({ hasText: '所选项目特征' })
    .getByRole('button', { name: '停止' })
    .click();
  await expect(page.getByText('Mac 已停止特征准备。')).toBeVisible();
});

test('personal sample generation preserves the selected Host source scope', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('training');
  await page.getByRole('button', { name: '准备与抽检' }).click();
  const sampleRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/sample-suggestions/requests' &&
      request.method() === 'POST',
  );
  await page.getByRole('button', { name: '开始抽检' }).click();
  expect((await sampleRequest).postDataJSON()).toMatchObject({
    mediaKind: 'image',
    assetIDs: [],
    sourceIDs: [sourceID],
  });
  await expect(page.getByText('Mac 已接受个人建议抽检任务。')).toBeVisible();
  await expect(page.getByLabel('建议抽检进度')).toBeVisible();
  await page
    .locator('.training-activity-card')
    .filter({ hasText: '个人建议抽检' })
    .getByRole('button', { name: '停止' })
    .click();
  await expect(page.getByText('Mac 已停止个人建议抽检。')).toBeVisible();
});

test('full-library and per-tag suggestions stay Host-authoritative', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('training');
  await page.getByRole('button', { name: '全库建议' }).click();
  await expect(page.getByText('Synthetic Core ML')).toBeVisible();

  const libraryRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/library-suggestions/requests' &&
      request.method() === 'POST',
  );
  const standardCard = page
    .locator('.training-suggestion-card')
    .filter({ hasText: '标准模型建议' });
  await standardCard.getByRole('button', { name: '开始生成' }).click();
  expect((await libraryRequest).postDataJSON()).toMatchObject({
    track: 'standard',
    sourceIDs: [sourceID],
  });
  await expect(standardCard.getByText('running', { exact: true })).toBeVisible();
  await standardCard.getByRole('button', { name: '暂停' }).click();
  await expect(standardCard.getByText('paused', { exact: true })).toBeVisible();

  await page
    .locator('.training-tag-suggestion-form')
    .getByRole('combobox')
    .nth(1)
    .selectOption(tagIDs[0]);
  const tagRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/tag-library-suggestions/requests' &&
      request.method() === 'POST',
  );
  await page.getByRole('button', { name: '开始扫描' }).click();
  expect((await tagRequest).postDataJSON()).toMatchObject({
    method: 'personalCentroid',
    tagID: tagIDs[0],
    sourceIDs: [sourceID],
  });
  await expect(page.getByLabel('按标签建议进度')).toBeVisible();
  await expectAccessible(page);
});

test('training explains a setup failure and recovers on explicit retry', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  let attempts = 0;
  await page.route('**/v1/training/setup?*', (route) => {
    attempts += 1;
    if (attempts <= 2) {
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        json: { message: '合成训练配置暂时不可用', retryable: true },
      });
    }
    return route.fallback();
  });
  await page.goto('training');
  const setupFailure = page.getByText('合成训练配置暂时不可用').locator('..');
  await expect(setupFailure).toBeVisible();
  await setupFailure.getByRole('button', { name: '重试' }).click();
  await expect(page.getByText('新建训练', { exact: true })).toBeVisible();
});
