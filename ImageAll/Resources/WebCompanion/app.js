"use strict";

const $ = (selector) => document.querySelector(selector);
const elements = {
  bootView: $("#bootView"),
  pairingView: $("#pairingView"),
  pairingForm: $("#pairingForm"),
  pairingToken: $("#pairingToken"),
  deviceName: $("#deviceName"),
  pairButton: $("#pairButton"),
  pairingError: $("#pairingError"),
  appView: $("#appView"),
  libraryTitle: $("#libraryTitle"),
  connectionStatus: $("#connectionStatus"),
  connectionLabel: $(".connection-label"),
  offlineBanner: $("#offlineBanner"),
  sourceSidebar: $("#sourceSidebar"),
  sourceList: $("#sourceList"),
  sourceEmpty: $("#sourceEmpty"),
  allAssetCount: $("#allAssetCount"),
  hostVersion: $("#hostVersion"),
  searchForm: $("#searchForm"),
  searchInput: $("#searchInput"),
  clearSearchButton: $("#clearSearchButton"),
  sortSelect: $("#sortSelect"),
  assetSummary: $("#assetSummary"),
  assetGrid: $("#assetGrid"),
  emptyState: $("#emptyState"),
  loadMoreButton: $("#loadMoreButton"),
  inspector: $("#inspector"),
  inspectorPlaceholder: $("#inspectorPlaceholder"),
  inspectorContent: $("#inspectorContent"),
  previewImage: $("#previewImage"),
  previewLoading: $("#previewLoading"),
  assetFileName: $("#assetFileName"),
  assetMetadata: $("#assetMetadata"),
  inspectorTags: $("#inspectorTags"),
  tagSummary: $("#tagSummary"),
  tagEmpty: $("#tagEmpty"),
  sidebarToggle: $("#sidebarToggle"),
  closeInspectorButton: $("#closeInspectorButton"),
  refreshButton: $("#refreshButton"),
  logoutButton: $("#logoutButton"),
  toast: $("#toast"),
};

const state = {
  capabilities: null,
  sources: [],
  tags: [],
  jobs: [],
  assets: [],
  nextCursor: null,
  selectedSourceID: "",
  selectedAssetID: null,
  selectedDetail: null,
  searchText: "",
  sort: "newest",
  online: false,
  loadingAssets: false,
  socket: null,
  socketGeneration: 0,
  reconnectAttempt: 0,
  eventRefreshTimer: null,
  toastTimer: null,
};

class APIError extends Error {
  constructor(status, payload) {
    super(payload?.message || `请求失败（${status}）`);
    this.status = status;
    this.code = payload?.code;
  }
}

function clientID() {
  const key = "imageall.web.client-id";
  let value = localStorage.getItem(key);
  if (!value) {
    value = crypto.randomUUID();
    localStorage.setItem(key, value);
  }
  return value;
}

function defaultDeviceName() {
  const ua = navigator.userAgent;
  if (/iPhone/i.test(ua)) return "iPhone 网页版";
  if (/iPad/i.test(ua)) return "iPad 网页版";
  if (/Macintosh/i.test(ua)) return "Mac Safari 网页版";
  return "浏览器网页版";
}

async function rawFetch(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  return fetch(path, {
    ...options,
    headers,
    credentials: "same-origin",
    cache: "no-store",
  });
}

async function parseResponse(response) {
  if (response.status === 204) return null;
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    return response.json();
  }
  return response.text();
}

async function refreshSession() {
  try {
    const response = await rawFetch("/web/session/refresh", {
      method: "POST",
      body: "{}",
    });
    return response.ok;
  } catch {
    return false;
  }
}

async function api(path, options = {}, canRefresh = true) {
  let response;
  try {
    response = await rawFetch(path, options);
  } catch (error) {
    setConnection(false);
    throw error;
  }

  if (response.status === 401 && canRefresh && await refreshSession()) {
    return api(path, options, false);
  }

  const payload = await parseResponse(response);
  if (!response.ok) {
    if (response.status >= 500) setConnection(false);
    throw new APIError(response.status, payload);
  }
  setConnection(true);
  return payload;
}

function showOnly(view) {
  for (const item of [elements.bootView, elements.pairingView, elements.appView]) {
    item.classList.toggle("hidden", item !== view);
  }
}

function showPairing(message = "") {
  disconnectEvents();
  showOnly(elements.pairingView);
  elements.pairingError.textContent = message;
  elements.pairingToken.focus({ preventScroll: true });
}

function showApp() {
  showOnly(elements.appView);
}

