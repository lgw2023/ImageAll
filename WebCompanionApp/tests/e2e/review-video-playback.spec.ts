import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { expect, test } from '@playwright/test';
import { assetIDs, sourceID, tagIDs, installSyntheticAuthenticatedHost } from './syntheticHost';

test('video review plays and seeks, switches assets and stops on close without cloud preview', async ({
  page,
}) => {
  const root = mkdtempSync(join(tmpdir(), 'imageall-review-video-'));
  try {
    const file = join(root, 'clip.mp4');
    execFileSync('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=160x90:rate=10',
      '-t',
      '2',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
      file,
    ]);
    const bytes = readFileSync(file);
    await installSyntheticAuthenticatedHost(page);
    let cloudRequests = 0;
    let broken = false;
    page.on('request', (request) => {
      if (request.url().includes('cloud-preview')) cloudRequests += 1;
    });
    await page.route('**/v1/review/queue?*', (route) =>
      route.fulfill({
        json: {
          items: assetIDs.slice(0, 2).map((assetID, index) => ({
            assetID,
            fileName: `VIDEO_${String(index)}.mp4`,
            availability: 'available',
            contentRevision: 1,
            acceptedTagCount: 0,
            rejectedTagCount: 0,
            suggestionOrigin: 'standardModel',
            score: 0.9,
            width: 160,
            height: 90,
            favorite: null,
          })),
          nextCursor: null,
        },
      }),
    );
    await page.route(/\/v1\/assets\/[0-9a-f-]+$/i, (route) =>
      route.fulfill({
        json: {
          assetID: new URL(route.request().url()).pathname.split('/').at(-1),
          sourceID,
          sourceName: 'Synthetic',
          fileName: 'Video',
          mediaKind: 'video',
          mediaType: 'public.mpeg-4',
          availability: 'available',
          contentRevision: 1,
          acceptedTagCount: 0,
          rejectedTagCount: 0,
          tags: [],
        },
      }),
    );
    await page.route(/\/v1\/assets\/[0-9a-f-]+\/media\?/, (route) => {
      if (broken)
        return route.fulfill({
          status: 404,
          json: {
            code: 'notFound',
            message: 'fixture',
            mediaFailureReason: 'cloudVideoOriginalRequired',
          },
        });
      const range = /^bytes=(\d+)-(\d*)$/.exec(route.request().headers().range ?? '');
      const start = range ? Number(range[1]) : 0;
      const end = range?.[2] ? Math.min(Number(range[2]), bytes.length - 1) : bytes.length - 1;
      return route.fulfill({
        status: range ? 206 : 200,
        contentType: 'video/mp4',
        headers: {
          'Accept-Ranges': 'bytes',
          ...(range
            ? { 'Content-Range': `bytes ${String(start)}-${String(end)}/${String(bytes.length)}` }
            : {}),
        },
        body: bytes.subarray(start, end + 1),
      });
    });
    await page.goto(`review?mediaKind=video&tag=${tagIDs[0]}`);
    await expect(page.getByRole('heading', { name: '审查队列', level: 2 })).toBeVisible();
    await page.keyboard.press('Space');
    const player = page.getByLabel('审核视频播放');
    await expect(player).toBeVisible();
    await expect
      .poll(() => player.evaluate((node: HTMLVideoElement) => node.readyState))
      .toBeGreaterThan(1);
    await player.evaluate(async (node: HTMLVideoElement) => {
      node.muted = true;
      await node.play();
    });
    await expect
      .poll(() => player.evaluate((node: HTMLVideoElement) => node.currentTime))
      .toBeGreaterThan(0);
    await player.evaluate((node: HTMLVideoElement) => {
      node.pause();
      node.currentTime = 1;
    });
    await expect
      .poll(() => player.evaluate((node: HTMLVideoElement) => node.currentTime))
      .toBeGreaterThanOrEqual(1);
    const previous = await player.elementHandle();
    broken = true;
    await page.getByRole('button', { name: '下一条建议' }).click();
    await expect(page.getByText(/视频原件仍在 iCloud/)).toBeVisible();
    broken = false;
    await page.getByRole('button', { name: '重试播放' }).click();
    await expect(player).toHaveAttribute('src', new RegExp(assetIDs[1] ?? 'missing'));
    expect(
      await previous.evaluate((node: HTMLVideoElement) => node.paused && !node.getAttribute('src')),
    ).toBe(true);
    await page.getByRole('button', { name: '关闭单图审核' }).click();
    await expect(player).toHaveCount(0);
    expect(cloudRequests).toBe(0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
