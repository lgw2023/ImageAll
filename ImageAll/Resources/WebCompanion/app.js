"use strict";

const $ = (selector) => document.querySelector(selector);
const elements = {
  bootView: $("#bootView"),
  pairingView: $("#pairingView"),
  accountLoginTab: $("#accountLoginTab"),
  pairingLoginTab: $("#pairingLoginTab"),
  accountLoginForm: $("#accountLoginForm"),
  accountUsername: $("#accountUsername"),
  accountPassword: $("#accountPassword"),
  accountLoginButton: $("#accountLoginButton"),
  accountLoginError: $("#accountLoginError"),
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
  openLightboxButton: $("#openLightboxButton"),
  assetFileName: $("#assetFileName"),
  assetMetadata: $("#assetMetadata"),
  inspectorTags: $("#inspectorTags"),
  tagSummary: $("#tagSummary"),
  tagEmpty: $("#tagEmpty"),
  sidebarToggle: $("#sidebarToggle"),
  closeInspectorButton: $("#closeInspectorButton"),
  refreshButton: $("#refreshButton"),
  logoutButton: $("#logoutButton"),
  reviewButton: $("#reviewButton"),
  jobsButton: $("#jobsButton"),
  jobsBadge: $("#jobsBadge"),
  jobsPopover: $("#jobsPopover"),
  closeJobsButton: $("#closeJobsButton"),
  jobsList: $("#jobsList"),
  jobsEmpty: $("#jobsEmpty"),
  filterButton: $("#filterButton"),
  filterBadge: $("#filterBadge"),
  filterPopover: $("#filterPopover"),
  closeFilterButton: $("#closeFilterButton"),
  mediaKindFilter: $("#mediaKindFilter"),
  availabilityFilter: $("#availabilityFilter"),
  mediaTypeFilter: $("#mediaTypeFilter"),
  tagPresenceFilter: $("#tagPresenceFilter"),
  filterTagSelect: $("#filterTagSelect"),
  filterTagDecision: $("#filterTagDecision"),
  addTagFilterButton: $("#addTagFilterButton"),
  filterTagChips: $("#filterTagChips"),
  tagMatchModeLabel: $("#tagMatchModeLabel"),
  tagMatchMode: $("#tagMatchMode"),
  resetFiltersButton: $("#resetFiltersButton"),
  applyFiltersButton: $("#applyFiltersButton"),
  selectionModeButton: $("#selectionModeButton"),
  batchBar: $("#batchBar"),
  selectionSummary: $("#selectionSummary"),
  selectAllLoadedButton: $("#selectAllLoadedButton"),
  batchTagSelect: $("#batchTagSelect"),
  batchAggregate: $("#batchAggregate"),
  batchNewTagButton: $("#batchNewTagButton"),
  cancelSelectionButton: $("#cancelSelectionButton"),
  inspectorNewTagButton: $("#inspectorNewTagButton"),
  newTagDialog: $("#newTagDialog"),
  newTagForm: $("#newTagForm"),
  newTagName: $("#newTagName"),
  newTagTargetSummary: $("#newTagTargetSummary"),
  newTagError: $("#newTagError"),
  createTagButton: $("#createTagButton"),
  cancelNewTagButton: $("#cancelNewTagButton"),
  cancelNewTagFooterButton: $("#cancelNewTagFooterButton"),
  reviewWorkspace: $("#reviewWorkspace"),
  closeReviewButton: $("#closeReviewButton"),
  reviewSummary: $("#reviewSummary"),
  reviewTagSelect: $("#reviewTagSelect"),
  reviewCurrentSourceOnly: $("#reviewCurrentSourceOnly"),
  refreshReviewButton: $("#refreshReviewButton"),
  reviewGrid: $("#reviewGrid"),
  reviewEmpty: $("#reviewEmpty"),
  loadMoreReviewButton: $("#loadMoreReviewButton"),
  reviewPlaceholder: $("#reviewPlaceholder"),
  reviewDetail: $("#reviewDetail"),
  reviewPreviewImage: $("#reviewPreviewImage"),
  reviewOpenLightboxButton: $("#reviewOpenLightboxButton"),
  reviewFileName: $("#reviewFileName"),
  reviewOrigin: $("#reviewOrigin"),
  reviewPosition: $("#reviewPosition"),
  previousReviewButton: $("#previousReviewButton"),
  nextReviewButton: $("#nextReviewButton"),
  lightbox: $("#lightbox"),
  lightboxTitle: $("#lightboxTitle"),
  lightboxImage: $("#lightboxImage"),
  lightboxPreviousButton: $("#lightboxPreviousButton"),
  lightboxNextButton: $("#lightboxNextButton"),
  lightboxPosition: $("#lightboxPosition"),
  closeLightboxButton: $("#closeLightboxButton"),
  toast: $("#toast"),
};

const emptyFilters = () => ({
  mediaKind: "",
  availability: "",
  mediaTypes: [],
  tagPresence: "any",
  tagMatchMode: "all",
  tagConditions: [],
});

const cloneFilters = (filters) => ({
  ...filters,
  mediaTypes: [...filters.mediaTypes],
  tagConditions: filters.tagConditions.map((condition) => ({ ...condition })),
});

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
  sort: "fileNameAscending",
  filters: emptyFilters(),
  filterDraft: null,
  selectionMode: false,
  selectedAssetIDs: new Set(),
  selectionAnchorID: null,
  online: false,
  authMode: null,
  accountAuthorization: null,
  loadingAssets: false,
  loadingAggregate: false,
  review: {
    items: [],
    nextCursor: null,
    selectedIndex: -1,
    loading: false,
  },
  lightboxContext: null,
  lightboxAssetID: null,
  socket: null,
  socketGeneration: 0,
  reconnectAttempt: 0,
  eventRefreshTimer: null,
  accountPollTimer: null,
  aggregateTimer: null,
  toastTimer: null,
  newTagOperationID: null,
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

function basicAuthorization(username, password) {
  const bytes = new TextEncoder().encode(`${username}:${password}`);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `Basic ${btoa(binary)}`;
}

async function rawFetch(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (state.accountAuthorization && !headers.has("Authorization")) {
    headers.set("Authorization", state.accountAuthorization);
  }
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
  if (contentType.includes("application/json")) return response.json();
  return response.text();
}

function setProtectedImageSource(image, path) {
  if (!state.accountAuthorization) {
    image.src = path;
    return;
  }
  rawFetch(path)
    .then(async (response) => {
      if (!response.ok) throw new Error(`图片请求失败（${response.status}）`);
      const objectURL = URL.createObjectURL(await response.blob());
      const release = () => URL.revokeObjectURL(objectURL);
      image.addEventListener("load", release, { once: true });
      image.addEventListener("error", release, { once: true });
      image.src = objectURL;
    })
    .catch(() => {
      image.removeAttribute("src");
      image.dispatchEvent(new Event("error"));
    });
}

