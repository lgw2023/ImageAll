import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { installSyntheticAuthenticatedHost } from './syntheticHost';

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
