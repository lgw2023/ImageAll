const bridge = globalThis.webkit?.messageHandlers?.worldMapBridge;
const tooltip = document.getElementById("tooltip");
const clusterNavigator = document.getElementById("cluster-navigator");
const clusterNavigatorPrevious = document.getElementById("cluster-navigator-previous");
const clusterNavigatorCurrent = document.getElementById("cluster-navigator-current");
const clusterNavigatorNext = document.getElementById("cluster-navigator-next");
const clusterNavigatorName = document.getElementById("cluster-navigator-name");
const clusterNavigatorMeta = document.getElementById("cluster-navigator-meta");
const clusterNavigatorStatus = document.getElementById("cluster-navigator-status");
const maplibregl = globalThis.maplibregl;
const deckRuntime = globalThis.deck;
const mapWorkerBase64 = globalThis.ImageAllMapLibreWorkerBase64;
const naturalEarthCountries = globalThis.ImageAllNaturalEarthCountries;
const requestedInitialCamera = globalThis.ImageAllWorldMapInitialCamera;

let overlay = null;
let clusters = [];
let selectedClusterID = null;
let keyboardClusterID = null;
let clusterNavigatorKeyboardActive = false;
let rendererReady = false;

function finiteNumber(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

const initialCamera = {
  centerLongitude: Math.max(
    -180,
    Math.min(180, finiteNumber(requestedInitialCamera?.centerLongitude, 18))
  ),
  centerLatitude: Math.max(
    -85,
    Math.min(85, finiteNumber(requestedInitialCamera?.centerLatitude, 24))
  ),
  zoom: Math.max(0.7, Math.min(12, finiteNumber(requestedInitialCamera?.zoom, 1.48))),
  bearing: finiteNumber(requestedInitialCamera?.bearing, -14),
  pitch: Math.max(0, Math.min(78, finiteNumber(requestedInitialCamera?.pitch, 44)))
};

function post(message) {
  if (bridge) {
    bridge.postMessage(message);
    return;
  }
  if (globalThis.parent && globalThis.parent !== globalThis) {
    globalThis.parent.postMessage(
      { type: "imageall-world-map-event", payload: message },
      globalThis.location.origin
    );
  }
}

globalThis.addEventListener("error", (event) => {
  const location = event?.filename
    ? `${event.filename}:${event.lineno || 0}:${event.colno || 0}`
    : "";
  const detail = event?.error?.stack || event?.error?.message || "";
  const message = [event?.message || "地图脚本发生未知错误。", location, detail]
    .filter(Boolean)
    .join(" | ");
  post({ type: "renderError", message });
});

globalThis.addEventListener("unhandledrejection", (event) => {
  const reason = event?.reason;
  post({
    type: "renderError",
    message: reason?.message || String(reason || "地图脚本 Promise 执行失败。")
  });
});

if (!bridge && globalThis.parent && globalThis.parent !== globalThis) {
  globalThis.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || event.defaultPrevented) return;
    event.preventDefault();
    post({ type: "escapePressed" });
  });
}

function webGL2Available() {
  const canvas = document.createElement("canvas");
  return Boolean(canvas.getContext("webgl2"));
}

function gridGeoJSON() {
  const features = [];
  for (let longitude = -180; longitude <= 180; longitude += 20) {
    features.push({
      type: "Feature",
      geometry: {
        type: "LineString",
        coordinates: [[longitude, -80], [longitude, 80]]
      },
      properties: {}
    });
  }
  for (let latitude = -80; latitude <= 80; latitude += 20) {
    const coordinates = [];
    for (let longitude = -180; longitude <= 180; longitude += 4) {
      coordinates.push([longitude, latitude]);
    }
    features.push({
      type: "Feature",
      geometry: { type: "LineString", coordinates },
      properties: {}
    });
  }
  return { type: "FeatureCollection", features };
}

const localGrid = gridGeoJSON();

const photoAtlasStyle = {
  version: 8,
  name: "ImageAll Photo Atlas",
  sources: {},
  layers: [
    { id: "paper", type: "background", paint: { "background-color": "#eef2ef" } }
  ]
};

