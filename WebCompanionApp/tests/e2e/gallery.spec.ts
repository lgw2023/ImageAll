import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { installSyntheticAuthenticatedHost, sourceID } from './syntheticHost';

test('gallery supports virtual browsing, range selection, mutations, undo, and detail', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');

  await expect(page.getByRole('heading', { name: '图库', level: 2 })).toBeVisible();
  await expect(page.getByRole('button', { name: '查看 IMG_0001.jpg' })).toBeVisible();
  expect(await page.getByRole('gridcell').count()).toBeLessThan(40);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/gallery/imageall-react-gallery-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }

  await page.getByRole('button', { name: '选择 IMG_0001.jpg' }).click();
  await page.getByRole('button', { name: '选择 IMG_0002.jpg' }).click({ modifiers: ['Shift'] });
  await expect(page.getByText('已选择 2 项')).toBeVisible();
  await expect(page.getByText('确认 1 · 拒绝 0 · 未决定 1')).toBeVisible();

  await page.getByRole('button', { name: '确认标签' }).click();
  await expect(page.getByText('已更新 2 项标签决定。')).toBeVisible();
  await page.getByRole('button', { name: '撤销' }).click();
  await expect(page.getByText('已撤销并恢复 2 项。')).toBeVisible();
  await page.getByRole('button', { name: '清除选择' }).click();

  await page.getByRole('button', { name: '收藏 IMG_0001.jpg' }).click();
  await expect(page.getByRole('button', { name: '取消收藏 IMG_0001.jpg' })).toBeVisible();

  const firstAsset = page.getByRole('button', { name: '查看 IMG_0001.jpg' });
  await firstAsset.click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'IMG_0001.jpg' })).toBeVisible();
  await expect(page.getByRole('button', { name: '确认标签 风景' })).toBeVisible();
  await page.getByRole('button', { name: '在 Mac 打开' }).click();
  await expect(page.getByText('已请求 Mac 打开原片。')).toBeVisible();
  if (
    process.env.IMAGEALL_CAPTURE_EVIDENCE === '1' &&
    testInfo.project.name === 'chromium-desktop'
  ) {
    await page.screenshot({
      path: '../docs/web-companion-refactor/evidence/gallery/imageall-react-asset-detail-chromium-desktop.png',
      animations: 'disabled',
    });
  }
  await page.getByRole('button', { name: '关闭照片详情' }).click();
  await expect(page.getByRole('dialog')).toBeHidden();
  await expect(firstAsset).toBeFocused();

  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
});

test('gallery filters are URL-addressable and sent to the Host', async ({ page }, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await expect(page.getByRole('heading', { name: '图库', level: 2 })).toBeVisible();

  const searchRequest = page.waitForRequest((request) => {
    const url = new URL(request.url());
    return url.pathname === '/v1/assets' && url.searchParams.get('q') === 'IMG_0007';
  });
  await page.getByRole('searchbox', { name: '搜索文件名或相对路径' }).fill('IMG_0007');
  await page.getByRole('searchbox', { name: '搜索文件名或相对路径' }).press('Enter');
  await searchRequest;
  await expect.poll(() => new URL(page.url()).searchParams.get('q')).toBe('IMG_0007');

  if (testInfo.project.name === 'chromium-mobile') {
    await page.getByRole('button', { name: '筛选', exact: true }).click();
  }
  const mediaRequest = page.waitForRequest((request) => {
    const url = new URL(request.url());
    return url.pathname === '/v1/assets' && url.searchParams.get('mediaKinds') === 'video';
  });
  await page.getByLabel('媒体').selectOption('video');
  await mediaRequest;
  await expect.poll(() => new URL(page.url()).searchParams.get('media')).toBe('video');

  await page.getByRole('link', { name: '收藏' }).click();
  await expect(page).toHaveURL(/\/gallery\/favorites/);
  await expect(page.getByRole('heading', { name: '收藏图库', level: 2 })).toBeVisible();
});

