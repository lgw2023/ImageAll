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
  workspace: $("#workspace"),
  sourceSidebar: $("#sourceSidebar"),
  sourceList: $("#sourceList"),
  sourceEmpty: $("#sourceEmpty"),
  allAssetCount: $("#allAssetCount"),
  allMediaLabel: $("#allMediaLabel"),
  untaggedNavigationButton: $("#untaggedNavigationButton"),
  reviewNavigationButton: $("#reviewNavigationButton"),
  reviewNavigationCount: $("#reviewNavigationCount"),
  tagNavigation: $("#tagNavigation"),
  tagNavigationSearch: $("#tagNavigationSearch"),
  tagNavigationEmpty: $("#tagNavigationEmpty"),
  sidebarNewTagButton: $("#sidebarNewTagButton"),
  hostVersion: $("#hostVersion"),
  mediaKindTabs: $("#mediaKindTabs"),
  libraryPane: $("#libraryPane"),
  filterTitle: $("#filterTitle"),
  tagPresenceAnyOption: $("#tagPresenceAnyOption"),
  searchForm: $("#searchForm"),
  searchInput: $("#searchInput"),
  clearSearchButton: $("#clearSearchButton"),
  sortSelect: $("#sortSelect"),
  assetSummary: $("#assetSummary"),
  assetGrid: $("#assetGrid"),
  libraryScroll: $("#libraryScroll"),
  loadMoreSentinel: $("#loadMoreSentinel"),
  marqueeSelection: $("#marqueeSelection"),
  emptyState: $("#emptyState"),
  emptyStateTitle: $("#emptyStateTitle"),
  emptyStateCopy: $("#emptyStateCopy"),
  loadMoreButton: $("#loadMoreButton"),
  gridDensitySlider: $("#gridDensitySlider"),
  inspector: $("#inspector"),
  inspectorPlaceholder: $("#inspectorPlaceholder"),
  inspectorPlaceholderText: $("#inspectorPlaceholderText"),
  selectionInspector: $("#selectionInspector"),
  selectionInspectorTitle: $("#selectionInspectorTitle"),
  selectionInspectorTags: $("#selectionInspectorTags"),
  selectionInspectorNewTagButton: $("#selectionInspectorNewTagButton"),
  selectionTagSearch: $("#selectionTagSearch"),
  inspectorContent: $("#inspectorContent"),
  previewImage: $("#previewImage"),
  previewLoading: $("#previewLoading"),
  openLightboxButton: $("#openLightboxButton"),
  assetFileName: $("#assetFileName"),
  assetMetadata: $("#assetMetadata"),
  inspectorTags: $("#inspectorTags"),
  inspectorTagSearch: $("#inspectorTagSearch"),
  tagSummary: $("#tagSummary"),
  tagEmpty: $("#tagEmpty"),
  sidebarToggle: $("#sidebarToggle"),
  sidebarVisibilityButton: $("#sidebarVisibilityButton"),
  inspectorVisibilityButton: $("#inspectorVisibilityButton"),
  closeInspectorButton: $("#closeInspectorButton"),
  inspectorPreviousButton: $("#inspectorPreviousButton"),
  inspectorNextButton: $("#inspectorNextButton"),
  inspectorPosition: $("#inspectorPosition"),
  inspectorNavigation: $("#inspectorNavigation"),
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
  commandButton: $("#commandButton"),
  shortcutButton: $("#shortcutButton"),
  commandPalette: $("#commandPalette"),
  commandSearchInput: $("#commandSearchInput"),
  commandList: $("#commandList"),
  shortcutDialog: $("#shortcutDialog"),
  closeShortcutButton: $("#closeShortcutButton"),
  assetContextMenu: $("#assetContextMenu"),
  toast: $("#toast"),
};

const emptyFilters = () => ({
  mediaKind: "image",
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
  mediaKind: "image",
  workspaceGeneration: 0,
  inspectorRequestGeneration: 0,
  mediaSessions: {
    image: null,
    video: null,
  },
  filterDraft: null,
  selectionMode: false,
  selectedAssetIDs: new Set(),
  selectionAnchorID: null,
  inspectorDismissed: false,
  online: false,
  authMode: null,
  accountAuthorization: null,
  loadingAssets: false,
  loadingAggregate: false,
  selectionAggregates: [],
  aggregateGeneration: 0,
  tagMutating: false,
  jobMutatingIDs: new Set(),
  inspectorTagSearchText: "",
  selectionTagSearchText: "",
  review: {
    items: [],
    nextCursor: null,
    selectedIndex: -1,
    loading: false,
    mutating: false,
    requestGeneration: 0,
    loadedScopeKey: null,
    deferredItemIDs: new Set(),
  },
  lightboxContext: null,
  lightboxAssetID: null,
  socket: null,
  socketGeneration: 0,
  reconnectAttempt: 0,
  eventRefreshTimer: null,
  pendingRefreshKinds: new Set(),
  pendingInspectorRefresh: false,
  refreshingWorkspace: false,
  accountPollTimer: null,
  aggregateTimer: null,
  assetLoadPromise: null,
  queuedAssetLoadOptions: null,
  refreshRetryTimer: null,
  refreshRetryAttempt: 0,
  toastTimer: null,
  newTagOperationID: null,
  autoLoadObserver: null,
  searchTimer: null,
  commandItems: [],
  commandIndex: 0,
  contextAssetID: null,
  marquee: null,
  reviewReturnFocus: null,
  lightboxReturnFocus: null,
  layout: {
    sidebarVisible: true,
    inspectorVisible: true,
    density: 4,
  },
};

const densityWidths = [74, 86, 100, 116, 132, 156, 184, 220, 268];
const protectedImageRequests = new WeakMap();
const protectedImageAbortControllers = new WeakMap();
let protectedImageRequestSequence = 0;

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

function rawFetch(path, options = {}) {
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

function parseResponse(response) {
  if (response.status === 204) return null;
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) return response.json();
  return response.text();
}

function dispatchProtectedImageEvent(image, type, requestID) {
  if (protectedImageRequests.get(image) !== requestID) return;
  image.dispatchEvent(new CustomEvent(type, {
    detail: { requestID },
  }));
}

function failProtectedImage(image, requestID) {
  if (protectedImageRequests.get(image) !== requestID) return;
  delete image.dataset.protectedPath;
  image.dataset.protectedAssignedRequestId = String(requestID);
  image.removeAttribute("src");
  dispatchProtectedImageEvent(image, "imageall-protected-error", requestID);
  image.dispatchEvent(new Event("error"));
}

async function monitorProtectedImageDecode(image, requestID, objectURL = null) {
  try {
    await image.decode();
    dispatchProtectedImageEvent(image, "imageall-protected-load", requestID);
  } catch {
    failProtectedImage(image, requestID);
  } finally {
    if (objectURL) URL.revokeObjectURL(objectURL);
  }
}

function setProtectedImageSource(image, path) {
  if (image.dataset.protectedPath === path) return;
  protectedImageAbortControllers.get(image)?.abort();
  protectedImageAbortControllers.delete(image);
  const requestID = ++protectedImageRequestSequence;
  protectedImageRequests.set(image, requestID);
  image.dataset.protectedRequestId = String(requestID);
  image.dataset.protectedPath = path;
  delete image.dataset.protectedAssignedRequestId;
  image.removeAttribute("src");
  if (!state.accountAuthorization) {
    image.dataset.protectedAssignedRequestId = String(requestID);
    image.src = path;
    void monitorProtectedImageDecode(image, requestID);
    return;
  }
  const controller = new AbortController();
  protectedImageAbortControllers.set(image, controller);
  rawFetch(path, { signal: controller.signal })
    .then(async (response) => {
      if (!response.ok) throw new Error(`图片请求失败（${response.status}）`);
      const blob = await response.blob();
      if (protectedImageRequests.get(image) !== requestID) return;
      const objectURL = URL.createObjectURL(blob);
      if (protectedImageRequests.get(image) !== requestID) {
        URL.revokeObjectURL(objectURL);
        return;
      }
      image.dataset.protectedAssignedRequestId = String(requestID);
      image.src = objectURL;
      await monitorProtectedImageDecode(image, requestID, objectURL);
    })
    .catch((error) => {
      if (error?.name === "AbortError") return;
      failProtectedImage(image, requestID);
    })
    .finally(() => {
      if (protectedImageAbortControllers.get(image) === controller) {
        protectedImageAbortControllers.delete(image);
      }
    });
}

function clearProtectedImageSource(image) {
  protectedImageAbortControllers.get(image)?.abort();
  protectedImageAbortControllers.delete(image);
  const requestID = ++protectedImageRequestSequence;
  protectedImageRequests.set(image, requestID);
  image.dataset.protectedRequestId = String(requestID);
  delete image.dataset.protectedPath;
  delete image.dataset.protectedAssignedRequestId;
  image.removeAttribute("src");
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
  elements.sourceSidebar.classList.remove("open");
  elements.assetContextMenu.classList.add("hidden");
  state.contextAssetID = null;
  if (elements.commandPalette.open) elements.commandPalette.close();
  if (elements.shortcutDialog.open) elements.shortcutDialog.close();
  if (elements.newTagDialog.open) closeNewTagDialog();
  elements.reviewWorkspace.classList.add("hidden");
  elements.reviewWorkspace.inert = false;
  elements.lightbox.classList.add("hidden");
  elements.appView.inert = false;
  clearProtectedImageSource(elements.lightboxImage);
  state.lightboxContext = null;
  state.lightboxAssetID = null;
  state.reviewReturnFocus = null;
  state.lightboxReturnFocus = null;
}

function restoreOverlayFocus(target) {
  if (!(target instanceof HTMLElement) || !document.contains(target)) return;
  requestAnimationFrame(() => target.focus({ preventScroll: true }));
}

function closeInspectorOverlay() {
  state.inspectorDismissed = true;
  elements.inspector.classList.remove("open");
  const assetID = state.selectionMode && state.selectedAssetIDs.size === 1
    ? [...state.selectedAssetIDs][0]
    : state.selectedAssetID;
  restoreOverlayFocus(
    assetID
      ? elements.assetGrid.querySelector(`[data-asset-id="${assetID}"]`)
      : elements.selectionModeButton
  );
}

function closeReviewWorkspace() {
  elements.reviewWorkspace.classList.add("hidden");
  elements.reviewWorkspace.inert = false;
  elements.appView.inert = false;
  const returnFocus = state.reviewReturnFocus;
  state.reviewReturnFocus = null;
  restoreOverlayFocus(returnFocus);
}

function closeLightbox() {
  elements.lightbox.classList.add("hidden");
  clearProtectedImageSource(elements.lightboxImage);
  state.lightboxContext = null;
  state.lightboxAssetID = null;
  elements.reviewWorkspace.inert = false;
  if (elements.reviewWorkspace.classList.contains("hidden")) {
    elements.appView.inert = false;
  }
  const returnFocus = state.lightboxReturnFocus;
  state.lightboxReturnFocus = null;
  restoreOverlayFocus(returnFocus);
}

function focusableOverlayElements(container) {
  return [...container.querySelectorAll(
    "button:not([disabled]), input:not([disabled]), select:not([disabled]), "
      + "textarea:not([disabled]), a[href], [tabindex]:not([tabindex=\"-1\"])"
  )].filter((element) => element.getClientRects().length > 0);
}

function trapOverlayFocus(event, container) {
  if (event.key !== "Tab") return false;
  const focusable = focusableOverlayElements(container);
  if (!focusable.length) return false;
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (!container.contains(document.activeElement)) {
    event.preventDefault();
    (event.shiftKey ? last : first).focus({ preventScroll: true });
    return true;
  }
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus({ preventScroll: true });
    return true;
  }
  if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus({ preventScroll: true });
    return true;
  }
  return false;
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
  state.accountAuthorization = null;
  state.authMode = null;
  resetWorkspaceSessionState();
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
  syncWriteActionControls();
}