if (!maplibregl) {
  post({ type: "renderError", message: "本地 MapLibre GL JS 运行时未载入。" });
  throw new Error("MapLibre GL JS runtime missing");
}

if (!deckRuntime) {
  post({ type: "renderError", message: "本地 deck.gl 运行时未载入。" });
  throw new Error("deck.gl runtime missing");
}

if (!naturalEarthCountries) {
  post({ type: "renderError", message: "本地 Natural Earth 世界轮廓未载入。" });
  throw new Error("Natural Earth basemap missing");
}

if (!mapWorkerBase64) {
  post({ type: "renderError", message: "本地 MapLibre worker 运行时未载入。" });
  throw new Error("MapLibre GL JS worker missing");
}
const workerBinary = atob(mapWorkerBase64);
const workerBytes = Uint8Array.from(workerBinary, (character) => character.charCodeAt(0));
const mapWorkerURL = URL.createObjectURL(new Blob([workerBytes], { type: "text/javascript" }));
maplibregl.setWorkerUrl(mapWorkerURL);
globalThis.addEventListener("pagehide", () => URL.revokeObjectURL(mapWorkerURL), { once: true });

let map;
try {
  map = new maplibregl.Map({
    container: "map",
    // Keep the basemap in Mercator for S0: deck.gl's separate overlay canvas can
    // share this camera exactly. Globe projection needs the future interleaved
    // compatibility path before it can be enabled without spatial drift.
    style: photoAtlasStyle,
    center: [initialCamera.centerLongitude, initialCamera.centerLatitude],
    zoom: initialCamera.zoom,
    pitch: initialCamera.pitch,
    bearing: initialCamera.bearing,
    maxPitch: 78,
    minZoom: 0.7,
    maxZoom: 12,
    antialias: true,
    renderWorldCopies: true,
    attributionControl: true,
    fadeDuration: 300
  });
} catch (error) {
  post({ type: "renderError", message: `Map construction failed: ${error?.stack || error}` });
  throw error;
}
map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), "top-right");

function colorForCount(count, alpha = 238) {
  const strength = Math.min(1, Math.log10(count + 1) / 3.5);
  if (strength < 0.48) {
    return [147, 191, 208, alpha];
  }
  if (strength < 0.68) {
    return [182, 168, 201, alpha];
  }
  if (strength < 0.86) {
    return [219, 175, 157, alpha];
  }
  return [216, 201, 143, alpha];
}

function radiusForZoom() {
  const zoom = map.getZoom();
  return Math.max(2800, Math.min(90000, 120000 / Math.pow(1.52, zoom)));
}

function elevationForCount(count) {
  return 4200 * Math.pow(Math.log2(count + 1), 1.65);
}

function clustersInCurrentViewport() {
  const bounds = map?.getBounds?.();
  return clusters
    .filter((cluster) => {
      if (!bounds) return true;
      return bounds.contains([cluster.longitude, cluster.latitude]);
    })
    .sort((left, right) => (
      right.photoCount - left.photoCount
      || left.displayName.localeCompare(right.displayName, "zh-CN")
      || left.id.localeCompare(right.id)
    ));
}

function keyboardClusterPresentation(cluster, index, count) {
  const name = cluster.displayName || "未命名地点";
  return {
    name: `${name} · ${index + 1} / ${count}`,
    meta: `${cluster.photoCount.toLocaleString()} 张 · GPS ${cluster.gpsCount.toLocaleString()} · 标签 ${cluster.tagCount.toLocaleString()}`,
    ariaLabel: `${name}，${cluster.photoCount.toLocaleString()} 张照片，GPS ${cluster.gpsCount.toLocaleString()}，地点标签 ${cluster.tagCount.toLocaleString()}，第 ${index + 1} 个，共 ${count} 个；按 Enter 打开`,
  };
}

function showKeyboardClusterTooltip(cluster) {
  if (!cluster || !map) return;
  const point = map.project([cluster.longitude, cluster.latitude]);
  showTooltip(cluster, point.x, point.y);
}

