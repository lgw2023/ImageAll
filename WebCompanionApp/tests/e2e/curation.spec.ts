import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { installSyntheticAuthenticatedHost } from './syntheticHost';

test('gallery overview exposes Host statistics and routes into filtered gallery', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery/overview');

  await expect(page.getByRole('heading', { name: '图库概览', level: 2 })).toBeVisible();
  await expect(
    page.getByRole('article').filter({ hasText: '媒体总数' }).getByText('120', { exact: true }),
  ).toBeVisible();
  await expect(page.locator('a.data-row[href*="media=image"]')).toBeVisible();
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/curation/imageall-react-overview-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
});

test('review queue applies an authoritative decision and supports undo', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('review');

  await expect(page.getByRole('heading', { name: '审查', level: 2 })).toBeVisible();
  await expect(page.getByText('8 待处理')).toBeVisible();
  await page.getByRole('link', { name: '开始审查' }).click();
  await expect(page.getByRole('heading', { name: '审查队列', level: 2 })).toBeVisible();
  await expect(page.getByText('REVIEW_001.jpg', { exact: true })).toBeVisible();
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/curation/imageall-react-review-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }

  await page.getByRole('button', { name: '接受 REVIEW_001.jpg' }).click();
  await expect(page.getByText('已处理 1 项建议。')).toBeVisible();
  await expect(page.getByText('REVIEW_001.jpg', { exact: true })).toBeHidden();
  await page.getByRole('button', { name: '撤销' }).click();
  await expect(page.getByText('已撤销并恢复 1 项。')).toBeVisible();
  await expect(page.getByText('REVIEW_001.jpg', { exact: true })).toBeVisible();

  await page.getByLabel('选择 REVIEW_001.jpg').check();
  await page.getByLabel('选择 REVIEW_002.jpg').check();
  await page
    .getByRole('region', { name: '审查批量操作' })
    .getByRole('button', { name: '接受', exact: true })
    .click();
  await expect(page.getByText('已处理 2 项建议。')).toBeVisible();
  await page.getByRole('button', { name: '撤销' }).click();
  await expect(page.getByText('已撤销并恢复 2 项。')).toBeVisible();

  await page.keyboard.press('a');
  await expect(page.getByText('已处理 1 项建议。')).toBeVisible();

  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
});

test('tag library creates a group and moves a renamed tag through Host mutations', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('tags');

  await expect(page.getByRole('heading', { name: '标签库', level: 2 })).toBeVisible();
  await expect(page.getByRole('heading', { name: '人物与地点' })).toBeVisible();
  await page.getByPlaceholder('新分组名称').fill('旅行主题');
  await page.getByRole('button', { name: '创建分组' }).click();
  await expect(page.getByRole('heading', { name: '旅行主题' })).toBeVisible();

  await page.getByRole('button', { name: '编辑' }).first().click();
  await page.getByLabel('名称', { exact: true }).fill('自然风景');
  await page.getByRole('combobox').selectOption({ label: '旅行主题' });
  await page.getByRole('button', { name: '保存' }).click();
  await expect(page.getByText('自然风景', { exact: true })).toBeVisible();
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/curation/imageall-react-tags-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }

  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
});

test('review overview explains a Host failure and recovers on retry', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route(
    '**/v1/review/overview?*',
    (route) =>
      route.fulfill({
        status: 503,
        contentType: 'application/json',
        json: { message: '审查服务暂时不可用', retryable: true },
      }),
    { times: 2 },
  );
  await page.goto('review');
  await expect(page.getByRole('alert')).toContainText('审查服务暂时不可用');
  await page.getByRole('button', { name: '重试' }).click();
  await expect(page.getByRole('heading', { name: '审查', level: 2 })).toBeVisible();
});
