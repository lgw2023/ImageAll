"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const baseURL = process.env.IMAGEALL_WEB_TEST_URL || "http://127.0.0.1:8799";
const resourceRoot = path.resolve(__dirname, "../ImageAll/Resources/WorldMap");
const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
};

let browser;

(async () => {
  browser = await chromium.launch({
    headless: true,
    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  });
  const context = await browser.newContext({ viewport: { width: 1_200, height: 760 } });
  const page = await context.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.route(`${baseURL}/world-map/**`, async (route) => {
    const requestURL = new URL(route.request().url());
    const relativePath = decodeURIComponent(requestURL.pathname.slice("/world-map/".length))
      || "index.html";
    const filePath = path.resolve(resourceRoot, relativePath);
    assert.ok(filePath.startsWith(`${resourceRoot}${path.sep}`), filePath);
    await route.fulfill({
      status: 200,
      contentType: contentTypes[path.extname(filePath)] || "application/octet-stream",
      body: fs.readFileSync(filePath),
    });
  });

  await page.goto(`${baseURL}/world-map/index.html`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(
    () => globalThis.ImageAllWorldMap?.rendererStatus().ready === true,
    null,
    { timeout: 15_000 }
  );
  await page.evaluate(() => {
    globalThis.ImageAllWorldMap.updateClusters({
      revision: 1,
      clusters: [
        {
          id: "shanghai", longitude: 121.4737, latitude: 31.2304,
          photoCount: 42, gpsCount: 30, tagCount: 12, displayName: "上海",
        },
        {
          id: "paris", longitude: 2.3522, latitude: 48.8566,
          photoCount: 30, gpsCount: 20, tagCount: 10, displayName: "巴黎",
        },
        {
          id: "new-york", longitude: -74.006, latitude: 40.7128,
          photoCount: 20, gpsCount: 18, tagCount: 2, displayName: "纽约",
        },
      ],
    });
  });

  const navigator = page.locator("#cluster-navigator");
  const current = page.locator("#cluster-navigator-current");
  await navigator.waitFor({ timeout: 3_000 });
  assert.equal(await navigator.getAttribute("aria-label"), "当前视口照片塔");
  assert.match(await current.innerText(), /上海/);
  assert.match(await current.innerText(), /1 \/ 3/);
  assert.match(await current.getAttribute("aria-label"), /上海.*42 张照片.*第 1 个，共 3 个/);
  assert.equal(await page.locator("#cluster-navigator-previous").isDisabled(), true);
  assert.equal(await page.locator("#cluster-navigator-next").isEnabled(), true);

  await current.focus();
  await page.keyboard.press("ArrowRight");
  assert.match(await current.innerText(), /巴黎/);
  assert.equal(await page.locator("#cluster-navigator-previous").isEnabled(), true);
  assert.equal(await page.evaluate(() => ImageAllWorldMap.snapshotState().selectedClusterID), null);
  assert.equal(await page.evaluate(() => document.activeElement?.id), "cluster-navigator-current");
  await page.keyboard.press("End");
  assert.match(await current.innerText(), /纽约/);
  await page.keyboard.press("Home");
  assert.match(await current.innerText(), /上海/);
  await page.keyboard.press("PageDown");
  assert.match(await current.innerText(), /纽约/);
  await page.keyboard.press("Enter");
  assert.equal(
    await page.evaluate(() => ImageAllWorldMap.snapshotState().selectedClusterID),
    "new-york"
  );
  assert.equal(await page.locator("#cluster-navigator-status").getAttribute("aria-live"), "polite");
  await page.screenshot({ path: "/tmp/imageall-world-map-keyboard-navigator.png" });

  await page.evaluate(() => {
    globalThis.ImageAllWorldMap.updateClusters({
      revision: 2,
      clusters: [{
        id: "shanghai", longitude: 121.4737, latitude: 31.2304,
        photoCount: 42, gpsCount: 30, tagCount: 12, displayName: "上海",
      }],
    });
  });
  assert.match(await current.innerText(), /上海/);
  assert.equal(await page.evaluate(() => ImageAllWorldMap.snapshotState().selectedClusterID), null);
  assert.equal(await page.locator("#cluster-navigator-previous").isDisabled(), true);
  assert.equal(await page.locator("#cluster-navigator-next").isDisabled(), true);

  await page.evaluate(() => ImageAllWorldMap.updateClusters({ revision: 3, clusters: [] }));
  assert.match(await current.innerText(), /当前视口没有照片塔/);
  assert.equal(await current.isDisabled(), true);
  assert.deepEqual(pageErrors, []);
  assert.deepEqual(consoleErrors, []);
  await context.close();
  console.log("world-map keyboard navigator browser flow passed");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}).finally(async () => {
  await browser?.close();
});
