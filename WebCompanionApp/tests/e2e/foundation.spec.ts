import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';

import { installSyntheticAuthenticatedHost } from './syntheticHost';

async function expectNoSeriousAccessibilityViolations(page: Page) {
  const scan = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(scan.violations).toEqual([]);
}

test('unauthenticated users get an accessible pairing and account entry point', async ({
  page,
}) => {
  await page.route('**/web/session', (route) =>
    route.fulfill({
      status: 401,
      contentType: 'application/json',
      json: { error: 'unauthorized' },
    }),
  );
  await page.route('**/web/session/refresh', (route) =>
    route.fulfill({
      status: 401,
      contentType: 'application/json',
      json: { error: 'unauthorized' },
    }),
  );

  await page.goto('.');
  await expect(page.getByRole('heading', { name: '连接你的 Mac 照片工作台' })).toBeVisible();

  const pairTab = page.getByRole('tab', { name: '配对码' });
  await pairTab.focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: '账户' })).toBeFocused();
  await expect(page.getByLabel('密码')).toBeVisible();
  await expectNoSeriousAccessibilityViolations(page);
});

test('authenticated users get the responsive workbench shell', async ({ page }, testInfo) => {
  await installSyntheticAuthenticatedHost(page);

  await page.goto('gallery');
  await expect(page.getByRole('heading', { name: '图库', level: 1 })).toBeVisible();
  await expect(page.getByRole('navigation', { name: '主导航' })).toBeVisible();
  await expect(page.getByText('Synthetic Host')).toBeVisible();
  await expectNoSeriousAccessibilityViolations(page);

  if (testInfo.project.name === 'chromium-mobile') {
    await expect(page.getByRole('navigation', { name: '主导航' })).not.toBeInViewport();
    await expect(page.getByRole('complementary', { name: '检视器' })).not.toBeInViewport();
    await page.getByRole('button', { name: '打开导航' }).click();
    await expect(page.getByRole('navigation', { name: '主导航' })).toBeInViewport();
    await expect(page.getByRole('complementary', { name: '检视器' })).not.toBeInViewport();
  }

  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/foundation/imageall-react-foundation-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
});

test('live Host events preserve context, refresh projections, and expose recoverable notices', async ({
  page,
}) => {
  let assetRequests = 0;
  page.on('request', (request) => {
    if (new URL(request.url()).pathname === '/v1/assets') assetRequests += 1;
  });
  const host = await installSyntheticAuthenticatedHost(page);

  await page.goto('gallery?q=IMG');
  await expect(page.getByText('已连接')).toBeVisible();
  await page.getByRole('button', { name: '选择 IMG_0001.jpg' }).click();
  await expect(page.getByText('已选择 1 项')).toBeVisible();
  const requestCountBeforeEvent = assetRequests;

  host.sendEvent('assetsChanged');
  await expect.poll(() => assetRequests).toBeGreaterThan(requestCountBeforeEvent);
  await expect(page.getByText('已选择 1 项')).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.get('q')).toBe('IMG');

  host.showRecycleNotice();
  await expect(page.getByText('来源删除被回收站中的项目阻止。')).toBeVisible();
  await page.getByRole('button', { name: '打开回收站' }).click();
  await expect(page).toHaveURL(/\/slimming\?section=recycle/);

  host.closeEvents();
  await expect(page.getByText('正在重连')).toBeVisible();
  await expect(page.getByText('正在恢复实时连接')).toBeVisible();
});
