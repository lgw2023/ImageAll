import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { assetIDs, installSyntheticAuthenticatedHost, sourceID } from './syntheticHost';

test('gallery supports virtual browsing, range selection, mutations, undo, and detail', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');

  await expect(page.getByRole('heading', { name: '全部照片', level: 2 })).toBeVisible();
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

test('single-photo inspector groups tags by the Host catalog order', async ({ page }, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  const landscapeTagID = '55220ca2-8800-4cea-a6b9-9f9e148d2adc';
  const familyTagID = '37cb4f7b-89bd-4548-80b8-ced4e1af5107';
  const peopleGroupID = 'a0000000-0000-4000-8000-000000000001';
  const natureGroupID = 'a0000000-0000-4000-8000-000000000005';

  await page.route('**/v1/tags', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: [
        { id: familyTagID, displayName: '家人', state: 'active', groupID: peopleGroupID },
        { id: landscapeTagID, displayName: '风景', state: 'active', groupID: natureGroupID },
      ],
    }),
  );
  await page.route('**/v1/tag-groups', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: [
        { id: natureGroupID, displayName: '自然与动植物', sortOrder: 4, isSystem: true },
        { id: peopleGroupID, displayName: '人物与关系', sortOrder: 0, isSystem: true },
      ],
    }),
  );
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
        favorite: null,
        tags: [
          { tagID: landscapeTagID, displayName: '风景', decision: 'accepted' },
          { tagID: familyTagID, displayName: '家人', decision: 'unknown' },
        ],
        pendingSuggestions: [],
      },
    }),
  );

  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  const dialog = page.getByRole('dialog');
  const groups = dialog.getByRole('region', { name: /^(人物与关系|自然与动植物)$/ });
  await expect(groups).toHaveCount(2);
  await expect(groups.nth(0)).toHaveAccessibleName('人物与关系');
  await expect(groups.nth(0)).toContainText('家人');
  await expect(groups.nth(1)).toHaveAccessibleName('自然与动植物');
  await expect(groups.nth(1)).toContainText('风景');

  const peopleToggle = dialog.getByRole('button', { name: /人物与关系/ });
  const natureToggle = dialog.getByRole('button', { name: /自然与动植物/ });
  await peopleToggle.focus();
  await peopleToggle.press('ArrowDown');
  await expect(natureToggle).toBeFocused();
  await natureToggle.press('Home');
  await expect(peopleToggle).toBeFocused();

  await peopleToggle.click();
  await expect(peopleToggle).toHaveAttribute('aria-expanded', 'false');
  await expect(dialog.getByRole('button', { name: '标签 家人，未决定' })).toBeHidden();
  await page.reload();
  const reloadedDialog = page.getByRole('dialog');
  await expect(reloadedDialog.getByRole('button', { name: /人物与关系/ })).toHaveAttribute(
    'aria-expanded',
    'false',
  );
  await expect(reloadedDialog.getByRole('button', { name: '标签 家人，未决定' })).toBeHidden();
  const accessibility = await new AxeBuilder({ page })
    .include('.asset-detail-sidebar')
    .withTags(['wcag2a', 'wcag2aa'])
    .analyze();
  expect(accessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await reloadedDialog.locator('.asset-tags').screenshot({
      path: `../docs/web-companion-refactor/evidence/gallery/imageall-react-inspector-tags-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
});

test('single-photo inspector tag body supports Mac click, right-click, and keyboard decisions', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  const landscapeTagID = '55220ca2-8800-4cea-a6b9-9f9e148d2adc';
  const familyTagID = '37cb4f7b-89bd-4548-80b8-ced4e1af5107';
  const decisions = new Map<string, 'unknown' | 'accepted' | 'rejected'>([
    [landscapeTagID, 'accepted'],
    [familyTagID, 'unknown'],
  ]);
  const actions: { tagID: string; assetIDs: string[]; action: string }[] = [];

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
        acceptedTagCount: [...decisions.values()].filter((value) => value === 'accepted').length,
        rejectedTagCount: [...decisions.values()].filter((value) => value === 'rejected').length,
        mediaCreatedAtMs: 1_787_820_000_000,
        mediaModifiedAtMs: 1_787_820_000_000,
        width: 1600,
        height: 1200,
        durationMs: null,
        fingerprintSizeBytes: 1024,
        favorite: null,
        tags: [
          { tagID: landscapeTagID, displayName: '风景', decision: decisions.get(landscapeTagID) },
          { tagID: familyTagID, displayName: '家人', decision: decisions.get(familyTagID) },
        ],
        pendingSuggestions: [],
      },
    }),
  );
  await page.route('**/v1/tag-decisions/batch', (route) => {
    const body = route.request().postDataJSON() as (typeof actions)[number];
    actions.push(body);
    decisions.set(
      body.tagID,
      body.action === 'accept' ? 'accepted' : body.action === 'reject' ? 'rejected' : 'unknown',
    );
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
  const family = page.getByRole('button', { name: '标签 家人，未决定' });
  await family.click();
  await expect.poll(() => actions.at(-1)).toMatchObject({ tagID: familyTagID, action: 'accept' });
  await expect(page.getByRole('button', { name: '标签 家人，已确认' })).toBeFocused();

  const acceptedFamily = page.getByRole('button', { name: '标签 家人，已确认' });
  await acceptedFamily.press('x');
  await expect.poll(() => actions.at(-1)).toMatchObject({ tagID: familyTagID, action: 'reject' });
  await expect(page.getByRole('button', { name: '标签 家人，已拒绝' })).toBeFocused();

  const rejectedFamily = page.getByRole('button', { name: '标签 家人，已拒绝' });
  await rejectedFamily.press('Backspace');
  await expect.poll(() => actions.at(-1)).toMatchObject({ tagID: familyTagID, action: 'clear' });
  await expect(page.getByRole('button', { name: '标签 家人，未决定' })).toBeFocused();

  await page.getByRole('button', { name: '标签 风景，已确认' }).click({ button: 'right' });
  await expect.poll(() => actions.at(-1)).toMatchObject({ tagID: landscapeTagID, action: 'clear' });
});

test('single-photo viewer submits an exact Host-authoritative deletion only after confirmation', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();

  await page.getByRole('button', { name: '删除当前照片' }).click();
  const confirmation = page.getByRole('alertdialog', { name: '删除 IMG_0001.jpg？' });
  await expect(confirmation).toBeVisible();
  await expect(confirmation).toContainText('文件夹原始媒体可能永久删除');
  await expect(confirmation).toContainText('Apple Photos 将移入“最近删除”');
  const accessibility = await new AxeBuilder({ page })
    .include('.asset-deletion-dialog')
    .withTags(['wcag2a', 'wcag2aa'])
    .analyze();
  expect(accessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await confirmation.screenshot({
      path: `../docs/web-companion-refactor/evidence/gallery/imageall-react-deletion-confirmation-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }

  const request = page.waitForRequest(
    (candidate) =>
      new URL(candidate.url()).pathname === '/v1/library-slimming/removals' &&
      candidate.method() === 'POST',
  );
  await confirmation.getByRole('button', { name: '提交给 Mac 确认删除' }).click();
  expect((await request).postDataJSON()).toMatchObject({
    scope: 'gallerySelection',
    jobID: null,
    clusterID: null,
    mediaKind: 'image',
    assetIDs: [assetIDs[0]],
    mode: 'releaseSourceSpace',
  });
  await expect(confirmation).toBeHidden();
  await expect(page.getByText(/Mac 已冻结 1 项选择.*不代表删除已完成/)).toBeVisible();
});

