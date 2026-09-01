import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

import { installSyntheticAuthenticatedHost } from './syntheticHost';

const reviewArchiveSourceID = '8de47499-1ca0-4cc2-84bc-a881018e8b0c';

function reviewSourceIDs(url: string): string[] | null {
  const parameters = new URL(url).searchParams;
  if (!parameters.has('sourceIDs')) return null;
  const value = parameters.get('sourceIDs') ?? '';
  return value ? value.split(',') : [];
}

function reviewQueueItem(index: number) {
  return {
    assetID: `10000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
    fileName: `REVIEW_${String(index + 1).padStart(3, '0')}.jpg`,
    availability: 'available',
    contentRevision: 1,
    acceptedTagCount: 0,
    rejectedTagCount: 0,
    suggestionOrigin: index % 2 ? 'standardModel' : 'featurePrint',
    score: 0.91 - index * 0.02,
    width: 1600,
    height: 1200,
    favorite: null,
  };
}

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

test('review queue supports the Mac-style continuous single-photo workflow', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.goto('review');
  await page.getByRole('link', { name: '开始审查' }).click();
  await expect(page.getByRole('heading', { name: '审查队列', level: 2 })).toBeVisible();

  await page.keyboard.press('Space');
  const reviewer = page.getByRole('dialog', { name: '单图审核' });
  await expect(reviewer).toBeVisible();
  await expect(reviewer.getByText('REVIEW_001.jpg', { exact: true })).toBeVisible();

  await page.keyboard.press('u');
  await expect(reviewer.getByText('REVIEW_002.jpg', { exact: true })).toBeVisible();
  await expect(page.getByText('REVIEW_001.jpg', { exact: true })).toBeVisible();
  await expect(reviewer.locator('.review-single-photo-feedback')).toContainText('稍后处理');

  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/curation/imageall-react-review-single-photo-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }

  const decisionRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/review/decisions/batch' &&
      request.method() === 'POST',
  );
  await page.keyboard.press('p');
  expect((await decisionRequest).postDataJSON()).toMatchObject({
    assetIDs: ['10000000-0000-4000-8000-000000000002'],
    action: 'accept',
  });
  await expect(reviewer.getByText('REVIEW_003.jpg', { exact: true })).toBeVisible();
  await expect(reviewer.getByRole('status')).toContainText('已处理 1 项建议');

  await page.keyboard.press('Escape');
  await expect(reviewer).toBeHidden();
  await expect(page.getByText('REVIEW_002.jpg', { exact: true })).toBeHidden();
  await expect(page.locator('.review-card[aria-current="true"]')).toContainText('REVIEW_003.jpg');
});

test('review single-photo explicitly recovers an iCloud preview without losing queue position', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page, {
    extraCapabilities: ['previews', 'cloudPreviewLifecycle'],
  });
  const cloudAssetID = reviewQueueItem(0).assetID;
  const localAssetID = reviewQueueItem(1).assetID;
  const operationIDs: string[] = [];
  let activeOperationID: string | null = null;
  let cancelCount = 0;
  let allowCompletion = false;

  await page.route(/\/v1\/assets\/[0-9a-f-]+\/preview\?.*/i, (route) => {
    const assetID = new URL(route.request().url()).pathname.split('/').at(-2);
    if (assetID === cloudAssetID && !allowCompletion) {
      return route.fulfill({
        status: 409,
        contentType: 'application/json',
        json: { code: 'conflict', message: 'cloud preview required' },
      });
    }
    return route.fulfill({
      status: 200,
      contentType: 'image/svg+xml',
      body: `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480"><rect width="640" height="480" fill="${assetID === localAssetID ? '#7194a9' : '#d9ff43'}"/></svg>`,
    });
  });
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/cloud-preview-requests\/cancel$/i, (route) => {
    cancelCount += 1;
    const body = route.request().postDataJSON() as { operationID: string };
    activeOperationID = null;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: body.operationID,
        assetID: cloudAssetID,
        phase: 'cancelled',
        progress: 0.42,
        message: 'iCloud preview download cancelled',
        updatedAtMs: 1_788_200_000_100,
      },
    });
  });
  await page.route(/\/v1\/assets\/[0-9a-f-]+\/cloud-preview-requests$/i, (route) => {
    if (route.request().method() === 'POST') {
      const body = route.request().postDataJSON() as { operationID: string };
      operationIDs.push(body.operationID);
      activeOperationID = body.operationID;
      return route.fulfill({
        status: 202,
        contentType: 'application/json',
        json: {
          operationID: body.operationID,
          assetID: cloudAssetID,
          phase: 'downloading',
          progress: 0.42,
          message: null,
          updatedAtMs: 1_788_200_000_000,
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
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        operationID: activeOperationID,
        assetID: cloudAssetID,
        phase: allowCompletion ? 'completed' : 'downloading',
        progress: allowCompletion ? 1 : 0.42,
        message: allowCompletion ? 'iCloud preview downloaded' : null,
        updatedAtMs: 1_788_200_000_200,
      },
    });
  });

  await page.goto('review');
  await page.getByRole('link', { name: '开始审查' }).click();
  await page.keyboard.press('Space');
  const reviewer = page.getByRole('dialog', { name: '单图审核' });
  await expect(reviewer.getByRole('button', { name: '从 iCloud 获取预览' })).toBeVisible();
  expect(operationIDs).toHaveLength(0);

  await reviewer.getByRole('button', { name: '从 iCloud 获取预览' }).click();
  await expect(reviewer.getByText('42%')).toBeVisible();
  expect(operationIDs).toHaveLength(1);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/curation/imageall-react-review-cloud-preview-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }

  const cancelled = page.waitForRequest(
    (request) =>
      request.method() === 'POST' &&
      new URL(request.url()).pathname.endsWith('/cloud-preview-requests/cancel'),
  );
  await reviewer.getByRole('button', { name: '下一条建议' }).click();
  await cancelled;
  await expect(reviewer.getByRole('img', { name: 'REVIEW_002.jpg' })).toBeVisible();
  expect(cancelCount).toBe(1);

  await reviewer.getByRole('button', { name: '上一条建议' }).click();
  await expect(reviewer.getByRole('button', { name: '从 iCloud 获取预览' })).toBeVisible();
  await reviewer.getByRole('button', { name: '从 iCloud 获取预览' }).click();
  await expect(reviewer.getByText('42%')).toBeVisible();
  expect(operationIDs).toHaveLength(2);
  expect(operationIDs[1]).not.toBe(operationIDs[0]);

  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
  allowCompletion = true;
  await expect(reviewer.getByRole('img', { name: 'REVIEW_001.jpg' })).toBeVisible();
  await expect(reviewer.getByText('REVIEW_001.jpg', { exact: true })).toBeVisible();
  await expect(page.locator('.review-card[aria-current="true"]')).toContainText('REVIEW_001.jpg');
});