async function refreshSession() {
  if (state.authMode === "account") return false;
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

function closeOverlays() {
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  elements.jobsPopover.classList.add("hidden");
  elements.reviewWorkspace.classList.add("hidden");
  elements.lightbox.classList.add("hidden");
  state.lightboxContext = null;
  state.lightboxAssetID = null;
}

function selectAuthMethod(method) {
  const account = method === "account";
  elements.accountLoginTab.classList.toggle("active", account);
  elements.accountLoginTab.setAttribute("aria-selected", String(account));
  elements.pairingLoginTab.classList.toggle("active", !account);
  elements.pairingLoginTab.setAttribute("aria-selected", String(!account));
  elements.accountLoginForm.classList.toggle("hidden", !account);
  elements.pairingForm.classList.toggle("hidden", account);
  if (account) {
    elements.accountUsername.focus({ preventScroll: true });
  } else {
    elements.pairingToken.focus({ preventScroll: true });
  }
}

function showPairing(message = "") {
  disconnectEvents();
  closeOverlays();
  showOnly(elements.pairingView);
  elements.accountLoginError.textContent = message;
  elements.pairingError.textContent = message;
  selectAuthMethod(elements.pairingToken.value.trim() ? "pairing" : "account");
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
  document.querySelectorAll(".write-action, .tag-action, .job-action").forEach((button) => {
    button.disabled = !online;
  });
}

function toast(message) {
  clearTimeout(state.toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.remove("hidden");
  state.toastTimer = setTimeout(() => elements.toast.classList.add("hidden"), 2600);
}

function clearElement(element) {
  element.replaceChildren();
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

function tagByID(tagID) {
  return state.tags.find((tag) => tag.id === tagID);
}

function activeTags() {
  return state.tags.filter((tag) => tag.state === "active");
}

function setSelectOptions(select, tags, placeholder) {
  const previous = select.value;
  clearElement(select);
  if (placeholder) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = placeholder;
    select.append(option);
  }
  for (const tag of tags) {
    const option = document.createElement("option");
    option.value = tag.id;
    option.textContent = tag.displayName;
    select.append(option);
  }
  if ([...select.options].some((option) => option.value === previous)) {
    select.value = previous;
  }
}

function renderTagSelects() {
  const tags = activeTags();
  setSelectOptions(elements.filterTagSelect, tags, tags.length ? "选择标签" : "尚无活动标签");
  setSelectOptions(elements.batchTagSelect, tags, tags.length ? "批量标签…" : "尚无活动标签");
  setSelectOptions(elements.reviewTagSelect, tags, tags.length ? "选择审核标签" : "尚无活动标签");
  elements.filterTagSelect.disabled = tags.length === 0;
  elements.batchTagSelect.disabled = tags.length === 0;
  elements.reviewTagSelect.disabled = tags.length === 0;
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

  document.querySelector('[data-source-id=""]')
    ?.classList.toggle("selected", state.selectedSourceID === "");
}

function unavailableBadge(text) {
  const badge = document.createElement("span");
  badge.className = "asset-unavailable";
  badge.textContent = text;
  return badge;
}

function appendAssetImage(container, asset, variant = "thumbnail", before = null) {
  const insert = (node) => {
    const reference = before?.parentNode === container ? before : container.firstChild;
    container.insertBefore(node, reference);
  };
  if (asset.availability !== "available") {
    insert(unavailableBadge(availabilityText(asset.availability)));
    return;
  }
  const image = document.createElement("img");
  image.className = "loading";
  image.alt = "";
  image.loading = "lazy";
  image.decoding = "async";
  image.addEventListener("load", () => image.classList.remove("loading"), { once: true });
  image.addEventListener("error", () => {
    image.remove();
    insert(unavailableBadge("缩略图不可用"));
  }, { once: true });
  const revision = asset.contentRevision == null ? "" : `&r=${asset.contentRevision}`;
  setProtectedImageSource(
    image,
    `/v1/assets/${asset.id || asset.assetID}/${variant}?w=420${revision}`
  );
  if (image.complete && image.naturalWidth > 0) image.classList.remove("loading");
  insert(image);
}

function syncAssetCardImage(button, asset) {
  const imageKey = [
    asset.id,
    asset.availability,
    asset.contentRevision == null ? "" : asset.contentRevision,
  ].join(":");
  const current = button.querySelector("img, .asset-unavailable");
  if (button.dataset.imageKey === imageKey && current) return;
  current?.remove();
  button.dataset.imageKey = imageKey;
  appendAssetImage(button, asset, "thumbnail", button.firstChild);
}

function syncAssetCardSelectionMark(button) {
  let mark = button.querySelector(".asset-selection-mark");
  if (!state.selectionMode) {
    mark?.remove();
    return;
  }
  if (!mark) {
    mark = document.createElement("span");
    mark.className = "asset-selection-mark";
    mark.setAttribute("aria-hidden", "true");
    button.append(mark);
  }
  mark.textContent = state.selectedAssetIDs.has(button.dataset.assetId) ? "✓" : "";
}

function syncAssetCardMeta(button, asset) {
  let meta = button.querySelector(".asset-card-meta");
  if (!asset.acceptedTagCount && !asset.rejectedTagCount) {
    meta?.remove();
    return;
  }
  if (!meta) {
    meta = document.createElement("span");
    meta.className = "asset-card-meta";
    button.append(meta);
  }
  clearElement(meta);
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
}

function syncAssetCard(button, asset) {
  button.type = "button";
  button.className = "asset-card";
  button.dataset.assetId = asset.id;
  button.classList.toggle("selected", state.selectedAssetID === asset.id && !state.selectionMode);
  button.classList.toggle("batch-selected", state.selectedAssetIDs.has(asset.id));
  button.setAttribute(
    "aria-label",
    `${asset.fileName || "未命名照片"}，${asset.sourceName}，已确认 ${asset.acceptedTagCount} 个标签`
  );
  button.setAttribute("aria-pressed", String(state.selectedAssetIDs.has(asset.id)));
  button.title = [
    asset.fileName || "未命名照片",
    `来源：${asset.sourceName}`,
    asset.width && asset.height ? `尺寸：${asset.width} × ${asset.height}` : "",
    `标签：已确认 ${asset.acceptedTagCount} · 已拒绝 ${asset.rejectedTagCount}`,
  ].filter(Boolean).join("\n");
  syncAssetCardImage(button, asset);
  syncAssetCardSelectionMark(button);
  syncAssetCardMeta(button, asset);
}

function syncAssetCardPosition(button, index) {
  const currentButton = elements.assetGrid.children[index] || null;
  if (currentButton !== button) {
    elements.assetGrid.insertBefore(button, currentButton);
  }
}

function renderAssets() {
  elements.emptyState.classList.toggle("hidden", state.assets.length > 0 || state.loadingAssets);
  elements.loadMoreButton.classList.toggle("hidden", !state.nextCursor);
  elements.allAssetCount.textContent = state.assets.length ? String(state.assets.length) : "";
  elements.assetSummary.textContent = state.assets.length
    ? `已载入 ${state.assets.length} 项${state.nextCursor ? " · 还有更多" : ""}`
    : "";

  const existing = new Map(
    [...elements.assetGrid.querySelectorAll(":scope > .asset-card")]
      .map((button) => [button.dataset.assetId, button])
  );
  const visibleIDs = new Set();
  for (const [index, asset] of state.assets.entries()) {
    const button = existing.get(asset.id) || document.createElement("button");
    visibleIDs.add(asset.id);
    syncAssetCard(button, asset);
    syncAssetCardPosition(button, index);
  }
  for (const button of existing.values()) {
    if (!visibleIDs.has(button.dataset.assetId)) button.remove();
  }
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
  setProtectedImageSource(
    elements.previewImage,
    `/v1/assets/${detail.assetID}/preview?r=${detail.contentRevision}`
  );

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
  const tags = detail.tags.filter((tag) => tagByID(tag.tagID)?.state !== "archived");
  elements.tagEmpty.classList.toggle("hidden", tags.length > 0);
  elements.tagSummary.textContent = `已确认 ${detail.acceptedTagCount} · 已拒绝 ${detail.rejectedTagCount}`;

  for (const tag of tags) {
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
      button.className = "tag-action write-action";
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

function filterCount() {
  const filters = state.filters;
  return filters.tagConditions.length
    + Number(Boolean(filters.mediaKind))
    + Number(Boolean(filters.availability))
    + Number(filters.mediaTypes.length > 0)
    + Number(filters.tagPresence !== "any");
}

function renderFilterBadge() {
  const count = filterCount();
  elements.filterBadge.textContent = String(count);
  elements.filterBadge.classList.toggle("hidden", count === 0);
}

function filterDecisionText(decision) {
  return {
    accepted: "已确认",
    rejected: "已拒绝",
    excluded: "不包含",
  }[decision] || decision;
}

function renderFilterChips() {
  clearElement(elements.filterTagChips);
  const filters = state.filterDraft || state.filters;
  for (const condition of filters.tagConditions) {
    const tag = tagByID(condition.tagID);
    if (!tag) continue;
    const chip = document.createElement("span");
    chip.className = "filter-chip";
    chip.textContent = `${filterDecisionText(condition.decision)} · ${tag.displayName}`;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.dataset.removeTagFilter = condition.tagID;
    remove.setAttribute("aria-label", `移除 ${tag.displayName} 条件`);
    remove.textContent = "×";
    chip.append(remove);
    elements.filterTagChips.append(chip);
  }
  elements.tagMatchModeLabel.classList.toggle(
    "hidden",
    filters.tagConditions.filter((condition) => condition.decision !== "excluded").length < 2
  );
  renderFilterBadge();
}

function syncFilterControlsFromState() {
  const filters = state.filterDraft || state.filters;
  elements.mediaKindFilter.value = filters.mediaKind;
  elements.availabilityFilter.value = filters.availability;
  elements.mediaTypeFilter.value = filters.mediaTypes.join(",");
  elements.tagPresenceFilter.value = filters.tagPresence;
  elements.tagMatchMode.value = filters.tagMatchMode;
  renderFilterChips();
}

function updateFiltersFromControls() {
  const filters = state.filterDraft || cloneFilters(state.filters);
  filters.mediaKind = elements.mediaKindFilter.value;
  filters.availability = elements.availabilityFilter.value;
  filters.mediaTypes = elements.mediaTypeFilter.value
    ? elements.mediaTypeFilter.value.split(",")
    : [];
  filters.tagPresence = elements.tagPresenceFilter.value;
  filters.tagMatchMode = elements.tagMatchMode.value;
  if (filters.tagPresence !== "any") {
    filters.tagConditions = [];
  }
  state.filterDraft = filters;
}

function appendAdvancedFilterQuery(query) {
  const acceptedTagIDs = [];
  const rejectedTagIDs = [];
  const excludedTagIDs = [];
  for (const condition of state.filters.tagConditions) {
    if (condition.decision === "accepted") acceptedTagIDs.push(condition.tagID);
    if (condition.decision === "rejected") rejectedTagIDs.push(condition.tagID);
    if (condition.decision === "excluded") excludedTagIDs.push(condition.tagID);
  }
  if (acceptedTagIDs.length) query.set("acceptedTagIDs", acceptedTagIDs.join(","));
  if (rejectedTagIDs.length) query.set("rejectedTagIDs", rejectedTagIDs.join(","));
  if (excludedTagIDs.length) query.set("excludedTagIDs", excludedTagIDs.join(","));
  if (acceptedTagIDs.length + rejectedTagIDs.length > 1) {
    query.set("tagMatchMode", state.filters.tagMatchMode);
  }
  if (state.filters.availability) query.set("availabilities", state.filters.availability);
  if (state.filters.mediaKind) query.set("mediaKinds", state.filters.mediaKind);
  if (state.filters.mediaTypes.length) query.set("mediaTypes", state.filters.mediaTypes.join(","));
  if (state.filters.tagPresence !== "any") query.set("tagPresence", state.filters.tagPresence);
}

function assetPageFingerprint(items, nextCursor) {
  return JSON.stringify([
    nextCursor || null,
    items.map((asset) => [
      asset.id,
      asset.sourceID,
      asset.sourceName,
      asset.fileName,
      asset.mediaType,
      asset.availability,
      asset.contentRevision,
      asset.acceptedTagCount,
      asset.rejectedTagCount,
      asset.mediaCreatedAtMs,
      asset.width,
      asset.height,
    ]),
  ]);
}

function assetPageQuery({ cursor = null, limit = 72 } = {}) {
  const query = new URLSearchParams({
    sort: state.sort,
    limit: String(limit),
  });
  if (state.selectedSourceID) query.set("sourceIDs", state.selectedSourceID);
  if (state.searchText) query.set("q", state.searchText);
  if (cursor) query.set("cursor", cursor);
  appendAdvancedFilterQuery(query);
  return query;
}

async function fetchLoadedAssetWindow(targetCount) {
  const items = [];
  const seenCursors = new Set();
  let nextCursor = null;

  do {
    const remaining = Math.max(1, targetCount - items.length);
    const query = assetPageQuery({
      cursor: nextCursor,
      limit: Math.min(200, remaining),
    });
    const page = await api(`/v1/assets?${query}`);
    items.push(...page.items);
    nextCursor = page.nextCursor || null;
    if (!nextCursor || seenCursors.has(nextCursor)) break;
    seenCursors.add(nextCursor);
  } while (items.length < targetCount);

  return { items, nextCursor };
}

async function loadAssets({
  append = false,
  preserveSelection = false,
  preserveUnchangedGrid = false,
  preserveLoadedWindow = false,
} = {}) {
  if (state.loadingAssets) return;
  const loadedTargetCount = preserveLoadedWindow
    ? Math.max(72, state.assets.length)
    : 72;
  state.loadingAssets = true;
  elements.loadMoreButton.disabled = true;
  let shouldRender = !preserveUnchangedGrid;
  if (!append) {
    if (!preserveSelection) {
      state.selectedAssetIDs.clear();
      state.selectionAnchorID = null;
    }
    if (!preserveUnchangedGrid) {
      state.nextCursor = null;
      state.assets = [];
      renderAssets();
    }
  }

  try {
    const page = append
      ? await api(`/v1/assets?${assetPageQuery({ cursor: state.nextCursor })}`)
      : await fetchLoadedAssetWindow(loadedTargetCount);
    const nextAssets = append ? state.assets.concat(page.items) : page.items;
    const nextCursor = page.nextCursor || null;
    shouldRender = shouldRender
      || assetPageFingerprint(state.assets, state.nextCursor)
        !== assetPageFingerprint(nextAssets, nextCursor);
    state.assets = nextAssets;
    state.nextCursor = nextCursor;
    const visibleIDs = new Set(state.assets.map((asset) => asset.id));
    state.selectedAssetIDs = new Set(
      [...state.selectedAssetIDs].filter((assetID) => visibleIDs.has(assetID))
    );
    if (state.selectionAnchorID && !visibleIDs.has(state.selectionAnchorID)) {
      state.selectionAnchorID = null;
    }
  } finally {
    state.loadingAssets = false;
    elements.loadMoreButton.disabled = false;
    if (shouldRender) {
      renderAssets();
      renderSelectionBar();
    }
  }
  return shouldRender;
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

function setSelectionMode(enabled, { seedCurrent = false } = {}) {
  if (enabled && seedCurrent && state.selectedAssetID
    && state.assets.some((asset) => asset.id === state.selectedAssetID)) {
    state.selectedAssetIDs.add(state.selectedAssetID);
    state.selectionAnchorID = state.selectedAssetID;
  }
  state.selectionMode = enabled;
  if (!enabled) {
    state.selectedAssetIDs.clear();
    state.selectionAnchorID = null;
  }
  elements.selectionModeButton.setAttribute("aria-pressed", String(enabled));
  elements.selectionModeButton.textContent = enabled ? "完成" : "选择";
  elements.batchBar.classList.toggle("hidden", !enabled);
  renderAssets();
  renderSelectionBar();
}

function toggleAssetSelection(assetID) {
  if (state.selectedAssetIDs.has(assetID)) {
    state.selectedAssetIDs.delete(assetID);
  } else {
    state.selectedAssetIDs.add(assetID);
  }
  renderAssets();
  renderSelectionBar();
  scheduleSelectionAggregate();
}

function selectAssetRange(assetID, additive = false) {
  const anchorID = state.selectionAnchorID || state.selectedAssetID || assetID;
  const anchorIndex = state.assets.findIndex((asset) => asset.id === anchorID);
  const targetIndex = state.assets.findIndex((asset) => asset.id === assetID);
  if (anchorIndex < 0 || targetIndex < 0) return;
  const start = Math.min(anchorIndex, targetIndex);
  const end = Math.max(anchorIndex, targetIndex);
  const next = additive ? new Set(state.selectedAssetIDs) : new Set();
  for (const asset of state.assets.slice(start, end + 1)) next.add(asset.id);
  state.selectedAssetIDs = next;
  state.selectionAnchorID = anchorID;
  renderAssets();
  renderSelectionBar();
  scheduleSelectionAggregate();
}

function handleAssetSelection(assetID, { additive = false, range = false } = {}) {
  if (range) {
    if (!state.selectionMode) setSelectionMode(true, { seedCurrent: true });
    selectAssetRange(assetID, additive);
    return;
  }
  if (additive) {
    if (!state.selectionMode) setSelectionMode(true, { seedCurrent: true });
    toggleAssetSelection(assetID);
    state.selectionAnchorID = state.selectedAssetIDs.has(assetID) ? assetID : null;
    return;
  }
  if (state.selectionMode) {
    state.selectedAssetIDs = new Set([assetID]);
    state.selectionAnchorID = assetID;
    renderAssets();
    renderSelectionBar();
    scheduleSelectionAggregate();
    return;
  }
  loadInspector(assetID);
}

function selectAllLoadedAssets() {
  if (!state.assets.length) return;
  if (!state.selectionMode) setSelectionMode(true);
  state.selectedAssetIDs = new Set(state.assets.map((asset) => asset.id));
  state.selectionAnchorID = state.assets[0]?.id || null;
  renderAssets();
  renderSelectionBar();
  scheduleSelectionAggregate();
}

function currentTagTargetAssetIDs() {
  if (state.selectionMode) return [...state.selectedAssetIDs];
  return state.selectedAssetID ? [state.selectedAssetID] : [];
}

function closeNewTagDialog() {
  if (elements.newTagDialog.open) elements.newTagDialog.close();
  elements.newTagError.textContent = "";
  elements.newTagName.value = "";
  state.newTagOperationID = null;
}

function openNewTagDialog() {
  const assetIDs = currentTagTargetAssetIDs();
  if (!assetIDs.length) {
    toast("请先选择至少一张照片");
    return;
  }
  state.newTagOperationID = crypto.randomUUID();
  elements.newTagTargetSummary.textContent = `创建后将为 ${assetIDs.length} 张照片确认此标签`;
  elements.newTagError.textContent = "";
  elements.newTagName.value = "";
  elements.newTagDialog.showModal();
  elements.newTagName.focus({ preventScroll: true });
}

async function createTagAndApply(event) {
  event.preventDefault();
  const name = elements.newTagName.value.trim();
  const assetIDs = currentTagTargetAssetIDs();
  if (!name || !assetIDs.length || !state.online) return;
  const operationID = state.newTagOperationID || crypto.randomUUID();
  state.newTagOperationID = operationID;
  elements.createTagButton.disabled = true;
  elements.createTagButton.textContent = "正在创建…";
  elements.newTagError.textContent = "";
  try {
    const result = await api("/v1/tags/create-and-apply", {
      method: "POST",
      body: JSON.stringify({ operationID, name, assetIDs }),
    });
    state.tags = await api("/v1/tags");
    renderTagSelects();
    await loadAssets({
      preserveSelection: true,
      preserveLoadedWindow: true,
    });
    if (state.selectionMode) {
      elements.batchTagSelect.value = result.tagID;
      await loadSelectionAggregate();
    } else if (state.selectedAssetID) {
      await loadInspector(state.selectedAssetID);
    }
    closeNewTagDialog();
    toast(`已新增标签“${result.displayName}”并应用到 ${result.appliedAssetCount} 张照片`);
  } catch (error) {
    elements.newTagError.textContent = error.message || "新增标签失败";
  } finally {
    elements.createTagButton.disabled = !state.online;
    elements.createTagButton.textContent = "创建并确认";
  }
}

function renderSelectionBar() {
  const count = state.selectedAssetIDs.size;
  elements.selectionSummary.textContent = `已选择 ${count} 项`;
  elements.selectAllLoadedButton.textContent = count === state.assets.length && count > 0
    ? "取消全选"
    : "全选已载入";
  document.querySelectorAll(".batch-action").forEach((button) => {
    button.disabled = !state.online || count === 0 || !elements.batchTagSelect.value;
  });
  if (!count) elements.batchAggregate.textContent = "选择照片后可查看标签汇总";
}

function scheduleSelectionAggregate() {
  clearTimeout(state.aggregateTimer);
  state.aggregateTimer = setTimeout(loadSelectionAggregate, 120);
}

async function loadSelectionAggregate() {
  const tagID = elements.batchTagSelect.value;
  const assetIDs = [...state.selectedAssetIDs];
  if (!tagID || !assetIDs.length || state.loadingAggregate) {
    renderSelectionBar();
    return;
  }
  state.loadingAggregate = true;
  elements.batchAggregate.textContent = "正在统计…";
  try {
    const aggregates = await api("/v1/tags/selection", {
      method: "POST",
      body: JSON.stringify({ tagIDs: [tagID], assetIDs }),
    });
    const aggregate = aggregates[0];
    elements.batchAggregate.textContent = aggregate
      ? `确认 ${aggregate.acceptedCount} · 拒绝 ${aggregate.rejectedCount} · 未决定 ${aggregate.unknownCount}`
      : "尚无标签状态";
  } catch (error) {
    elements.batchAggregate.textContent = error.message || "无法读取标签汇总";
  } finally {
    state.loadingAggregate = false;
    renderSelectionBar();
  }
}

function confirmBatchTagDecision(action, tagName, assetCount) {
  const actionText = {
    accept: "确认",
    reject: "拒绝",
    clear: "清除",
  }[action];
  if (!actionText) return false;
  return window.confirm(
    `确认要为 ${assetCount} 张照片${actionText}标签“${tagName}”吗？`
  );
}

async function applyBatchTagDecision(action) {
  const tagID = elements.batchTagSelect.value;
  const assetIDs = [...state.selectedAssetIDs];
  if (!state.online || !tagID || !assetIDs.length) return;
  const tagName = tagByID(tagID)?.displayName || "所选";
  if (!confirmBatchTagDecision(action, tagName, assetIDs.length)) return;
  document.querySelectorAll(".batch-action").forEach((button) => { button.disabled = true; });
  try {
    const result = await api("/v1/tag-decisions/batch", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        tagID,
        assetIDs,
        action,
      }),
    });
    await loadAssets({ preserveSelection: true });
    await loadSelectionAggregate();
    toast(`已更新 ${result.appliedAssetCount} 项`);
  } catch (error) {
    toast(error.message || "批量标签更新失败");
  } finally {
    renderSelectionBar();
  }
}

function jobTitle(kind) {
  return {
    folderReconcile: "文件夹同步",
    photosReconcile: "照片图库同步",
    personalizationSuggestions: "个性化建议",
    standardSuggestions: "标准模型建议",
    librarySlimmingAnalysis: "图库瘦身分析",
    librarySlimmingSourceIndex: "来源相似度索引",
    background: "后台任务",
    other: "后台任务",
  }[kind] || "后台任务";
}

function jobStateText(job) {
  return {
    pending: "等待中",
    running: "进行中",
    paused: "已暂停",
    retryableFailed: "失败，可重试",
    completed: "已完成",
    terminalFailed: "失败",
    cancelled: "已取消",
  }[job.state] || job.state;
}

function jobActionText(action) {
  return { pause: "暂停", resume: "继续", cancel: "取消" }[action] || action;
}

function renderJobs() {
  clearElement(elements.jobsList);
  elements.jobsEmpty.classList.toggle("hidden", state.jobs.length > 0);
  const activeCount = state.jobs.filter((job) =>
    ["pending", "running", "paused", "retryableFailed"].includes(job.state)
  ).length;
  elements.jobsBadge.textContent = String(activeCount);
  elements.jobsBadge.classList.toggle("hidden", activeCount === 0);

  for (const job of state.jobs) {
    const row = document.createElement("article");
    row.className = "job-row";
    const heading = document.createElement("div");
    heading.className = "job-heading";
    const title = document.createElement("strong");
    title.textContent = jobTitle(job.kind);
    const stateLabel = document.createElement("span");
    stateLabel.className = "secondary";
    stateLabel.textContent = jobStateText(job);
    heading.append(title, stateLabel);

    const completed = Number(job.progress?.completedUnitCount || 0);
    const total = Number(job.progress?.totalUnitCount || 0);
    const percent = total > 0 ? Math.max(0, Math.min(100, completed / total * 100)) : 0;
    const progress = document.createElement("div");
    progress.className = "job-progress";
    const fill = document.createElement("span");
    fill.style.width = `${percent}%`;
    progress.append(fill);

    const stateLine = document.createElement("div");
    stateLine.className = "job-state-line";
    const amount = document.createElement("span");
    amount.textContent = total > 0 ? `${completed} / ${total}` : `${completed} 项`;
    const percentLabel = document.createElement("span");
    percentLabel.textContent = total > 0 ? `${Math.round(percent)}%` : "";
    stateLine.append(amount, percentLabel);
    row.append(heading, progress, stateLine);

    if (job.availableActions?.length) {
      const actions = document.createElement("div");
      actions.className = "job-actions";
      for (const action of job.availableActions) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "button job-action write-action";
        button.dataset.jobId = job.id;
        button.dataset.action = action;
        button.disabled = !state.online;
        button.textContent = jobActionText(action);
        actions.append(button);
      }
      row.append(actions);
    }
    elements.jobsList.append(row);
  }
}

async function applyJobAction(jobID, action, button) {
  if (!state.online) return;
  button.disabled = true;
  try {
    await api(`/v1/jobs/${jobID}/actions`, {
      method: "POST",
      body: JSON.stringify({ action }),
    });
    state.jobs = await api("/v1/jobs");
    renderJobs();
    toast(`任务已${jobActionText(action)}`);
  } catch (error) {
    toast(error.message || "任务操作失败");
  }
}

function reviewOriginText(origin) {
  return {
    featurePrint: "相似特征建议",
    standardModel: "标准模型建议",
    personalModel: "个性化模型建议",
    personalAdamW: "个性化 AdamW 建议",
  }[origin] || "模型建议";
}

function renderReview() {
  clearElement(elements.reviewGrid);
  elements.reviewEmpty.classList.toggle("hidden", state.review.items.length > 0);
  elements.loadMoreReviewButton.classList.toggle("hidden", !state.review.nextCursor);
  elements.loadMoreReviewButton.disabled = state.review.loading;
  elements.reviewSummary.textContent = state.review.loading
    ? "正在载入…"
    : `待审核 ${state.review.items.length} 项${state.review.nextCursor ? " · 还有更多" : ""}`;

  state.review.items.forEach((item, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "review-card";
    button.dataset.reviewIndex = String(index);
    button.classList.toggle("selected", index === state.review.selectedIndex);
    button.setAttribute("aria-label", `${item.fileName || "未命名照片"}，${reviewOriginText(item.suggestionOrigin)}`);
    appendAssetImage(button, item);
    const origin = document.createElement("span");
    origin.className = "review-origin-badge";
    origin.textContent = reviewOriginText(item.suggestionOrigin).replace("建议", "");
    button.append(origin);
    if (item.score != null) {
      const score = document.createElement("span");
      score.className = "review-score";
      score.textContent = `${Math.round(item.score * 100)}%`;
      button.append(score);
    }
    elements.reviewGrid.append(button);
  });
  renderReviewDetail();
}

function renderReviewDetail() {
  const item = state.review.items[state.review.selectedIndex];
  elements.reviewPlaceholder.classList.toggle("hidden", Boolean(item));
  elements.reviewDetail.classList.toggle("hidden", !item);
  if (!item) return;

  elements.reviewPreviewImage.alt = item.fileName || "审核照片预览";
  setProtectedImageSource(
    elements.reviewPreviewImage,
    `/v1/assets/${item.assetID}/preview`
  );
  elements.reviewFileName.textContent = item.fileName || "未命名照片";
  elements.reviewOrigin.textContent = [
    reviewOriginText(item.suggestionOrigin),
    item.score == null ? "" : `可信度 ${Math.round(item.score * 100)}%`,
    `已确认 ${item.acceptedTagCount} · 已拒绝 ${item.rejectedTagCount}`,
  ].filter(Boolean).join(" · ");
  elements.reviewPosition.textContent = `${state.review.selectedIndex + 1} / ${state.review.items.length}`;
  elements.previousReviewButton.disabled = state.review.selectedIndex <= 0;
  elements.nextReviewButton.disabled = state.review.selectedIndex >= state.review.items.length - 1;
  document.querySelectorAll(".review-action").forEach((button) => {
    button.disabled = !state.online;
  });
}

function selectReviewIndex(index) {
  if (!state.review.items.length) {
    state.review.selectedIndex = -1;
  } else {
    state.review.selectedIndex = Math.max(0, Math.min(index, state.review.items.length - 1));
  }
  renderReview();
  elements.reviewGrid.querySelector(".review-card.selected")?.scrollIntoView({
    block: "nearest",
    inline: "nearest",
  });
}

function reviewPageFingerprint(items, nextCursor) {
  return JSON.stringify([
    nextCursor || null,
    items.map((item) => [
      item.assetID,
      item.fileName,
      item.availability,
      item.acceptedTagCount,
      item.rejectedTagCount,
      item.suggestionOrigin,
      item.score,
    ]),
  ]);
}

async function loadReviewQueue({
  append = false,
  preserveUnchangedGrid = false,
} = {}) {
  const tagID = elements.reviewTagSelect.value;
  if (state.review.loading) return false;
  if (!tagID) {
    state.review.items = [];
    state.review.nextCursor = null;
    state.review.selectedIndex = -1;
    renderReview();
    return true;
  }

  state.review.loading = true;
  let shouldRender = !preserveUnchangedGrid;
  if (!append) {
    if (!preserveUnchangedGrid) {
      state.review.items = [];
      state.review.nextCursor = null;
      state.review.selectedIndex = -1;
    }
  }
  if (shouldRender) renderReview();
  const query = new URLSearchParams({ tagID, limit: "48" });
  if (elements.reviewCurrentSourceOnly.checked && state.selectedSourceID) {
    query.set("sourceIDs", state.selectedSourceID);
  }
  if (append && state.review.nextCursor) query.set("cursor", state.review.nextCursor);

  try {
    const page = await api(`/v1/review-queue?${query}`);
    const nextItems = append ? state.review.items.concat(page.items) : page.items;
    const nextCursor = page.nextCursor || null;
    shouldRender = shouldRender
      || reviewPageFingerprint(state.review.items, state.review.nextCursor)
        !== reviewPageFingerprint(nextItems, nextCursor);
    state.review.items = nextItems;
    state.review.nextCursor = nextCursor;
    if (state.review.selectedIndex < 0 && state.review.items.length) {
      state.review.selectedIndex = 0;
    } else if (state.review.selectedIndex >= state.review.items.length) {
      state.review.selectedIndex = state.review.items.length - 1;
    }
  } catch (error) {
    toast(error.message || "审核队列载入失败");
  } finally {
    state.review.loading = false;
    if (shouldRender) renderReview();
  }
  return shouldRender;
}

async function openReviewWorkspace() {
  elements.jobsPopover.classList.add("hidden");
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  elements.reviewWorkspace.classList.remove("hidden");
  if (!elements.reviewTagSelect.value && activeTags().length) {
    elements.reviewTagSelect.value = activeTags()[0].id;
  }
  await loadReviewQueue();
}

async function applyReviewDecision(action) {
  const item = state.review.items[state.review.selectedIndex];
  const tagID = elements.reviewTagSelect.value;
  if (!state.online || !item || !tagID) return;
  document.querySelectorAll(".review-action").forEach((button) => { button.disabled = true; });
  try {
    const result = await api("/v1/review-decisions/batch", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        tagID,
        assetIDs: [item.assetID],
        action,
      }),
    });
    const previousIndex = state.review.selectedIndex;
    await Promise.all([
      loadReviewQueue(),
      loadAssets({ preserveSelection: true }),
    ]);
    if (state.review.items.length) {
      selectReviewIndex(Math.min(previousIndex, state.review.items.length - 1));
    }
    toast(result.replayed ? "审核操作已恢复" : "审核决定已保存");
  } catch (error) {
    toast(error.message || "审核决定保存失败");
    renderReviewDetail();
  }
}