function syncClusterNavigator({ announce = false, preferSelected = false } = {}) {
  const candidates = clustersInCurrentViewport();
  const selected = candidates.find((cluster) => cluster.id === selectedClusterID);
  let current = candidates.find((cluster) => cluster.id === keyboardClusterID);
  if ((preferSelected && selected) || !current) current = selected || candidates[0] || null;
  keyboardClusterID = current?.id || null;

  if (!current) {
    clusterNavigator.dataset.empty = "true";
    delete clusterNavigatorCurrent.dataset.clusterId;
    clusterNavigatorName.textContent = "当前视口没有照片塔";
    clusterNavigatorMeta.textContent = "拖动或缩放地图后重试";
    clusterNavigatorCurrent.setAttribute("aria-label", "当前视口没有照片塔");
    clusterNavigatorCurrent.disabled = true;
    clusterNavigatorPrevious.disabled = true;
    clusterNavigatorNext.disabled = true;
    if (announce) clusterNavigatorStatus.textContent = "当前视口没有可浏览的照片塔";
    return;
  }

  const index = candidates.indexOf(current);
  const presentation = keyboardClusterPresentation(current, index, candidates.length);
  delete clusterNavigator.dataset.empty;
  clusterNavigatorCurrent.dataset.clusterId = current.id;
  clusterNavigatorName.textContent = presentation.name;
  clusterNavigatorMeta.textContent = presentation.meta;
  clusterNavigatorCurrent.setAttribute("aria-label", presentation.ariaLabel);
  clusterNavigatorCurrent.title = `${current.displayName || "未命名地点"} · 按 Enter 打开照片塔`;
  clusterNavigatorCurrent.disabled = false;
  clusterNavigatorPrevious.disabled = index === 0;
  clusterNavigatorNext.disabled = index === candidates.length - 1;
  if (announce) clusterNavigatorStatus.textContent = `已定位到${presentation.ariaLabel}`;
  if (clusterNavigatorKeyboardActive) showKeyboardClusterTooltip(current);
}

function moveKeyboardCluster(target) {
  const candidates = clustersInCurrentViewport();
  if (!candidates.length) {
    syncClusterNavigator({ announce: true });
    return;
  }
  const currentIndex = Math.max(0, candidates.findIndex(
    (cluster) => cluster.id === keyboardClusterID
  ));
  const nextIndex = typeof target === "number"
    ? Math.max(0, Math.min(candidates.length - 1, target))
    : Math.max(0, Math.min(candidates.length - 1, currentIndex + target));
  keyboardClusterID = candidates[nextIndex].id;
  syncClusterNavigator({ announce: true });
  renderLayers();
}

