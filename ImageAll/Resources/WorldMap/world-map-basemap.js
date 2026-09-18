/* OpenFreeMap Liberty adapter shared by the native WebView and browser iframe. */
(() => {
  "use strict";
  const storageKey = "imageall-world-map-basemap-v2";
  const origin = "https://tiles.openfreemap.org";
  // OpenMapTiles source layers used by the official Liberty style.
  const groups = [
    { id: "boundaries", name: "行政边界", detail: "国家、省市与行政分界", layers: "boundary" },
    { id: "roads", name: "道路交通", detail: "街道、公路、步道与交通网络", layers: "transportation transportation_name aeroway" },
    { id: "poi", name: "兴趣点", detail: "景点、餐饮、住宿与公共设施", layers: "poi aerodrome_label" },
    { id: "names", name: "地名标注", detail: "国家、城市、乡镇与自然地名", layers: "place water_name" },
    { id: "landcover", name: "土地覆盖", detail: "森林、草地、农田与土地用途", layers: "landcover landuse park" },
    { id: "buildings", name: "建筑", detail: "建筑轮廓与立体建筑 · 放大至街区查看", layers: "building housenumber" }
  ];
  const layerGroups = new Map(groups.flatMap(group => group.layers.split(" ").filter(Boolean).map(layer => [layer, group.id])));
  function category(layer) {
    const sourceLayer = layer["source-layer"] || "";
    return layerGroups.get(sourceLayer);
  }
  const defaults = () => ({ mode: "online", groups: Object.fromEntries(groups.map(group => [group.id, true])) });
  function normalize(value) {
    const result = defaults();
    if (!value || typeof value !== "object") return result;
    if (value.mode === "offline") result.mode = "offline";
    for (const group of groups) {
      if (typeof value.groups?.[group.id] === "boolean") result.groups[group.id] = value.groups[group.id];
    }
    return result;
  }
  function trustedURL(value) {
    const url = new URL(value);
    if (url.origin !== origin || url.username || url.password) throw new Error("unsupported-map-resource");
    return url;
  }
  function prepareStyle(style) {
    if (style?.version !== 8 || !Array.isArray(style.layers) || !style.sources || style.imports?.length) {
      throw new Error("unsupported-map-style");
    }
    // Only official remote tile data. No arbitrary style URLs or remotely loaded code.
    for (const source of Object.values(style.sources)) {
      if (!["vector", "raster", "raster-dem"].includes(source.type)) throw new Error("unsupported-map-source");
      if (source.url) trustedURL(source.url);
      for (const tile of source.tiles || []) trustedURL(tile);
    }
    if (style.glyphs) trustedURL(style.glyphs);
    if (typeof style.sprite === "string") trustedURL(style.sprite);
    else for (const sprite of style.sprite || []) trustedURL(sprite.url);
    // This photo renderer uses a Mercator camera and its existing independent deck overlay.
    delete style.projection;
    delete style.terrain;
    for (const layer of style.layers) {
      if (["names", "poi"].includes(category(layer)) && layer.layout?.["text-field"]) {
        layer.layout["text-field"] = ["coalesce", ["get", "name:zh"], ["get", "name"], layer.layout["text-field"]];
      }
    }
    return style;
  }

  function create({ map, offlineStyle, onChange }) {
    let settings;
    let storageAvailable = true;
    try { settings = normalize(JSON.parse(localStorage.getItem(storageKey))); }
    catch { settings = defaults(); }
    let active = false;
    let pending = false;
    let stage = "offline";
    let generation = 0;
    let aborter;
    let timer;
    let baseLayers = [];
    const rows = new Map();
    const panel = document.getElementById("basemap-panel");
    const status = document.getElementById("basemap-status");
    const badge = document.getElementById("fallback-badge");
    const modeSelect = document.getElementById("basemap-mode");
    const title = document.getElementById("basemap-toggle");
    const body = document.getElementById("basemap-body");
    function save() {
      try { localStorage.setItem(storageKey, JSON.stringify(settings)); }
      catch { storageAvailable = false; }

    }
    function refreshRows() {
      for (const group of groups) {
        const { input, hint } = rows.get(group.id);
        input.checked = settings.groups[group.id];
        const mapped = baseLayers.filter(layer => category(layer) === group.id);
        input.disabled = active && mapped.length === 0;
        hint.textContent = !active ? "联网后生效" : !mapped.length ? "此样式未提供" : !input.checked ? "已隐藏" :
          mapped.every(layer => (layer.minzoom || 0) > map.getZoom()) ? "放大后显示" : "已开启";
      }
      modeSelect.value = settings.mode;
    }
    function present(message) {
      status.textContent = message;
      panel.dataset.state = stage;
      document.body.dataset.basemap = active ? "online" : "offline";
      badge.textContent = active ? "OPENFREEMAP · 免费街道地图" : pending ? "正在连接街道地图…" : "离线轮廓地图";
      refreshRows();
      onChange(active);
    }
    function applyVisibility() {
      if (!active) return;
      for (const layer of baseLayers) {
        const group = category(layer);
        if (group && map.getLayer(layer.id)) {
          map.setLayoutProperty(layer.id, "visibility", settings.groups[group]
            ? layer.layout?.visibility || "visible" : "none");
        }
      }
      refreshRows();
    }
    function fallback(message, failed = false) {
      generation++;
      aborter?.abort();
      clearTimeout(timer);
      const needsReset = active || pending;
      active = false;
      pending = false;
      stage = failed ? "failed" : "offline";
      baseLayers = [];
      if (needsReset) map.setStyle(offlineStyle, { diff: false });
      present(message);
    }
    async function connect() {
      if (settings.mode === "offline") return fallback("已使用离线轮廓，照片塔仍可浏览。");
      fallback("正在连接免费街道地图…");
      const current = ++generation;
      aborter = new AbortController();
      stage = "loading";
      pending = true;
      present("正在加载详细街道地图…");
      timer = setTimeout(() => {
        if (current === generation) fallback("地图连接超时，已使用离线轮廓。请检查网络后重试。", true);
      }, 20000);
      try {
        const url = new URL(`${origin}/styles/liberty`);
        const response = await fetch(url, { signal: aborter.signal, credentials: "omit", referrerPolicy: "no-referrer" });
        if (current !== generation) return;
        if (!response.ok) {
          const message = response.status === 429 ? "地图服务暂时繁忙，请稍后重试。" : "免费地图服务暂不可用，请稍后重试。";
          return fallback(`${message} 已使用离线轮廓。`, true);
        }
        const style = prepareStyle(await response.json());
        if (current !== generation) return;
        baseLayers = structuredClone(style.layers);
        map.setStyle(style, { diff: false });
      } catch {
        if (current === generation) fallback("街道地图加载失败，已使用离线轮廓。请检查网络或样式兼容性。", true);
      }
    }
    map.on("style.load", () => {
      if (!pending || !baseLayers.length) return;
      active = true;
      applyVisibility();
      present("街道地图已载入，正在补充当前视口细节…");
    });
    map.on("idle", () => {
      if (!active || !pending) return;
      clearTimeout(timer);
      pending = false;
      stage = "online";
      present("免费街道地图已连接，六类信息可分别开启或隐藏。" + (storageAvailable ? "" : "设置仅本次有效。"));
    });
    map.on("zoomend", refreshRows);
    for (const group of groups) {
      const label = document.createElement("label");
      label.className = "basemap-layer";
      const input = document.createElement("input");
      input.type = "checkbox";
      input.id = `basemap-${group.id}`;
      input.setAttribute("aria-label", group.name);
      const copy = document.createElement("span");
      const name = document.createElement("strong");
      name.textContent = group.name;
      const detail = document.createElement("small");
      detail.textContent = group.detail;
      copy.append(name, detail);
      const hint = document.createElement("span");
      hint.className = "basemap-layer-state";
      label.append(input, copy, hint);
      document.getElementById("basemap-layers").append(label);
      rows.set(group.id, { input, hint });
      input.addEventListener("change", () => {
        settings.groups[group.id] = input.checked;
        save();
        applyVisibility();
        refreshRows();
      });
    }
    title.addEventListener("click", () => {
      body.hidden = !body.hidden;
      title.setAttribute("aria-expanded", String(!body.hidden));
    });
    panel.addEventListener("keydown", event => {
      if (event.key !== "Escape" || body.hidden) return;
      event.preventDefault();
      event.stopPropagation();
      body.hidden = true;
      title.setAttribute("aria-expanded", "false");
      title.focus();
    });
    modeSelect.addEventListener("change", () => {
      settings.mode = modeSelect.value;
      save();
      void connect();
    });
    document.getElementById("basemap-retry").addEventListener("click", () => void connect());
    body.hidden = false;
    title.setAttribute("aria-expanded", String(!body.hidden));
    refreshRows();
    void connect();
    return {
      handleError() {
        if (stage === "failed") return true;
        if (!active && !pending) return false;
        fallback("部分地图资源加载失败，已使用离线轮廓。请检查网络 后重试。", true);
        return true;
      },
      // Diagnostic state deliberately excludes credentials, URLs and photo payloads.
      snapshot() {
        return { stage, active, groups: { ...settings.groups }, layers: baseLayers.map(layer => ({
          id: layer.id, group: category(layer), visibility: map.getLayer(layer.id) ? map.getLayoutProperty(layer.id, "visibility") || "visible" : "none"
        })) };
      }
    };
  }
  globalThis.ImageAllBasemap = Object.freeze({ create, category, prepareStyle, normalize });
})();
