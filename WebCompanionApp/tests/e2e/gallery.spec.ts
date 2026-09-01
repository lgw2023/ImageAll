import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { assetIDs, installSyntheticAuthenticatedHost, sourceID } from './syntheticHost';

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

test('viewer only downloads an iCloud preview after an explicit user request', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  let startCount = 0;
  let activeOperationID: string | null = null;

  await page.route('**/v1/capabilities', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        protocolVersion: 1,
        hostAppVersion: 'Synthetic Host',
        minimumClientProtocolVersion: 1,
        capabilities: ['assetPages', 'assetDetail', 'previews', 'cloudPreviewLifecycle'],
        listenPort: 5173,
        usesTLS: false,
        hostID: 'a90e71ec-d641-488e-a2c4-c462c13b08ff',
        certificateFingerprintSHA256: null,
      },
    }),
  );
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/preview\?.*/i, (route) =>
    route.fulfill({
      status: 409,
      contentType: 'application/json',
      json: { code: 'conflict', message: 'cloud preview required' },
    }),
  );
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/cloud-preview-requests$/i, (route) => {
    if (route.request().method() === 'GET') {
      if (activeOperationID) {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          json: {
            operationID: activeOperationID,
            assetID: assetIDs[0],
            phase: 'downloading',
            progress: 0.42,
            message: null,
            updatedAtMs: 1_787_820_000_100,
          },
        });
      }
      return route.fulfill({
        status: 404,
        contentType: 'application/json',
        json: { code: 'notFound', message: 'cloud preview download not found' },
      });
    }
    startCount += 1;
    const body = route.request().postDataJSON() as { operationID: string };
    activeOperationID = body.operationID;
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        assetID: assetIDs[0],
        phase: 'downloading',
        progress: 0.42,
        message: null,
        updatedAtMs: 1_787_820_000_000,
      },
    });
  });

  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  await expect(page.getByRole('button', { name: '从 iCloud 获取预览' })).toBeVisible();
  expect(startCount).toBe(0);

  await page.getByRole('button', { name: '从 iCloud 获取预览' }).click();
  await expect(page.getByText('42%')).toBeVisible();
  expect(startCount).toBe(1);
  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/gallery/imageall-react-cloud-preview-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
});

test('viewer cancels and retries an iCloud preview without leaving the current asset', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  let startCount = 0;
  let cancelCount = 0;
  let activeOperationID: string | null = null;
  let completed = false;

  await page.route('**/v1/capabilities', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        protocolVersion: 1,
        hostAppVersion: 'Synthetic Host',
        minimumClientProtocolVersion: 1,
        capabilities: ['assetPages', 'assetDetail', 'previews', 'cloudPreviewLifecycle'],
        listenPort: 5173,
        usesTLS: false,
        hostID: 'a90e71ec-d641-488e-a2c4-c462c13b08ff',
        certificateFingerprintSHA256: null,
      },
    }),
  );
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/preview\?.*/i, (route) =>
    completed
      ? route.fulfill({
          status: 200,
          contentType: 'image/svg+xml',
          body: '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480"><rect width="640" height="480" fill="#7194a9"/></svg>',
        })
      : route.fulfill({
          status: 409,
          contentType: 'application/json',
          json: { code: 'conflict', message: 'cloud preview required' },
        }),
  );
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/cloud-preview-requests\/cancel$/i, (route) => {
    cancelCount += 1;
    const body = route.request().postDataJSON() as { operationID: string };
    activeOperationID = null;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        assetID: assetIDs[0],
        phase: 'cancelled',
        progress: 0.42,
        message: 'iCloud preview download cancelled',
        updatedAtMs: 1_787_820_000_100,
      },
    });
  });
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/cloud-preview-requests$/i, (route) => {
    if (route.request().method() === 'POST') {
      startCount += 1;
      activeOperationID = (route.request().postDataJSON() as { operationID: string }).operationID;
      return route.fulfill({
        status: 202,
        contentType: 'application/json',
        json: {
          operationID: activeOperationID,
          assetID: assetIDs[0],
          phase: 'downloading',
          progress: 0.42,
          message: null,
          updatedAtMs: 1_787_820_000_000,
        },
      });
    }
    if (!activeOperationID) {
      return route.fulfill({
        status: 404,
        contentType: 'application/json',
        json: { code: 'notFound', message: 'cloud preview download not found' },
      });
    }
    if (startCount === 2) completed = true;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: activeOperationID,
        assetID: assetIDs[0],
        phase: completed ? 'completed' : 'downloading',
        progress: completed ? 1 : 0.42,
        message: completed ? 'iCloud preview downloaded' : null,
        updatedAtMs: 1_787_820_000_200,
      },
    });
  });

  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  await page.getByRole('button', { name: '从 iCloud 获取预览' }).click();
  await expect(page.getByText('42%')).toBeVisible();
  await page.getByRole('button', { name: '取消获取 iCloud 预览' }).click();
  await expect(page.getByText('已停止获取；需要时可以重新开始。')).toBeVisible();
  expect(cancelCount).toBe(1);

  await page.getByRole('button', { name: '从 iCloud 获取预览' }).click();
  await expect(page.getByRole('img', { name: 'IMG_0001.jpg' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'IMG_0001.jpg' })).toBeVisible();
  expect(startCount).toBe(2);
});