function lightboxItems() {
  if (state.lightboxContext === "review") {
    return state.review.items.map((item) => ({
      id: item.assetID,
      fileName: item.fileName,
    }));
  }
  return state.assets;
}

function openLightbox(context, assetID) {
  if (!assetID) return;
  state.lightboxContext = context;
  state.lightboxAssetID = assetID;
  elements.lightbox.classList.remove("hidden");
  renderLightbox();
}

function renderLightbox() {
  const items = lightboxItems();
  const index = items.findIndex((item) => item.id === state.lightboxAssetID);
  if (index < 0) {
    elements.lightbox.classList.add("hidden");
    return;
  }
  const item = items[index];
  elements.lightboxTitle.textContent = item.fileName || "未命名照片";
  elements.lightboxImage.alt = item.fileName || "照片全屏预览";
  setProtectedImageSource(elements.lightboxImage, `/v1/assets/${item.id}/preview`);
  elements.lightboxPosition.textContent = `${index + 1} / ${items.length}`;
  elements.lightboxPreviousButton.disabled = index <= 0;
  elements.lightboxNextButton.disabled = index >= items.length - 1;
}

function navigateLightbox(direction) {
  const items = lightboxItems();
  const index = items.findIndex((item) => item.id === state.lightboxAssetID);
  const next = index + direction;
  if (next < 0 || next >= items.length) return;
  state.lightboxAssetID = items[next].id;
  renderLightbox();
}