function toast(message) {
  clearTimeout(state.toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.remove("hidden");
  state.toastTimer = setTimeout(() => elements.toast.classList.add("hidden"), 2600);
}

function clearElement(element) {
  element.querySelectorAll("img[data-protected-path]").forEach(clearProtectedImageSource);
  element.replaceChildren();
}

function syncWriteActionControls() {
  elements.batchTagSelect.disabled = !state.online
    || state.tagMutating
    || activeTags().length === 0;
  document.querySelectorAll(".write-action, .tag-action, .job-action").forEach((button) => {
    const isReviewAction = button.classList.contains("review-action");
    const isJobAction = button.classList.contains("job-action");
    const isBatchAction = button.classList.contains("batch-action");
    const isSelectionTagAction = Boolean(button.closest("#selectionInspectorTags"));
    const reviewLocked = isReviewAction
      && (state.review.loading || state.review.mutating);
    const jobLocked = isJobAction
      && state.jobMutatingIDs.has(button.dataset.jobId);
    const tagLocked = !isReviewAction && !isJobAction && state.tagMutating;
    const batchUnavailable = isBatchAction
      && (!state.selectedAssetIDs.size || !elements.batchTagSelect.value);
    const aggregateUnavailable = isSelectionTagAction
      && (!state.selectedAssetIDs.size || state.loadingAggregate);
    button.disabled = !state.online
      || reviewLocked
      || jobLocked
      || tagLocked
      || batchUnavailable
      || aggregateUnavailable;
  });
}

function persistWorkspacePreferences() {
  localStorage.setItem("imageall.web.workspace-preferences", JSON.stringify({
    sidebarVisible: state.layout.sidebarVisible,
    inspectorVisible: state.layout.inspectorVisible,
    density: state.layout.density,
  }));
}

function loadWorkspacePreferences() {
  try {
    const saved = JSON.parse(
      localStorage.getItem("imageall.web.workspace-preferences") || "{}"
    );
    if (typeof saved.sidebarVisible === "boolean") {
      state.layout.sidebarVisible = saved.sidebarVisible;
    }
    if (typeof saved.inspectorVisible === "boolean") {
      state.layout.inspectorVisible = saved.inspectorVisible;
    }
    if (Number.isInteger(saved.density) && saved.density >= 0 && saved.density <= 8) {
      state.layout.density = saved.density;
    }
  } catch {
    // Invalid UI preferences are ignored; credentials are never stored here.
  }
}

function renderLayoutPreferences() {
  elements.workspace.classList.toggle("sidebar-hidden", !state.layout.sidebarVisible);
  elements.workspace.classList.toggle("inspector-hidden", !state.layout.inspectorVisible);
  elements.sidebarVisibilityButton.setAttribute(
    "aria-pressed",
    String(state.layout.sidebarVisible)
  );
  elements.sidebarVisibilityButton.setAttribute(
    "aria-label",
    state.layout.sidebarVisible ? "隐藏侧栏" : "显示侧栏"
  );
  elements.sidebarVisibilityButton.title = state.layout.sidebarVisible ? "隐藏侧栏" : "显示侧栏";
  elements.inspectorVisibilityButton.setAttribute(
    "aria-pressed",
    String(state.layout.inspectorVisible)
  );
  elements.inspectorVisibilityButton.setAttribute(
    "aria-label",
    state.layout.inspectorVisible ? "隐藏检查器" : "显示检查器"
  );
  elements.inspectorVisibilityButton.title = state.layout.inspectorVisible
    ? "隐藏检查器"
    : "显示检查器";
  elements.gridDensitySlider.value = String(state.layout.density);
  document.documentElement.style.setProperty(
    "--asset-min-width",
    `${densityWidths[state.layout.density]}px`
  );
}

function setSidebarVisible(visible) {
  state.layout.sidebarVisible = visible;
  renderLayoutPreferences();
  persistWorkspacePreferences();
}

function setInspectorVisible(visible) {
  state.layout.inspectorVisible = visible;
  renderLayoutPreferences();
  persistWorkspacePreferences();
}

function captureMediaSession() {
  state.mediaSessions[state.mediaKind] = {
    assets: state.assets.map((asset) => ({ ...asset })),
    nextCursor: state.nextCursor,
    selectedSourceID: state.selectedSourceID,
    selectedAssetID: state.selectedAssetID,
    selectedDetail: state.selectedDetail,
    searchText: state.searchText,
    sort: state.sort,
    filters: cloneFilters(state.filters),
    selectionMode: state.selectionMode,
    selectedAssetIDs: [...state.selectedAssetIDs],
    selectionAnchorID: state.selectionAnchorID,
    inspectorDismissed: state.inspectorDismissed,
    scrollTop: elements.libraryScroll.scrollTop,
  };
}

function currentMediaNoun() {
  return state.mediaKind === "video" ? "视频" : "照片";
}

function mediaItemCountText(count) {
  return state.mediaKind === "video" ? `${count} 个视频` : `${count} 张照片`;
}

function renderMediaKindLabels() {
  const noun = currentMediaNoun();
  elements.allMediaLabel.textContent = `全部${noun}`;
  elements.libraryPane.setAttribute("aria-label", `${noun}图库`);
  elements.filterTitle.textContent = `筛选${noun}`;
  elements.tagPresenceAnyOption.textContent = `全部${noun}`;
  elements.emptyStateTitle.textContent = `没有找到${noun}`;
  elements.emptyStateCopy.textContent = `尝试选择其他来源或清除${noun}筛选条件。`;
  elements.inspector.setAttribute("aria-label", `${noun}检查器`);
  elements.inspectorPlaceholderText.textContent = `选择一个${noun}以查看详细信息和标签`;
  elements.inspectorNavigation.setAttribute("aria-label", `${noun}导航`);
  elements.inspectorPreviousButton.setAttribute("aria-label", `上一个${noun}`);
  elements.inspectorNextButton.setAttribute("aria-label", `下一个${noun}`);
  elements.sidebarNewTagButton.title = `为所选${noun}新增标签`;
  elements.lightbox.setAttribute("aria-label", `${noun}全屏预览`);
}

function renderMediaKindTabs() {
  for (const button of elements.mediaKindTabs.querySelectorAll("[data-media-kind]")) {
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.mediaKind === state.mediaKind)
    );
  }
  renderMediaKindLabels();
}

function syncSelectionModeControls() {
  elements.selectionModeButton.setAttribute("aria-pressed", String(state.selectionMode));
  elements.selectionModeButton.textContent = state.selectionMode ? "完成" : "选择";
  elements.batchBar.classList.toggle("hidden", !state.selectionMode);
}

async function switchMediaKind(mediaKind) {
  if (!["image", "video"].includes(mediaKind) || mediaKind === state.mediaKind) return;
  clearTimeout(state.searchTimer);
  state.searchTimer = null;
  captureMediaSession();
  const saved = state.mediaSessions[mediaKind];
  state.mediaKind = mediaKind;
  state.filterDraft = null;
  state.selectionAggregates = [];

  if (saved) {
    state.assets = saved.assets.map((asset) => ({ ...asset }));
    state.nextCursor = saved.nextCursor;
    state.selectedSourceID = saved.selectedSourceID;
    state.selectedAssetID = saved.selectedAssetID;
    state.selectedDetail = saved.selectedDetail;
    state.searchText = saved.searchText;
    state.sort = saved.sort;
    state.filters = cloneFilters(saved.filters);
    state.filters.mediaKind = mediaKind;
    state.selectionMode = saved.selectionMode;
    state.selectedAssetIDs = new Set(saved.selectedAssetIDs);
    state.selectionAnchorID = saved.selectionAnchorID;
    state.inspectorDismissed = Boolean(saved.inspectorDismissed);
  } else {
    state.assets = [];
    state.nextCursor = null;
    state.selectedSourceID = "";
    state.selectedAssetID = null;
    state.selectedDetail = null;
    state.searchText = "";
    state.sort = "fileNameAscending";
    state.filters = emptyFilters();
    state.filters.mediaKind = mediaKind;
    state.selectionMode = false;
    state.selectedAssetIDs.clear();
    state.selectionAnchorID = null;
    state.inspectorDismissed = false;
  }

  elements.searchInput.value = state.searchText;
  elements.clearSearchButton.classList.toggle("hidden", !state.searchText);
  elements.sortSelect.value = state.sort;
  renderMediaKindTabs();
  renderSources();
  renderTagNavigation();
  syncFilterControlsFromState();
  updateLibraryTitle();
  syncSelectionModeControls();
  renderAssets();
  renderSelectionBar();
  if (!state.selectionMode && saved?.selectedDetail) {
    renderInspector(saved.selectedDetail);
  }
  requestAnimationFrame(() => {
    elements.libraryScroll.scrollTop = saved?.scrollTop || 0;
  });
  await loadAssets({
    preserveSelection: true,
    preserveUnchangedGrid: Boolean(saved),
    preserveLoadedWindow: Boolean(saved),
  });
  if (!state.selectionMode && state.selectedAssetID) {
    await loadInspector(state.selectedAssetID, {
      preserveExisting: Boolean(saved?.selectedDetail),
    });
  } else if (state.selectionMode && state.selectedAssetIDs.size) {
    scheduleSelectionAggregate();
  }
  captureMediaSession();
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

function sourceStateText(stateValue) {
  return {
    active: "",
    disabled: "已停用",
    unavailable: "离线",
    authorizationRequired: "需授权",
  }[stateValue] ?? stateValue;
}

function tagByID(tagID) {
  return state.tags.find((tag) => tag.id === tagID);
}

function activeTags() {
  return state.tags.filter((tag) => tag.state === "active");
}

function projectionFingerprint(value) {
  return JSON.stringify(value);
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
  elements.batchTagSelect.disabled = tags.length === 0 || state.tagMutating;
  elements.reviewTagSelect.disabled = tags.length === 0
    || state.review.loading
    || state.review.mutating;
  renderTagNavigation();
  renderCommandItems();
}

function quickIncludedTagID() {
  const included = state.filters.tagConditions.filter(
    (condition) => condition.decision === "accepted"
  );
  const hasOtherTagCondition = state.filters.tagConditions.some(
    (condition) => condition.decision !== "accepted"
  );
  return included.length === 1 && !hasOtherTagCondition ? included[0].tagID : null;
}

function renderTagNavigation() {
  const query = elements.tagNavigationSearch.value.trim().toLocaleLowerCase("zh-CN");
  const tags = activeTags().filter((tag) => (
    !query || tag.displayName.toLocaleLowerCase("zh-CN").includes(query)
  ));
  const selectedTagID = quickIncludedTagID();
  clearElement(elements.tagNavigation);
  elements.tagNavigationEmpty.classList.toggle("hidden", tags.length > 0);

  for (const tag of tags) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "sidebar-tag-chip";
    button.dataset.quickTagId = tag.id;
    button.textContent = tag.displayName;
    button.title = `只显示已确认“${tag.displayName}”的${state.mediaKind === "video" ? "视频" : "照片"}`;
    button.classList.toggle("selected", selectedTagID === tag.id);
    button.setAttribute("aria-pressed", String(selectedTagID === tag.id));
    elements.tagNavigation.append(button);
  }
  elements.untaggedNavigationButton.classList.toggle(
    "selected",
    state.filters.tagPresence === "untagged"
  );
}

async function applyQuickTagFilter(tagID) {
  const alreadySelected = quickIncludedTagID() === tagID
    && state.filters.tagPresence === "any";
  state.filters.tagConditions = alreadySelected
    ? []
    : [{ tagID, decision: "accepted" }];
  state.filters.tagPresence = "any";
  state.filters.tagMatchMode = "all";
  state.filterDraft = null;
  renderTagNavigation();
  syncFilterControlsFromState();
  await loadAssets();
}