test('viewer keeps the explicit cloud-preview flow with an older Host', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  let legacyRequestCount = 0;
  let completed = false;

  await page.route(/\/v1\/assets\/[0-9a-f-]+\/preview\?.*/i, (route) =>
    completed
      ? route.fulfill({
          status: 200,
          contentType: 'image/svg+xml',
          body: '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480"><rect width="640" height="480" fill="#7194a9"/></svg>',
        })
      : route.fulfill({
          status: 409,
          contentType: 'application/json',
          json: { code: 'conflict', message: 'cloud preview required' },
        }),
  );
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/cloud-preview$/i, (route) => {
    legacyRequestCount += 1;
    completed = true;
    return route.fulfill({
      status: 200,
      contentType: 'image/svg+xml',
      body: '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480"><rect width="640" height="480" fill="#7194a9"/></svg>',
    });
  });

  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  await expect(page.getByRole('button', { name: '从 iCloud 获取预览' })).toBeVisible();
  expect(legacyRequestCount).toBe(0);
  await page.getByRole('button', { name: '从 iCloud 获取预览' }).click();
  await expect(page.getByRole('img', { name: 'IMG_0001.jpg' })).toBeVisible();
  expect(legacyRequestCount).toBe(1);
});

test('viewer exposes all Host pending suggestions and applies a decision in place', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  const suggestionIDs = [
    '20000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000003',
    '20000000-0000-4000-8000-000000000004',
    '20000000-0000-4000-8000-000000000005',
    '20000000-0000-4000-8000-000000000006',
  ];
  const suggestionNames = ['建筑', '海边', '城市', '动物', '旅行', '夜景'];
  let decisionBody: { tagID: string; assetIDs: string[]; action: string } | null = null;

  await page.route(/\/v1\/assets\/([0-9a-f-]+)$/i, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        assetID: assetIDs[0],
        sourceID,
        sourceName: 'Synthetic Library',
        fileName: 'IMG_0001.jpg',
        relativePath: '2026/Synthetic/IMG_0001.jpg',
        mediaType: 'image/jpeg',
        availability: 'available',
        contentRevision: 1,
        acceptedTagCount: 1,
        rejectedTagCount: 0,
        mediaCreatedAtMs: 1_787_820_000_000,
        mediaModifiedAtMs: 1_787_820_000_000,
        width: 1600,
        height: 1200,
        durationMs: null,
        fingerprintSizeBytes: 1024,
        favorite: {
          assetID: assetIDs[0],
          isFavorite: false,
          photosObservedValue: false,
          syncStatus: 'synced',
          lastErrorCode: null,
        },
        tags: [],
        pendingSuggestions: suggestionIDs.map((tagID, index) => ({
          tagID,
          displayName: suggestionNames[index],
          suggestionOrigin: ['featurePrint', 'standardModel', 'personalModel', 'personalAdamW'][
            index % 4
          ],
        })),
      },
    }),
  );
  await page.route('**/v1/tag-decisions/batch', (route) => {
    decisionBody = route.request().postDataJSON() as typeof decisionBody;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: '2cba0aa1-e0c3-4421-bb0f-4f7edab5c3b0',
        appliedAssetCount: 1,
        replayed: false,
        undoID: '9de47499-1ca0-4cc2-84bc-a881018e8b0c',
      },
    });
  });

  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  await expect(page.getByRole('heading', { name: '待审 AI 建议' })).toBeVisible();
  await expect(page.getByRole('button', { name: '属于 建筑', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: '属于 夜景', exact: true })).toBeHidden();
  await page.getByRole('button', { name: '另外 1 条建议' }).click();
  await expect(page.getByRole('button', { name: '属于 夜景', exact: true })).toBeVisible();
  await expect(page.getByText('超级个人模型')).toBeVisible();
  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/gallery/imageall-react-pending-suggestions-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }

  await page.getByRole('button', { name: '属于 建筑', exact: true }).click();
  await expect(page.getByText('已更新 1 项标签决定。')).toBeVisible();
  expect(decisionBody).toMatchObject({
    tagID: suggestionIDs[0],
    assetIDs: [assetIDs[0]],
    action: 'accept',
  });
});
