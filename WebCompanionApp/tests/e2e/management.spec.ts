import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import {
  installSyntheticAuthenticatedHost,
  sourceID as syntheticSourceID,
  tagIDs,
} from './syntheticHost';

async function expectAccessible(page: import('@playwright/test').Page) {
  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
}

test('source management submits a Host request and shows its authoritative result', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('sources');
  await expect(page.getByRole('heading', { name: '照片来源', level: 2 })).toBeVisible();
  await expect(page.getByText('Synthetic Library')).toBeVisible();
  await page.getByRole('button', { name: '刷新全部' }).click();
  await expect(page.getByText('Mac 已完成合成来源请求。', { exact: true })).toBeVisible();
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/management/imageall-react-sources-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await expectAccessible(page);
});

test('source action failure is announced and remains retryable in place', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  let attempts = 0;
  await page.route(/\/v1\/source-management\/requests$/, (route) => {
    attempts += 1;
    const body = route.request().postDataJSON() as {
      operationID: string;
      action: string;
      sourceID: string | null;
    };
    if (attempts === 1) {
      return route.fulfill({
        status: 409,
        contentType: 'application/json',
        json: { message: 'Mac 正在处理另一项来源任务，请稍后重试。' },
      });
    }
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: {
        id: '74ba0aa1-e0c3-4421-bb0f-4f7edab5c301',
        operationID: body.operationID,
        action: body.action,
        sourceID: body.sourceID,
        sourceDisplayName: 'Synthetic Library',
        phase: 'completed',
        message: 'Mac 已在重试后接受来源请求。',
        completedCount: null,
        totalCount: null,
        warmedCount: null,
        failedCount: null,
        reusedCount: null,
        ineligibleCount: null,
        completedSourceCount: null,
        totalSourceCount: null,
        updatedAtMs: 1_788_000_000_000,
      },
    });
  });

  await page.goto('sources');
  const scanButton = page.getByRole('button', { name: '扫描' });
  await scanButton.click();
  await expect(page.getByRole('alert')).toHaveText(/Mac 正在处理另一项来源任务/);
  await expect(scanButton).toBeEnabled();

  await scanButton.click();
  await expect(page.getByRole('status')).toHaveText(/Mac 已在重试后接受来源请求/);
  expect(attempts).toBe(2);
});

test('active Photos source exposes complete repair through an exact Host request', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  const photosSourceID = '44ba0aa1-e0c3-4421-bb0f-4f7edab5c344';
  const submitted: { action: string; sourceID: string | null }[] = [];
  page.on('request', (request) => {
    if (request.method() !== 'POST' || !request.url().endsWith('/v1/source-management/requests'))
      return;
    const body = request.postDataJSON() as { action: string; sourceID: string | null };
    submitted.push({ action: body.action, sourceID: body.sourceID });
  });
  await page.route(/\/v1\/source-management$/, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        sources: [
          {
            id: photosSourceID,
            kind: 'photos',
            displayName: '家庭照片图库',
            state: 'active',
          },
        ],
        canConnectPhotos: false,
        requests: [],
      },
    }),
  );

  await page.goto('sources');
  const sourceCard = page.getByRole('article').filter({ hasText: '家庭照片图库' });
  await sourceCard.getByRole('button', { name: '更多操作' }).click();
  await sourceCard.getByRole('button', { name: '完整修复扫描' }).click();

  await expect
    .poll(() => submitted)
    .toContainEqual({
      action: 'fullRepair',
      sourceID: photosSourceID,
    });
  await expect(page.getByText('Mac 已完成合成来源请求。', { exact: true })).toBeVisible();
});