function setConnection(online, label) {
  state.online = online;
  const status = online ? "online" : "offline";
  elements.connectionStatus.dataset.state = status;
  elements.connectionLabel.textContent = label || (online ? "已连接" : "Mac 离线");
  elements.offlineBanner.classList.toggle("hidden", online);
  document.querySelectorAll(".tag-action").forEach((button) => {
    button.disabled = !online;
  });
}

function toast(message) {
  clearTimeout(state.toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.remove("hidden");
  state.toastTimer = setTimeout(() => elements.toast.classList.add("hidden"), 2600);
}

function formatDate(milliseconds) {
  if (!milliseconds) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(milliseconds));
}

function availabilityText(value) {
  return {
    available: "可用",
    missing: "文件缺失",
    unreadable: "不可读取",
    unsupported: "格式不支持",
  }[value] || value;
}

function sourceIcon(kind) {
  return kind === "photos" ? "▣" : "▤";
}

function clearElement(element) {
  element.replaceChildren();
}

function renderSources() {
  clearElement(elements.sourceList);
  elements.sourceEmpty.classList.toggle("hidden", state.sources.length > 0);

  for (const source of state.sources) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "sidebar-row";
    button.dataset.sourceId = source.id;
    button.classList.toggle("selected", state.selectedSourceID === source.id);
    button.disabled = source.state !== "active";

    const icon = document.createElement("span");
    icon.className = "sidebar-icon";
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = sourceIcon(source.kind);
    const name = document.createElement("span");
    name.textContent = source.displayName;
    const status = document.createElement("span");
    status.className = "sidebar-count";
    status.textContent = source.state === "active" ? "" : availabilityText(source.state);
    button.append(icon, name, status);
    elements.sourceList.append(button);
  }

  const allButton = document.querySelector('[data-source-id=""]');
  allButton?.classList.toggle("selected", state.selectedSourceID === "");
}

function renderAssets() {
  clearElement(elements.assetGrid);
  elements.emptyState.classList.toggle("hidden", state.assets.length > 0 || state.loadingAssets);
  elements.loadMoreButton.classList.toggle("hidden", !state.nextCursor);
  elements.allAssetCount.textContent = state.assets.length ? String(state.assets.length) : "";
  elements.assetSummary.textContent = state.assets.length
    ? `已载入 ${state.assets.length} 张${state.nextCursor ? " · 还有更多" : ""}`
    : "";

  for (const asset of state.assets) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "asset-card";
    button.dataset.assetId = asset.id;
    button.classList.toggle("selected", state.selectedAssetID === asset.id);
    button.setAttribute(
      "aria-label",
      `${asset.fileName || "未命名照片"}，${asset.sourceName}，已确认 ${asset.acceptedTagCount} 个标签`
    );
    button.title = [
      asset.fileName || "未命名照片",
      `来源：${asset.sourceName}`,
      asset.width && asset.height ? `尺寸：${asset.width} × ${asset.height}` : "",
      `标签：已确认 ${asset.acceptedTagCount} · 已拒绝 ${asset.rejectedTagCount}`,
    ].filter(Boolean).join("\n");

    if (asset.availability === "available") {
      const image = document.createElement("img");
      image.className = "loading";
      image.alt = "";
      image.loading = "lazy";
      image.decoding = "async";
      image.addEventListener("load", () => image.classList.remove("loading"), { once: true });
      image.addEventListener("error", () => {
        image.remove();
        button.append(unavailableBadge("缩略图不可用"));
      }, { once: true });
      image.src = `/v1/assets/${asset.id}/thumbnail?w=420&r=${asset.contentRevision}`;
      if (image.complete && image.naturalWidth > 0) {
        image.classList.remove("loading");
      }
      button.append(image);
    } else {
      button.append(unavailableBadge(availabilityText(asset.availability)));
    }

    if (asset.acceptedTagCount || asset.rejectedTagCount) {
      const meta = document.createElement("span");
      meta.className = "asset-card-meta";
      if (asset.acceptedTagCount) {
        const accepted = document.createElement("span");
        accepted.className = "asset-tag-count";
        accepted.textContent = `✓ ${asset.acceptedTagCount}`;
        meta.append(accepted);
      }
      if (asset.rejectedTagCount) {
        const rejected = document.createElement("span");
        rejected.className = "asset-tag-count";
        rejected.textContent = `× ${asset.rejectedTagCount}`;
        meta.append(rejected);
      }
      button.append(meta);
    }
    elements.assetGrid.append(button);
  }
}