async function applyUntaggedFilter() {
  const clearing = state.filters.tagPresence === "untagged";
  state.filters.tagPresence = clearing ? "any" : "untagged";
  state.filters.tagConditions = [];
  state.filterDraft = null;
  renderTagNavigation();
  syncFilterControlsFromState();
  await loadAssets();
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
    button.classList.toggle("unavailable", source.state !== "active");

    const icon = document.createElement("span");
    icon.className = "sidebar-icon";
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = sourceIcon(source.kind);
    const name = document.createElement("span");
    name.textContent = source.displayName;
    const status = document.createElement("span");
    status.className = "sidebar-count";
    status.textContent = sourceStateText(source.state);
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
  const assetID = asset.id || asset.assetID;
  const imageKey = [
    assetID,
    asset.availability,
    asset.contentRevision == null ? "" : asset.contentRevision,
  ].join(":");
  const current = button.querySelector("img, .asset-unavailable");
  if (button.dataset.imageKey === imageKey && current) return;
  if (current instanceof HTMLImageElement) clearProtectedImageSource(current);
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
  button.setAttribute(
    "aria-pressed",
    String(state.selectionMode
      ? state.selectedAssetIDs.has(asset.id)
      : state.selectedAssetID === asset.id)
  );
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
  elements.allAssetCount.textContent = state.assets.length
    ? `${state.assets.length}${state.nextCursor ? "+" : ""}`
    : "";
  elements.allAssetCount.title = state.assets.length
    ? `当前已载入 ${state.assets.length} 项${state.nextCursor ? "，还有更多" : ""}`
    : "";
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
    if (!visibleIDs.has(button.dataset.assetId)) {
      button.querySelectorAll("img[data-protected-path]").forEach(clearProtectedImageSource);
      button.remove();
    }
  }
  updateInspectorNavigation();
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
  if (!state.inspectorDismissed) elements.inspector.classList.add("open");
  elements.assetFileName.textContent = detail.fileName || "未命名照片";

  elements.previewImage.alt = detail.fileName || `所选${currentMediaNoun()}预览`;
  const previewPath = `/v1/assets/${detail.assetID}/preview?r=${detail.contentRevision}`;
  const previewReady = elements.previewImage.dataset.protectedPath === previewPath
    && elements.previewImage.hasAttribute("src")
    && elements.previewImage.dataset.protectedAssignedRequestId
      === elements.previewImage.dataset.protectedRequestId
    && elements.previewImage.complete
    && elements.previewImage.naturalWidth > 0;
  if (!previewReady) {
    elements.previewLoading.classList.remove("hidden");
    elements.previewImage.classList.add("hidden");
    setProtectedImageSource(elements.previewImage, previewPath);
  } else {
    elements.previewLoading.classList.add("hidden");
    elements.previewImage.classList.remove("hidden");
  }

  clearElement(elements.assetMetadata);
  const rows = [
    metadataRow("来源", detail.sourceName),
    metadataRow("相对位置", detail.relativePath),
    metadataRow("媒体", state.mediaKind === "video" ? "视频" : "照片"),
    metadataRow("尺寸", detail.width && detail.height ? `${detail.width} × ${detail.height}` : "—"),
    metadataRow("拍摄时间", formatDate(detail.mediaCreatedAtMs)),
    metadataRow("修改时间", formatDate(detail.mediaModifiedAtMs)),
    metadataRow("格式", detail.mediaType),
    metadataRow("状态", availabilityText(detail.availability)),
  ];
  for (const pair of rows) elements.assetMetadata.append(...pair);

  clearElement(elements.inspectorTags);
  const tagQuery = state.inspectorTagSearchText.toLocaleLowerCase("zh-CN");
  const tags = detail.tags.filter((tag) => (
    tagByID(tag.tagID)?.state !== "archived"
      && (!tagQuery || tag.displayName.toLocaleLowerCase("zh-CN").includes(tagQuery))
  ));
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
      button.disabled = !state.online || state.tagMutating;
      button.textContent = symbol;
      actions.append(button);
    }
    row.append(name, actions);
    elements.inspectorTags.append(row);
  }
  updateInspectorNavigation();
  renderInspectorSurface();
}

function updateInspectorNavigation() {
  const index = state.assets.findIndex((asset) => asset.id === state.selectedAssetID);
  const hasSelection = index >= 0;
  elements.inspectorPosition.textContent = hasSelection
    ? `${index + 1} / ${state.assets.length}`
    : "";
  elements.inspectorPreviousButton.disabled = !hasSelection || index === 0;
  elements.inspectorNextButton.disabled = !hasSelection || index >= state.assets.length - 1;
}

function selectionAggregateText(aggregate, total) {
  if (!aggregate) return "未决定";
  if (aggregate.acceptedCount === total) return "全部确认";
  if (aggregate.rejectedCount === total) return "全部拒绝";
  if (aggregate.unknownCount === total) return "全部未决定";
  return `混合 · 确认 ${aggregate.acceptedCount} · 拒绝 ${aggregate.rejectedCount} · 未决定 ${aggregate.unknownCount}`;
}

function renderSelectionInspector() {
  const total = state.selectedAssetIDs.size;
  elements.selectionInspectorTitle.textContent = `已选择 ${mediaItemCountText(total)}`;
  clearElement(elements.selectionInspectorTags);
  const aggregates = new Map(
    state.selectionAggregates.map((aggregate) => [aggregate.tagID, aggregate])
  );
  const query = state.selectionTagSearchText.toLocaleLowerCase("zh-CN");
  const tags = activeTags().filter((tag) => (
    !query || tag.displayName.toLocaleLowerCase("zh-CN").includes(query)
  ));

  for (const tag of tags) {
    const aggregate = aggregates.get(tag.id);
    const row = document.createElement("div");
    row.className = "selection-tag-row";
    const copy = document.createElement("div");
    copy.className = "selection-tag-copy";
    const name = document.createElement("strong");
    name.textContent = tag.displayName;
    const summary = document.createElement("span");
    summary.textContent = state.loadingAggregate
      ? "正在统计…"
      : selectionAggregateText(aggregate, total);
    copy.append(name, summary);

    const actions = document.createElement("div");
    actions.className = "tag-actions";
    actions.setAttribute("role", "group");
    actions.setAttribute("aria-label", `${tag.displayName} 批量标签决定`);
    for (const [action, symbol, label, active] of [
      ["accept", "✓", "全部确认", aggregate?.acceptedCount === total],
      ["reject", "×", "全部拒绝", aggregate?.rejectedCount === total],
      ["clear", "−", "全部清除", aggregate?.unknownCount === total],
    ]) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "tag-action write-action";
      button.dataset.action = action;
      button.dataset.tagId = tag.id;
      button.title = `${label}“${tag.displayName}”`;
      button.setAttribute("aria-label", label);
      button.setAttribute("aria-pressed", String(Boolean(active)));
      button.classList.toggle("active", Boolean(active));
      button.disabled = !state.online
        || !total
        || state.loadingAggregate
        || state.tagMutating;
      button.textContent = symbol;
      actions.append(button);
    }
    row.append(copy, actions);
    elements.selectionInspectorTags.append(row);
  }

  if (!tags.length) {
    const empty = document.createElement("p");
    empty.className = "sidebar-empty";
    empty.textContent = "没有匹配的标签";
    elements.selectionInspectorTags.append(empty);
  }
}

function renderInspectorSurface() {
  const showsSelection = state.selectionMode && state.selectedAssetIDs.size > 0;
  const showsDetail = !showsSelection && Boolean(state.selectedDetail);
  elements.inspectorPlaceholder.classList.toggle("hidden", showsSelection || showsDetail);
  elements.selectionInspector.classList.toggle("hidden", !showsSelection);
  elements.inspectorContent.classList.toggle("hidden", !showsDetail);
  if (showsSelection && !state.inspectorDismissed) {
    elements.inspector.classList.add("open");
    renderSelectionInspector();
  } else if (showsSelection) {
    renderSelectionInspector();
  }
}

function updateLibraryTitle() {
  const source = state.sources.find((item) => item.id === state.selectedSourceID);
  const mediaTitle = state.mediaKind === "video" ? "视频" : "照片";
  elements.libraryTitle.textContent = source
    ? `${source.displayName} · ${mediaTitle}`
    : `全部${mediaTitle}`;
}

function filterCount() {
  const filters = state.filters;
  return filters.tagConditions.length
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
  elements.mediaKindFilter.value = state.mediaKind;
  elements.availabilityFilter.value = filters.availability;
  elements.mediaTypeFilter.value = filters.mediaTypes.join(",");
  elements.tagPresenceFilter.value = filters.tagPresence;
  elements.tagMatchMode.value = filters.tagMatchMode;
  renderFilterChips();
}

function updateFiltersFromControls() {
  const filters = state.filterDraft || cloneFilters(state.filters);
  filters.mediaKind = state.mediaKind;
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

function appendAdvancedFilterQuery(query, filters = state.filters) {
  const acceptedTagIDs = [];
  const rejectedTagIDs = [];
  const excludedTagIDs = [];
  for (const condition of filters.tagConditions) {
    if (condition.decision === "accepted") acceptedTagIDs.push(condition.tagID);
    if (condition.decision === "rejected") rejectedTagIDs.push(condition.tagID);
    if (condition.decision === "excluded") excludedTagIDs.push(condition.tagID);
  }
  if (acceptedTagIDs.length) query.set("acceptedTagIDs", acceptedTagIDs.join(","));
  if (rejectedTagIDs.length) query.set("rejectedTagIDs", rejectedTagIDs.join(","));
  if (excludedTagIDs.length) query.set("excludedTagIDs", excludedTagIDs.join(","));
  if (acceptedTagIDs.length + rejectedTagIDs.length > 1) {
    query.set("tagMatchMode", filters.tagMatchMode);
  }
  if (filters.availability) query.set("availabilities", filters.availability);
  if (filters.mediaKind) query.set("mediaKinds", filters.mediaKind);
  if (filters.mediaTypes.length) query.set("mediaTypes", filters.mediaTypes.join(","));
  if (filters.tagPresence !== "any") query.set("tagPresence", filters.tagPresence);
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

function assetQuerySnapshot() {
  return {
    workspaceGeneration: state.workspaceGeneration,
    selectedSourceID: state.selectedSourceID,
    searchText: state.searchText,
    sort: state.sort,
    filters: cloneFilters(state.filters),
  };
}

function assetQuerySignature(snapshot = assetQuerySnapshot()) {
  return JSON.stringify(snapshot);
}

function assetPageQuery({
  cursor = null,
  limit = 72,
  snapshot = assetQuerySnapshot(),
} = {}) {
  const query = new URLSearchParams({
    sort: snapshot.sort,
    limit: String(limit),
  });
  if (snapshot.selectedSourceID) query.set("sourceIDs", snapshot.selectedSourceID);
  if (snapshot.searchText) query.set("q", snapshot.searchText);
  if (cursor) query.set("cursor", cursor);
  appendAdvancedFilterQuery(query, snapshot.filters);
  return query;
}

async function fetchLoadedAssetWindow(targetCount, snapshot) {
  const items = [];
  const seenCursors = new Set();
  let nextCursor = null;

  do {
    const remaining = Math.max(1, targetCount - items.length);
    const query = assetPageQuery({
      cursor: nextCursor,
      limit: Math.min(200, remaining),
      snapshot,
    });
    const page = await api(`/v1/assets?${query}`);
    items.push(...page.items);
    nextCursor = page.nextCursor || null;
    if (!nextCursor || seenCursors.has(nextCursor)) break;
    seenCursors.add(nextCursor);
  } while (items.length < targetCount);

  return { items, nextCursor };
}

function mergeQueuedAssetLoadOptions(existing, incoming) {
  if (!existing) return incoming;
  if (!incoming.append) return incoming;
  if (!existing.append) return existing;
  return incoming;
}

async function loadAssets(options = {}) {
  const {
    append = false,
    preserveSelection = false,
    preserveUnchangedGrid = false,
    preserveLoadedWindow = false,
  } = options;
  const normalizedOptions = {
    append,
    preserveSelection,
    preserveUnchangedGrid,
    preserveLoadedWindow,
  };
  if (state.loadingAssets) {
    state.queuedAssetLoadOptions = mergeQueuedAssetLoadOptions(
      state.queuedAssetLoadOptions,
      normalizedOptions
    );
    do {
      await state.assetLoadPromise;
    } while (state.loadingAssets && state.assetLoadPromise);
    if (state.queuedAssetLoadOptions) {
      const queuedOptions = state.queuedAssetLoadOptions;
      state.queuedAssetLoadOptions = null;
      return loadAssets(queuedOptions);
    }
    return false;
  }
  const querySnapshot = assetQuerySnapshot();
  const requestSignature = assetQuerySignature(querySnapshot);
  const existingAssets = state.assets;
  const existingCursor = state.nextCursor;
  let finishAssetLoad;
  state.assetLoadPromise = new Promise((resolve) => {
    finishAssetLoad = resolve;
  });
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
      ? await api(`/v1/assets?${assetPageQuery({
        cursor: existingCursor,
        snapshot: querySnapshot,
      })}`)
      : await fetchLoadedAssetWindow(loadedTargetCount, querySnapshot);
    if (requestSignature !== assetQuerySignature()) {
      shouldRender = false;
      return false;
    }
    const nextAssets = append ? existingAssets.concat(page.items) : page.items;
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
    if (state.selectedAssetID && !visibleIDs.has(state.selectedAssetID)) {
      state.selectedAssetID = null;
      state.selectedDetail = null;
      elements.inspector.classList.remove("open");
    }
  } finally {
    state.loadingAssets = false;
    elements.loadMoreButton.disabled = false;
    if (shouldRender) {
      renderAssets();
      renderSelectionBar();
    }
    finishAssetLoad();
    state.assetLoadPromise = null;
  }
  captureMediaSession();
  if (append) requestAnimationFrame(autoPaginateIfNeeded);
  return shouldRender;
}

async function loadInspector(assetID, {
  reveal = false,
  focusInspector = false,
  preserveExisting = false,
  quiet = false,
  throwOnError = false,
} = {}) {
  const workspaceGeneration = state.workspaceGeneration;
  const requestGeneration = ++state.inspectorRequestGeneration;
  const keepExisting = preserveExisting
    && state.selectedAssetID === assetID
    && Boolean(state.selectedDetail);
  if (reveal) state.inspectorDismissed = false;
  state.selectedAssetID = assetID;
  if (!keepExisting) {
    state.selectedDetail = null;
    renderAssets();
    renderInspectorSurface();
    elements.previewLoading.classList.remove("hidden");
  }
  try {
    const detail = await api(`/v1/assets/${assetID}`);
    if (
      workspaceGeneration === state.workspaceGeneration
      && requestGeneration === state.inspectorRequestGeneration
      && state.selectedAssetID === assetID
      && !state.selectionMode
    ) {
      renderInspector(detail);
      if (focusInspector && globalThis.matchMedia("(max-width: 980px)").matches) {
        requestAnimationFrame(() => {
          elements.closeInspectorButton.focus({ preventScroll: true });
        });
      }
      return true;
    }
    return false;
  } catch (error) {
    const isCurrentRequest = workspaceGeneration === state.workspaceGeneration
      && requestGeneration === state.inspectorRequestGeneration
      && state.selectedAssetID === assetID;
    if (!quiet && isCurrentRequest) {
      toast(error.message || `无法载入${currentMediaNoun()}详情`);
    }
    if (throwOnError && isCurrentRequest) throw error;
    return false;
  }
}

async function mutateTag(tagID, action) {
  if (!state.selectedAssetID || !state.online || state.tagMutating) return;
  const generation = state.workspaceGeneration;
  const assetID = state.selectedAssetID;
  state.tagMutating = true;
  syncWriteActionControls();
  try {
    const result = await api("/v1/tag-decisions/batch", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        tagID,
        assetIDs: [assetID],
        action,
      }),
    });
    if (generation !== state.workspaceGeneration) return;
    try {
      const shouldRefreshDetail = state.selectedAssetID === assetID && !state.selectionMode;
      await Promise.all([
        loadAssets({
          preserveSelection: true,
          preserveUnchangedGrid: true,
          preserveLoadedWindow: true,
        }),
        shouldRefreshDetail
          ? loadInspector(assetID, {
            preserveExisting: true,
            quiet: true,
            throwOnError: true,
          })
          : null,
      ]);
      if (generation !== state.workspaceGeneration) return;
      toast(result.replayed ? "标签操作已恢复" : "标签已更新");
    } catch {
      if (generation !== state.workspaceGeneration) return;
      void refreshWorkspace({ quiet: true, kinds: ["assetsChanged"] });
      toast("标签已更新，界面同步暂时失败，正在重试");
    }
  } catch (error) {
    if (generation === state.workspaceGeneration) {
      toast(error.message || "标签更新失败");
    }
  } finally {
    if (generation === state.workspaceGeneration) {
      state.tagMutating = false;
      syncWriteActionControls();
    }
  }
}