test('source cards expose only the Host-valid tools for their current state', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route(/\/v1\/source-management$/, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        sources: [
          {
            id: '44ba0aa1-e0c3-4421-bb0f-4f7edab5c301',
            kind: 'folder',
            displayName: '工作照片',
            state: 'active',
          },
          {
            id: '44ba0aa1-e0c3-4421-bb0f-4f7edab5c302',
            kind: 'folder',
            displayName: '需要重新授权',
            state: 'authorizationRequired',
          },
          {
            id: '44ba0aa1-e0c3-4421-bb0f-4f7edab5c303',
            kind: 'photos',
            displayName: '当前系统图库',
            state: 'active',
          },
          {
            id: '44ba0aa1-e0c3-4421-bb0f-4f7edab5c304',
            kind: 'photos',
            displayName: '旧系统图库',
            state: 'unavailable',
          },
        ],
        canConnectPhotos: false,
        requests: [],
      },
    }),
  );

  await page.goto('sources');

  const activeFolder = page.getByRole('article').filter({ hasText: '工作照片' });
  await activeFolder.getByRole('button', { name: '更多操作' }).click();
  await expect(activeFolder.getByRole('button', { name: '更新回收权限' })).toBeVisible();
  await expect(activeFolder.getByRole('button', { name: '预热缩略图' })).toBeVisible();
  await expect(activeFolder.getByRole('button', { name: '预热原始比例' })).toBeVisible();

  const authorizationRequired = page.getByRole('article').filter({ hasText: '需要重新授权' });
  await authorizationRequired.getByRole('button', { name: '更多操作' }).click();
  await expect(authorizationRequired.getByRole('button', { name: '重新授权' })).toBeVisible();
  await expect(authorizationRequired.getByRole('button', { name: '预热缩略图' })).toHaveCount(0);

  const activePhotos = page
    .getByRole('article')
    .filter({ has: page.getByText('当前系统图库', { exact: true }) });
  await activePhotos.getByRole('button', { name: '更多操作' }).click();
  await expect(activePhotos.getByRole('button', { name: '请求照片写入权限' })).toBeVisible();
  await expect(activePhotos.getByRole('button', { name: '打开照片权限设置' })).toBeVisible();

  const unavailablePhotos = page.getByRole('article').filter({ hasText: '旧系统图库' });
  await unavailablePhotos.getByRole('button', { name: '更多操作' }).click();
  await expect(unavailablePhotos.getByRole('button', { name: '连接当前系统图库' })).toBeVisible();
  await expect(unavailablePhotos.getByRole('button', { name: '重新授权' })).toHaveCount(0);

  await activePhotos.getByRole('button', { name: '更多操作' }).click();
  const collisions = await page.locator('.domain-workspace').evaluate((workspace) => {
    const containerSelectors = [
      '.source-command-deck-heading',
      '.source-command-bands',
      '.source-command-band-actions',
      '.source-card-primary-actions',
      '.source-command-grid',
    ];
    const overlaps: string[] = [];
    for (const selector of containerSelectors) {
      for (const container of workspace.querySelectorAll<HTMLElement>(selector)) {
        const children = [...container.children].filter((child): child is HTMLElement => {
          if (!(child instanceof HTMLElement)) return false;
          const style = getComputedStyle(child);
          const box = child.getBoundingClientRect();
          return (
            style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            box.width > 0 &&
            box.height > 0
          );
        });
        children.forEach((left, index) => {
          const a = left.getBoundingClientRect();
          children.slice(index + 1).forEach((right) => {
            const b = right.getBoundingClientRect();
            const overlapWidth = Math.min(a.right, b.right) - Math.max(a.left, b.left);
            const overlapHeight = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
            if (overlapWidth > 1 && overlapHeight > 1) {
              overlaps.push(
                `${selector}: ${left.textContent.trim().slice(0, 18)} <> ${right.textContent.trim().slice(0, 18)}`,
              );
            }
          });
        });
      }
    }
    return overlaps;
  });
  expect(collisions).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/management/imageall-react-source-command-deck-${testInfo.project.name}.png`,
      animations: 'disabled',
      fullPage: true,
    });
  }
  await expectAccessible(page);
});

test('batch source maintenance submits the exact authorization actions', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  const submitted: { action: string; sourceID: string | null }[] = [];
  page.on('request', (request) => {
    if (request.method() !== 'POST' || !request.url().endsWith('/v1/source-management/requests'))
      return;
    const body = request.postDataJSON() as { action: string; sourceID: string | null };
    submitted.push({ action: body.action, sourceID: body.sourceID });
  });
  await page.route(/\/v1\/source-management$/, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        sources: [
          {
            id: '44ba0aa1-e0c3-4421-bb0f-4f7edab5c311',
            kind: 'folder',
            displayName: '活跃文件夹',
            state: 'active',
          },
          {
            id: '44ba0aa1-e0c3-4421-bb0f-4f7edab5c312',
            kind: 'folder',
            displayName: '待重新授权文件夹',
            state: 'authorizationRequired',
          },
        ],
        canConnectPhotos: true,
        requests: [],
      },
    }),
  );

  await page.goto('sources');
  await page.getByRole('button', { name: '重新授权待处理来源' }).click();
  await page.getByRole('button', { name: '更新全部回收权限' }).click();

  await expect
    .poll(() => submitted)
    .toEqual([
      { action: 'reauthorizeAll', sourceID: null },
      { action: 'refreshAllFolderMutationAuthorizations', sourceID: null },
    ]);
});

test('running source prewarm locks conflicting actions and remains cancellable', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  const sourceID = '44ba0aa1-e0c3-4421-bb0f-4f7edab5c321';
  const submitted: { action: string; sourceID: string | null }[] = [];
  page.on('request', (request) => {
    if (request.method() !== 'POST' || !request.url().endsWith('/v1/source-management/requests'))
      return;
    const body = request.postDataJSON() as { action: string; sourceID: string | null };
    submitted.push({ action: body.action, sourceID: body.sourceID });
  });
  await page.route(/\/v1\/source-management$/, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        sources: [
          {
            id: sourceID,
            kind: 'folder',
            displayName: '正在预热的图库',
            state: 'active',
          },
        ],
        canConnectPhotos: true,
        requests: [
          {
            id: '54ba0aa1-e0c3-4421-bb0f-4f7edab5c321',
            operationID: '64ba0aa1-e0c3-4421-bb0f-4f7edab5c321',
            action: 'prewarmThumbnails',
            sourceID,
            sourceDisplayName: '正在预热的图库',
            phase: 'running',
            message: 'Mac 正在生成缩略图缓存。',
            completedCount: 36,
            totalCount: 100,
            warmedCount: 20,
            failedCount: 1,
            reusedCount: 15,
            ineligibleCount: 0,
            completedSourceCount: null,
            totalSourceCount: null,
            updatedAtMs: 1_788_000_000_000,
          },
        ],
      },
    }),
  );

  await page.goto('sources');
  await expect(page.getByText('20 新生成')).toBeVisible();
  await expect(page.getByText('15 已复用')).toBeVisible();
  await expect(page.getByText('1 失败')).toBeVisible();
  await expect(page.getByRole('button', { name: '刷新全部' })).toBeDisabled();

  await page.getByRole('button', { name: '取消预热' }).click();
  await expect.poll(() => submitted).toContainEqual({ action: 'cancelPrewarm', sourceID });
});

test('source removal uses an in-app confirmation and restores focus on cancel', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  const submitted: { action: string; sourceID: string | null }[] = [];
  page.on('request', (request) => {
    if (request.method() !== 'POST' || !request.url().endsWith('/v1/source-management/requests'))
      return;
    const body = request.postDataJSON() as { action: string; sourceID: string | null };
    submitted.push({ action: body.action, sourceID: body.sourceID });
  });

  await page.goto('sources');
  await page.getByRole('button', { name: '更多操作' }).click();
  const removeButton = page.getByRole('button', { name: '移除来源' });
  await removeButton.click();
  const dialog = page.getByRole('alertdialog', { name: '移除 Synthetic Library？' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByText(/原始照片不会被修改或删除/)).toBeVisible();
  await expect(dialog.getByRole('button', { name: '取消' })).toBeFocused();

  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(removeButton).toBeFocused();
  expect(submitted).toEqual([]);

  await removeButton.click();
  await page.getByRole('button', { name: '提交给 Mac 确认移除' }).click();
  await expect
    .poll(() => submitted)
    .toContainEqual({
      action: 'delete',
      sourceID: syntheticSourceID,
    });
});

test('source card opens its exact addressable gallery scope without a mutation', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  const sourceMutations: string[] = [];
  page.on('request', (request) => {
    if (request.method() === 'POST' && request.url().endsWith('/v1/source-management/requests')) {
      sourceMutations.push(request.url());
    }
  });

  await page.goto('sources');
  await page.getByRole('link', { name: '在图库中查看' }).click();

  await expect(page).toHaveURL(new RegExp(`source=${syntheticSourceID}`));
  await expect(page.getByRole('heading', { name: '图库', level: 1 })).toBeVisible();
  expect(sourceMutations).toEqual([]);
});

test('storage cleanup uses an in-app safety confirmation and exact Host request', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  const submitted: string[] = [];
  page.on('request', (request) => {
    if (request.method() !== 'POST' || !request.url().endsWith('/v1/storage-maintenance/requests'))
      return;
    const body = request.postDataJSON() as { action: string };
    submitted.push(body.action);
  });
  await page.goto('storage');
  await expect(page.getByRole('heading', { name: '存储与维护', level: 2 })).toBeVisible();
  await expect(page.getByText('24.0 MiB')).toBeVisible();
  const cleanupButton = page.getByRole('button', { name: '清理预览缓存' });
  await cleanupButton.click();
  const dialog = page.getByRole('alertdialog', { name: '清理预览缓存？' });
  await expect(dialog).toBeVisible();
  await expect(
    dialog.getByText(/原始照片、标签、Feature Print 与个人模型不会被删除/),
  ).toBeVisible();
  await expect(dialog.getByRole('button', { name: '取消' })).toBeFocused();

  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(cleanupButton).toBeFocused();
  expect(submitted).toEqual([]);

  await cleanupButton.click();
  await dialog.getByRole('button', { name: '提交给 Mac 确认清理' }).click();
  await expect.poll(() => submitted).toEqual(['clearPreviewCache']);
  await expect(
    page.getByRole('status').getByText('Mac 已完成合成维护请求。', { exact: true }),
  ).toBeVisible();
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/management/imageall-react-storage-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await expectAccessible(page);
});

test('storage maintenance locks conflicting commands while Mac owns an active request', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route(/\/v1\/storage-maintenance$/, (route) =>
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
        requests: [
          {
            id: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3c1',
            operationID: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3c2',
            action: 'exportPortableData',
            phase: 'awaitingMac',
            message: '请回到 Mac 选择用户数据导出位置',
            updatedAtMs: 1_787_820_000_000,
            result: null,
          },
        ],
      },
    }),
  );

  await page.goto('storage');
  await expect(
    page.getByRole('region', { name: '可用操作' }).getByText('等待 Mac 操作', { exact: true }),
  ).toBeVisible();
  await expect(page.getByText('请回到 Mac 选择用户数据导出位置')).toBeVisible();
  for (const name of ['导出便携数据', '选择外部存储', '清理预览缓存', '清理原片缓存']) {
    await expect(page.getByRole('button', { name })).toBeDisabled();
  }
});

test('storage maintenance explains unavailable cleanup and pending external migration', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route(/\/v1\/storage-maintenance$/, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        previewCache: { entryCount: 0, registeredBytes: 0 },
        photosOriginals: { entryCount: 3, registeredBytes: 314_572_800 },
        clearPreviewCacheAvailability: { isAvailable: false, reason: 'empty' },
        clearPhotosOriginalsAvailability: {
          isAvailable: false,
          reason: 'librarySlimmingAnalysisInProgress',
        },
        appStorage: {
          kind: 'externalStorage',
          requiresRestart: true,
          pendingExternalRootName: 'PhotoVault',
        },
        requests: [],
      },
    }),
  );

  await page.goto('storage');
  await expect(page.getByText('没有可清理的预览缓存')).toBeVisible();
  await expect(page.getByText('图库精简正在使用原片副本')).toBeVisible();
  await expect(page.getByText('PhotoVault', { exact: true })).toBeVisible();
  await expect(page.getByText(/重启 ImageAll 后迁移/)).toBeVisible();
  await expect(page.getByRole('button', { name: '清理预览缓存' })).toBeDisabled();
  await expect(page.getByRole('button', { name: '清理原片缓存' })).toBeDisabled();
});

test('storage history renders every Host result without hiding partial outcomes', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route(/\/v1\/storage-maintenance$/, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        previewCache: { entryCount: 0, registeredBytes: 0 },
        photosOriginals: { entryCount: 0, registeredBytes: 0 },
        clearPreviewCacheAvailability: { isAvailable: false, reason: 'empty' },
        clearPhotosOriginalsAvailability: { isAvailable: false, reason: 'empty' },
        appStorage: {
          kind: 'externalStorage',
          requiresRestart: false,
          pendingExternalRootName: null,
        },
        requests: [
          {
            id: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3d1',
            operationID: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3d2',
            action: 'exportPortableData',
            phase: 'completed',
            message: 'Mac 已完成便携数据导出。',
            updatedAtMs: 1_787_820_000_000,
            result: {
              affectedEntryCount: null,
              affectedBytes: null,
              bundleName: 'ImageAll-Portable-2026-09-01',
              totalRecordCount: 12_842,
              requiresRestart: null,
              partialReclaim: null,
            },
          },
          {
            id: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3d3',
            operationID: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3d4',
            action: 'clearPreviewCache',
            phase: 'completed',
            message: 'Mac 已完成预览缓存清理。',
            updatedAtMs: 1_787_819_000_000,
            result: {
              affectedEntryCount: 120,
              affectedBytes: 25_165_824,
              bundleName: null,
              totalRecordCount: null,
              requiresRestart: null,
              partialReclaim: true,
            },
          },
          {
            id: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3d5',
            operationID: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3d6',
            action: 'chooseExternalStorage',
            phase: 'completed',
            message: 'Mac 已选择新的外置存储。',
            updatedAtMs: 1_787_818_000_000,
            result: {
              affectedEntryCount: null,
              affectedBytes: null,
              bundleName: null,
              totalRecordCount: null,
              requiresRestart: true,
              partialReclaim: null,
            },
          },
        ],
      },
    }),
  );

  await page.goto('storage');
  const history = page.getByRole('region', { name: '最近请求' });
  await expect(history.getByText('ImageAll-Portable-2026-09-01', { exact: true })).toBeVisible();
  await expect(history.getByText('12,842 条记录', { exact: true })).toBeVisible();
  await expect(history.getByText('120 项', { exact: true })).toBeVisible();
  await expect(history.getByText('24.0 MiB', { exact: true })).toBeVisible();
  await expect(history.getByText('部分空间待后续重试', { exact: true })).toBeVisible();
  await expect(history.getByText('重启后生效', { exact: true })).toBeVisible();
});

test('storage cleanup keeps Host failure in the dialog and retries idempotently', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  const submitted: { action: string; operationID: string }[] = [];
  await page.route(/\/v1\/storage-maintenance\/requests$/, (route) => {
    const body = route.request().postDataJSON() as { action: string; operationID: string };
    submitted.push(body);
    if (submitted.length === 1) {
      return route.fulfill({
        status: 409,
        contentType: 'application/json',
        json: { message: 'Mac 正在处理另一项维护，请稍后重试。' },
      });
    }
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: {
        id: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3e1',
        operationID: body.operationID,
        action: body.action,
        phase: 'completed',
        message: 'Mac 已在重试后完成维护请求。',
        updatedAtMs: 1_787_820_000_000,
        result: {
          affectedEntryCount: 120,
          affectedBytes: 25_165_824,
          bundleName: null,
          totalRecordCount: null,
          requiresRestart: null,
          partialReclaim: false,
        },
      },
    });
  });

  await page.goto('storage');
  await page.getByRole('button', { name: '清理预览缓存' }).click();
  const dialog = page.getByRole('alertdialog', { name: '清理预览缓存？' });
  const confirm = dialog.getByRole('button', { name: '提交给 Mac 确认清理' });
  await confirm.click();
  await expect(dialog.getByRole('alert')).toHaveText(/Mac 正在处理另一项维护/);
  await expect(dialog).toBeVisible();

  await confirm.click();
  await expect(dialog).toHaveCount(0);
  expect(submitted).toHaveLength(2);
  expect(submitted[0]?.operationID).toBe(submitted[1]?.operationID);
  await expect(page.getByRole('status')).toHaveText(/Mac 已在重试后完成维护请求/);
});

test('storage export failure is announced and remains retryable in place', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  let attempts = 0;
  await page.route(/\/v1\/storage-maintenance\/requests$/, (route) => {
    attempts += 1;
    const body = route.request().postDataJSON() as { action: string; operationID: string };
    if (attempts === 1) {
      return route.fulfill({
        status: 409,
        contentType: 'application/json',
        json: { message: 'Mac 正在处理另一项维护，请稍后重试。' },
      });
    }
    return route.fulfill({
      status: 202,
      contentType: 'application/json',
      json: {
        id: '8cba0aa1-e0c3-4421-bb0f-4f7edab5c3f1',
        operationID: body.operationID,
        action: body.action,
        phase: 'completed',
        message: 'Mac 已在重试后接受导出请求。',
        updatedAtMs: 1_787_820_000_000,
        result: {
          affectedEntryCount: null,
          affectedBytes: null,
          bundleName: 'ImageAll-Portable-2026-09-01',
          totalRecordCount: 12_842,
          requiresRestart: null,
          partialReclaim: null,
        },
      },
    });
  });

  await page.goto('storage');
  const exportButton = page.getByRole('button', { name: '导出便携数据' });
  await exportButton.click();
  await expect(page.getByRole('alert')).toHaveText(/Mac 正在处理另一项维护/);
  await expect(exportButton).toBeEnabled();

  await exportButton.click();
  await expect(page.getByRole('status')).toHaveText(/Mac 已在重试后接受导出请求/);
  expect(attempts).toBe(2);
});

test('storage command vault preserves hierarchy without desktop or mobile collisions', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('storage');

  await expect(page.getByRole('region', { name: '存储命令台' })).toBeVisible();
  await expect(page.getByRole('region', { name: '数据出口' })).toBeVisible();
  await expect(page.getByRole('region', { name: '空间回收' })).toBeVisible();
  await expect(page.getByText(/长期 Photos 原图默认保留/)).toBeVisible();

  const collisions = await page.locator('.storage-workspace').evaluate((workspace) => {
    const selectors = [
      '.storage-vault-heading',
      '.storage-ledger',
      '.storage-command-grid',
      '.storage-reclaim-grid',
      '.storage-request-results',
    ];
    const overlaps: string[] = [];
    for (const selector of selectors) {
      for (const container of workspace.querySelectorAll<HTMLElement>(selector)) {
        const children = [...container.children].filter((child): child is HTMLElement => {
          if (!(child instanceof HTMLElement)) return false;
          const style = getComputedStyle(child);
          const box = child.getBoundingClientRect();
          return (
            style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            box.width > 0 &&
            box.height > 0
          );
        });
        children.forEach((left, index) => {
          const a = left.getBoundingClientRect();
          children.slice(index + 1).forEach((right) => {
            const b = right.getBoundingClientRect();
            const overlapWidth = Math.min(a.right, b.right) - Math.max(a.left, b.left);
            const overlapHeight = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
            if (overlapWidth > 1 && overlapHeight > 1) {
              overlaps.push(
                `${selector}: ${left.textContent.trim().slice(0, 18)} <> ${right.textContent.trim().slice(0, 18)}`,
              );
            }
          });
        });
      }
    }
    return overlaps;
  });
  expect(collisions).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(
    true,
  );
  if (testInfo.project.name === 'chromium-mobile') {
    const touchTargetHeights = await page
      .locator('.storage-workspace button')
      .evaluateAll((buttons) => buttons.map((button) => button.getBoundingClientRect().height));
    expect(touchTargetHeights.every((height) => height >= 44)).toBe(true);
  }
  await expectAccessible(page);

  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/management/imageall-react-storage-vault-${testInfo.project.name}.png`,
      animations: 'disabled',
      fullPage: true,
    });
  }
});