function unavailableBadge(text) {
  const badge = document.createElement("span");
  badge.className = "asset-unavailable";
  badge.textContent = text;
  return badge;
}

function metadataRow(label, value) {
  const term = document.createElement("dt");
  term.textContent = label;
  const detail = document.createElement("dd");
  detail.textContent = value || "—";
  return [term, detail];
}

function renderInspector(detail) {
  state.selectedDetail = detail;
  elements.inspectorPlaceholder.classList.add("hidden");
  elements.inspectorContent.classList.remove("hidden");
  elements.inspector.classList.add("open");
  elements.assetFileName.textContent = detail.fileName || "未命名照片";

  elements.previewLoading.classList.remove("hidden");
  elements.previewImage.classList.add("hidden");
  elements.previewImage.alt = detail.fileName || "所选照片预览";
  elements.previewImage.src = `/v1/assets/${detail.assetID}/preview?r=${detail.contentRevision}`;

  clearElement(elements.assetMetadata);
  const rows = [
    metadataRow("来源", detail.sourceName),
    metadataRow("尺寸", detail.width && detail.height ? `${detail.width} × ${detail.height}` : "—"),
    metadataRow("拍摄时间", formatDate(detail.mediaCreatedAtMs)),
    metadataRow("格式", detail.mediaType),
    metadataRow("状态", availabilityText(detail.availability)),
  ];
  for (const pair of rows) elements.assetMetadata.append(...pair);

  clearElement(elements.inspectorTags);
  elements.tagEmpty.classList.toggle("hidden", detail.tags.length > 0);
  elements.tagSummary.textContent = `已确认 ${detail.acceptedTagCount} · 已拒绝 ${detail.rejectedTagCount}`;

  for (const tag of detail.tags) {
    const row = document.createElement("div");
    row.className = "tag-row";
    const name = document.createElement("span");
    name.className = "tag-name";
    name.textContent = tag.displayName;
    const actions = document.createElement("div");
    actions.className = "tag-actions";
    actions.setAttribute("role", "group");
    actions.setAttribute("aria-label", `${tag.displayName} 标签决定`);

    for (const [action, symbol, label, decision] of [
      ["accept", "✓", "确认", "accepted"],
      ["reject", "×", "拒绝", "rejected"],
      ["clear", "−", "清除", "unknown"],
    ]) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "tag-action";
      button.dataset.action = action;
      button.dataset.tagId = tag.tagID;
      button.title = `${label}“${tag.displayName}”`;
      button.setAttribute("aria-label", label);
      button.setAttribute("aria-pressed", String(tag.decision === decision));
      button.classList.toggle("active", tag.decision === decision);
      button.disabled = !state.online;
      button.textContent = symbol;
      actions.append(button);
    }
    row.append(name, actions);
    elements.inspectorTags.append(row);
  }
}

function updateLibraryTitle() {
  const source = state.sources.find((item) => item.id === state.selectedSourceID);
  elements.libraryTitle.textContent = source?.displayName || "全部照片";
}

async function loadAssets({ append = false } = {}) {
  if (state.loadingAssets) return;
  state.loadingAssets = true;
  elements.loadMoreButton.disabled = true;
  if (!append) {
    state.nextCursor = null;
    state.assets = [];
    renderAssets();
  }

  const query = new URLSearchParams({
    sort: state.sort,
    limit: "72",
  });
  if (state.selectedSourceID) query.set("sourceIDs", state.selectedSourceID);
  if (state.searchText) query.set("q", state.searchText);
  if (append && state.nextCursor) query.set("cursor", state.nextCursor);

  try {
    const page = await api(`/v1/assets?${query}`);
    state.assets = append ? state.assets.concat(page.items) : page.items;
    state.nextCursor = page.nextCursor || null;
  } finally {
    state.loadingAssets = false;
    elements.loadMoreButton.disabled = false;
    renderAssets();
  }
}

async function loadInspector(assetID) {
  state.selectedAssetID = assetID;
  renderAssets();
  elements.inspectorPlaceholder.classList.add("hidden");
  elements.inspectorContent.classList.add("hidden");
  elements.previewLoading.classList.remove("hidden");
  try {
    const detail = await api(`/v1/assets/${assetID}`);
    if (state.selectedAssetID === assetID) renderInspector(detail);
  } catch (error) {
    toast(error.message || "无法载入照片详情");
  }
}