function setSelectionMode(enabled, { seedCurrent = false } = {}) {
  if (enabled && seedCurrent && state.selectedAssetID
    && state.assets.some((asset) => asset.id === state.selectedAssetID)) {
    state.selectedAssetIDs.add(state.selectedAssetID);
    state.selectionAnchorID = state.selectedAssetID;
  }
  state.selectionMode = enabled;
  if (enabled) state.inspectorDismissed = false;
  if (!enabled) {
    state.selectedAssetIDs.clear();
    state.selectionAnchorID = null;
    state.selectionAggregates = [];
    state.aggregateGeneration += 1;
  }
  syncSelectionModeControls();
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
  loadInspector(assetID, { reveal: true, focusInspector: true });
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
    toast(`请先选择至少${mediaItemCountText(1)}`);
    return;
  }
  state.newTagOperationID = crypto.randomUUID();
  elements.newTagTargetSummary.textContent = `创建后将为 ${mediaItemCountText(assetIDs.length)}确认此标签`;
  elements.newTagError.textContent = "";
  elements.newTagName.value = "";
  elements.newTagDialog.showModal();
  elements.newTagName.focus({ preventScroll: true });
}

async function createTagAndApply(event) {
  event.preventDefault();
  const name = elements.newTagName.value.trim();
  const assetIDs = currentTagTargetAssetIDs();
  if (!name || !assetIDs.length || !state.online || state.tagMutating) return;
  const generation = state.workspaceGeneration;
  const operationID = state.newTagOperationID || crypto.randomUUID();
  state.newTagOperationID = operationID;
  state.tagMutating = true;
  elements.createTagButton.disabled = true;
  elements.createTagButton.textContent = "正在创建…";
  elements.newTagError.textContent = "";
  try {
    const result = await api("/v1/tags/create-and-apply", {
      method: "POST",
      body: JSON.stringify({ operationID, name, assetIDs }),
    });
    if (generation !== state.workspaceGeneration) return;
    try {
      const tags = await api("/v1/tags");
      if (generation !== state.workspaceGeneration) return;
      state.tags = tags;
      renderTagSelects();
      await loadAssets({
        preserveSelection: true,
        preserveUnchangedGrid: true,
        preserveLoadedWindow: true,
      });
      if (generation !== state.workspaceGeneration) return;
      if (state.selectionMode) {
        elements.batchTagSelect.value = result.tagID;
        await loadSelectionAggregate();
      } else if (state.selectedAssetID) {
        await loadInspector(state.selectedAssetID, {
          preserveExisting: true,
        });
      }
      if (generation !== state.workspaceGeneration) return;
      closeNewTagDialog();
      toast(`已新增标签“${result.displayName}”并应用到 ${mediaItemCountText(result.appliedAssetCount)}`);
    } catch {
      if (generation !== state.workspaceGeneration) return;
      closeNewTagDialog();
      void refreshWorkspace({
        quiet: true,
        kinds: ["tagsChanged", "assetsChanged"],
      });
      toast(`标签“${result.displayName}”已创建并应用，界面同步暂时失败，正在重试`);
    }
  } catch (error) {
    if (generation === state.workspaceGeneration) {
      elements.newTagError.textContent = error.message || "新增标签失败";
    }
  } finally {
    if (generation === state.workspaceGeneration) {
      state.tagMutating = false;
      syncWriteActionControls();
      elements.createTagButton.textContent = "创建并确认";
    }
  }
}

function renderSelectionBar({ updateInspector = true } = {}) {
  const count = state.selectedAssetIDs.size;
  elements.selectionSummary.textContent = `已选择 ${count} 项`;
  elements.selectAllLoadedButton.textContent = count === state.assets.length && count > 0
    ? "取消全选"
    : "全选已载入";
  document.querySelectorAll(".batch-action").forEach((button) => {
    button.disabled = !state.online
      || state.tagMutating
      || count === 0
      || !elements.batchTagSelect.value;
  });
  if (!count) elements.batchAggregate.textContent = `选择${currentMediaNoun()}后可查看标签汇总`;
  if (updateInspector) renderInspectorSurface();
}

function renderAssetSelectionState() {
  for (const button of elements.assetGrid.querySelectorAll(":scope > .asset-card")) {
    const selected = state.selectedAssetIDs.has(button.dataset.assetId);
    button.classList.toggle("batch-selected", selected);
    button.setAttribute("aria-pressed", String(selected));
    syncAssetCardSelectionMark(button);
  }
}

function scheduleSelectionAggregate() {
  clearTimeout(state.aggregateTimer);
  state.aggregateTimer = setTimeout(loadSelectionAggregate, 120);
}

async function loadSelectionAggregate() {
  const assetIDs = [...state.selectedAssetIDs];
  const tagIDs = activeTags().map((tag) => tag.id);
  if (!tagIDs.length || !assetIDs.length) {
    state.selectionAggregates = [];
    renderSelectionBar();
    return;
  }
  if (state.loadingAggregate) {
    state.aggregateGeneration += 1;
    renderSelectionBar();
    return;
  }
  const generation = ++state.aggregateGeneration;
  state.loadingAggregate = true;
  state.selectionAggregates = [];
  elements.batchAggregate.textContent = "正在统计…";
  renderSelectionInspector();
  try {
    const aggregates = await api("/v1/tags/selection", {
      method: "POST",
      body: JSON.stringify({ tagIDs, assetIDs }),
    });
    if (generation !== state.aggregateGeneration) return;
    state.selectionAggregates = aggregates;
    const aggregate = aggregates.find(
      (item) => item.tagID === elements.batchTagSelect.value
    );
    elements.batchAggregate.textContent = aggregate
      ? `确认 ${aggregate.acceptedCount} · 拒绝 ${aggregate.rejectedCount} · 未决定 ${aggregate.unknownCount}`
      : "选择标签后可查看汇总";
  } catch (error) {
    if (generation !== state.aggregateGeneration) return;
    elements.batchAggregate.textContent = error.message || "无法读取标签汇总";
  } finally {
    state.loadingAggregate = false;
    if (generation === state.aggregateGeneration) {
      renderSelectionBar();
      renderSelectionInspector();
    } else {
      setTimeout(loadSelectionAggregate, 0);
    }
  }
}

function confirmBatchTagDecision(action, tagName, assetCount) {
  const actionText = {
    accept: "确认",
    reject: "拒绝",
    clear: "清除",
  }[action];
  if (!actionText) return false;
  return globalThis.confirm(
    `确认要为 ${mediaItemCountText(assetCount)}${actionText}标签“${tagName}”吗？`
  );
}

async function applyBatchTagDecision(action, requestedTagID = null) {
  const tagID = requestedTagID || elements.batchTagSelect.value;
  const assetIDs = [...state.selectedAssetIDs];
  if (!state.online || !tagID || !assetIDs.length || state.tagMutating) return;
  const generation = state.workspaceGeneration;
  const tagName = tagByID(tagID)?.displayName || "所选";
  if (!confirmBatchTagDecision(action, tagName, assetIDs.length)) return;
  state.tagMutating = true;
  syncWriteActionControls();
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
    if (generation !== state.workspaceGeneration) return;
    try {
      await loadAssets({
        preserveSelection: true,
        preserveUnchangedGrid: true,
        preserveLoadedWindow: true,
      });
      await loadSelectionAggregate();
      if (generation !== state.workspaceGeneration) return;
      toast(`已更新 ${result.appliedAssetCount} 项`);
    } catch {
      if (generation !== state.workspaceGeneration) return;
      void refreshWorkspace({
        quiet: true,
        kinds: ["tagsChanged", "assetsChanged"],
      });
      toast(`已更新 ${result.appliedAssetCount} 项，界面同步暂时失败，正在重试`);
    }
  } catch (error) {
    if (generation === state.workspaceGeneration) {
      toast(error.message || "批量标签更新失败");
    }
  } finally {
    if (generation === state.workspaceGeneration) {
      state.tagMutating = false;
      renderSelectionBar();
      syncWriteActionControls();
    }
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
        button.disabled = !state.online || state.jobMutatingIDs.has(job.id);
        button.textContent = jobActionText(action);
        actions.append(button);
      }
      row.append(actions);
    }
    elements.jobsList.append(row);
  }
}