test('storage command vault remains usable at the 1024 by 768 workbench boundary', async ({
  page,
}, testInfo) => {
  test.skip(testInfo.project.name !== 'chromium-desktop');
  await page.setViewportSize({ width: 1024, height: 768 });
  await installSyntheticAuthenticatedHost(page);
  await page.goto('storage');

  await expect(page.getByRole('region', { name: '数据出口' })).toBeVisible();
  await expect(page.getByRole('button', { name: '导出便携数据' })).toBeVisible();
  await expect(page.getByRole('button', { name: '清理原片缓存' })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(
    true,
  );
  await expectAccessible(page);
});

test('activity controls a long-running Host job without optimistic completion', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('activity');
  await expect(page.getByRole('heading', { name: '活动', level: 2 })).toBeVisible();
  await expect(page.getByText('42 / 120')).toBeVisible();
  await page.getByRole('button', { name: '暂停' }).click();
  await expect(page.getByText('已请求暂停任务。')).toBeVisible();
  await expect(page.getByText('paused', { exact: true })).toBeVisible();
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/management/imageall-react-activity-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await expectAccessible(page);
});

test('settings save partial fields and protect the current paired device', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('settings');
  await expect(page.getByRole('heading', { name: '设置', level: 2 })).toBeVisible();
  await expect(page.getByRole('button', { name: '撤销' }).first()).toBeDisabled();

  await page.getByRole('checkbox', { name: /启用本地模型/ }).uncheck();
  await page.getByLabel('Mac 工具栏显示').selectOption('iconOnly');
  await page.getByLabel('每标签最多待处理建议').fill('320');
  await page.getByRole('button', { name: '保存设置' }).click();
  await expect(page.getByText('设置已由 Mac 保存。')).toBeVisible();

  page.once('dialog', (dialog) => dialog.accept());
  await page.getByRole('button', { name: '撤销' }).nth(1).click();
  await expect(page.locator('.device-row').filter({ hasText: '旧 iPad' })).toHaveCount(0);
  await expect(page.getByText('已撤销设备“旧 iPad”。', { exact: true })).toBeVisible();
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/management/imageall-react-settings-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await expectAccessible(page);
});

