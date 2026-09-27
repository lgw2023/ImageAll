import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { expect, test } from '@playwright/test';
import { assetIDs, installSyntheticAuthenticatedHost, sourceID } from './syntheticHost';

test('production UTI video plays, seeks, switches and reports unavailable formats', async ({
  page,
}) => {
  const root = mkdtempSync(join(tmpdir(), 'imageall-video-contract-'));
  try {
    const file = join(root, 'synthetic.mp4');
    execFileSync('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=160x90:rate=10',
      '-t',
      '3',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
      file,
    ]);
    const bytes = readFileSync(file);
    await installSyntheticAuthenticatedHost(page, { extraCapabilities: ['assetLocalSuggestions'] });
    let analysisCount = 0;
    await page.route(/\/v1\/assets\/[0-9a-f-]+\/local-suggestions$/i, (route) => {
      const request = route.request().postDataJSON() as { operationID: string; track: string };
      expect(request.track).toBe('standard');
      analysisCount += 1;
      return route.fulfill({
        json: {
          operationID: request.operationID,
          assetID: new URL(route.request().url()).pathname.split('/')[3],
          track: 'standard',
          state: 'results',
          suggestions: [],
          replayed: false,
        },
      });
    });
    let format = 'public.mpeg-4';
    let broken = false;
    let mediaRequests = 0;
    let cloudPreviewRequests = 0;
    page.on('request', (request) => {
      if (request.url().includes('cloud-preview')) cloudPreviewRequests += 1;
    });
    await page.route(/\/v1\/assets\/[0-9a-f-]+$/i, (route) =>
      route.fulfill({
        json: {
          assetID: new URL(route.request().url()).pathname.split('/').at(-1),
          sourceID,
          sourceName: 'Synthetic',
          fileName: 'Synthetic video',
          mediaType: format,
          availability: 'available',
          contentRevision: 1,
          acceptedTagCount: 0,
          rejectedTagCount: 0,
          durationMs: 3000,
          tags: [],
        },
      }),
    );
    await page.route(/\/v1\/assets\/[0-9a-f-]+\/media\?/, (route) => {
      mediaRequests += 1;
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
        body: bytes.subarray(start, end + 1),
        headers: {
          'accept-ranges': 'bytes',
          'content-length': String(end - start + 1),
          ...(range
            ? { 'content-range': `bytes ${String(start)}-${String(end)}/${String(bytes.length)}` }
            : {}),
        },
      });
    });
    await page.goto('gallery');
    await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).click();
    const player = page.getByLabel('视频播放');
    await expect(player).toBeVisible();
    await expect(page.getByRole('button', { name: '运行个人标签模型' })).toBeDisabled();
    await page.getByRole('button', { name: '运行标准场景模型' }).click();
    await expect(page.getByText('当前模型没有给出建议。')).toBeVisible();
    expect(analysisCount).toBe(1);
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
      node.currentTime = 2;
    });
    await expect
      .poll(() => player.evaluate((node: HTMLVideoElement) => node.currentTime))
      .toBeGreaterThanOrEqual(2);
    expect(mediaRequests).toBeGreaterThan(0);
    await page.getByRole('button', { name: '关闭照片详情' }).click();
    await expect(player).toHaveCount(0);
    format = 'com.apple.quicktime-movie';
    await page.getByRole('button', { name: '查看 IMG_0002.jpg' }).click();
    await expect(player).toHaveAttribute('src', new RegExp(assetIDs[1] ?? 'missing-synthetic-id'));
    await expect
      .poll(() => player.evaluate((node: HTMLVideoElement) => node.readyState))
      .toBeGreaterThan(1);
    await page.getByRole('button', { name: '关闭照片详情' }).click();
    broken = true;
    await page.getByRole('button', { name: '查看 IMG_0003.jpg' }).click();
    await expect(page.getByText('暂时无法播放视频')).toBeVisible();
    await expect(page.getByText(/视频原件仍在 iCloud/)).toBeVisible();
    expect(cloudPreviewRequests).toBe(0);
    broken = false;
    await page.getByRole('button', { name: '重试播放' }).click();
    await expect
      .poll(() => player.evaluate((node: HTMLVideoElement) => node.readyState))
      .toBeGreaterThan(1);
    await page.getByRole('button', { name: '关闭照片详情' }).click();
    format = 'vendor.unknown';
    const before = mediaRequests;
    await page.getByRole('button', { name: '查看 IMG_0004.jpg' }).click();
    await expect(page.getByText('当前无法显示预览')).toBeVisible();
    await expect(player).toHaveCount(0);
    expect(mediaRequests).toBe(before);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('older Host without video standard capability does not offer video analysis', async ({
  page,
}) => {
  await installSyntheticAuthenticatedHost(page, { extraCapabilities: ['assetLocalSuggestions'] });
  await page.route(/\/v1\/assets\/[0-9a-f-]+$/i, (route) =>
    route.fulfill({
      json: {
        assetID: assetIDs[0],
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
  let capabilityChecked = false;
  await page.route('**/v1/library-suggestions?*', (route) => {
    expect(new URL(route.request().url()).searchParams.get('mediaKind')).toBe('video');
    capabilityChecked = true;
    return route.fulfill({
      json: {
        mediaKind: 'video',
        service: { state: 'unavailable', serviceVersion: null, provider: null, modelID: null },
        standardAvailable: false,
        personalMode: 'unavailable',
        standardJob: null,
        personalJob: null,
      },
    });
  });
  await page.goto('gallery');
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).click();
  await expect.poll(() => capabilityChecked).toBe(true);
  await expect(page.getByRole('button', { name: '运行标准场景模型' })).toHaveCount(0);
});