async function loadWorkspace() {
  showApp();
  setConnection(true, "正在同步");
  const [capabilities, sources, tags, jobs] = await Promise.all([
    api("/v1/capabilities"),
    api("/v1/sources"),
    api("/v1/tags"),
    api("/v1/jobs"),
  ]);
  state.capabilities = capabilities;
  state.sources = sources;
  state.tags = tags;
  state.jobs = jobs;
  elements.hostVersion.textContent = `Mac Host ${capabilities.hostAppVersion}`;
  renderSources();
  updateLibraryTitle();
  await loadAssets();
  connectEvents();
}

async function refreshWorkspace({ quiet = false } = {}) {
  try {
    const [sources, tags, jobs] = await Promise.all([
      api("/v1/sources"),
      api("/v1/tags"),
      api("/v1/jobs"),
    ]);
    state.sources = sources;
    state.tags = tags;
    state.jobs = jobs;
    renderSources();
    await loadAssets();
    if (state.selectedAssetID) await loadInspector(state.selectedAssetID);
    if (!quiet) toast("图库已刷新");
  } catch (error) {
    if (!quiet) toast(error.message || "刷新失败");
  }
}

async function mutateTag(tagID, action, button) {
  if (!state.selectedAssetID || !state.online) return;
  const rowButtons = button.closest(".tag-actions").querySelectorAll("button");
  rowButtons.forEach((item) => { item.disabled = true; });
  try {
    const result = await api("/v1/tag-decisions/batch", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        tagID,
        assetIDs: [state.selectedAssetID],
        action,
      }),
    });
    await loadInspector(state.selectedAssetID);
    const card = state.assets.find((item) => item.id === state.selectedAssetID);
    if (card && state.selectedDetail) {
      card.acceptedTagCount = state.selectedDetail.acceptedTagCount;
      card.rejectedTagCount = state.selectedDetail.rejectedTagCount;
      renderAssets();
    }
    toast(result.replayed ? "标签操作已恢复" : "标签已更新");
  } catch (error) {
    toast(error.message || "标签更新失败");
  } finally {
    rowButtons.forEach((item) => { item.disabled = !state.online; });
  }
}