test('settings updates one default suggestion threshold without overwriting other settings', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  let submitted: Record<string, unknown> | null = null;
  await page.route('**/v1/settings/general', async (route) => {
    if (route.request().method() !== 'PUT') return route.fallback();
    submitted = route.request().postDataJSON() as Record<string, unknown>;
    return route.fallback();
  });
  await page.goto('settings');

  const featureThreshold = page.getByRole('spinbutton', { name: /^特征向量默认门槛/ });
  await featureThreshold.fill('0.79');
  await page.getByRole('button', { name: '保存特征向量默认门槛' }).click();

  await expect(page.getByText('特征向量默认门槛已更新为 0.79。')).toBeVisible();
  expect(submitted).toMatchObject({
    suggestionThresholdMutation: {
      action: 'setDefault',
      method: 'featureKnn',
      minScore: 0.79,
    },
  });
  expect(submitted).not.toHaveProperty('modelEnabled');
  expect(submitted).not.toHaveProperty('idleThumbnailPrewarmEnabled');
  expect(submitted).not.toHaveProperty('toolbarDisplayMode');
  await expect(featureThreshold).toHaveValue('0.79');
  await expectAccessible(page);
});

test('settings manages per-tag threshold overrides through the Host', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  const submitted: Record<string, unknown>[] = [];
  await page.route('**/v1/settings/general', async (route) => {
    if (route.request().method() !== 'PUT') return route.fallback();
    submitted.push(route.request().postDataJSON() as Record<string, unknown>);
    return route.fallback();
  });
  await page.goto('settings');

  const openButton = page.getByRole('button', { name: '按标签覆盖' });
  await openButton.click();
  const dialog = page.getByRole('dialog', { name: '按标签覆盖' });
  await expect(dialog).toBeVisible();
  await dialog.getByRole('searchbox', { name: '搜索标签' }).fill('风景');
  const centroid = dialog.getByRole('group', { name: '风景 · 个人模型' });
  await centroid.getByRole('spinbutton').fill('0.88');
  await centroid.getByRole('button', { name: '保存覆盖' }).click();
  await expect(dialog.getByText('风景的个人模型门槛已更新为 0.88。')).toBeVisible();

  const feature = dialog.getByRole('group', { name: '风景 · 特征向量' });
  await feature.getByRole('button', { name: '采用参考值 0.69' }).click();
  await expect(feature.getByRole('spinbutton')).toHaveValue('0.69');

  await centroid.getByRole('button', { name: '恢复继承默认' }).click();
  await expect(centroid.getByText('继承默认 0.82')).toBeVisible();
  expect(submitted.map((body) => body.suggestionThresholdMutation)).toEqual([
    { action: 'setOverride', method: 'personalCentroid', tagID: tagIDs[0], minScore: 0.88 },
    { action: 'setOverride', method: 'featureKnn', tagID: tagIDs[0], minScore: 0.69 },
    { action: 'clearOverride', method: 'personalCentroid', tagID: tagIDs[0] },
  ]);

  await expectAccessible(page);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(
    true,
  );
  if (testInfo.project.name === 'chromium-mobile') {
    const undersizedTouchTargets = await dialog.getByRole('button').evaluateAll((buttons) =>
      buttons
        .map((button) => ({
          name: button.getAttribute('aria-label') ?? button.textContent.trim(),
          height: button.getBoundingClientRect().height,
        }))
        .filter((item) => item.height < 44),
    );
    expect(undersizedTouchTargets).toEqual([]);
  }
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/management/imageall-react-suggestion-thresholds-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }

  await dialog.getByRole('button', { name: '完成' }).click();
  await expect(dialog).toBeHidden();
  await expect(openButton).toBeFocused();
  await expectAccessible(page);
});