test('gallery preserves source, folder, density, selection, and viewer return context', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await expect(page.getByRole('heading', { name: '图库', level: 2 })).toBeVisible();
  if (testInfo.project.name === 'chromium-mobile') {
    await page.getByRole('button', { name: '筛选', exact: true }).click();
  }

  const sourceRequest = page.waitForRequest((request) => {
    const url = new URL(request.url());
    return url.pathname === '/v1/assets' && url.searchParams.get('sourceIDs') === sourceID;
  });
  await page.getByLabel('来源').selectOption(sourceID);
  await sourceRequest;
  await expect.poll(() => new URL(page.url()).searchParams.get('source')).toBe(sourceID);

  const tripsRequest = page.waitForRequest((request) => {
    const url = new URL(request.url());
    return (
      url.pathname === '/v1/assets' &&
      url.searchParams.get('folderSourceID') === sourceID &&
      url.searchParams.get('folderRelativePath') === 'Trips'
    );
  });
  await page.getByLabel('选择子文件夹').selectOption('Trips');
  await tripsRequest;
  await expect(page.getByRole('button', { name: 'Trips' })).toHaveAttribute('aria-current', 'page');

  const nestedRequest = page.waitForRequest((request) => {
    const url = new URL(request.url());
    return (
      url.pathname === '/v1/assets' && url.searchParams.get('folderRelativePath') === 'Trips/2026'
    );
  });
  await page.getByLabel('选择子文件夹').selectOption('Trips/2026');
  await nestedRequest;

  const firstSelection = page.getByRole('button', { name: '选择 IMG_0001.jpg' });
  await firstSelection.click();
  await expect(page.getByText('已选择 1 项')).toBeVisible();
  await page.getByLabel('视图').selectOption('compact');
  await expect(page.getByText('已选择 1 项')).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.get('view')).toBe('compact');

  const firstAsset = page.getByRole('button', { name: '查看 IMG_0001.jpg' });
  await firstAsset.click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await page.getByRole('button', { name: '关闭照片详情' }).click();
  await expect(firstAsset).toBeFocused();
  const restoredURL = new URL(page.url());
  expect(restoredURL.searchParams.get('folder')).toBe('Trips/2026');
  expect(restoredURL.searchParams.get('view')).toBe('compact');
  await expect(page.getByText('已选择 1 项')).toBeVisible();
});

test('gallery explains a Host failure and recovers on retry', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route(
    /\/v1\/assets\?.*/,
    (route) =>
      route.fulfill({
        status: 503,
        contentType: 'application/json',
        json: { message: '合成图库暂时不可用', retryable: true },
      }),
    { times: 2 },
  );

  await page.goto('gallery');
  await expect(page.getByRole('alert')).toContainText('合成图库暂时不可用');
  await page.getByRole('button', { name: '重试' }).click();
  await expect(page.getByRole('button', { name: '查看 IMG_0001.jpg' })).toBeVisible();
});

test('gallery reports Host partial favorite failures without false success', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route('**/v1/favorites', async (route) => {
    const body = route.request().postDataJSON() as { assetIDs: string[]; isFavorite: boolean };
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
        changedCount: 1,
        localOnlyCount: 0,
        syncedCount: 0,
        pendingCount: 0,
        failedCount: 1,
        states: [
          {
            assetID: body.assetIDs[0],
            isFavorite: body.isFavorite,
            photosObservedValue: false,
            syncStatus: 'failed',
            lastErrorCode: 'syntheticFailure',
          },
        ],
        replayed: false,
      },
    });
  });

  await page.goto('gallery');
  await page.getByRole('button', { name: '收藏 IMG_0001.jpg' }).click();
  await expect(page.getByText('已更新 1 项；1 项同步失败，可稍后重试。')).toBeVisible();
});

test('gallery supports select-all, modifier selection, context menus, and explicit box selection', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  const firstAsset = page.getByRole('button', { name: '查看 IMG_0001.jpg' });
  await firstAsset.focus();

  await page.keyboard.press('Meta+A');
  await expect(page.getByText('已选择 72 项')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByText('已选择 72 项')).toBeHidden();

  await firstAsset.click({ modifiers: ['Meta'] });
  await expect(page.getByText('已选择 1 项')).toBeVisible();
  await firstAsset.click({ button: 'right' });
  await expect(page.getByRole('menu', { name: '照片操作' })).toBeVisible();
  await page.getByRole('menuitem', { name: '收藏' }).click();
  await expect(page.getByRole('button', { name: '取消收藏 IMG_0001.jpg' })).toBeVisible();

  await page.getByRole('button', { name: '清除选择' }).click();
  await page.getByRole('button', { name: '框选' }).click();
  const firstBox = await firstAsset.boundingBox();
  const secondBox = await page.getByRole('button', { name: '查看 IMG_0002.jpg' }).boundingBox();
  expect(firstBox).not.toBeNull();
  expect(secondBox).not.toBeNull();
  if (!firstBox || !secondBox) return;
  await page.mouse.move(firstBox.x + 4, firstBox.y + 4);
  await page.mouse.down();
  await page.mouse.move(secondBox.x + secondBox.width - 4, secondBox.y + secondBox.height - 4, {
    steps: 5,
  });
  await page.mouse.up();
  await expect(page.getByText('已选择 2 项')).toBeVisible();
});

test('viewer preloads adjacent items and supports keyboard navigation and image zoom', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  await expect(page.getByRole('heading', { name: 'IMG_0001.jpg' })).toBeVisible();
  await expect(page.getByText('100%')).toBeVisible();
  await expect(page.getByRole('button', { name: '进入全屏预览' })).toBeEnabled();

  await page.keyboard.press('+');
  await expect(page.getByText('125%')).toBeVisible();
  await page.getByRole('button', { name: '下一张照片' }).click();
  await expect(page.getByRole('heading', { name: 'IMG_0002.jpg' })).toBeVisible();
  await page.keyboard.press('ArrowLeft');
  await expect(page.getByRole('heading', { name: 'IMG_0001.jpg' })).toBeVisible();
});
