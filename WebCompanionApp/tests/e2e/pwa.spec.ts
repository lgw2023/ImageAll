import { expect, test } from '@playwright/test';

test.use({ serviceWorkers: 'allow' });

import { installSyntheticAuthenticatedHost } from './syntheticHost';

test('PWA caches only the public shell, upgrades cleanly, and exposes no private offline data', async ({
  context,
  page,
}, testInfo) => {
  test.skip(testInfo.project.name !== 'chromium-desktop', 'One Chromium service-worker gate');
  await installSyntheticAuthenticatedHost(page);
  await page.goto('gallery');
  await expect(page.getByRole('button', { name: '查看 IMG_0001.jpg' })).toBeVisible();
  await expect
    .poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller)))
    .toBe(true);

  const manifest = await page.evaluate(async () => {
    const response = await fetch('/web-v2/manifest.webmanifest');
    return (await response.json()) as Record<string, unknown>;
  });
  expect(manifest).toMatchObject({
    name: 'ImageAll Web Companion',
    short_name: 'ImageAll',
    start_url: '/web-v2/gallery',
    scope: '/web-v2/',
    display: 'standalone',
    background_color: '#11110f',
    theme_color: '#11110f',
  });
  expect(Array.isArray(manifest.icons)).toBe(true);

  const cachedURLs = await page.evaluate(async () => {
    const keys = await caches.keys();
    const urls: string[] = [];
    for (const key of keys.filter((candidate) => candidate.startsWith('imageall-web-v2-shell-'))) {
      const cache = await caches.open(key);
      urls.push(...(await cache.keys()).map((request) => new URL(request.url).pathname));
    }
    return urls;
  });
  expect(cachedURLs).toContain('/web-v2/index.html');
  expect(cachedURLs.some((path) => path.startsWith('/v1/'))).toBe(false);
  expect(
    cachedURLs.some((path) => /\/assets\/[0-9a-f-]+\/(thumbnail|preview|media)/i.test(path)),
  ).toBe(false);

  await page.evaluate(async () => {
    await caches.open('imageall-web-v2-shell-obsolete-test');
    await navigator.serviceWorker.register('/web-v2/service-worker.js?upgrade=1', {
      scope: '/',
      updateViaCache: 'none',
    });
  });
  await expect
    .poll(() =>
      page.evaluate(
        async () => !(await caches.keys()).includes('imageall-web-v2-shell-obsolete-test'),
      ),
    )
    .toBe(true);
  await expect
    .poll(() =>
      page.evaluate(() => navigator.serviceWorker.controller?.scriptURL.includes('upgrade=1')),
    )
    .toBe(true);

  const publicEntrypoints = await page.evaluate(() => {
    const script = document.querySelector<HTMLScriptElement>('script[type="module"]');
    const stylesheet = document.querySelector<HTMLLinkElement>('link[rel="stylesheet"]');
    if (!script?.src || !stylesheet?.href) throw new Error('public entrypoints missing');
    return [new URL(script.src).pathname, new URL(stylesheet.href).pathname];
  });
  const cachedEntrypointSizes = await page.evaluate(async (paths) => {
    const keys = await caches.keys();
    return Promise.all(
      paths.map(async (path) => {
        for (const key of keys) {
          const response = await (await caches.open(key)).match(path);
          if (response) return (await response.arrayBuffer()).byteLength;
        }
        return 0;
      }),
    );
  }, publicEntrypoints);
  expect(cachedEntrypointSizes.every((size) => size > 1_000)).toBe(true);

  await page.unrouteAll({ behavior: 'wait' });
  await context.setOffline(true);
  try {
    const offlineEntrypointSizes = await page.evaluate(
      async (paths) =>
        Promise.all(
          paths.map(async (path) => (await (await fetch(path)).arrayBuffer()).byteLength),
        ),
      publicEntrypoints,
    );
    expect(offlineEntrypointSizes.every((size) => size > 1_000)).toBe(true);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await expect(page.getByRole('heading', { name: '连接你的 Mac 照片工作台' })).toBeVisible();
    await expect(page.getByText('暂时无法连接 Mac。')).toBeVisible();
    await expect(page.getByText('IMG_0001.jpg')).toBeHidden();
  } finally {
    await context.setOffline(false);
  }
});