function navigateLibrarySelection(direction) {
  const index = state.assets.findIndex((asset) => asset.id === state.selectedAssetID);
  const next = index + direction;
  if (index < 0 || next < 0 || next >= state.assets.length) return;
  loadInspector(state.assets[next].id);
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
  renderTagSelects();
  renderJobs();
  syncFilterControlsFromState();
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
    renderTagSelects();
    renderJobs();
    renderFilterChips();
    const assetsChanged = await loadAssets({
      preserveSelection: true,
      preserveUnchangedGrid: quiet,
      preserveLoadedWindow: true,
    });
    if (state.selectedAssetID && (!quiet || assetsChanged)) {
      await loadInspector(state.selectedAssetID);
    }
    if (!elements.reviewWorkspace.classList.contains("hidden")) {
      await loadReviewQueue({ preserveUnchangedGrid: quiet });
    }
    if (!quiet) toast("图库已刷新");
  } catch (error) {
    if (!quiet) toast(error.message || "刷新失败");
  }
}

function socketURL() {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${location.host}/v1/events/websocket`;
}

function disconnectEvents() {
  state.socketGeneration += 1;
  clearTimeout(state.accountPollTimer);
  state.accountPollTimer = null;
  if (state.socket) {
    state.socket.onclose = null;
    state.socket.close();
    state.socket = null;
  }
}

function scheduleAccountPoll(generation) {
  clearTimeout(state.accountPollTimer);
  state.accountPollTimer = setTimeout(async () => {
    if (generation !== state.socketGeneration
      || state.authMode !== "account"
      || elements.appView.classList.contains("hidden")) return;
    try {
      await api("/web/session", {}, false);
      await refreshWorkspace({ quiet: true });
      setConnection(true, "账号已登录");
      scheduleAccountPoll(generation);
    } catch (error) {
      if (error.status === 401) {
        state.accountAuthorization = null;
        state.authMode = null;
        showPairing("账号密码无效或已从 Mac 白名单移除。");
      } else {
        setConnection(false);
        scheduleAccountPoll(generation);
      }
    }
  }, 10_000);
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
  if (state.authMode === "account") {
    try {
      await api("/web/session", {}, false);
      if (generation !== state.socketGeneration) return;
      state.reconnectAttempt = 0;
      setConnection(true, "账号已登录");
      scheduleAccountPoll(generation);
    } catch (error) {
      if (error.status === 401) {
        state.accountAuthorization = null;
        state.authMode = null;
        showPairing("账号密码无效或已从 Mac 白名单移除。");
      } else {
        setConnection(false);
        scheduleAccountPoll(generation);
      }
    }
    return;
  }
  setConnection(true, "正在连接实时更新");
  try {
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
      // Ignore malformed events while preserving the live connection.
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
    state.accountAuthorization = null;
    await api("/web/session/pair", {
      method: "POST",
      body: JSON.stringify({
        pairingToken,
        deviceName,
        clientID: clientID(),
      }),
    }, false);
    state.authMode = "pairedDevice";
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

async function loginWithAccount(event) {
  event.preventDefault();
  const username = elements.accountUsername.value.trim();
  const password = elements.accountPassword.value;
  if (!username || !password) return;

  elements.accountLoginButton.disabled = true;
  elements.accountLoginButton.textContent = "正在登录…";
  elements.accountLoginError.textContent = "";
  const authorization = basicAuthorization(username, password);
  state.accountAuthorization = authorization;
  try {
    const session = await api("/web/account/login", {
      method: "POST",
      body: "{}",
    }, false);
    state.authMode = session.authMode || "account";
    elements.accountPassword.value = "";
    await loadWorkspace();
  } catch (error) {
    state.accountAuthorization = null;
    state.authMode = null;
    elements.accountLoginError.textContent = error.status === 401
      ? "账号名或密码不正确，或该账号不在 Mac 白名单中。"
      : (error.message || "无法登录图库");
  } finally {
    elements.accountLoginButton.disabled = false;
    elements.accountLoginButton.textContent = "登录图库";
  }
}

async function logout() {
  try {
    await rawFetch("/web/session/logout", { method: "POST", body: "{}" });
  } finally {
    state.accountAuthorization = null;
    state.authMode = null;
    state.assets = [];
    state.selectedAssetID = null;
    state.selectedDetail = null;
    state.selectedAssetIDs.clear();
    state.selectionAnchorID = null;
    showPairing("已退出这台设备上的网页会话。");
  }
}

async function selectSource(sourceID) {
  state.selectedSourceID = sourceID;
  state.selectedAssetID = null;
  state.selectedDetail = null;
  elements.inspector.classList.remove("open");
  renderSources();
  updateLibraryTitle();
  elements.sourceSidebar.classList.remove("open");
  await loadAssets();
}

function togglePopover(popover, button) {
  const willOpen = popover.classList.contains("hidden");
  elements.filterPopover.classList.add("hidden");
  elements.jobsPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  if (willOpen) {
    popover.classList.remove("hidden");
    if (popover === elements.filterPopover) {
      state.filterDraft = cloneFilters(state.filters);
      syncFilterControlsFromState();
      elements.filterButton.setAttribute("aria-expanded", "true");
    }
  }
}

function isTextInputTarget(target) {
  return target instanceof HTMLInputElement
    || target instanceof HTMLSelectElement
    || target instanceof HTMLTextAreaElement;
}

function bindEvents() {
  elements.accountLoginTab.addEventListener("click", () => selectAuthMethod("account"));
  elements.pairingLoginTab.addEventListener("click", () => selectAuthMethod("pairing"));
  elements.accountLoginForm.addEventListener("submit", loginWithAccount);
  elements.pairingForm.addEventListener("submit", pair);
  elements.sourceList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-source-id]");
    if (button) selectSource(button.dataset.sourceId);
  });
  document.querySelector('[data-source-id=""]').addEventListener("click", () => selectSource(""));
  elements.assetGrid.addEventListener("click", (event) => {
    const card = event.target.closest("[data-asset-id]");
    if (!card) return;
    handleAssetSelection(card.dataset.assetId, {
      additive: event.metaKey || event.ctrlKey,
      range: event.shiftKey,
    });
  });
  elements.assetGrid.addEventListener("dblclick", (event) => {
    const card = event.target.closest("[data-asset-id]");
    if (card && !state.selectionMode) openLightbox("library", card.dataset.assetId);
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
  elements.openLightboxButton.addEventListener("click", () => {
    openLightbox("library", state.selectedAssetID);
  });
  elements.previewImage.addEventListener("dblclick", () => {
    openLightbox("library", state.selectedAssetID);
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

  elements.filterButton.addEventListener("click", () => {
    togglePopover(elements.filterPopover, elements.filterButton);
  });
  elements.closeFilterButton.addEventListener("click", () => {
    elements.filterPopover.classList.add("hidden");
    elements.filterButton.setAttribute("aria-expanded", "false");
    state.filterDraft = null;
  });
  elements.addTagFilterButton.addEventListener("click", () => {
    const tagID = elements.filterTagSelect.value;
    const decision = elements.filterTagDecision.value;
    if (!tagID) return;
    state.filterDraft = state.filterDraft || cloneFilters(state.filters);
    state.filterDraft.tagConditions = state.filterDraft.tagConditions
      .filter((condition) => condition.tagID !== tagID);
    state.filterDraft.tagConditions.push({ tagID, decision });
    state.filterDraft.tagPresence = "any";
    elements.tagPresenceFilter.value = "any";
    renderFilterChips();
  });
  elements.filterTagChips.addEventListener("click", (event) => {
    const button = event.target.closest("[data-remove-tag-filter]");
    if (!button) return;
    state.filterDraft = state.filterDraft || cloneFilters(state.filters);
    state.filterDraft.tagConditions = state.filterDraft.tagConditions
      .filter((condition) => condition.tagID !== button.dataset.removeTagFilter);
    renderFilterChips();
  });
  elements.resetFiltersButton.addEventListener("click", async () => {
    state.filters = emptyFilters();
    state.filterDraft = null;
    syncFilterControlsFromState();
    await loadAssets();
    elements.filterPopover.classList.add("hidden");
    elements.filterButton.setAttribute("aria-expanded", "false");
  });
  elements.applyFiltersButton.addEventListener("click", async () => {
    updateFiltersFromControls();
    state.filters = cloneFilters(state.filterDraft);
    state.filterDraft = null;
    renderFilterChips();
    await loadAssets();
    elements.filterPopover.classList.add("hidden");
    elements.filterButton.setAttribute("aria-expanded", "false");
  });

  elements.selectionModeButton.addEventListener("click", () => {
    setSelectionMode(!state.selectionMode);
  });
  elements.cancelSelectionButton.addEventListener("click", () => setSelectionMode(false));
  elements.selectAllLoadedButton.addEventListener("click", () => {
    if (state.selectedAssetIDs.size === state.assets.length && state.assets.length) {
      state.selectedAssetIDs.clear();
      state.selectionAnchorID = null;
      renderAssets();
      renderSelectionBar();
      scheduleSelectionAggregate();
    } else {
      selectAllLoadedAssets();
    }
  });
  elements.batchTagSelect.addEventListener("change", scheduleSelectionAggregate);
  elements.batchNewTagButton.addEventListener("click", openNewTagDialog);
  elements.inspectorNewTagButton.addEventListener("click", openNewTagDialog);
  elements.newTagForm.addEventListener("submit", createTagAndApply);
  elements.cancelNewTagButton.addEventListener("click", closeNewTagDialog);
  elements.cancelNewTagFooterButton.addEventListener("click", closeNewTagDialog);
  elements.newTagDialog.addEventListener("cancel", () => {
    state.newTagOperationID = null;
    elements.newTagError.textContent = "";
    elements.newTagName.value = "";
  });
  elements.batchBar.addEventListener("click", (event) => {
    const button = event.target.closest(".batch-action");
    if (button) applyBatchTagDecision(button.dataset.action);
  });

  elements.jobsButton.addEventListener("click", () => {
    togglePopover(elements.jobsPopover, elements.jobsButton);
  });
  elements.closeJobsButton.addEventListener("click", () => {
    elements.jobsPopover.classList.add("hidden");
  });
  elements.jobsList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-job-id][data-action]");
    if (button) applyJobAction(button.dataset.jobId, button.dataset.action, button);
  });

  elements.reviewButton.addEventListener("click", openReviewWorkspace);
  elements.closeReviewButton.addEventListener("click", () => {
    elements.reviewWorkspace.classList.add("hidden");
  });
  elements.reviewTagSelect.addEventListener("change", () => loadReviewQueue());
  elements.reviewCurrentSourceOnly.addEventListener("change", () => loadReviewQueue());
  elements.refreshReviewButton.addEventListener("click", () => loadReviewQueue());
  elements.loadMoreReviewButton.addEventListener("click", () => loadReviewQueue({ append: true }));
  elements.reviewGrid.addEventListener("click", (event) => {
    const card = event.target.closest("[data-review-index]");
    if (card) selectReviewIndex(Number(card.dataset.reviewIndex));
  });
  elements.previousReviewButton.addEventListener("click", () => {
    selectReviewIndex(state.review.selectedIndex - 1);
  });
  elements.nextReviewButton.addEventListener("click", () => {
    selectReviewIndex(state.review.selectedIndex + 1);
  });
  elements.reviewDetail.addEventListener("click", (event) => {
    const button = event.target.closest(".review-action");
    if (button) applyReviewDecision(button.dataset.action);
  });
  elements.reviewOpenLightboxButton.addEventListener("click", () => {
    const item = state.review.items[state.review.selectedIndex];
    openLightbox("review", item?.assetID);
  });
  elements.reviewPreviewImage.addEventListener("dblclick", () => {
    const item = state.review.items[state.review.selectedIndex];
    openLightbox("review", item?.assetID);
  });

  elements.closeLightboxButton.addEventListener("click", () => {
    elements.lightbox.classList.add("hidden");
    state.lightboxContext = null;
  });
  elements.lightboxPreviousButton.addEventListener("click", () => navigateLightbox(-1));
  elements.lightboxNextButton.addEventListener("click", () => navigateLightbox(1));

  document.addEventListener("click", (event) => {
    if (!elements.filterPopover.classList.contains("hidden")
      && !elements.filterPopover.contains(event.target)
      && !elements.filterButton.contains(event.target)) {
      elements.filterPopover.classList.add("hidden");
      elements.filterButton.setAttribute("aria-expanded", "false");
      state.filterDraft = null;
    }
    if (!elements.jobsPopover.classList.contains("hidden")
      && !elements.jobsPopover.contains(event.target)
      && !elements.jobsButton.contains(event.target)) {
      elements.jobsPopover.classList.add("hidden");
    }
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      if (elements.newTagDialog.open) {
        closeNewTagDialog();
        return;
      }
      if (!elements.lightbox.classList.contains("hidden")) {
        elements.lightbox.classList.add("hidden");
        state.lightboxContext = null;
        return;
      }
      if (!elements.reviewWorkspace.classList.contains("hidden")) {
        elements.reviewWorkspace.classList.add("hidden");
        return;
      }
      elements.filterPopover.classList.add("hidden");
      elements.filterButton.setAttribute("aria-expanded", "false");
      elements.jobsPopover.classList.add("hidden");
      elements.sourceSidebar.classList.remove("open");
      elements.inspector.classList.remove("open");
      return;
    }
    if (isTextInputTarget(event.target)) return;
    if (!elements.lightbox.classList.contains("hidden")) {
      if (event.key === "ArrowLeft") navigateLightbox(-1);
      if (event.key === "ArrowRight") navigateLightbox(1);
      return;
    }
    if (!elements.reviewWorkspace.classList.contains("hidden")) {
      if (event.key === "ArrowLeft") selectReviewIndex(state.review.selectedIndex - 1);
      if (event.key === "ArrowRight") selectReviewIndex(state.review.selectedIndex + 1);
      if (event.key.toLowerCase() === "a") applyReviewDecision("accept");
      if (event.key.toLowerCase() === "r") applyReviewDecision("reject");
      if (event.key.toLowerCase() === "c") applyReviewDecision("clear");
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") {
      event.preventDefault();
      selectAllLoadedAssets();
      return;
    }
    if (state.selectedAssetID && elements.inspector.classList.contains("open")) {
      if (event.key === "ArrowLeft") navigateLibrarySelection(-1);
      if (event.key === "ArrowRight") navigateLibrarySelection(1);
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
  renderSelectionBar();

  const hash = new URLSearchParams(location.hash.slice(1));
  const pairingToken = hash.get("pair");
  if (pairingToken) {
    elements.pairingToken.value = pairingToken;
    selectAuthMethod("pairing");
    history.replaceState(null, "", `${location.pathname}${location.search}`);
  }

  try {
    const session = await api("/web/session");
    state.authMode = session.authMode || "pairedDevice";
    await loadWorkspace();
  } catch (error) {
    const message = error.status && error.status !== 401
      ? "暂时无法连接 Mac Host，请稍后重试。"
      : "";
    showPairing(message);
  }
}

boot();
