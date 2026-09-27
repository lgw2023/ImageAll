import { expect, test } from '@playwright/test';
import { installSyntheticAuthenticatedHost, tagIDs } from './syntheticHost';

test('review media scope reaches overview, model commands and queue and survives reload', async ({ page }) => {
  await installSyntheticAuthenticatedHost(page);
  const mediaRequests: { path: string; kind: string | null }[] = [];
  page.on('request', (request) => {
    const url = new URL(request.url());
    if (['/v1/review/overview', '/v1/review/queue', '/v1/tag-library-suggestions'].includes(url.pathname)) {
      mediaRequests.push({ path: url.pathname, kind: url.searchParams.get('mediaKind') });
    }
  });
  await page.goto('review');
  await page.getByLabel('审核媒体范围').selectOption('video');
  await expect(page).toHaveURL(/mediaKind=video/);
  await expect.poll(() => mediaRequests.some((item) => item.path === '/v1/review/overview' && item.kind === 'video')).toBe(true);
  await expect.poll(() => mediaRequests.some((item) => item.path === '/v1/tag-library-suggestions' && item.kind === 'video')).toBe(true);
  const card = page.getByRole('article').filter({ hasText: '风景' });
  await card.getByText('调整门槛与生成', { exact: true }).click();
  const launched = page.waitForRequest((request) => new URL(request.url()).pathname === '/v1/training/launch' && request.method() === 'POST');
  await card.getByRole('button', { name: '更新特征建议' }).click();
  expect((await launched).postDataJSON()).toMatchObject({ mediaKind: 'video', tagIDs: [tagIDs[0]] });
  await card.getByRole('link', { name: '开始审查' }).click();
  await expect(page).toHaveURL(/mediaKind=video/);
  await expect.poll(() => mediaRequests.some((item) => item.path === '/v1/review/queue' && item.kind === 'video')).toBe(true);
  await page.reload();
  await expect(page.getByLabel('审核媒体范围')).toHaveValue('video');
  await page.getByLabel('审核媒体范围').selectOption('image');
  await expect.poll(() => mediaRequests.some((item) => item.path === '/v1/review/queue' && item.kind === 'image')).toBe(true);
});
