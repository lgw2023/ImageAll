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

test('pairing, logout, and account login stay Host-authoritative without persisted secrets', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  let authenticated = false;
  let pairingBody: Record<string, unknown> = {};
  let accountAuthorization = '';

  await page.route('**/web/session', (route) =>
    route.fulfill({
      status: authenticated ? 200 : 401,
      contentType: 'application/json',
      json: authenticated
        ? {
            authenticated: true,
            deviceID: '8bc2a920-f281-413b-8c4c-33c8ed7f78ca',
            authMode: 'pairedDevice',
            username: null,
          }
        : { error: 'unauthorized' },
    }),
  );
  await page.route('**/web/session/refresh', (route) =>
    route.fulfill({
      status: 401,
      contentType: 'application/json',
      json: { error: 'unauthorized' },
    }),
  );
  await page.route('**/web/session/pair', async (route) => {
    pairingBody = route.request().postDataJSON() as Record<string, unknown>;
    authenticated = true;
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        authenticated: true,
        deviceID: '8bc2a920-f281-413b-8c4c-33c8ed7f78ca',
        authMode: 'pairedDevice',
        username: null,
      },
    });
  });
  await page.route('**/web/session/logout', async (route) => {
    authenticated = false;
    await route.fulfill({ status: 204 });
  });
  await page.route('**/web/account/login', async (route) => {
    accountAuthorization = route.request().headers().authorization ?? '';
    authenticated = true;
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        authenticated: true,
        deviceID: null,
        authMode: 'account',
        username: 'reader',
      },
    });
  });

  await page.goto('.');
  await page.getByRole('textbox', { name: '配对码' }).fill('pairing-secret');
  await page.getByRole('button', { name: '连接图库' }).click();
  await expect(page.getByRole('heading', { name: '图库', level: 1 })).toBeVisible();
  expect(pairingBody).toMatchObject({ pairingToken: 'pairing-secret' });
  expect(typeof pairingBody.clientID).toBe('string');

  await page.getByRole('button', { name: '显示检视器' }).click();
  await page.getByRole('button', { name: '退出当前会话' }).click();
  await expect(page.getByRole('heading', { name: '连接你的 Mac 照片工作台' })).toBeVisible();

  await page.getByRole('tab', { name: '账户' }).click();
  await page.getByRole('textbox', { name: '账户名' }).fill('reader');
  await page.getByLabel('密码').fill('account-secret');
  await page.getByRole('button', { name: '登录图库' }).click();
  await expect(page.getByRole('heading', { name: '图库', level: 1 })).toBeVisible();
  expect(accountAuthorization).toMatch(/^Basic /);

  const persistedValues = await page.evaluate(() => {
    const values: string[] = [];
    for (const storage of [localStorage, sessionStorage]) {
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index);
        if (key) values.push(storage.getItem(key) ?? '');
      }
    }
    return values;
  });
  expect(persistedValues).not.toContain('pairing-secret');
  expect(persistedValues).not.toContain('account-secret');
});

test('authenticated users get the responsive workbench shell', async ({ page }, testInfo) => {
  await installSyntheticAuthenticatedHost(page);

  await page.goto('gallery');
  await expect(page.getByRole('heading', { name: '图库', level: 1 })).toBeVisible();
  await expect(page.getByRole('navigation', { name: '主导航' })).toBeVisible();
  await page.getByRole('button', { name: '显示检视器' }).click();
  await expect(page.getByText('Synthetic Host')).toBeVisible();
  if (testInfo.project.name === 'chromium-mobile') {
    await page.getByRole('button', { name: '关闭检视器' }).click();
  }
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

test('command palette supports keyboard discovery, focus return, navigation, and theme commands', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await expect(page.getByRole('heading', { name: '全部照片', level: 2 })).toBeVisible();

  await page.keyboard.press('Control+K');
  await expect(page.getByRole('dialog', { name: '命令面板' })).toBeVisible();
  await expect(page.getByRole('button', { name: '打开图库', exact: true })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('button', { name: '打开命令面板' })).toBeFocused();

  await page.keyboard.press('?');
  await page
    .getByRole('dialog', { name: '命令面板' })
    .getByRole('button', { name: '使用深色主题' })
    .click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');

  await page.keyboard.press('Control+K');
  await page
    .getByRole('dialog', { name: '命令面板' })
    .getByRole('button', { name: '打开设置' })
    .click();
  await expect(page).toHaveURL(/\/settings$/);
  await expect(page.getByRole('heading', { name: '设置', level: 2 })).toBeVisible();
});