test('review source scope stays authoritative across overview, queue, empty scope, and back', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  await page.route('**/v1/sources', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: [
        {
          id: '9de47499-1ca0-4cc2-84bc-a881018e8b0c',
          kind: 'folder',
          displayName: 'Synthetic Library',
          state: 'active',
        },
        {
          id: reviewArchiveSourceID,
          kind: 'folder',
          displayName: 'Archive Library',
          state: 'active',
        },
      ],
    }),
  );
  await page.route('**/v1/review/overview?*', (route) => {
    const sourceIDs = reviewSourceIDs(route.request().url());
    const pendingCount = sourceIDs === null ? 8 : sourceIDs.length === 0 ? 0 : 4;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        totalPendingSuggestionCount: pendingCount,
        tags: [
          {
            id: '10000000-0000-4000-8000-000000000001',
            displayName: '风景',
            acceptedSampleCount: 12,
            rejectedSampleCount: 5,
            pendingSuggestionCount: pendingCount,
            pendingSuggestionCounts: {
              featurePrint: pendingCount,
              standardModel: 0,
              personalModel: 0,
              personalAdamW: 0,
            },
            taskStatus: 'ready',
            checkedCount: 120,
            totalCount: 120,
            skippedCount: 0,
            missingPositiveCount: 0,
            missingNegativeCount: 0,
            canGenerate: true,
            canUpdate: true,
            canGeneratePersonalModel: false,
            canReview: pendingCount > 0,
            canPause: false,
            canResume: false,
            canCancel: false,
            activeJobID: null,
          },
        ],
      },
    });
  });
  await page.route('**/v1/review/queue?*', (route) => {
    const sourceIDs = reviewSourceIDs(route.request().url());
    const itemCount = sourceIDs === null ? 8 : sourceIDs.length === 0 ? 0 : 4;
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      json: {
        items: Array.from({ length: itemCount }, (_, index) => reviewQueueItem(index)),
        nextCursor: null,
      },
    });
  });

  await page.goto('review');
  await expect(page.getByRole('heading', { name: '审查', level: 2 })).toBeVisible();
  await expect(page.getByRole('button', { name: /全部 2 个来源/ })).toBeVisible();

  await page.getByRole('button', { name: /全部 2 个来源/ }).click();
  const narrowedOverviewRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/review/overview' &&
      reviewSourceIDs(request.url())?.length === 1,
  );
  await page.getByRole('checkbox', { name: 'Archive Library' }).click();
  expect(reviewSourceIDs((await narrowedOverviewRequest).url())).toEqual([
    '9de47499-1ca0-4cc2-84bc-a881018e8b0c',
  ]);
  await expect(page).toHaveURL(/source=9de47499-1ca0-4cc2-84bc-a881018e8b0c/);
  await expect(page.getByText('4 待处理')).toBeVisible();

  const narrowedQueueRequest = page.waitForRequest(
    (request) => new URL(request.url()).pathname === '/v1/review/queue',
  );
  await page.getByRole('link', { name: '开始审查' }).click();
  expect(reviewSourceIDs((await narrowedQueueRequest).url())).toEqual([
    '9de47499-1ca0-4cc2-84bc-a881018e8b0c',
  ]);
  await expect(page.getByText('4 项已载入')).toBeVisible();
  await expect(page.getByRole('button', { name: /仅 Synthetic Library/ })).toBeVisible();

  await page.getByRole('button', { name: /仅 Synthetic Library/ }).click();
  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/curation/imageall-react-review-source-scope-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
  const emptyQueueRequest = page.waitForRequest(
    (request) =>
      new URL(request.url()).pathname === '/v1/review/queue' &&
      new URL(request.url()).searchParams.has('sourceIDs') &&
      reviewSourceIDs(request.url())?.length === 0,
  );
  await page.getByRole('checkbox', { name: 'Synthetic Library' }).click();
  expect(reviewSourceIDs((await emptyQueueRequest).url())).toEqual([]);
  await expect(page).toHaveURL(/sourceScope=none/);
  await expect(page.getByText('当前队列已处理完')).toBeVisible();

  await page.getByRole('link', { name: '审查概览' }).click();
  await expect(page).toHaveURL(/review\?sourceScope=none/);
  await expect(page.getByText('0 待处理')).toBeVisible();
});

