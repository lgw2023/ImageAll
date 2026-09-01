import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { installSyntheticAuthenticatedHost, sourceID as syntheticSourceID } from './syntheticHost';

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

test('storage maintenance confirms cleanup and renders the Host result', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('storage');
  await expect(page.getByRole('heading', { name: '存储与维护', level: 2 })).toBeVisible();
  await expect(page.getByText('24.0 MiB')).toBeVisible();
  page.once('dialog', (dialog) => dialog.accept());
  await page.getByRole('button', { name: '清理预览缓存' }).click();
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