test('single-photo deletion cancel and keyboard shortcut preserve focus without writing', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  let deletionRequestCount = 0;
  page.on('request', (request) => {
    if (
      new URL(request.url()).pathname === '/v1/library-slimming/removals' &&
      request.method() === 'POST'
    ) {
      deletionRequestCount += 1;
    }
  });
  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  const deleteButton = page.getByRole('button', { name: '删除当前照片' });

  await deleteButton.click();
  let confirmation = page.getByRole('alertdialog', { name: '删除 IMG_0001.jpg？' });
  await confirmation.getByRole('button', { name: '取消' }).click();
  await expect(confirmation).toBeHidden();
  await expect(deleteButton).toBeFocused();
  expect(deletionRequestCount).toBe(0);

  await page.keyboard.press('Delete');
  confirmation = page.getByRole('alertdialog', { name: '删除 IMG_0001.jpg？' });
  await expect(confirmation).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(confirmation).toBeHidden();
  await expect(deleteButton).toBeFocused();
  expect(deletionRequestCount).toBe(0);
});

test('single-photo deletion keeps a Host failure retryable inside the confirmation', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  let attempts = 0;
  await page.route('**/v1/library-slimming/removals', (route) => {
    attempts += 1;
    if (attempts === 1) {
      return route.fulfill({
        status: 409,
        contentType: 'application/json',
        json: { code: 'conflict', message: 'Mac 当前有另一个删除确认正在进行' },
      });
    }
    return route.fallback();
  });
  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  await page.getByRole('button', { name: '删除当前照片' }).click();
  const confirmation = page.getByRole('alertdialog', { name: '删除 IMG_0001.jpg？' });
  const submit = confirmation.getByRole('button', { name: '提交给 Mac 确认删除' });

  await submit.click();
  await expect(confirmation.getByRole('alert')).toHaveText('Mac 当前有另一个删除确认正在进行');
  await expect(confirmation).toBeVisible();
  await expect(submit).toBeEnabled();

  await submit.click();
  await expect(confirmation).toBeHidden();
  await expect(page.getByText(/Mac 已冻结 1 项选择.*不代表删除已完成/)).toBeVisible();
});