function socketURL() {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${location.host}/v1/events/websocket`;
}

function disconnectEvents() {
  state.socketGeneration += 1;
  if (state.socket) {
    state.socket.onclose = null;
    state.socket.close();
    state.socket = null;
  }
}

function scheduleEventReconnect(generation) {
  const delays = [1000, 2000, 4000, 8000, 16000, 30000];
  const delay = delays[Math.min(state.reconnectAttempt, delays.length - 1)];
  state.reconnectAttempt += 1;
  setTimeout(() => {
    if (generation === state.socketGeneration && !elements.appView.classList.contains("hidden")) {
      connectEvents();
    }
  }, delay);
}

async function connectEvents() {
  disconnectEvents();
  const generation = state.socketGeneration;
  setConnection(true, "正在连接实时更新");
  try {
    // A browser WebSocket cannot add an Authorization header. Validate (and, when
    // necessary, refresh) the HttpOnly cookie before every handshake so reconnect
    // still recovers after the one-hour access token expires.
    await api("/web/session");
  } catch (error) {
    if (generation !== state.socketGeneration) return;
    if (error.status === 401) {
      showPairing("网页会话已过期，请在 Mac 上重新配对。");
      return;
    }
    setConnection(false);
    scheduleEventReconnect(generation);
    return;
  }
  if (generation !== state.socketGeneration) return;

  const socket = new WebSocket(socketURL());
  state.socket = socket;

  socket.addEventListener("open", () => {
    if (generation !== state.socketGeneration) return;
    state.reconnectAttempt = 0;
    setConnection(true);
  });

  socket.addEventListener("message", (event) => {
    if (generation !== state.socketGeneration) return;
    try {
      const message = JSON.parse(event.data);
      if (message.kind === "ping") return;
      clearTimeout(state.eventRefreshTimer);
      state.eventRefreshTimer = setTimeout(() => refreshWorkspace({ quiet: true }), 280);
    } catch {
      // Ignore malformed server events and keep the live connection.
    }
  });

  socket.addEventListener("close", () => {
    if (generation !== state.socketGeneration) return;
    state.socket = null;
    setConnection(false);
    scheduleEventReconnect(generation);
  });

  socket.addEventListener("error", () => {
    if (generation === state.socketGeneration) setConnection(false);
  });
}

async function pair(event) {
  event.preventDefault();
  const pairingToken = elements.pairingToken.value.trim();
  const deviceName = elements.deviceName.value.trim();
  if (!pairingToken || !deviceName) return;

  elements.pairButton.disabled = true;
  elements.pairButton.textContent = "正在连接…";
  elements.pairingError.textContent = "";
  try {
    await api("/web/session/pair", {
      method: "POST",
      body: JSON.stringify({
        pairingToken,
        deviceName,
        clientID: clientID(),
      }),
    }, false);
    elements.pairingToken.value = "";
    await loadWorkspace();
  } catch (error) {
    const message = /invalidToken|noActiveOffer|offerExpired/.test(error.message)
      ? "配对码无效或已过期，请在 Mac 上重新开始配对。"
      : (error.message || "无法完成配对");
    elements.pairingError.textContent = message;
  } finally {
    elements.pairButton.disabled = false;
    elements.pairButton.textContent = "连接图库";
  }
}

async function logout() {
  try {
    await rawFetch("/web/session/logout", { method: "POST", body: "{}" });
  } finally {
    state.assets = [];
    state.selectedAssetID = null;
    state.selectedDetail = null;
    showPairing("已退出这台设备上的网页会话。");
  }
}

function bindEvents() {
  elements.pairingForm.addEventListener("submit", pair);
  elements.sourceList.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-source-id]");
    if (!button) return;
    state.selectedSourceID = button.dataset.sourceId;
    state.selectedAssetID = null;
    elements.inspector.classList.remove("open");
    renderSources();
    updateLibraryTitle();
    elements.sourceSidebar.classList.remove("open");
    await loadAssets();
  });
  document.querySelector('[data-source-id=""]').addEventListener("click", async () => {
    state.selectedSourceID = "";
    state.selectedAssetID = null;
    elements.inspector.classList.remove("open");
    renderSources();
    updateLibraryTitle();
    elements.sourceSidebar.classList.remove("open");
    await loadAssets();
  });
  elements.assetGrid.addEventListener("click", (event) => {
    const card = event.target.closest("[data-asset-id]");
    if (card) loadInspector(card.dataset.assetId);
  });
  elements.inspectorTags.addEventListener("click", (event) => {
    const button = event.target.closest("[data-action][data-tag-id]");
    if (button) mutateTag(button.dataset.tagId, button.dataset.action, button);
  });
  elements.previewImage.addEventListener("load", () => {
    elements.previewLoading.classList.add("hidden");
    elements.previewImage.classList.remove("hidden");
  });
  elements.previewImage.addEventListener("error", () => {
    elements.previewLoading.classList.add("hidden");
    toast("预览暂不可用");
  });
  elements.searchForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    state.searchText = elements.searchInput.value.trim();
    elements.clearSearchButton.classList.toggle("hidden", !state.searchText);
    await loadAssets();
  });
  elements.searchInput.addEventListener("input", () => {
    elements.clearSearchButton.classList.toggle("hidden", !elements.searchInput.value);
  });
  elements.clearSearchButton.addEventListener("click", async () => {
    elements.searchInput.value = "";
    state.searchText = "";
    elements.clearSearchButton.classList.add("hidden");
    await loadAssets();
  });
  elements.sortSelect.addEventListener("change", async () => {
    state.sort = elements.sortSelect.value;
    await loadAssets();
  });
  elements.loadMoreButton.addEventListener("click", () => loadAssets({ append: true }));
  elements.refreshButton.addEventListener("click", () => refreshWorkspace());
  elements.logoutButton.addEventListener("click", logout);
  elements.sidebarToggle.addEventListener("click", () => {
    elements.sourceSidebar.classList.toggle("open");
  });
  elements.closeInspectorButton.addEventListener("click", () => {
    elements.inspector.classList.remove("open");
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      elements.sourceSidebar.classList.remove("open");
      elements.inspector.classList.remove("open");
    }
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && !elements.appView.classList.contains("hidden")) {
      refreshWorkspace({ quiet: true });
      if (!state.socket) connectEvents();
    }
  });
}

async function boot() {
  bindEvents();
  elements.deviceName.value = defaultDeviceName();

  const hash = new URLSearchParams(location.hash.slice(1));
  const pairingToken = hash.get("pair");
  if (pairingToken) {
    elements.pairingToken.value = pairingToken;
    history.replaceState(null, "", `${location.pathname}${location.search}`);
  }

  try {
    await api("/web/session");
    await loadWorkspace();
  } catch (error) {
    const message = error.status && error.status !== 401
      ? "暂时无法连接 Mac Host，请稍后重试。"
      : "";
    showPairing(message);
  }
}

boot();
