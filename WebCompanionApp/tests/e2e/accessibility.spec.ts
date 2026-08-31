import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';

import { installSyntheticAuthenticatedHost } from './syntheticHost';

async function expectNoSeriousAccessibilityViolations(page: Page) {
  const scan = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(scan.violations).toEqual([]);
}

async function expectNoDocumentOverflow(page: Page) {
  const overflow = await page.evaluate(() => ({
    width: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
    height: document.documentElement.clientHeight,
    scrollHeight: document.documentElement.scrollHeight,
  }));
  expect(overflow.scrollWidth).toBeLessThanOrEqual(overflow.width + 1);
  expect(overflow.scrollHeight).toBeGreaterThanOrEqual(overflow.height);
}

test('1024 by 768 workbench keeps navigation, gallery, and controls usable', async ({
  page,
}, testInfo) => {
  test.skip(testInfo.project.name !== 'chromium-desktop', 'Explicit medium viewport gate');
  await page.setViewportSize({ width: 1024, height: 768 });
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');

  await expect(page.getByRole('navigation', { name: '主导航' })).toBeVisible();
  await expect(page.getByRole('button', { name: '查看 IMG_0001.jpg' })).toBeVisible();
  await expect(page.getByRole('button', { name: '打开命令面板' })).toBeVisible();
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: '../docs/web-companion-refactor/evidence/accessibility/imageall-react-gallery-1024x768.png',
      animations: 'disabled',
    });
  }
  await expectNoDocumentOverflow(page);
  await expectNoSeriousAccessibilityViolations(page);
});

test('system, light, dark, reduced-motion, forced-colors, and enlarged text remain accessible', async ({
  page,
}, testInfo) => {
  test.skip(testInfo.project.name !== 'chromium-desktop', 'One desktop visual-mode gate');
  await page.emulateMedia({ colorScheme: 'dark' });
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await expect(page.getByRole('heading', { name: '图库', level: 2 })).toBeVisible();

  await page.keyboard.press('Control+K');
  await page
    .getByRole('dialog', { name: '命令面板' })
    .getByRole('button', { name: '使用浅色主题' })
    .click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await page.waitForTimeout(200);
  await expectNoSeriousAccessibilityViolations(page);

  await page.keyboard.press('Control+K');
  await page
    .getByRole('dialog', { name: '命令面板' })
    .getByRole('button', { name: '使用深色主题' })
    .click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.waitForTimeout(200);
  await expectNoSeriousAccessibilityViolations(page);

  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce', forcedColors: 'active' });
  const motionDuration = await page
    .getByRole('button', { name: '刷新图库' })
    .evaluate((element) => getComputedStyle(element).transitionDuration);
  expect(['0s', '0.001ms', '1e-06s']).toContain(motionDuration);
  await expectNoSeriousAccessibilityViolations(page);

  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce', forcedColors: 'none' });
  await page.evaluate(() => {
    document.documentElement.style.fontSize = '200%';
  });
  await expect(page.getByRole('heading', { name: '图库', level: 2 })).toBeVisible();
  await expect(page.getByRole('button', { name: '框选' })).toBeVisible();
  await expectNoDocumentOverflow(page);
  await expectNoSeriousAccessibilityViolations(page);

  const session = await page.context().newCDPSession(page);
  await session.send('Emulation.setPageScaleFactor', { pageScaleFactor: 2 });
  await expect(page.getByRole('button', { name: '打开命令面板' })).toBeVisible();
});