async function applyJobAction(jobID, action) {
  if (!state.online || state.jobMutatingIDs.has(jobID)) return;
  const generation = state.workspaceGeneration;
  state.jobMutatingIDs.add(jobID);
  syncWriteActionControls();
  try {
    await api(`/v1/jobs/${jobID}/actions`, {
      method: "POST",
      body: JSON.stringify({ action }),
    });
    if (generation !== state.workspaceGeneration) return;
    try {
      const jobs = await api("/v1/jobs");
      if (generation !== state.workspaceGeneration) return;
      state.jobs = jobs;
      renderJobs();
      toast(`任务已${jobActionText(action)}`);
    } catch {
      if (generation !== state.workspaceGeneration) return;
      void refreshWorkspace({ quiet: true, kinds: ["jobsChanged"] });
      toast(`任务已${jobActionText(action)}，状态同步暂时失败，正在重试`);
    }
  } catch (error) {
    if (generation === state.workspaceGeneration) {
      toast(error.message || "任务操作失败");
    }
  } finally {
    if (generation === state.workspaceGeneration) {
      state.jobMutatingIDs.delete(jobID);
      syncWriteActionControls();
    }
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

function syncReviewControls() {
  const controlsLocked = state.review.loading || state.review.mutating;
  elements.loadMoreReviewButton.disabled = controlsLocked;
  elements.reviewTagSelect.disabled = controlsLocked || activeTags().length === 0;
  elements.reviewCurrentSourceOnly.disabled = controlsLocked;
  elements.refreshReviewButton.disabled = controlsLocked;
  document.querySelectorAll(".review-action").forEach((button) => {
    button.disabled = !state.online || controlsLocked;
  });
}

function renderReview() {
  elements.reviewEmpty.classList.toggle("hidden", state.review.items.length > 0);
  elements.loadMoreReviewButton.classList.toggle("hidden", !state.review.nextCursor);
  elements.reviewSummary.textContent = state.review.loading
    ? "正在载入…"
    : `待审核 ${state.review.items.length} 项${state.review.nextCursor ? " · 还有更多" : ""}`;
  elements.reviewNavigationCount.textContent = state.review.items.length
    ? `${state.review.items.length}${state.review.nextCursor ? "+" : ""}`
    : "";
  syncReviewControls();

  const existing = new Map(
    [...elements.reviewGrid.querySelectorAll(":scope > .review-card")]
      .map((button) => [button.dataset.reviewKey, button])
  );
  state.review.items.forEach((item, index) => {
    const key = reviewItemKey(item);
    const button = existing.get(key) || document.createElement("button");
    existing.delete(key);
    button.type = "button";
    button.className = "review-card";
    button.dataset.reviewKey = key;
    button.dataset.reviewIndex = String(index);
    button.classList.toggle("selected", index === state.review.selectedIndex);
    button.setAttribute("aria-pressed", String(index === state.review.selectedIndex));
    button.setAttribute("aria-label", `${item.fileName || "未命名照片"}，${reviewOriginText(item.suggestionOrigin)}`);
    syncAssetCardImage(button, item);
    let origin = button.querySelector(".review-origin-badge");
    if (!origin) {
      origin = document.createElement("span");
      origin.className = "review-origin-badge";
      button.append(origin);
    }
    origin.textContent = reviewOriginText(item.suggestionOrigin).replace("建议", "");
    let score = button.querySelector(".review-score");
    if (item.score != null) {
      if (!score) {
        score = document.createElement("span");
        score.className = "review-score";
        button.append(score);
      }
      score.textContent = `${Math.round(item.score * 100)}%`;
    } else {
      score?.remove();
    }
    elements.reviewGrid.append(button);
  });
  for (const button of existing.values()) {
    button.querySelectorAll("img[data-protected-path]").forEach(clearProtectedImageSource);
    button.remove();
  }
  renderReviewDetail();
}

function renderReviewDetail() {
  const item = state.review.items[state.review.selectedIndex];
  elements.reviewPlaceholder.classList.toggle("hidden", Boolean(item));
  elements.reviewDetail.classList.toggle("hidden", !item);
  if (!item) {
    syncReviewControls();
    return;
  }

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
  syncReviewControls();
}

function selectReviewIndex(index) {
  const previousIndex = state.review.selectedIndex;
  if (!state.review.items.length) {
    state.review.selectedIndex = -1;
  } else {
    state.review.selectedIndex = Math.max(0, Math.min(index, state.review.items.length - 1));
  }
  for (const candidate of new Set([previousIndex, state.review.selectedIndex])) {
    const card = elements.reviewGrid.querySelector(`[data-review-index="${candidate}"]`);
    if (!card) continue;
    const selected = candidate === state.review.selectedIndex;
    card.classList.toggle("selected", selected);
    card.setAttribute("aria-pressed", String(selected));
  }
  renderReviewDetail();
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

function reviewItemKey(item) {
  return item ? `${item.assetID}:${item.suggestionOrigin}` : null;
}

function currentReviewScopeKey() {
  return JSON.stringify({
    tagID: elements.reviewTagSelect.value,
    sourceID: elements.reviewCurrentSourceOnly.checked
      ? state.selectedSourceID
      : "",
  });
}

async function loadReviewQueue({
  append = false,
  preserveUnchangedGrid = false,
  preserveLoadedWindow = false,
  throwOnError = false,
} = {}) {
  const tagID = elements.reviewTagSelect.value;
  const scopeKey = currentReviewScopeKey();
  if (state.review.loadedScopeKey && state.review.loadedScopeKey !== scopeKey) {
    state.review.deferredItemIDs.clear();
  }
  const loadedTargetCount = preserveLoadedWindow
    && state.review.loadedScopeKey === scopeKey
    ? Math.max(48, state.review.items.length)
    : 48;
  const generation = ++state.review.requestGeneration;
  const selectedKey = reviewItemKey(state.review.items[state.review.selectedIndex]);
  const previousIndex = state.review.selectedIndex;
  if (!tagID) {
    state.review.items = [];
    state.review.nextCursor = null;
    state.review.selectedIndex = -1;
    state.review.loadedScopeKey = scopeKey;
    state.review.loading = false;
    renderReview();
    return true;
  }

  state.review.loading = true;
  let shouldRender = !preserveUnchangedGrid;
  if (!append) {
    if (!preserveUnchangedGrid || state.review.loadedScopeKey !== scopeKey) {
      state.review.items = [];
      state.review.nextCursor = null;
      state.review.selectedIndex = -1;
    }
  }
  if (shouldRender) {
    renderReview();
  } else {
    syncReviewControls();
  }
  const sourceID = elements.reviewCurrentSourceOnly.checked
    ? state.selectedSourceID
    : "";
  const fetchPage = (cursor = null) => {
    const query = new URLSearchParams({ tagID, limit: "48" });
    if (sourceID) query.set("sourceIDs", sourceID);
    if (cursor) query.set("cursor", cursor);
    return api(`/v1/review/queue?${query}`);
  };
  const requestCursor = append ? state.review.nextCursor : null;

  try {
    let page;
    if (!append && loadedTargetCount > 48) {
      const items = [];
      const seenCursors = new Set();
      let nextCursor = null;
      do {
        const nextPage = await fetchPage(nextCursor);
        items.push(...nextPage.items);
        nextCursor = nextPage.nextCursor || null;
        if (!nextCursor || seenCursors.has(nextCursor)) break;
        seenCursors.add(nextCursor);
      } while (items.length < loadedTargetCount);
      page = { items, nextCursor };
    } else {
      page = await fetchPage(requestCursor);
    }
    if (generation !== state.review.requestGeneration
      || scopeKey !== currentReviewScopeKey()) return false;
    const receivedItems = append ? state.review.items.concat(page.items) : page.items;
    const nextItems = [
      ...receivedItems.filter((item) => !state.review.deferredItemIDs.has(reviewItemKey(item))),
      ...receivedItems.filter((item) => state.review.deferredItemIDs.has(reviewItemKey(item))),
    ];
    const nextCursor = page.nextCursor || null;
    shouldRender = shouldRender
      || reviewPageFingerprint(state.review.items, state.review.nextCursor)
        !== reviewPageFingerprint(nextItems, nextCursor);
    state.review.items = nextItems;
    state.review.nextCursor = nextCursor;
    state.review.loadedScopeKey = scopeKey;
    const restoredIndex = selectedKey
      ? state.review.items.findIndex((item) => reviewItemKey(item) === selectedKey)
      : -1;
    state.review.selectedIndex = restoredIndex >= 0
      ? restoredIndex
      : (state.review.items.length
        ? Math.max(0, Math.min(previousIndex, state.review.items.length - 1))
        : -1);
  } catch (error) {
    if (generation === state.review.requestGeneration && !throwOnError) {
      toast(error.message || "审核队列载入失败");
    }
    if (throwOnError) throw error;
  } finally {
    if (generation === state.review.requestGeneration) {
      state.review.loading = false;
      if (shouldRender) {
        renderReview();
      } else {
        syncReviewControls();
      }
    }
  }
  return shouldRender;
}

async function openReviewWorkspace() {
  elements.jobsPopover.classList.add("hidden");
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  if (elements.reviewWorkspace.classList.contains("hidden")) {
    state.reviewReturnFocus = document.activeElement;
  }
  elements.appView.inert = true;
  elements.reviewWorkspace.classList.remove("hidden");
  requestAnimationFrame(() => {
    elements.closeReviewButton.focus({ preventScroll: true });
  });
  if (!elements.reviewTagSelect.value && activeTags().length) {
    elements.reviewTagSelect.value = activeTags()[0].id;
  }
  await loadReviewQueue({ preserveLoadedWindow: true });
}

async function applyReviewDecision(action) {
  const item = state.review.items[state.review.selectedIndex];
  const tagID = elements.reviewTagSelect.value;
  const generation = state.workspaceGeneration;
  if (!state.online
    || !item
    || !tagID
    || state.review.loading
    || state.review.mutating
    || state.review.loadedScopeKey !== currentReviewScopeKey()) return;
  state.review.mutating = true;
  syncReviewControls();
  try {
    const result = await api("/v1/review/decisions/batch", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        tagID,
        assetIDs: [item.assetID],
        action,
      }),
    });
    if (generation !== state.workspaceGeneration) return;
    const previousIndex = state.review.selectedIndex;
    try {
      await Promise.all([
        loadReviewQueue({
          preserveLoadedWindow: true,
          throwOnError: true,
        }),
        loadAssets({
          preserveSelection: true,
          preserveUnchangedGrid: true,
          preserveLoadedWindow: true,
        }),
      ]);
      if (generation !== state.workspaceGeneration) return;
      if (state.review.items.length) {
        selectReviewIndex(Math.min(previousIndex, state.review.items.length - 1));
      }
      toast(result.replayed ? "审核操作已恢复" : "审核决定已保存");
    } catch {
      if (generation === state.workspaceGeneration) {
        void refreshWorkspace({
          quiet: true,
          kinds: ["reviewChanged", "assetsChanged"],
        });
        toast("审核决定已保存，界面同步暂时失败，正在重试");
      }
    }
  } catch (error) {
    if (generation === state.workspaceGeneration) {
      toast(error.message || "审核决定保存失败");
    }
  } finally {
    if (generation === state.workspaceGeneration) {
      state.review.mutating = false;
      syncReviewControls();
    }
  }
}

function deferReviewSelection() {
  const index = state.review.selectedIndex;
  if (state.review.loading
    || state.review.mutating
    || state.review.loadedScopeKey !== currentReviewScopeKey()
    || index < 0
    || index >= state.review.items.length) return;
  const deferredCard = elements.reviewGrid.querySelector(`[data-review-index="${index}"]`);
  const [item] = state.review.items.splice(index, 1);
  state.review.items.push(item);
  state.review.deferredItemIDs.add(reviewItemKey(item));
  state.review.selectedIndex = state.review.items.length > 1
    ? Math.min(index, state.review.items.length - 2)
    : 0;
  if (deferredCard) {
    elements.reviewGrid.append(deferredCard);
    [...elements.reviewGrid.querySelectorAll(".review-card")].forEach((card, cardIndex) => {
      const selected = cardIndex === state.review.selectedIndex;
      card.dataset.reviewIndex = String(cardIndex);
      card.classList.toggle("selected", selected);
      card.setAttribute("aria-pressed", String(selected));
    });
    renderReviewDetail();
    elements.reviewGrid.querySelector(".review-card.selected")?.scrollIntoView({
      block: "nearest",
      inline: "nearest",
    });
  } else {
    renderReview();
  }
  toast("已移到队列后面，没有修改标签决定");
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
  if (elements.lightbox.classList.contains("hidden")) {
    state.lightboxReturnFocus = document.activeElement;
  }
  state.lightboxContext = context;
  state.lightboxAssetID = assetID;
  if (context === "review") {
    elements.reviewWorkspace.inert = true;
  } else {
    elements.appView.inert = true;
  }
  elements.lightbox.classList.remove("hidden");
  renderLightbox();
  requestAnimationFrame(() => {
    elements.closeLightboxButton.focus({ preventScroll: true });
  });
}

function renderLightbox() {
  const items = lightboxItems();
  const index = items.findIndex((item) => item.id === state.lightboxAssetID);
  if (index < 0) {
    closeLightbox();
    return;
  }
  const item = items[index];
  elements.lightboxTitle.textContent = item.fileName || "未命名照片";
  elements.lightboxImage.alt = item.fileName || `${currentMediaNoun()}全屏预览`;
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
  selectLibraryAssetByIndex(next);
}