test('gallery filters are URL-addressable and sent to the Host', async ({ page }, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await expect(page.getByRole('heading', { name: '全部照片', level: 2 })).toBeVisible();

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
  await expect(page.getByRole('heading', { name: '我的收藏', level: 2 })).toBeVisible();
});

test('gallery preserves source, folder, density, selection, and viewer return context', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await expect(page.getByRole('heading', { name: '全部照片', level: 2 })).toBeVisible();
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

test('gallery exposes a Host-authoritative retry for visible failed favorite sync', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  let retryOperationID: string | null = null;
  let favoriteSyncStatus: 'synced' | 'failed' = 'synced';
  await page.route(/\/v1\/assets\?.*/i, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        items: [
          {
            id: assetIDs[0],
            sourceID,
            sourceName: 'Synthetic Library',
            fileName: 'IMG_0001.jpg',
            mediaType: 'image/jpeg',
            availability: 'available',
            contentRevision: 1,
            acceptedTagCount: 1,
            rejectedTagCount: 0,
            mediaCreatedAtMs: 1_787_820_000_000,
            width: 1600,
            height: 1200,
            favorite: {
              assetID: assetIDs[0],
              isFavorite: favoriteSyncStatus === 'failed',
              photosObservedValue: false,
              syncStatus: favoriteSyncStatus,
              lastErrorCode: favoriteSyncStatus === 'failed' ? 'syntheticFailure' : null,
            },
            relativePath: '2026/Synthetic/IMG_0001.jpg',
            mediaModifiedAtMs: 1_787_820_000_000,
            durationMs: null,
          },
        ],
        nextCursor: null,
      },
    }),
  );
  await page.route('**/v1/favorites', async (route) => {
    const body = route.request().postDataJSON() as { assetIDs: string[]; isFavorite: boolean };
    favoriteSyncStatus = 'failed';
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
  await page.route('**/v1/favorites/retry', (route) => {
    const body = route.request().postDataJSON() as { operationID: string };
    retryOperationID = body.operationID;
    favoriteSyncStatus = 'synced';
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        localOnlyCount: 0,
        syncedCount: 1,
        pendingCount: 0,
        failedCount: 0,
        replayed: false,
      },
    });
  });

  await page.goto('gallery');
  await page.getByRole('button', { name: '收藏 IMG_0001.jpg' }).click();
  const retry = page.getByRole('button', { name: '重试红心同步：1 项' });
  await expect(retry).toBeVisible();
  await page.getByRole('button', { name: '关闭消息' }).click();
  const favoriteAccessibility = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa'])
    .analyze();
  expect(favoriteAccessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/gallery/imageall-react-favorite-retry-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await retry.click();
  await expect(page.getByText('Photos 红心同步已完成。')).toBeVisible();
  expect(retryOperationID).toMatch(/^[0-9a-f-]{36}$/i);
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
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).click();
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