test('settings confirms and idempotently retries pruning low-score suggestions', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  const submitted: Record<string, unknown>[] = [];
  await page.route('**/v1/settings/general', async (route) => {
    if (route.request().method() !== 'PUT') return route.fallback();
    const body = route.request().postDataJSON() as Record<string, unknown>;
    const mutation = body.suggestionThresholdMutation as { action?: string } | undefined;
    if (mutation?.action !== 'prune') return route.fallback();
    submitted.push(body);
    if (submitted.length === 1) {
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        json: { message: 'Mac 正在刷新建议，请稍后重试。' },
      });
    }
    return route.fallback();
  });
  await page.goto('settings');
  await page.getByRole('button', { name: '按标签覆盖' }).click();
  const thresholdDialog = page.getByRole('dialog', { name: '按标签覆盖' });
  const feature = thresholdDialog.getByRole('group', { name: '风景 · 特征向量' });
  const pruneButton = feature.getByRole('button', { name: '清理低分待审项' });
  await pruneButton.click();

  const confirmation = page.getByRole('alertdialog', {
    name: '清理“风景”的特征向量低分建议？',
  });
  await expect(confirmation).toContainText('当前有效门槛 0.74');
  await expect(confirmation).toContainText('不会修改门槛，也不会启动新的图库扫描');
  await confirmation.getByRole('button', { name: '确认清理低分待审项' }).click();
  await expect(confirmation.getByText('Mac 正在刷新建议，请稍后重试。')).toBeVisible();
  await confirmation.getByRole('button', { name: '确认清理低分待审项' }).click();

  await expect(confirmation).toBeHidden();
  await expect(
    thresholdDialog.getByText('Mac 已按风景的特征向量有效门槛清理低分待审项。'),
  ).toBeVisible();
  await expect(pruneButton).toBeFocused();
  expect(submitted).toHaveLength(2);
  expect(submitted[0]?.operationID).toBe(submitted[1]?.operationID);
  expect(submitted[1]?.suggestionThresholdMutation).toEqual({
    action: 'prune',
    method: 'featureKnn',
    tagID: tagIDs[0],
  });
  await expectAccessible(page);
});

test('settings surfaces a Host conflict instead of claiming success', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route('**/v1/settings/general', (route) => {
    if (route.request().method() === 'PUT') {
      return route.fulfill({
        status: 409,
        contentType: 'application/json',
        json: { message: 'Mac 设置刚刚发生变化，请重新确认。' },
      });
    }
    return route.fallback();
  });
  await page.goto('settings');
  await page.getByRole('checkbox', { name: /启用本地模型/ }).uncheck();
  await page.getByRole('button', { name: '保存设置' }).click();
  await expect(page.getByText('Mac 设置刚刚发生变化，请重新确认。')).toBeVisible();
});
