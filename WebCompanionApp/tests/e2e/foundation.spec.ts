import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';

const authenticatedSession = {
  authenticated: true,
  deviceID: '8bc2a920-f281-413b-8c4c-33c8ed7f78ca',
  authMode: 'pairedDevice',
  username: null,
};

const capabilities = {
  protocolVersion: 1,
  hostAppVersion: 'Synthetic Host',
  minimumClientProtocolVersion: 1,
  capabilities: ['assetPages', 'thumbnails', 'pairing'],
  listenPort: 5173,
  usesTLS: false,
  hostID: 'a90e71ec-d641-488e-a2c4-c462c13b08ff',
  certificateFingerprintSHA256: null,
};

async function mockAuthenticatedHost(page: Page) {
  await page.route('**/web/session', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: authenticatedSession }),
  );
  await page.route('**/v1/capabilities', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', json: capabilities }),
  );
}

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
  await mockAuthenticatedHost(page);

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