function gridColumnCount() {
  const cards = [...elements.assetGrid.querySelectorAll(":scope > .asset-card")];
  if (!cards.length) return 1;
  const firstTop = cards[0].offsetTop;
  const count = cards.findIndex((card) => card.offsetTop !== firstTop);
  return count < 0 ? cards.length : Math.max(1, count);
}

function visibleGridPageItemCount() {
  const card = elements.assetGrid.querySelector(":scope > .asset-card");
  if (!card) return gridColumnCount();
  const rowHeight = Math.max(1, card.getBoundingClientRect().height + 8);
  const rows = Math.max(1, Math.floor(elements.libraryScroll.clientHeight / rowHeight));
  return rows * gridColumnCount();
}

async function selectLibraryAssetByIndex(index, { focusGrid = false } = {}) {
  if (!state.assets.length) return;
  const bounded = Math.max(0, Math.min(index, state.assets.length - 1));
  const assetID = state.assets[bounded].id;
  if (state.selectionMode) {
    state.selectedAssetIDs = new Set([assetID]);
    state.selectionAnchorID = assetID;
    state.selectedAssetID = assetID;
    renderAssets();
    renderSelectionBar();
    scheduleSelectionAggregate();
  } else {
    state.selectedAssetID = assetID;
    state.selectedDetail = null;
    renderAssets();
    renderInspectorSurface();
  }
  const card = elements.assetGrid.querySelector(`[data-asset-id="${assetID}"]`);
  card?.scrollIntoView({ block: "nearest", inline: "nearest" });
  if (focusGrid) card?.focus({ preventScroll: true });
  if (!state.selectionMode) {
    await loadInspector(assetID, {
      reveal: true,
      focusInspector: !focusGrid,
    });
  }
}

function moveLibrarySelection(key) {
  if (!state.assets.length) return;
  const primaryID = state.selectionMode
    ? (state.selectionAnchorID || [...state.selectedAssetIDs][0])
    : state.selectedAssetID;
  const index = state.assets.findIndex((asset) => asset.id === primaryID);
  if (index < 0) {
    selectLibraryAssetByIndex(0, { focusGrid: true });
    return;
  }
  const columns = gridColumnCount();
  const delta = {
    ArrowLeft: -1,
    ArrowRight: 1,
    ArrowUp: -columns,
    ArrowDown: columns,
    PageUp: -visibleGridPageItemCount(),
    PageDown: visibleGridPageItemCount(),
  }[key];
  if (!delta) return;
  selectLibraryAssetByIndex(index + delta, { focusGrid: true });
}

async function loadWorkspace() {
  resetWorkspaceSessionState();
  const generation = state.workspaceGeneration;
  showApp();
  setConnection(true, "正在同步");
  const [capabilities, sources, tags, jobs] = await Promise.all([
    api("/v1/capabilities"),
    api("/v1/sources"),
    api("/v1/tags"),
    api("/v1/jobs"),
  ]);
  if (generation !== state.workspaceGeneration) return;
  state.capabilities = capabilities;
  state.sources = sources;
  state.tags = tags;
  state.jobs = jobs;
  elements.hostVersion.textContent = `Mac Host ${capabilities.hostAppVersion}`;
  renderSources();
  renderTagSelects();
  renderJobs();
  renderMediaKindTabs();
  syncSelectionModeControls();
  renderLayoutPreferences();
  syncFilterControlsFromState();
  updateLibraryTitle();
  await loadAssets();
  if (generation !== state.workspaceGeneration) return;
  captureMediaSession();
  setupAutoPagination();
  connectEvents();
}

function expandedRefreshKinds(kinds) {
  const expanded = new Set(kinds);
  if (expanded.has("full")) {
    return new Set([
      "sourcesChanged",
      "tagsChanged",
      "assetsChanged",
      "jobsChanged",
      "reviewChanged",
    ]);
  }
  if (expanded.has("sourcesChanged") || expanded.has("tagsChanged")) {
    expanded.add("assetsChanged");
  }
  return expanded;
}