test('viewer runs Host local models for the current photo and decides personal results', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page, { extraCapabilities: ['assetLocalSuggestions'] });
  const personalTagID = '30000000-0000-4000-8000-000000000001';
  const localSuggestionRequests: { operationID: string; track: string }[] = [];
  let decisionBody: { tagID: string; assetIDs: string[]; action: string } | null = null;

  await page.route(/\/v1\/assets\/([0-9a-f-]+)\/local-suggestions$/i, async (route) => {
    const body = route.request().postDataJSON() as { operationID: string; track: string };
    localSuggestionRequests.push(body);
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        assetID: assetIDs[0],
        track: body.track,
        state: 'results',
        suggestions:
          body.track === 'personal'
            ? [
                {
                  id: 'personal:pet',
                  track: 'personal',
                  tagID: personalTagID,
                  displayName: '我的猫',
                  recommendation: 'suggested',
                },
              ]
            : [
                {
                  id: 'standard:coast',
                  track: 'standard',
                  tagID: null,
                  displayName: '海岸风景',
                  recommendation: 'autoAssigned',
                },
              ],
        replayed: false,
      },
    });
  });
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
  expect(
    await page.evaluate(async () => {
      const response = await fetch('/v1/capabilities');
      const payload = (await response.json()) as { capabilities: string[] };
      return payload.capabilities.includes('assetLocalSuggestions');
    }),
  ).toBe(true);
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).dblclick();
  await expect(page.getByRole('heading', { name: '当前照片模型' })).toBeVisible();
  await page.getByRole('button', { name: '运行标准场景模型' }).click();
  await expect(page.getByText('海岸风景')).toBeVisible();
  await expect(page.getByText('自动匹配')).toBeVisible();
  await page.getByRole('button', { name: '运行个人标签模型' }).click();
  await expect(page.getByText('我的猫')).toBeVisible();
  const localModelAccessibility = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa'])
    .analyze();
  expect(localModelAccessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/gallery/imageall-react-local-model-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await page.getByRole('button', { name: '属于 我的猫', exact: true }).click();

  expect(localSuggestionRequests.map((request) => request.track)).toEqual(['standard', 'personal']);
  expect(decisionBody).toMatchObject({
    tagID: personalTagID,
    assetIDs: [assetIDs[0]],
    action: 'accept',
  });
});

test('single-photo and frozen multi-selection create and apply a tag inline', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  const requests: { operationID: string; name: string; assetIDs: string[] }[] = [];
  let failFirst = true;
  await page.route('**/v1/tags/create-and-apply', async (route) => {
    const body = route.request().postDataJSON() as (typeof requests)[number];
    requests.push(body);
    if (failFirst) {
      failFirst = false;
      return route.fulfill({
        status: 409,
        contentType: 'application/json',
        json: { code: 'conflict', message: '合成标签暂时冲突' },
      });
    }
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        tagID: '40000000-0000-4000-8000-000000000001',
        displayName: body.name,
        appliedAssetCount: body.assetIDs.length,
        replayed: false,
        undoID: '9de47499-1ca0-4cc2-84bc-a881018e8b0c',
      },
    });
  });

  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).click();
  const singleInput = page.getByRole('textbox', { name: '为当前照片新建标签' });
  await singleInput.fill('胶片感');
  await singleInput.press('Enter');
  await expect(page.getByText('合成标签暂时冲突')).toBeVisible();
  await singleInput.press('Enter');
  await expect(page.getByText('已新增标签“胶片感”并应用到 1 项。')).toBeVisible();
  await expect(singleInput).toHaveValue('');
  await expect(singleInput).toBeFocused();
  expect(requests[0]?.operationID).toBe(requests[1]?.operationID);
  expect(requests[1]?.assetIDs).toEqual([assetIDs[0]]);

  await page.getByRole('button', { name: '关闭消息' }).click();
  await page.getByRole('button', { name: '关闭照片详情' }).click();
  await expect(page.getByRole('dialog')).toBeHidden();
  await page.getByRole('button', { name: '选择 IMG_0001.jpg' }).click();
  await page.getByRole('button', { name: '选择 IMG_0002.jpg' }).click({ modifiers: ['Shift'] });
  const selectionInput = page.getByRole('textbox', { name: '为已选照片新建标签' });
  await selectionInput.fill('周末散步');
  const inlineTagAccessibility = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa'])
    .analyze();
  expect(inlineTagAccessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/gallery/imageall-react-inline-tag-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await selectionInput.press('Enter');
  await expect(page.getByText('已新增标签“周末散步”并应用到 2 项。')).toBeVisible();
  await expect(page.getByText('已选择 2 项')).toBeVisible();
  await expect(selectionInput).toBeFocused();
  expect(requests[2]?.assetIDs).toEqual([assetIDs[0], assetIDs[1]]);
  expect(requests[2]?.operationID).not.toBe(requests[1]?.operationID);
});
