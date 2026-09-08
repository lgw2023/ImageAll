import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import process from 'node:process';

import { expect } from '@playwright/test';

import { startSandbox } from './dev-sandbox-runtime.mjs';

let probeRequests = 0;
const probe = createServer((_request, response) => {
  probeRequests += 1;
  response.end('should never be reached');
});
await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
let sandbox;
try {
  sandbox = await startSandbox({ headless: true, port: 5174 });
  const { page, origin } = sandbox;
  await expect(page.getByRole('heading', { name: '全部照片', level: 2 })).toBeVisible();
  await expect(page.locator('#imageall-development-badge')).toBeVisible();
  await page.getByRole('button', { name: '收藏 IMG_0001.jpg' }).click();
  await expect(page.getByRole('button', { name: '取消收藏 IMG_0001.jpg' })).toBeVisible();
  await page.reload();
  await expect(page.getByRole('button', { name: '取消收藏 IMG_0001.jpg' })).toBeVisible();
  await page.getByRole('button', { name: '查看 IMG_0001.jpg' }).click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await page.getByRole('button', { name: '关闭照片详情' }).click();
  const unsupported = await page.evaluate(async () => (await fetch('/v1/not-implemented')).status);
  assert.equal(unsupported, 501);
  const outsideURL = `http://127.0.0.1:${probe.address().port}/v1/assets`;
  const blocked = await page.evaluate(async (url) => {
    try {
      await fetch(url);
      return false;
    } catch {
      return true;
    }
  }, outsideURL);
  assert.equal(blocked, true);
  assert.equal(probeRequests, 0);
  assert.equal((await fetch(`${origin}/v1/capabilities`)).status, 503);
  // The dev websocket remains usable for HMR while the API socket is synthetic.
  await expect.poll(() => sandbox.consoleMessages.includes('[vite] connected.')).toBe(true);
  const reloadedByVite = page.waitForEvent('load');
  sandbox.server.ws.send({ type: 'full-reload', path: '*' });
  await reloadedByVite;
  await expect(page.getByRole('button', { name: '取消收藏 IMG_0001.jpg' })).toBeVisible();
  await assert.rejects(startSandbox({ headless: true, port: 5174 }), /already in use/);
  await expect(page.getByRole('heading', { name: '全部照片', level: 2 })).toBeVisible();
  await page.screenshot({ path: 'test-results/dev-sandbox.png' });
  process.stdout.write(
    'PASS: interactive gallery, in-memory mutation, reload, preview, unknown API and external-host blocking.\n',
  );
} finally {
  await sandbox?.close();
  await new Promise((resolve, reject) =>
    probe.close((error) => (error ? reject(error) : resolve())),
  );
}