async function refreshWorkspace({ quiet = false, kinds = null } = {}) {
  const refreshGeneration = state.workspaceGeneration;
  const requestedKinds = kinds == null ? ["full"] : kinds;
  for (const kind of requestedKinds) state.pendingRefreshKinds.add(kind);
  if (
    !quiet
    || (kinds != null
      && kinds.some((kind) => ["full", "assetsChanged", "tagsChanged"].includes(kind)))
  ) {
    state.pendingInspectorRefresh = true;
  }
  if (state.refreshingWorkspace) return;

  clearTimeout(state.refreshRetryTimer);
  state.refreshRetryTimer = null;
  state.refreshingWorkspace = true;
  let failedBatch = null;
  let failedInspectorRefresh = false;
  let retryDelay = 0;
  try {
    while (state.pendingRefreshKinds.size) {
      const batch = expandedRefreshKinds(state.pendingRefreshKinds);
      state.pendingRefreshKinds.clear();
      failedBatch = batch;
      const refreshInspectorForBatch = state.pendingInspectorRefresh;
      state.pendingInspectorRefresh = false;
      failedInspectorRefresh = refreshInspectorForBatch;

      const [sources, tags, jobs] = await Promise.all([
        batch.has("sourcesChanged") ? api("/v1/sources") : null,
        batch.has("tagsChanged") ? api("/v1/tags") : null,
        batch.has("jobsChanged") ? api("/v1/jobs") : null,
      ]);
      if (refreshGeneration !== state.workspaceGeneration) {
        failedBatch = null;
        return;
      }

      const sourcesChanged = Boolean(
        sources
        && projectionFingerprint(sources) !== projectionFingerprint(state.sources)
      );
      const tagsChanged = Boolean(
        tags
        && projectionFingerprint(tags) !== projectionFingerprint(state.tags)
      );
      const jobsChanged = Boolean(
        jobs
        && projectionFingerprint(jobs) !== projectionFingerprint(state.jobs)
      );
      if (sourcesChanged) {
        state.sources = sources;
        if (state.selectedSourceID
          && !state.sources.some((source) => source.id === state.selectedSourceID)) {
          state.selectedSourceID = "";
          state.selectedAssetID = null;
          state.selectedDetail = null;
        }
        renderSources();
        updateLibraryTitle();
      }
      if (tagsChanged) {
        state.tags = tags;
        const activeTagIDs = new Set(activeTags().map((tag) => tag.id));
        state.filters.tagConditions = state.filters.tagConditions.filter(
          (condition) => activeTagIDs.has(condition.tagID)
        );
        if (state.filterDraft) {
          state.filterDraft.tagConditions = state.filterDraft.tagConditions.filter(
            (condition) => activeTagIDs.has(condition.tagID)
          );
        }
        renderTagSelects();
        renderFilterChips();
      }
      if (jobsChanged) {
        state.jobs = jobs;
        renderJobs();
      }

      let assetsChanged = false;
      if (batch.has("assetsChanged")) {
        assetsChanged = await loadAssets({
          preserveSelection: true,
          preserveUnchangedGrid: true,
          preserveLoadedWindow: true,
        });
      }
      const shouldRefreshInspector = Boolean(
        state.selectedAssetID
        && (refreshInspectorForBatch || tagsChanged || assetsChanged)
        && !state.selectionMode
      );
      if (shouldRefreshInspector) {
        failedInspectorRefresh = true;
        await loadInspector(state.selectedAssetID, {
          preserveExisting: true,
          quiet: true,
          throwOnError: true,
        });
      }
      if (state.selectionMode && batch.has("tagsChanged")) {
        scheduleSelectionAggregate();
      }
      if (
        !elements.reviewWorkspace.classList.contains("hidden")
        && (batch.has("reviewChanged") || batch.has("assetsChanged") || batch.has("tagsChanged"))
      ) {
        await loadReviewQueue({
          preserveUnchangedGrid: true,
          preserveLoadedWindow: true,
          throwOnError: true,
        });
      }
      failedBatch = null;
      failedInspectorRefresh = false;
    }
    state.refreshRetryAttempt = 0;
    if (!quiet) toast("图库已刷新");
  } catch (error) {
    if (refreshGeneration !== state.workspaceGeneration) {
      failedBatch = null;
      return;
    }
    for (const kind of failedBatch || []) state.pendingRefreshKinds.add(kind);
    if (failedInspectorRefresh) state.pendingInspectorRefresh = true;
    const retryDelays = [1000, 2000, 4000, 8000, 16000, 30000];
    retryDelay = retryDelays[
      Math.min(state.refreshRetryAttempt, retryDelays.length - 1)
    ];
    state.refreshRetryAttempt += 1;
    if (!quiet) toast(error.message || "刷新失败");
  } finally {
    state.refreshingWorkspace = false;
    if (state.pendingRefreshKinds.size) {
      state.refreshRetryTimer = setTimeout(
        () => refreshWorkspace({ quiet: true, kinds: [] }),
        retryDelay
      );
    }
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

function scheduleProjectionPoll(generation) {
  clearTimeout(state.accountPollTimer);
  const interval = state.authMode === "account" ? 10_000 : 15_000;
  state.accountPollTimer = setTimeout(async () => {
    if (generation !== state.socketGeneration
      || !["account", "pairedDevice"].includes(state.authMode)
      || elements.appView.classList.contains("hidden")) return;
    try {
      await api("/web/session", {}, false);
      await refreshWorkspace({ quiet: true });
      setConnection(true, state.authMode === "account" ? "账号已登录" : "已连接");
      scheduleProjectionPoll(generation);
    } catch (error) {
      if (error.status === 401) {
        if (state.authMode === "account") {
          state.accountAuthorization = null;
          state.authMode = null;
          showPairing("账号密码无效或已从 Mac 白名单移除。");
        } else {
          showPairing("网页会话已过期，请在 Mac 上重新配对。");
        }
      } else {
        setConnection(false);
        scheduleProjectionPoll(generation);
      }
    }
  }, interval);
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
      scheduleProjectionPoll(generation);
    } catch (error) {
      if (error.status === 401) {
        state.accountAuthorization = null;
        state.authMode = null;
        showPairing("账号密码无效或已从 Mac 白名单移除。");
      } else {
        setConnection(false);
        scheduleProjectionPoll(generation);
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
  scheduleProjectionPoll(generation);

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
      state.pendingRefreshKinds.add(message.kind);
      if (["full", "assetsChanged", "tagsChanged"].includes(message.kind)) {
        state.pendingInspectorRefresh = true;
      }
      clearTimeout(state.eventRefreshTimer);
      state.eventRefreshTimer = setTimeout(
        () => refreshWorkspace({ quiet: true, kinds: [] }),
        280
      );
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

function resetWorkspaceSessionState() {
  disconnectEvents();
  state.workspaceGeneration += 1;
  state.inspectorRequestGeneration += 1;
  state.capabilities = null;
  state.sources = [];
  state.tags = [];
  state.jobs = [];
  state.assets = [];
  state.nextCursor = null;
  state.selectedSourceID = "";
  state.selectedAssetID = null;
  state.selectedDetail = null;
  state.searchText = "";
  state.sort = "fileNameAscending";
  state.mediaKind = "image";
  state.mediaSessions = { image: null, video: null };
  state.filters = emptyFilters();
  state.filters.mediaKind = state.mediaKind;
  state.filterDraft = null;
  state.selectionMode = false;
  state.selectedAssetIDs.clear();
  state.selectionAnchorID = null;
  state.inspectorDismissed = false;
  state.selectionAggregates = [];
  state.aggregateGeneration += 1;
  state.tagMutating = false;
  state.jobMutatingIDs.clear();
  state.review.items = [];
  state.review.nextCursor = null;
  state.review.selectedIndex = -1;
  state.review.loading = false;
  state.review.mutating = false;
  state.review.requestGeneration += 1;
  state.review.loadedScopeKey = null;
  state.review.deferredItemIDs.clear();
  state.reviewReturnFocus = null;
  state.lightboxReturnFocus = null;
  state.pendingRefreshKinds.clear();
  state.pendingInspectorRefresh = false;
  state.refreshRetryAttempt = 0;
  clearTimeout(state.searchTimer);
  state.searchTimer = null;
  clearTimeout(state.aggregateTimer);
  state.aggregateTimer = null;
  clearTimeout(state.eventRefreshTimer);
  state.eventRefreshTimer = null;
  clearTimeout(state.refreshRetryTimer);
  state.refreshRetryTimer = null;
  elements.searchInput.value = "";
  elements.clearSearchButton.classList.add("hidden");
  elements.sortSelect.value = state.sort;
  clearProtectedImageSource(elements.previewImage);
  clearProtectedImageSource(elements.reviewPreviewImage);
  clearProtectedImageSource(elements.lightboxImage);
  elements.appView.inert = false;
  elements.reviewWorkspace.inert = false;
  elements.reviewWorkspace.classList.add("hidden");
  elements.lightbox.classList.add("hidden");
  elements.inspector.classList.remove("open");
  syncSelectionModeControls();
  renderMediaKindTabs();
}

async function logout() {
  try {
    await rawFetch("/web/session/logout", { method: "POST", body: "{}" });
  } finally {
    state.autoLoadObserver?.disconnect();
    showPairing("已退出这台设备上的网页会话。");
  }
}

async function selectSource(sourceID) {
  if (state.selectionMode) setSelectionMode(false);
  state.selectedSourceID = sourceID;
  state.selectedAssetID = null;
  state.selectedDetail = null;
  state.inspectorDismissed = false;
  elements.inspector.classList.remove("open");
  renderInspectorSurface();
  renderSources();
  updateLibraryTitle();
  elements.sourceSidebar.classList.remove("open");
  await loadAssets();
  if (!elements.reviewWorkspace.classList.contains("hidden")
    && elements.reviewCurrentSourceOnly.checked) {
    await loadReviewQueue();
  }
}

function togglePopover(popover) {
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
    || target instanceof HTMLTextAreaElement
    || (target instanceof HTMLElement && target.isContentEditable);
}

function isInteractiveControlTarget(target) {
  if (!(target instanceof Element)) return false;
  const control = target.closest(
    "button, a, [role=\"button\"], [role=\"option\"], [role=\"menuitem\"]"
  );
  return Boolean(control && !control.matches(".asset-card, .review-card"));
}

function availableCommands() {
  const commands = [
    { id: "showAll", icon: "▦", title: `显示全部${state.mediaKind === "video" ? "视频" : "照片"}`, hint: "" },
    { id: "media:image", icon: "▧", title: "切换到照片", hint: "" },
    { id: "media:video", icon: "▶", title: "切换到视频", hint: "" },
    { id: "showUntagged", icon: "⊘", title: "显示无标签项目", hint: "" },
    { id: "focusSearch", icon: "⌕", title: "搜索文件名", hint: "⌘F" },
    { id: "openFilter", icon: "≡", title: "打开高级筛选", hint: "" },
    { id: "selectAll", icon: "✓", title: "全选当前已载入项目", hint: "⌘A" },
    { id: "openReview", icon: "✦", title: "打开待审核建议", hint: "" },
    { id: "openJobs", icon: "◷", title: "查看后台任务", hint: "" },
    {
      id: "toggleSidebar",
      icon: "◫",
      title: state.layout.sidebarVisible ? "隐藏侧栏" : "显示侧栏",
      hint: "",
    },
    {
      id: "toggleInspector",
      icon: "◧",
      title: state.layout.inspectorVisible ? "隐藏检查器" : "显示检查器",
      hint: "",
    },
    { id: "refresh", icon: "↻", title: "刷新图库", hint: "" },
    { id: "shortcuts", icon: "?", title: "查看快捷键", hint: "" },
  ];
  if (currentTagTargetAssetIDs().length) {
    commands.splice(5, 0,
      { id: "previewSelection", icon: "⛶", title: `预览所选${currentMediaNoun()}`, hint: "Space" },
      { id: "newTag", icon: "＋", title: `为所选${currentMediaNoun()}新增标签`, hint: "" });
  }
  for (const source of state.sources) {
    commands.push({
      id: `source:${source.id}`,
      icon: sourceIcon(source.kind),
      title: `切换来源：${source.displayName}`,
      hint: sourceStateText(source.state),
    });
  }
  for (const tag of activeTags()) {
    commands.push({
      id: `tag:${tag.id}`,
      icon: "#",
      title: `筛选标签：${tag.displayName}`,
      hint: "",
    });
  }
  return commands;
}

function renderCommandItems() {
  if (!elements.commandList) return;
  const query = elements.commandSearchInput.value.trim().toLocaleLowerCase("zh-CN");
  state.commandItems = availableCommands().filter(
    (command) => !query || command.title.toLocaleLowerCase("zh-CN").includes(query)
  );
  state.commandIndex = Math.max(
    0,
    Math.min(state.commandIndex, Math.max(0, state.commandItems.length - 1))
  );
  clearElement(elements.commandList);
  if (!state.commandItems.length) {
    const empty = document.createElement("div");
    empty.className = "command-empty";
    empty.textContent = `没有与“${elements.commandSearchInput.value.trim()}”匹配的命令`;
    elements.commandList.append(empty);
    return;
  }
  state.commandItems.forEach((command, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "command-item";
    button.dataset.commandId = command.id;
    button.classList.toggle("active", index === state.commandIndex);
    button.setAttribute("role", "option");
    button.setAttribute("aria-selected", String(index === state.commandIndex));
    const icon = document.createElement("span");
    icon.textContent = command.icon;
    const title = document.createElement("span");
    title.textContent = command.title;
    const hint = document.createElement("small");
    hint.textContent = command.hint;
    button.append(icon, title, hint);
    elements.commandList.append(button);
  });
}

async function executeCommand(commandID) {
  elements.commandPalette.close();
  if (commandID.startsWith("media:")) {
    await switchMediaKind(commandID.slice(6));
    return;
  }
  if (commandID.startsWith("source:")) {
    await selectSource(commandID.slice(7));
    return;
  }
  if (commandID.startsWith("tag:")) {
    await applyQuickTagFilter(commandID.slice(4));
    return;
  }
  switch (commandID) {
  case "showAll":
    state.filters.tagConditions = [];
    state.filters.tagPresence = "any";
    renderTagNavigation();
    await selectSource("");
    break;
  case "showUntagged":
    if (state.filters.tagPresence !== "untagged") await applyUntaggedFilter();
    break;
  case "focusSearch":
    elements.searchInput.focus({ preventScroll: true });
    elements.searchInput.select();
    break;
  case "openFilter":
    togglePopover(elements.filterPopover);
    break;
  case "selectAll":
    selectAllLoadedAssets();
    break;
  case "previewSelection": {
    const assetID = state.selectionMode && state.selectedAssetIDs.size === 1
      ? [...state.selectedAssetIDs][0]
      : state.selectedAssetID;
    if (assetID) openLightbox("library", assetID);
    break;
  }
  case "newTag":
    openNewTagDialog();
    break;
  case "openReview":
    await openReviewWorkspace();
    break;
  case "openJobs":
    togglePopover(elements.jobsPopover);
    break;
  case "toggleSidebar":
    setSidebarVisible(!state.layout.sidebarVisible);
    break;
  case "toggleInspector":
    setInspectorVisible(!state.layout.inspectorVisible);
    break;
  case "refresh":
    await refreshWorkspace();
    break;
  case "shortcuts":
    elements.shortcutDialog.showModal();
    break;
  default:
    break;
  }
}

function openCommandPalette() {
  elements.commandSearchInput.value = "";
  state.commandIndex = 0;
  renderCommandItems();
  elements.commandPalette.showModal();
  elements.commandSearchInput.focus({ preventScroll: true });
}

function hideContextMenu() {
  elements.assetContextMenu.classList.add("hidden");
  state.contextAssetID = null;
}

function showAssetContextMenu(event, assetID) {
  state.contextAssetID = assetID;
  elements.assetContextMenu.classList.remove("hidden");
  const rect = elements.assetContextMenu.getBoundingClientRect();
  const left = Math.max(6, Math.min(event.clientX, globalThis.innerWidth - rect.width - 6));
  const top = Math.max(6, Math.min(event.clientY, globalThis.innerHeight - rect.height - 6));
  elements.assetContextMenu.style.left = `${left}px`;
  elements.assetContextMenu.style.top = `${top}px`;
}

function startMarqueeSelection(event) {
  if (event.button !== 0
    || event.target.closest(
      ".asset-card, button, input, select, textarea, a, [role=\"button\"]"
    )) return;
  const additive = event.metaKey || event.ctrlKey;
  state.marquee = {
    pointerID: event.pointerId,
    startX: event.clientX,
    startY: event.clientY,
    additive,
    base: additive ? new Set(state.selectedAssetIDs) : new Set(),
    moved: false,
  };
  try {
    elements.libraryScroll.setPointerCapture(event.pointerId);
  } catch {
    // Pointer capture is an enhancement; document-level listeners remain the fallback.
  }
}

function updateMarqueeSelection(event) {
  const marquee = state.marquee;
  if (!marquee || event.pointerId !== marquee.pointerID) return;
  const dx = event.clientX - marquee.startX;
  const dy = event.clientY - marquee.startY;
  if (!marquee.moved && Math.hypot(dx, dy) < 5) return;
  if (!marquee.moved) {
    marquee.moved = true;
    if (!state.selectionMode) setSelectionMode(true);
    elements.marqueeSelection.classList.remove("hidden");
    elements.assetGrid.classList.add("marquee-active");
  }
  event.preventDefault();
  const left = Math.min(marquee.startX, event.clientX);
  const top = Math.min(marquee.startY, event.clientY);
  const right = Math.max(marquee.startX, event.clientX);
  const bottom = Math.max(marquee.startY, event.clientY);
  Object.assign(elements.marqueeSelection.style, {
    left: `${left}px`,
    top: `${top}px`,
    width: `${right - left}px`,
    height: `${bottom - top}px`,
  });
  const selected = new Set(marquee.base);
  for (const card of elements.assetGrid.querySelectorAll(":scope > .asset-card")) {
    const rect = card.getBoundingClientRect();
    if (rect.right >= left && rect.left <= right && rect.bottom >= top && rect.top <= bottom) {
      selected.add(card.dataset.assetId);
    }
  }
  state.selectedAssetIDs = selected;
  state.selectionAnchorID = [...selected].at(-1) || null;
  renderAssetSelectionState();
  renderSelectionBar({ updateInspector: false });
}

function finishMarqueeSelection(event = null) {
  if (event?.pointerId != null && event.pointerId !== state.marquee?.pointerID) return;
  const moved = state.marquee?.moved;
  const pointerID = state.marquee?.pointerID;
  state.marquee = null;
  if (pointerID != null && elements.libraryScroll.hasPointerCapture(pointerID)) {
    elements.libraryScroll.releasePointerCapture(pointerID);
  }
  elements.marqueeSelection.classList.add("hidden");
  elements.assetGrid.classList.remove("marquee-active");
  if (moved) {
    renderSelectionBar();
    scheduleSelectionAggregate();
  }
}

async function autoPaginateIfNeeded() {
  if (!state.nextCursor
    || state.loadingAssets
    || elements.appView.classList.contains("hidden")) return;
  const rootBounds = elements.libraryScroll.getBoundingClientRect();
  const sentinelBounds = elements.loadMoreSentinel.getBoundingClientRect();
  if (sentinelBounds.top > rootBounds.bottom + 280) return;
  const previousCursor = state.nextCursor;
  await loadAssets({ append: true });
  if (state.nextCursor && state.nextCursor !== previousCursor) {
    requestAnimationFrame(autoPaginateIfNeeded);
  }
}

function setupAutoPagination() {
  state.autoLoadObserver?.disconnect();
  state.autoLoadObserver = new IntersectionObserver((entries) => {
    const entry = entries[0];
    if (
      entry?.isIntersecting
      && state.nextCursor
      && !state.loadingAssets
      && !elements.appView.classList.contains("hidden")
    ) {
      autoPaginateIfNeeded();
    }
  }, {
    root: elements.libraryScroll,
    rootMargin: "0px 0px 280px 0px",
    threshold: 0.01,
  });
  state.autoLoadObserver.observe(elements.loadMoreSentinel);
  requestAnimationFrame(autoPaginateIfNeeded);
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
  elements.untaggedNavigationButton.addEventListener("click", applyUntaggedFilter);
  elements.reviewNavigationButton.addEventListener("click", openReviewWorkspace);
  elements.tagNavigation.addEventListener("click", (event) => {
    const button = event.target.closest("[data-quick-tag-id]");
    if (button) applyQuickTagFilter(button.dataset.quickTagId);
  });
  elements.tagNavigationSearch.addEventListener("input", renderTagNavigation);
  elements.sidebarNewTagButton.addEventListener("click", openNewTagDialog);
  elements.mediaKindTabs.addEventListener("click", (event) => {
    const button = event.target.closest("[data-media-kind]");
    if (button) switchMediaKind(button.dataset.mediaKind);
  });
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
  elements.assetGrid.addEventListener("contextmenu", (event) => {
    const card = event.target.closest("[data-asset-id]");
    if (!card) return;
    event.preventDefault();
    showAssetContextMenu(event, card.dataset.assetId);
  });
  elements.libraryScroll.addEventListener("pointerdown", startMarqueeSelection);
  document.addEventListener("pointermove", updateMarqueeSelection);
  document.addEventListener("pointerup", finishMarqueeSelection);
  document.addEventListener("pointercancel", finishMarqueeSelection);
  globalThis.addEventListener("blur", () => finishMarqueeSelection());
  elements.inspectorTags.addEventListener("click", (event) => {
    const button = event.target.closest("[data-action][data-tag-id]");
    if (button) mutateTag(button.dataset.tagId, button.dataset.action);
  });
  elements.selectionInspectorTags.addEventListener("click", (event) => {
    const button = event.target.closest("[data-action][data-tag-id]");
    if (button) applyBatchTagDecision(button.dataset.action, button.dataset.tagId);
  });
  elements.inspectorTagSearch.addEventListener("input", () => {
    state.inspectorTagSearchText = elements.inspectorTagSearch.value.trim();
    if (state.selectedDetail) renderInspector(state.selectedDetail);
  });
  elements.selectionTagSearch.addEventListener("input", () => {
    state.selectionTagSearchText = elements.selectionTagSearch.value.trim();
    renderSelectionInspector();
  });
  elements.previewImage.addEventListener("imageall-protected-load", (event) => {
    if (String(event.detail?.requestID) !== elements.previewImage.dataset.protectedRequestId) {
      return;
    }
    elements.previewLoading.classList.add("hidden");
    elements.previewImage.classList.remove("hidden");
  });
  elements.previewImage.addEventListener("imageall-protected-error", (event) => {
    if (String(event.detail?.requestID) !== elements.previewImage.dataset.protectedRequestId) {
      return;
    }
    delete elements.previewImage.dataset.protectedPath;
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
    clearTimeout(state.searchTimer);
    state.searchText = elements.searchInput.value.trim();
    elements.clearSearchButton.classList.toggle("hidden", !state.searchText);
    await loadAssets();
  });
  elements.searchInput.addEventListener("input", () => {
    elements.clearSearchButton.classList.toggle("hidden", !elements.searchInput.value);
    clearTimeout(state.searchTimer);
    const nextSearch = elements.searchInput.value.trim();
    if (nextSearch === state.searchText) return;
    state.searchText = nextSearch;
    state.searchTimer = setTimeout(async () => {
      await loadAssets();
    }, 280);
  });
  elements.clearSearchButton.addEventListener("click", async () => {
    clearTimeout(state.searchTimer);
    elements.searchInput.value = "";
    state.searchText = "";
    elements.clearSearchButton.classList.add("hidden");
    await loadAssets();
  });
  elements.sortSelect.addEventListener("change", async () => {
    state.sort = elements.sortSelect.value;
    await loadAssets();
  });
  elements.gridDensitySlider.addEventListener("input", () => {
    state.layout.density = Number(elements.gridDensitySlider.value);
    renderLayoutPreferences();
    persistWorkspacePreferences();
  });
  elements.loadMoreButton.addEventListener("click", () => loadAssets({ append: true }));
  elements.refreshButton.addEventListener("click", () => refreshWorkspace());
  elements.logoutButton.addEventListener("click", logout);
  elements.sidebarToggle.addEventListener("click", () => {
    elements.sourceSidebar.classList.toggle("open");
  });
  elements.sidebarVisibilityButton.addEventListener("click", () => {
    setSidebarVisible(!state.layout.sidebarVisible);
  });
  elements.inspectorVisibilityButton.addEventListener("click", () => {
    setInspectorVisible(!state.layout.inspectorVisible);
  });
  elements.closeInspectorButton.addEventListener("click", closeInspectorOverlay);
  elements.inspectorPreviousButton.addEventListener("click", () => navigateLibrarySelection(-1));
  elements.inspectorNextButton.addEventListener("click", () => navigateLibrarySelection(1));

  elements.filterButton.addEventListener("click", () => {
    togglePopover(elements.filterPopover);
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
    state.filters.mediaKind = state.mediaKind;
    state.filterDraft = null;
    syncFilterControlsFromState();
    renderTagNavigation();
    await loadAssets();
    elements.filterPopover.classList.add("hidden");
    elements.filterButton.setAttribute("aria-expanded", "false");
  });
  elements.applyFiltersButton.addEventListener("click", async () => {
    updateFiltersFromControls();
    state.filters = cloneFilters(state.filterDraft);
    state.filters.mediaKind = state.mediaKind;
    state.filterDraft = null;
    renderFilterChips();
    renderTagNavigation();
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
  elements.selectionInspectorNewTagButton.addEventListener("click", openNewTagDialog);
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
    togglePopover(elements.jobsPopover);
  });
  elements.closeJobsButton.addEventListener("click", () => {
    elements.jobsPopover.classList.add("hidden");
  });
  elements.jobsList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-job-id][data-action]");
    if (button) applyJobAction(button.dataset.jobId, button.dataset.action);
  });

  elements.reviewButton.addEventListener("click", openReviewWorkspace);
  elements.closeReviewButton.addEventListener("click", closeReviewWorkspace);
  elements.reviewTagSelect.addEventListener("change", () => {
    state.review.deferredItemIDs.clear();
    loadReviewQueue();
  });
  elements.reviewCurrentSourceOnly.addEventListener("change", () => loadReviewQueue());
  elements.refreshReviewButton.addEventListener("click", () => (
    loadReviewQueue({ preserveLoadedWindow: true })
  ));
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
    if (!button) return;
    if (button.dataset.action === "defer") {
      deferReviewSelection();
    } else {
      applyReviewDecision(button.dataset.action);
    }
  });
  elements.reviewOpenLightboxButton.addEventListener("click", () => {
    const item = state.review.items[state.review.selectedIndex];
    openLightbox("review", item?.assetID);
  });
  elements.reviewPreviewImage.addEventListener("dblclick", () => {
    const item = state.review.items[state.review.selectedIndex];
    openLightbox("review", item?.assetID);
  });

  elements.closeLightboxButton.addEventListener("click", closeLightbox);
  elements.lightboxPreviousButton.addEventListener("click", () => navigateLightbox(-1));
  elements.lightboxNextButton.addEventListener("click", () => navigateLightbox(1));
  elements.commandButton.addEventListener("click", openCommandPalette);
  elements.shortcutButton.addEventListener("click", () => elements.shortcutDialog.showModal());
  elements.closeShortcutButton.addEventListener("click", () => elements.shortcutDialog.close());
  elements.commandSearchInput.addEventListener("input", () => {
    state.commandIndex = 0;
    renderCommandItems();
  });
  elements.commandList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-command-id]");
    if (button) executeCommand(button.dataset.commandId);
  });
  elements.commandSearchInput.addEventListener("keydown", (event) => {
    if (!state.commandItems.length) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const direction = event.key === "ArrowDown" ? 1 : -1;
      state.commandIndex = (
        state.commandIndex + direction + state.commandItems.length
      ) % state.commandItems.length;
      renderCommandItems();
      elements.commandList.querySelector(".command-item.active")?.scrollIntoView({
        block: "nearest",
      });
    } else if (event.key === "Enter") {
      event.preventDefault();
      executeCommand(state.commandItems[state.commandIndex].id);
    }
  });
  elements.assetContextMenu.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-context-action]");
    const assetID = state.contextAssetID;
    if (!button || !assetID) return;
    hideContextMenu();
    if (button.dataset.contextAction === "preview") {
      state.selectedAssetID = assetID;
      openLightbox("library", assetID);
    } else if (button.dataset.contextAction === "toggleSelection") {
      if (!state.selectionMode) setSelectionMode(true);
      toggleAssetSelection(assetID);
      state.selectionAnchorID = assetID;
    } else if (button.dataset.contextAction === "filterSource") {
      const asset = state.assets.find((item) => item.id === assetID);
      if (asset) await selectSource(asset.sourceID);
    }
  });

  document.addEventListener("click", (event) => {
    if (!elements.assetContextMenu.contains(event.target)) hideContextMenu();
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
    if (event.defaultPrevented) return;
    if (elements.appView.classList.contains("hidden")) return;
    const blockingDialogOpen = elements.shortcutDialog.open || elements.newTagDialog.open;
    const lightboxOpen = !elements.lightbox.classList.contains("hidden");
    const reviewOpen = !elements.reviewWorkspace.classList.contains("hidden");
    const inspectorOverlayOpen = globalThis.matchMedia("(max-width: 980px)").matches
      && elements.inspector.classList.contains("open");
    const customOverlayOpen = lightboxOpen || reviewOpen || inspectorOverlayOpen;
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      if (blockingDialogOpen || customOverlayOpen) {
        event.preventDefault();
        return;
      }
      event.preventDefault();
      if (elements.commandPalette.open) {
        elements.commandPalette.close();
      } else {
        openCommandPalette();
      }
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
      if (blockingDialogOpen || elements.commandPalette.open || customOverlayOpen) {
        event.preventDefault();
        return;
      }
      event.preventDefault();
      elements.searchInput.focus({ preventScroll: true });
      elements.searchInput.select();
      return;
    }
    if (event.key === "Escape") {
      if (elements.commandPalette.open) {
        elements.commandPalette.close();
        return;
      }
      if (elements.shortcutDialog.open) {
        elements.shortcutDialog.close();
        return;
      }
      if (elements.newTagDialog.open) {
        closeNewTagDialog();
        return;
      }
      if (lightboxOpen) {
        closeLightbox();
        return;
      }
      if (reviewOpen) {
        closeReviewWorkspace();
        return;
      }
      if (inspectorOverlayOpen) {
        closeInspectorOverlay();
        return;
      }
      if (state.selectionMode) {
        setSelectionMode(false);
        return;
      }
      elements.filterPopover.classList.add("hidden");
      elements.filterButton.setAttribute("aria-expanded", "false");
      elements.jobsPopover.classList.add("hidden");
      elements.sourceSidebar.classList.remove("open");
      return;
    }
    if (elements.commandPalette.open
      || elements.shortcutDialog.open
      || elements.newTagDialog.open) return;
    if (lightboxOpen) {
      if (trapOverlayFocus(event, elements.lightbox)) return;
    } else if (reviewOpen) {
      if (trapOverlayFocus(event, elements.reviewWorkspace)) return;
    } else if (inspectorOverlayOpen && trapOverlayFocus(event, elements.inspector)) {
      return;
    }
    if (isTextInputTarget(event.target)) return;
    if (lightboxOpen) {
      if (event.key === "ArrowLeft") {
        event.preventDefault();
        navigateLightbox(-1);
      }
      if (event.key === "ArrowRight") {
        event.preventDefault();
        navigateLightbox(1);
      }
      if (event.code === "Space") {
        event.preventDefault();
        closeLightbox();
      }
      return;
    }
    if (reviewOpen) {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.key === "ArrowLeft") {
        event.preventDefault();
        selectReviewIndex(state.review.selectedIndex - 1);
      }
      if (event.key === "ArrowRight") {
        event.preventDefault();
        selectReviewIndex(state.review.selectedIndex + 1);
      }
      if (!event.repeat && event.key.toLowerCase() === "p") {
        event.preventDefault();
        applyReviewDecision("accept");
      }
      if (!event.repeat && event.key.toLowerCase() === "x") {
        event.preventDefault();
        applyReviewDecision("reject");
      }
      if (!event.repeat && event.key.toLowerCase() === "u") {
        event.preventDefault();
        deferReviewSelection();
      }
      return;
    }
    if (isInteractiveControlTarget(event.target)) return;
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") {
      event.preventDefault();
      selectAllLoadedAssets();
      return;
    }
    if (event.code === "Space") {
      const assetID = state.selectionMode && state.selectedAssetIDs.size === 1
        ? [...state.selectedAssetIDs][0]
        : state.selectedAssetID;
      if (assetID) {
        event.preventDefault();
        openLightbox("library", assetID);
      }
      return;
    }
    if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "PageUp", "PageDown"]
      .includes(event.key)) {
      event.preventDefault();
      moveLibrarySelection(event.key);
      return;
    }
    if (event.key === "?") {
      elements.shortcutDialog.showModal();
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
  loadWorkspacePreferences();
  renderLayoutPreferences();
  renderMediaKindTabs();
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