function renderLayers() {
  if (!overlay) return;
  const selected = clusters.find((cluster) => cluster.id === selectedClusterID);
  const radius = radiusForZoom();
  const layers = [
    new deckRuntime.GeoJsonLayer({
      id: "natural-earth-land",
      data: naturalEarthCountries,
      pickable: false,
      filled: true,
      stroked: true,
      getFillColor: [218, 228, 216, 238],
      getLineColor: [142, 166, 157, 176],
      getLineWidth: 0.8,
      lineWidthUnits: "pixels",
      lineWidthMinPixels: 0.55
    }),
    new deckRuntime.GeoJsonLayer({
      id: "local-graticule",
      data: localGrid,
      pickable: false,
      filled: false,
      stroked: true,
      getLineColor: [142, 160, 166, 48],
      getLineWidth: 0.55,
      lineWidthUnits: "pixels",
      lineWidthMinPixels: 0.35
    }),
    new deckRuntime.ScatterplotLayer({
      id: "photo-city-footprints",
      data: clusters,
      pickable: false,
      stroked: false,
      filled: true,
      radiusUnits: "meters",
      getPosition: (item) => [item.longitude, item.latitude],
      getRadius: (item) => radius * (1.45 + Math.min(1.4, Math.log10(item.photoCount + 1) * 0.24)),
      getFillColor: (item) => colorForCount(item.photoCount, 34),
      opacity: 0.48,
      parameters: { depthWriteEnabled: false }
    }),
    new deckRuntime.ColumnLayer({
      id: "photo-city-columns",
      data: clusters,
      diskResolution: 6,
      radius,
      extruded: true,
      wireframe: false,
      pickable: true,
      elevationScale: 1,
      getPosition: (item) => [item.longitude, item.latitude],
      getElevation: (item) => elevationForCount(item.photoCount),
      getFillColor: (item) => colorForCount(item.photoCount),
      getLineColor: (item) => item.id === selectedClusterID ? [255, 252, 245, 255] : colorForCount(item.photoCount, 112),
      lineWidthMinPixels: 0.55,
      material: {
        ambient: 0.72,
        diffuse: 0.54,
        shininess: 18,
        specularColor: [235, 232, 222]
      },
      transitions: {
        getElevation: { duration: 850, type: "spring", stiffness: 0.16, damping: 0.34 },
        getFillColor: 420
      },
      onHover: ({ object, x, y }) => showTooltip(object, x, y),
      onClick: ({ object }) => selectCluster(object)
    })
  ];

  if (selected) {
    layers.push(
      new deckRuntime.ScatterplotLayer({
        id: "selected-city-ring",
        data: [selected],
        pickable: false,
        stroked: true,
        filled: false,
        radiusUnits: "meters",
        getPosition: (item) => [item.longitude, item.latitude],
        getRadius: radius * 3.4,
        getLineColor: [101, 140, 151, 226],
        lineWidthMinPixels: 2.2
      })
    );
  }

  const keyboardCluster = clusterNavigatorKeyboardActive
    ? clusters.find((cluster) => cluster.id === keyboardClusterID)
    : null;
  if (keyboardCluster) {
    layers.push(
      new deckRuntime.ScatterplotLayer({
        id: "keyboard-city-ring",
        data: [keyboardCluster],
        pickable: false,
        stroked: true,
        filled: false,
        radiusUnits: "meters",
        getPosition: (item) => [item.longitude, item.latitude],
        getRadius: radius * 2.6,
        getLineColor: [60, 89, 96, 238],
        lineWidthMinPixels: 3.1
      })
    );
  }

  overlay.setProps({ layers });
}

function showTooltip(object, x, y) {
  if (!object) {
    tooltip.style.display = "none";
    map.getCanvas().style.cursor = "grab";
    return;
  }
  map.getCanvas().style.cursor = "pointer";
  tooltip.style.display = "block";
  tooltip.style.left = `${x}px`;
  tooltip.style.top = `${y}px`;
  tooltip.replaceChildren();
  const title = document.createElement("strong");
  title.textContent = object.displayName;
  const count = document.createElement("div");
  count.textContent = `${object.photoCount.toLocaleString()} 张照片`;
  const composition = document.createElement("span");
  composition.textContent = `GPS ${object.gpsCount.toLocaleString()} · 标签 ${object.tagCount.toLocaleString()}`;
  tooltip.append(title, count, composition);
}

function selectCluster(object) {
  if (!object) return;
  selectedClusterID = object.id;
  keyboardClusterID = object.id;
  syncClusterNavigator({ preferSelected: true });
  renderLayers();
  post({ type: "clusterClicked", clusterID: object.id });
}

function currentViewport() {
  const bounds = map.getBounds();
  const center = map.getCenter();
  return {
    west: bounds.getWest(),
    south: bounds.getSouth(),
    east: bounds.getEast(),
    north: bounds.getNorth(),
    centerLongitude: center.lng,
    centerLatitude: center.lat,
    zoom: map.getZoom(),
    bearing: map.getBearing(),
    pitch: map.getPitch()
  };
}

function postViewport() {
  post({ type: "cameraChanged", viewport: currentViewport() });
}

function restoreViewport(viewport) {
  if (!viewport || typeof viewport !== "object") return;
  map.jumpTo({
    center: [
      Math.max(-180, Math.min(180, finiteNumber(viewport.centerLongitude, map.getCenter().lng))),
      Math.max(-85, Math.min(85, finiteNumber(viewport.centerLatitude, map.getCenter().lat)))
    ],
    zoom: Math.max(0.7, Math.min(12, finiteNumber(viewport.zoom, map.getZoom()))),
    bearing: finiteNumber(viewport.bearing, map.getBearing()),
    pitch: Math.max(0, Math.min(78, finiteNumber(viewport.pitch, map.getPitch())))
  });
}

