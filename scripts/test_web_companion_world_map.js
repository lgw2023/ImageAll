"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

const baseURL = process.env.IMAGEALL_WEB_TEST_URL || "http://127.0.0.1:8799";
const assetID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb";
const folderSourceID = "cccccccc-1111-2222-3333-cccccccccccc";
const photosSourceID = "dddddddd-1111-2222-3333-dddddddddddd";
const placeTagID = "abababab-1111-2222-3333-abababababab";
const selectionQuery = {
  cellDegrees: 0.25,
  longitudeBucket: 1205,
  latitudeBucket: 485,
  bounds: { west: 118, south: 30, east: 123, north: 33 },
  maximumAssets: 36,
};
const cluster = {
  id: "shanghai",
  longitude: 121.47,
  latitude: 31.23,
  photoCount: 42,
  gpsCount: 30,
  tagCount: 12,
  displayName: "上海",
  selectionQuery,
};
const onePixelPNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64"
);

function json(route, body, status = 200) {
  return route.fulfill({
    status,
    contentType: "application/json",
    body: JSON.stringify(body),
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

let browser;

(async () => {
  browser = await chromium.launch({
    headless: true,
    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 960 },
    serviceWorkers: "block",
  });
  await context.addInitScript(() => {
    class QuietWebSocket extends EventTarget {
      send() {}
      close() {}
    }
    Object.defineProperty(globalThis, "WebSocket", { value: QuietWebSocket });
  });

  const page = await context.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  let snapshotRequestCount = 0;
  let placeTagSnapshotRequestCount = 0;
  let locationBackfillRequestCount = 0;
  const locationBackfillCommands = [];
  let folderPhase = "ready";
  let photosPhase = "running";
  let placeTagStatus = "unresolved";
  let confirmedPlaceID = null;
  const placeTagCommands = [];
  const favoriteMutations = [];
  let favoriteState = false;
  const worldMapGalleryRequests = [];
  let selectionShouldFail = false;
  let selectionRequestCount = 0;
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await page.route(`${baseURL}/world-map/index.html`, (route) => route.fulfill({
    status: 200,
    contentType: "text/html; charset=utf-8",
    body: `<!doctype html><html><body style="margin:0;background:#e9e3d8">
      <button id="syntheticCluster" hidden>上海照片塔</button>
      <script>
        const button = document.getElementById("syntheticCluster");
        globalThis.ImageAllWorldMap = {
          updateClusters(payload) {
            button.hidden = !(payload.clusters || []).some((item) => item.id === "shanghai");
          },
          restoreSelection(clusterID) { button.dataset.selected = clusterID || ""; },
          rendererStatus() { return { ready: true, webgl2Available: true }; }
        };
        button.addEventListener("click", () => parent.postMessage({
          type: "imageall-world-map-event",
          payload: { type: "clusterClicked", clusterID: "shanghai" }
        }, location.origin));
        parent.postMessage({
          type: "imageall-world-map-event",
          payload: { type: "ready", webgl2Available: true }
        }, location.origin);
        parent.postMessage({
          type: "imageall-world-map-event",
          payload: { type: "cameraChanged", viewport: {
            west: 118, south: 30, east: 123, north: 33,
            centerLongitude: 121, centerLatitude: 31, zoom: 6, bearing: 0, pitch: 42
          } }
        }, location.origin);
      <\/script></body></html>`,
  }));

  await page.route(`${baseURL}/web/session`, (route) => json(route, {
    authenticated: true,
    authMode: "account",
    username: "test",
  }));
  await page.route(`${baseURL}/v1/capabilities`, (route) => json(route, {
    protocolVersion: 1,
    hostID: "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa",
    hostDisplayName: "Synthetic Mac",
    hostAppVersion: "test",
    capabilities: ["favorites"],
  }));
  await page.route(`${baseURL}/v1/sources`, (route) => json(route, []));
  await page.route(`${baseURL}/v1/tags`, (route) => json(route, []));
  await page.route(`${baseURL}/v1/tag-groups`, (route) => json(route, []));
  await page.route(`${baseURL}/v1/jobs`, (route) => json(route, []));
  await page.route(`${baseURL}/v1/embedding-preparation**`, (route) => json(route, {
    mediaKind: "image", isAvailable: true, activities: [],
  }));
  await page.route(`${baseURL}/v1/sample-suggestions**`, (route) => json(route, {
    mediaKind: "image", isAvailable: true, maximumSampleCount: 500, activities: [],
  }));
  await page.route(`${baseURL}/v1/tag-library-suggestions**`, (route) => json(route, {
    mediaKind: "image", maximumPendingCount: 500,
    personalCentroidAvailable: false, personalAdamWAvailable: false,
    tags: [], activities: [],
  }));
  await page.route(
    new RegExp(`/v1/assets/${assetID}/(thumbnail|preview)(\\?.*)?$`),
    (route) => route.fulfill({ status: 200, contentType: "image/png", body: onePixelPNG })
  );
  await page.route(`${baseURL}/v1/assets?**`, (route) => {
    const requestURL = new URL(route.request().url());
    const query = requestURL.searchParams;
    if (query.has("worldMapCellDegrees")) {
      worldMapGalleryRequests.push(Object.fromEntries(query.entries()));
      assert.equal(query.get("worldMapCellDegrees"), "0.25");
      assert.equal(query.get("worldMapLongitudeBucket"), "1205");
      assert.equal(query.get("worldMapLatitudeBucket"), "485");
      assert.equal(query.get("worldMapMaximumAssets"), "36");
      assert.equal(query.get("worldMapWest"), "118");
      assert.equal(query.get("worldMapSouth"), "30");
      assert.equal(query.get("worldMapEast"), "123");
      assert.equal(query.get("worldMapNorth"), "33");
      assert.equal(query.get("mediaKinds"), "image");
      return json(route, {
        items: [{
          id: assetID,
          sourceID: photosSourceID,
          sourceName: "Apple Photos",
          fileName: "IMG_0001.HEIC",
          mediaType: "public.heic",
          availability: "available",
          contentRevision: 7,
          acceptedTagCount: 1,
          rejectedTagCount: 0,
          mediaCreatedAtMs: 1_700_000_000_000,
          width: 4032,
          height: 3024,
          favorite: {
            assetID,
            isFavorite: favoriteState,
            photosObservedValue: favoriteState,
            syncStatus: "synced",
            lastErrorCode: null,
          },
        }],
        nextCursor: null,
      });
    }
    return json(route, { items: [], nextCursor: null });
  });
  await page.route(`${baseURL}/v1/world-map/snapshot**`, (route) => {
    snapshotRequestCount += 1;
    return json(route, {
      clusters: [cluster],
      eligiblePhotoCount: 100,
      locatedPhotoCount: 70,
      unlocatedPhotoCount: 30,
    });
  });
  await page.route(`${baseURL}/v1/world-map/selection`, async (route) => {
    selectionRequestCount += 1;
    const requestBody = route.request().postDataJSON();
    assert.deepEqual(requestBody.query, selectionQuery);
    if (selectionShouldFail) {
      return json(route, {
        code: "internalError",
        message: "synthetic place selection failure",
      }, 500);
    }
    return json(route, {
      assets: [{
        id: assetID,
        fileName: "IMG_0001.HEIC",
        availability: "available",
        contentRevision: 7,
        favorite: {
          assetID,
          isFavorite: favoriteState,
          photosObservedValue: favoriteState,
          syncStatus: "synced",
          lastErrorCode: null,
        },
      }],
      totalPhotoCount: 42,
    });
  });
  await page.route(`${baseURL}/v1/favorites`, (route) => {
    const body = route.request().postDataJSON();
    favoriteMutations.push(body);
    assert.deepEqual(body.assetIDs, [assetID]);
    favoriteState = body.isFavorite;
    return json(route, {
      operationID: body.operationID,
      changedCount: 1,
      localOnlyCount: 0,
      syncedCount: 1,
      pendingCount: 0,
      failedCount: 0,
      states: [{
        assetID,
        isFavorite: favoriteState,
        photosObservedValue: favoriteState,
        syncStatus: "synced",
        lastErrorCode: null,
      }],
      replayed: false,
    });
  });
  const locationBackfillSnapshots = () => [{
    sourceID: folderSourceID,
    sourceKind: "folder",
    sourceDisplayName: "Synthetic Folder",
    sourceState: "active",
    phase: folderPhase,
    totalPhotoCount: 120,
    inspectedPhotoCount: folderPhase === "completed" ? 120 : (folderPhase === "ready" ? 40 : 64),
    locatedPhotoCount: folderPhase === "completed" ? 88 : 27,
    activeJobID: folderPhase === "running" ? "eeeeeeee-1111-2222-3333-eeeeeeeeeeee" : null,
    scanProgress: folderPhase === "running"
      ? { completedUnitCount: 65, totalUnitCount: 120 }
      : null,
    canStart: ["ready", "cancelled", "retryableFailed", "terminalFailed"].includes(folderPhase),
    canCancel: folderPhase === "running",
  }, {
    sourceID: photosSourceID,
    sourceKind: "photos",
    sourceDisplayName: "Apple Photos",
    sourceState: "active",
    phase: photosPhase,
    totalPhotoCount: 80,
    inspectedPhotoCount: 31,
    locatedPhotoCount: 20,
    activeJobID: ["running", "cancelling"].includes(photosPhase)
      ? "ffffffff-1111-2222-3333-ffffffffffff"
      : null,
    scanProgress: ["running", "cancelling"].includes(photosPhase)
      ? { completedUnitCount: 32, totalUnitCount: 80 }
      : null,
    canStart: photosPhase === "cancelled",
    canCancel: photosPhase === "running",
  }];
  await page.route(`${baseURL}/v1/world-map/location-backfill`, (route) => {
    locationBackfillRequestCount += 1;
    if (folderPhase === "running") folderPhase = "completed";
    if (photosPhase === "cancelling") photosPhase = "cancelled";
    return json(route, locationBackfillSnapshots());
  });
  await page.route(`${baseURL}/v1/world-map/location-backfill/requests`, (route) => {
    const body = route.request().postDataJSON();
    locationBackfillCommands.push(body);
    if (body.sourceID === folderSourceID && body.action === "start") folderPhase = "running";
    if (body.sourceID === photosSourceID && body.action === "cancel") photosPhase = "cancelling";
    const snapshot = locationBackfillSnapshots().find((item) => item.sourceID === body.sourceID);
    return json(route, { operationID: body.operationID, snapshot, replayed: false }, 202);
  });
  const placeCandidates = [{
    placeID: "paris-fr",
    displayName: "Paris",
    subtitle: "Île-de-France, France",
    latitude: 48.8566,
    longitude: 2.3522,
    kind: "city",
  }, {
    placeID: "paris-us",
    displayName: "Paris",
    subtitle: "Texas, United States",
    latitude: 33.6609,
    longitude: -95.5555,
    kind: "city",
  }];
  const placeTagResolution = () => ({
    tagID: placeTagID,
    tagName: "巴黎",
    groupName: "地点与场景",
    acceptedPhotoCount: 14,
    status: placeTagStatus,
    confirmedPlaceID,
    candidates: placeTagStatus === "unresolved" ? [] : placeCandidates,
  });
  const fillerPlaceTags = Array.from({ length: 8 }, (_, index) => ({
    tagID: `10000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    tagName: `合成地点 ${index + 1}`,
    groupName: "地点与场景",
    acceptedPhotoCount: index + 1,
    status: "resolved",
    confirmedPlaceID: placeCandidates[0].placeID,
    candidates: placeCandidates.slice(0, 1),
  }));
  await page.route(`${baseURL}/v1/world-map/place-tags`, async (route) => {
    placeTagSnapshotRequestCount += 1;
    const snapshot = {
      items: [...fillerPlaceTags, placeTagResolution()],
      maximumQueryLength: 160,
    };
    if (placeTagSnapshotRequestCount === 2) await delay(280);
    return json(route, snapshot);
  });
  await page.route(`${baseURL}/v1/world-map/place-tags/requests`, async (route) => {
    const body = route.request().postDataJSON();
    placeTagCommands.push(body);
    if (body.action === "search") {
      await delay(140);
      placeTagStatus = "ambiguous";
      confirmedPlaceID = null;
    } else if (body.action === "confirm") {
      placeTagStatus = "resolved";
      confirmedPlaceID = body.placeID;
    }
    return json(route, {
      operationID: body.operationID,
      resolution: placeTagResolution(),
      replayed: false,
    });
  });

  await page.goto(baseURL, { waitUntil: "networkidle" });
  await page.locator("#worldMapButton").click();
  await page.locator("#worldMapWorkspace:not(.hidden)").waitFor();
  await page.locator("#worldMapClusterMetric").getByText("1", { exact: true }).waitFor();
  assert.equal(await page.locator("#worldMapLocatedMetric").textContent(), "70");
  assert.equal(await page.locator("#worldMapUnlocatedMetric").textContent(), "30");
  await page.locator("#worldMapRendererMetric").getByText("已就绪", { exact: true }).waitFor();
  assert.equal(await page.locator("#closeWorldMapButton").getAttribute("aria-label"), "返回图库");
  assert.equal(await page.evaluate(() => history.state?.imageAllWorkspace?.route), "worldMap");
  await page.locator("#refreshWorldMapButton").focus();
  await page.keyboard.press("Meta+K");
  await page.locator("#commandPalette[open]").waitFor();
  assert.equal(await page.locator("#commandContextLabel").textContent(), "当前：照片世界");
  assert.equal(await page.locator('[data-command-id="media:video"]').count(), 0);
  assert.match(await page.locator('[data-command-id="returnWorkspace"]').textContent(), /返回图库/);
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => document.activeElement?.id === "refreshWorldMapButton");
  await page.keyboard.press("Meta+K");
  await page.locator('[data-command-id="returnWorkspace"]').click();
  await page.locator("#worldMapWorkspace").waitFor({ state: "hidden" });
  await page.waitForFunction(() => history.state?.imageAllWorkspace?.route === "gallery");
  await page.waitForFunction(() => document.activeElement?.id === "worldMapButton");
  await page.evaluate(() => history.forward());
  await page.locator("#worldMapWorkspace:not(.hidden)").waitFor();
  await page.locator("#worldMapClusterMetric").getByText("1", { exact: true }).waitFor();
  assert.equal(await page.evaluate(() => history.state?.imageAllWorkspace?.route), "worldMap");

  const mapFrame = page.frameLocator("#worldMapFrame");
  await mapFrame.locator("#syntheticCluster:not([hidden])").click();
  await page.locator("#worldMapDetail:not(.hidden)").waitFor();
  assert.equal(await page.locator("#worldMapDetailName").textContent(), "上海");
  assert.match(await page.locator("#worldMapDetailCount").textContent(), /42/);

  const worldMapCard = page.locator(`.world-map-photo-card[data-world-map-card-asset-id="${assetID}"]`);
  const worldMapFavorite = worldMapCard.locator(":scope > .world-map-photo-favorite");
  const stripScrollLeft = await page.locator("#worldMapPhotoStrip").evaluate(
    (element) => element.scrollLeft
  );
  await worldMapCard.hover();
  await worldMapFavorite.click();
  await page.waitForFunction(() => (
    document.querySelector(".world-map-photo-favorite")?.dataset.favorite === "true"
  ));
  assert.equal(favoriteMutations.length, 1);
  assert.equal(favoriteMutations[0].isFavorite, true);
  assert.equal(await page.locator("#lightbox").isHidden(), true);
  assert.equal(await page.locator("#worldMapDetail").isVisible(), true);
  assert.equal(await page.locator("#worldMapPhotoStrip").evaluate((element) => element.scrollLeft), stripScrollLeft);
  await worldMapFavorite.press("Enter");
  await page.waitForFunction(() => (
    document.querySelector(".world-map-photo-favorite")?.dataset.favorite === "false"
  ));
  assert.equal(favoriteMutations.length, 2);
  assert.equal(favoriteMutations[1].isFavorite, false);
  assert.equal(await page.locator("#lightbox").isHidden(), true);
  assert.equal(await page.locator("#worldMapPhotoStrip").evaluate((element) => element.scrollLeft), stripScrollLeft);

  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await worldMapFavorite.isVisible(), true);
  assert.equal(await page.locator("#closeWorldMapButton").isVisible(), true);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({ path: "/tmp/imageall-world-map-photo-favorite-mobile.png" });
  await page.setViewportSize({ width: 1440, height: 960 });

  await page.locator(`[data-world-map-asset-id="${assetID}"]`).click();
  await page.locator("#lightbox:not(.hidden)").waitFor();
  assert.equal(await page.locator("#lightboxTitle").textContent(), "IMG_0001.HEIC");
  await page.locator("#closeLightboxButton").click();
  assert.equal(await page.locator("#worldMapWorkspace").getAttribute("inert"), null);
  assert.equal(await page.locator("#worldMapDetail").isVisible(), true);

  await page.locator("#worldMapBrowseClusterButton").click();
  await page.locator("#worldMapWorkspace").waitFor({ state: "hidden" });
  await page.locator("#worldMapGalleryBanner:not(.hidden)").waitFor();
  await page.locator(`.asset-card[data-asset-id="${assetID}"]`).waitFor();
  assert.ok(worldMapGalleryRequests.length >= 1);
  assert.equal(await page.locator("#libraryTitle").textContent(), "上海 · 照片世界");
  assert.match(await page.locator("#worldMapGallerySummary").textContent(), /精确地点范围.*42 张/);
  assert.equal(await page.locator("#mediaKindTabs").isHidden(), true);
  assert.equal(await page.evaluate(() => history.state?.imageAllWorkspace?.route), "gallery");

  await page.evaluate(() => history.back());
  await page.locator("#worldMapWorkspace:not(.hidden)").waitFor();
  assert.equal(await page.locator("#worldMapDetail").isVisible(), true);
  await page.evaluate(() => history.forward());
  await page.locator("#worldMapGalleryBanner:not(.hidden)").waitFor();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(260);
  assert.equal(await page.locator("#returnToWorldMapButton").isVisible(), true);
  assert.equal(await page.locator("#clearWorldMapGalleryButton").isVisible(), true);
  for (const selector of [
    "#worldMapGalleryBanner",
    "#returnToWorldMapButton",
    "#clearWorldMapGalleryButton",
  ]) {
    const box = await page.locator(selector).boundingBox();
    assert.ok(box && box.x >= 0 && box.y >= 0, `${selector} must remain inside the viewport`);
    assert.ok(box.x + box.width <= 390.5, `${selector} must not overflow at 390px`);
  }
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({ path: "/tmp/imageall-world-map-gallery-scope-mobile.png" });
  await page.setViewportSize({ width: 1440, height: 960 });

  await page.locator("#returnToWorldMapButton").click();
  await page.locator("#worldMapWorkspace:not(.hidden)").waitFor();
  await page.evaluate(() => history.back());
  await page.locator("#worldMapGalleryBanner:not(.hidden)").waitFor();
  await page.locator("#clearWorldMapGalleryButton").click();
  await page.locator("#worldMapGalleryBanner").waitFor({ state: "hidden" });
  assert.equal(await page.locator("#libraryTitle").textContent(), "全部照片");
  assert.equal(await page.locator("#mediaKindTabs").isVisible(), true);
  await page.locator("#worldMapButton").click();
  await page.locator("#worldMapWorkspace:not(.hidden)").waitFor();
  assert.equal(await page.locator("#worldMapDetail").isVisible(), true);

  selectionShouldFail = true;
  await page.evaluate(() => loadWorldMapSelection("shanghai"));
  await page.locator(".world-map-photo-error").waitFor();
  assert.match(await page.locator(".world-map-photo-error").textContent(), /synthetic place selection failure.*重试/s);
  assert.equal(await page.locator("#worldMapBrowseClusterButton").isHidden(), true);
  assert.doesNotMatch(await page.locator("#worldMapPhotoStrip").textContent(), /没有可预览照片/);
  const expectedSelectionFailure = consoleErrors.findIndex(
    (message) => message.includes("Failed to load resource") && message.includes("500")
  );
  assert.ok(expectedSelectionFailure >= 0, "the synthetic HTTP failure should reach Chromium");
  consoleErrors.splice(expectedSelectionFailure, 1);
  selectionShouldFail = false;
  await page.locator("[data-retry-world-map-selection=shanghai]").click();
  await page.locator(`.world-map-photo-card[data-world-map-card-asset-id="${assetID}"]`).waitFor();
  assert.equal(await page.locator(".world-map-photo-error").count(), 0);
  assert.equal(await page.locator("#worldMapBrowseClusterButton").isVisible(), true);

  await page.locator("#openWorldMapLocationBackfillButton").click();
  await page.locator("#worldMapLocationBackfillDialog[open]").waitFor();
  await page.locator(`[data-source-id="${folderSourceID}"][data-phase="ready"]`).waitFor();
  assert.match(
    await page.locator(`.world-map-location-source-card[data-source-id="${folderSourceID}"]`).textContent(),
    /40 \/ 120.*已检查.*27.*已定位.*13.*无坐标/s
  );
  await page.locator(
    `[data-source-id="${folderSourceID}"] [data-location-backfill-action="start"]`
  ).click();
  await page.locator(`[data-source-id="${folderSourceID}"][data-phase="running"]`).waitFor();
  await page.locator(
    `[data-source-id="${photosSourceID}"] [data-location-backfill-action="cancel"]`
  ).click();
  await page.locator(`[data-source-id="${photosSourceID}"][data-phase="cancelling"]`).waitFor();
  assert.equal(locationBackfillCommands.length, 2);
  assert.equal(locationBackfillCommands[0].sourceID, folderSourceID);
  assert.equal(locationBackfillCommands[0].action, "start");
  assert.match(locationBackfillCommands[0].operationID, /^[0-9a-f-]{36}$/i);
  assert.equal(locationBackfillCommands[1].sourceID, photosSourceID);
  assert.equal(locationBackfillCommands[1].action, "cancel");
  await page.locator(`[data-source-id="${folderSourceID}"][data-phase="completed"]`).waitFor({
    timeout: 4_000,
  });
  await page.locator(`[data-source-id="${photosSourceID}"][data-phase="cancelled"]`).waitFor({
    timeout: 4_000,
  });
  assert.match(
    await page.locator(`.world-map-location-source-card[data-source-id="${folderSourceID}"]`).textContent(),
    /目录已更新/
  );

  await page.locator("#closeWorldMapLocationBackfillButton").click();
  await page.locator("#openWorldMapPlaceTagsButton").click();
  await page.locator("#worldMapPlaceTagDialog[open]").waitFor();
  const placeCard = page.locator(`[data-place-tag-card="${placeTagID}"]`);
  await placeCard.waitFor();
  await placeCard.scrollIntoViewIfNeeded();
  const placeBody = page.locator("#worldMapPlaceTagBody");
  const placeScrollBefore = await placeBody.evaluate((element) => element.scrollTop);
  assert.ok(placeScrollBefore > 0, "synthetic place list should exercise a nonzero scroll position");
  assert.match(await placeCard.textContent(), /巴黎.*地点与场景.*14 张.*未识别/s);
  const placeInput = placeCard.locator("[data-place-tag-query]");
  const placeInputOffsetBefore = await placeInput.evaluate((element) => {
    const body = document.querySelector("#worldMapPlaceTagBody");
    return element.getBoundingClientRect().top - body.getBoundingClientRect().top;
  });
  await placeInput.fill("x".repeat(161));
  await placeInput.press("Enter");
  assert.equal(placeTagCommands.length, 0, "overlong location queries must stay in the browser");
  assert.match(await placeCard.locator("[data-place-tag-hint]").textContent(), /160/);
  await placeInput.fill("  Paris   France  ");
  await placeInput.press("Enter");
  while (placeTagCommands.length === 0) await page.waitForTimeout(10);
  await placeInput.fill("Paris Texas USA");
  assert.match(
    await placeCard.locator("[data-place-tag-provenance]").textContent(),
    /正在用“Paris France”搜索.*继续编辑.*Paris Texas USA/
  );
  await page.evaluate(() => loadWorldMapPlaceTags());
  await placeCard.locator("[data-place-id=paris-fr]").waitFor();
  await page.locator("#worldMapPlaceTagLoading").waitFor({ state: "hidden" });
  await page.waitForTimeout(100);
  const placeScrollAfterSearch = await placeBody.evaluate((element) => element.scrollTop);
  const placeInputOffsetAfter = await placeInput.evaluate((element) => {
    const body = document.querySelector("#worldMapPlaceTagBody");
    return element.getBoundingClientRect().top - body.getBoundingClientRect().top;
  });
  assert.ok(placeScrollAfterSearch > 0, "async place refresh must not jump the long list to its top");
  assert.ok(Math.abs(placeInputOffsetAfter - placeInputOffsetBefore) <= 2,
    `place search moved the edited field: ${placeInputOffsetBefore} -> ${placeInputOffsetAfter}`);
  assert.equal(await placeInput.inputValue(), "Paris Texas USA");
  assert.equal(await placeInput.evaluate((element) => document.activeElement === element), true,
    "search completion should restore the edited field without scrolling away");
  assert.match(
    await placeCard.locator("[data-place-tag-provenance]").textContent(),
    /输入已改为“Paris Texas USA”.*下方仍是“Paris France”的结果/
  );
  assert.equal(await placeCard.getAttribute("data-status"), "ambiguous",
    "a stale snapshot completing after search must not replace the new candidates");
  assert.equal(placeTagSnapshotRequestCount, 2);
  assert.equal(placeTagCommands[0].action, "search");
  assert.equal(placeTagCommands[0].query, "Paris France");
  assert.equal(placeTagCommands[0].tagID, placeTagID);
  assert.match(placeTagCommands[0].operationID, /^[0-9a-f-]{36}$/i);
  await placeInput.press("ArrowDown");
  const parisFrance = placeCard.locator("[data-place-id=paris-fr]");
  const parisTexas = placeCard.locator("[data-place-id=paris-us]");
  assert.equal(await parisFrance.evaluate((element) => document.activeElement === element), true,
    "ArrowDown from the query should enter the candidate list");
  await page.keyboard.press("ArrowDown");
  assert.equal(await parisTexas.evaluate((element) => document.activeElement === element), true);
  await page.keyboard.press("Home");
  assert.equal(await parisFrance.evaluate((element) => document.activeElement === element), true);
  await page.keyboard.press("End");
  assert.equal(await parisTexas.evaluate((element) => document.activeElement === element), true);
  await page.keyboard.press("Enter");
  await page.locator(`[data-place-tag-card="${placeTagID}"][data-status=resolved]`).waitFor();
  assert.equal(placeTagCommands[1].action, "confirm");
  assert.equal(placeTagCommands[1].placeID, "paris-us");
  assert.match(await placeCard.textContent(), /已确认.*Paris.*Texas/s);

  await page.setViewportSize({ width: 390, height: 844 });
  const placeDialogBox = await page.locator("#worldMapPlaceTagDialog").boundingBox();
  assert.ok(placeDialogBox && placeDialogBox.x >= 0 && placeDialogBox.y >= 0);
  assert.ok(placeDialogBox.x + placeDialogBox.width <= 390.5);
  assert.ok(placeDialogBox.y + placeDialogBox.height <= 844.5);
  assert.equal(
    await page.locator("#worldMapPlaceTagDialog").evaluate(
      (element) => element.scrollWidth <= element.clientWidth
    ),
    true,
    "place resolution dialog must not overflow horizontally at 390px"
  );
  await page.screenshot({ path: "/tmp/imageall-world-map-place-tags-mobile.png" });
  await page.keyboard.press("Escape");
  assert.equal(await page.locator("#worldMapPlaceTagDialog").getAttribute("open"), null);
  assert.equal(await page.locator("#worldMapWorkspace").isVisible(), true);

  await page.locator("#openWorldMapLocationBackfillButton").click();
  const dialogBox = await page.locator("#worldMapLocationBackfillDialog").boundingBox();
  assert.ok(dialogBox && dialogBox.x >= 0 && dialogBox.y >= 0);
  assert.ok(dialogBox.x + dialogBox.width <= 390.5);
  assert.ok(dialogBox.y + dialogBox.height <= 844.5);
  await page.screenshot({ path: "/tmp/imageall-world-map-location-backfill-mobile.png" });

  await page.locator("#closeWorldMapLocationBackfillButton").click();
  const requestsAfterClose = locationBackfillRequestCount;
  await page.waitForTimeout(1_700);
  assert.equal(locationBackfillRequestCount, requestsAfterClose,
    "closing the panel must stop UI polling without cancelling jobs");
  assert.equal(await page.locator("#worldMapWorkspace").isVisible(), true);
  await page.setViewportSize({ width: 1440, height: 960 });
  await page.locator("#openWorldMapLocationBackfillButton").click();
  await page.locator(`[data-source-id="${folderSourceID}"][data-phase="completed"]`).waitFor();
  await page.keyboard.press("Escape");
  assert.equal(await page.locator("#worldMapLocationBackfillDialog").getAttribute("open"), null);
  assert.equal(await page.locator("#worldMapWorkspace").isVisible(), true);

  await page.waitForTimeout(700);
  assert.ok(snapshotRequestCount >= 1 && snapshotRequestCount <= 3,
    `unexpected repeated world-map refresh count: ${snapshotRequestCount}`);
  assert.deepEqual(pageErrors, []);
  assert.deepEqual(consoleErrors, []);
  await page.screenshot({ path: "/tmp/imageall-world-map-synthetic.png", fullPage: true });

  await page.route(`${baseURL}/v1/world-map/snapshot**`, (route) => json(route, {
    code: "internalError",
    message: "synthetic map failure",
  }, 500));
  await page.locator("#refreshWorldMapButton").click();
  await page.locator("#worldMapStatus[data-state=error]").waitFor();
  assert.match(await page.locator("#worldMapStatus strong").textContent(), /暂时无法读取/);

  await page.keyboard.press("Escape");
  await page.locator("#worldMapWorkspace").waitFor({ state: "hidden" });
  assert.equal(await page.evaluate(() => history.state?.imageAllWorkspace?.route), "gallery");
  assert.equal(await page.locator("#appView").getAttribute("inert"), null);
  await browser.close();
  browser = null;
  process.stdout.write(
    `world-map browser flow passed; snapshot requests=${snapshotRequestCount}; `
      + `place commands=${placeTagCommands.length}; favorites=${favoriteMutations.length}; `
      + `gallery scopes=${worldMapGalleryRequests.length}; selections=${selectionRequestCount}\n`
  );
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}).finally(async () => {
  if (browser) await browser.close();
});
