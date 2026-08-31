import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { installSyntheticAuthenticatedHost } from './syntheticHost';

async function expectAccessible(page: import('@playwright/test').Page) {
  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
}

test('world map bridge selects a cluster and opens a reversible gallery scope', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('map');
  await expect(page.getByRole('heading', { name: '世界地图', level: 2 })).toBeVisible();
  await expect(page.getByText('62', { exact: true })).toBeVisible();

  const renderer = page.frameLocator('iframe[title="照片世界地图"]');
  await renderer.getByRole('button', { name: '深圳，9 张照片' }).click();
  await expect(page.getByRole('heading', { name: '深圳', level: 3 })).toBeVisible();
  await expect(page.getByRole('button', { name: '在图库查看全部 18 张' })).toBeEnabled();
  const pageWidths = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
  }));
  expect(pageWidths.document).toBeLessThanOrEqual(pageWidths.viewport);
  const headingWidths = await page
    .getByText('地图只显示 Mac Host 提供的位置聚合；网页不会请求浏览器定位。')
    .evaluate((element) => ({ client: element.clientWidth, scroll: element.scrollWidth }));
  expect(headingWidths.scroll).toBeLessThanOrEqual(headingWidths.client);
  const workspaceWidths = await page.locator('#main-content').evaluate((element) => ({
    client: element.clientWidth,
    scroll: element.scrollWidth,
  }));
  expect(workspaceWidths.scroll).toBeLessThanOrEqual(workspaceWidths.client);

  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/map/imageall-react-map-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  await expectAccessible(page);

  const scopedRequest = page.waitForRequest((request) => {
    const url = new URL(request.url());
    return url.pathname === '/v1/assets' && url.searchParams.has('worldMapCellDegrees');
  });
  await page.getByRole('button', { name: '在图库查看全部 18 张' }).click();
  expect((await scopedRequest).url()).toContain('worldMapLongitudeBucket=456');
  await expect(page.getByText('深圳', { exact: true })).toBeVisible();
  await expect(page.getByText('图库结果保持地图聚合边界')).toBeVisible();
  await page.getByRole('button', { name: '返回世界地图' }).click();
  await expect(page.getByRole('heading', { name: '世界地图', level: 2 })).toBeVisible();
});

test('world map delegates location and place mutations to the Host', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('map');
  await page.getByRole('button', { name: '开始回填' }).click();
  await expect(page.getByText('Mac 已接收位置回填任务。')).toBeVisible();
  await expect(page.getByText('running', { exact: true })).toBeVisible();

  await page.getByLabel('搜索地点').fill('上海 中国');
  await page.getByRole('button', { name: '搜索', exact: true }).click();
  await expect(page.getByText('中国上海市')).toBeVisible();
  await page.getByRole('button', { name: '确认地点' }).click();
  await expect(page.getByText('已将“上海”绑定到确认地点。')).toBeVisible();
  await expect(page.getByRole('button', { name: '已确认' })).toBeDisabled();
  await expectAccessible(page);
});

test('world map explains a Host snapshot failure and recovers on retry', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  let attempts = 0;
  await page.route('**/v1/world-map/snapshot?*', (route) => {
    attempts += 1;
    if (attempts <= 2) {
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        json: { message: '合成地图暂时不可用', retryable: true },
      });
    }
    return route.fallback();
  });
  await page.goto('map');
  await expect(page.getByText('合成地图暂时不可用')).toBeVisible();
  await page.getByRole('button', { name: '重试' }).click();
  await expect(page.getByText('上海', { exact: true }).first()).toBeVisible();
});