test('review view controls preserve queue context while changing density and cached aspect', async ({
  page,
}, testInfo) => {
  await installSyntheticAuthenticatedHost(page);
  let queueRequestCount = 0;
  page.on('request', (request) => {
    if (new URL(request.url()).pathname === '/v1/review/queue') queueRequestCount += 1;
  });

  await page.goto('review');
  await page.getByRole('link', { name: '开始审查' }).click();
  const grid = page.getByRole('list', { name: '待审查照片' });
  await expect(grid).toBeVisible();
  await page.getByText('REVIEW_003.jpg', { exact: true }).click();
  await expect(page.locator('.review-card[aria-current="true"]')).toContainText('REVIEW_003.jpg');

  const density = page.getByRole('combobox', { name: '缩略图大小' });
  await expect(density).toHaveValue('3');
  const standardColumns = await grid.evaluate(
    (element) => getComputedStyle(element).gridTemplateColumns.split(' ').length,
  );
  await density.selectOption('1');
  await expect(page).toHaveURL(/density=1/);
  await expect(grid).toHaveAttribute('data-density', '1');
  const fineColumns = await grid.evaluate(
    (element) => getComputedStyle(element).gridTemplateColumns.split(' ').length,
  );
  expect(fineColumns).toBeGreaterThan(standardColumns);
  await expect(page.locator('.review-card[aria-current="true"]')).toContainText('REVIEW_003.jpg');

  const squareThumbnail = page.locator('.review-card img').first();
  await expect(squareThumbnail).not.toHaveAttribute('src', /aspect=original/);
  await page.getByRole('button', { name: '缩略图比例：正方形' }).click();
  await expect(page).toHaveURL(/aspect=original/);
  await expect(grid).toHaveAttribute('data-aspect', 'original');
  await expect(squareThumbnail).toHaveAttribute('src', /aspect=original/);
  await expect(page.locator('.review-card[aria-current="true"]')).toContainText('REVIEW_003.jpg');
  expect(queueRequestCount).toBe(1);

  await page.reload();
  await expect(density).toHaveValue('1');
  await expect(grid).toHaveAttribute('data-aspect', 'original');
  await expect(page.locator('.review-card img').first()).toHaveAttribute('src', /aspect=original/);

  const accessibility = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(accessibility.violations).toEqual([]);
  if (process.env.IMAGEALL_CAPTURE_EVIDENCE === '1') {
    await page.screenshot({
      path: `../docs/web-companion-refactor/evidence/curation/imageall-react-review-view-controls-${testInfo.project.name}.png`,
      animations: 'disabled',
    });
  }
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