function installRenderer() {
  try {
    if (!overlay) {
      // MapLibre GL JS 6 changed custom-layer framebuffer details that deck.gl 9.3
      // does not yet receive consistently in WKWebView. Overlay mode preserves the
      // shared camera while keeping deck.gl on its own canvas and avoids that crash.
      overlay = new deckRuntime.MapboxOverlay({ interleaved: false, layers: [] });
      map.addControl(overlay);
    }
    syncClusterNavigator();
    renderLayers();
    if (!rendererReady) {
      rendererReady = true;
      post({ type: "ready", webgl2Available: webGL2Available() });
      postViewport();
    }
  } catch (error) {
    post({ type: "renderError", message: `Deck renderer failed: ${error?.stack || error}` });
    throw error;
  }
}

map.on("style.load", installRenderer);
installRenderer();
map.on("zoomend", renderLayers);
map.on("moveend", () => {
  syncClusterNavigator();
  renderLayers();
  postViewport();
});
map.on("dragstart", () => { tooltip.style.display = "none"; });
map.on("error", (event) => {
  post({
    type: "renderError",
    message: event?.error?.stack || event?.error?.message || String(event?.error || "unknown")
  });
  console.warn("MapLibre renderer error", event.error);
});

clusterNavigatorPrevious.addEventListener("click", () => moveKeyboardCluster(-1));
clusterNavigatorNext.addEventListener("click", () => moveKeyboardCluster(1));
clusterNavigatorCurrent.addEventListener("click", () => {
  const current = clusters.find((cluster) => cluster.id === keyboardClusterID);
  if (current) selectCluster(current);
});
clusterNavigator.addEventListener("keydown", (event) => {
  const candidates = clustersInCurrentViewport();
  if (!candidates.length) return;
  const currentIndex = Math.max(0, candidates.findIndex(
    (cluster) => cluster.id === keyboardClusterID
  ));
  const target = {
    ArrowLeft: currentIndex - 1,
    ArrowRight: currentIndex + 1,
    PageUp: currentIndex - 5,
    PageDown: currentIndex + 5,
    Home: 0,
    End: candidates.length - 1,
  }[event.key];
  if (target == null) return;
  event.preventDefault();
  moveKeyboardCluster(target);
});
clusterNavigator.addEventListener("focusin", () => {
  clusterNavigatorKeyboardActive = true;
  syncClusterNavigator();
  renderLayers();
});
clusterNavigator.addEventListener("focusout", () => {
  requestAnimationFrame(() => {
    if (clusterNavigator.contains(document.activeElement)) return;
    clusterNavigatorKeyboardActive = false;
    tooltip.style.display = "none";
    renderLayers();
  });
});

globalThis.ImageAllWorldMap = Object.freeze({
  updateClusters(payload) {
    if (!payload || !Array.isArray(payload.clusters)) return;
    clusters = payload.clusters.slice(0, 2_000);
    if (selectedClusterID && !clusters.some((item) => item.id === selectedClusterID)) {
      selectedClusterID = null;
    }
    if (keyboardClusterID && !clusters.some((item) => item.id === keyboardClusterID)) {
      keyboardClusterID = null;
    }
    syncClusterNavigator();
    renderLayers();
  },
  restoreSelection(clusterID) {
    selectedClusterID = typeof clusterID === "string"
      && clusters.some((item) => item.id === clusterID)
      ? clusterID
      : null;
    keyboardClusterID = selectedClusterID;
    syncClusterNavigator({ preferSelected: true });
    renderLayers();
  },
  restoreViewport,
  snapshotState() {
    return { selectedClusterID, keyboardClusterID, viewport: currentViewport() };
  },
  rendererStatus() {
    return { ready: rendererReady, webgl2Available: webGL2Available() };
  }
});
