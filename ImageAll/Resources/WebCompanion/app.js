"use strict";

const $ = (selector) => document.querySelector(selector);
const SLIMMING_CLUSTER_LIMIT_MAX = 10_000;
const SLIMMING_MEMBER_LIMIT_MAX = 5_000;
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
  sourceManagerButton: $("#sourceManagerButton"),
  sourceManagerDialog: $("#sourceManagerDialog"),
  sourceManagerCloseButton: $("#sourceManagerCloseButton"),
  sourceConnectFolderButton: $("#sourceConnectFolderButton"),
  sourceConnectPhotosButton: $("#sourceConnectPhotosButton"),
  sourceManagerPending: $("#sourceManagerPending"),
  sourceManagerRefreshButton: $("#sourceManagerRefreshButton"),
  sourceManagerList: $("#sourceManagerList"),
  sourceManagerEmpty: $("#sourceManagerEmpty"),
  settingsButton: $("#settingsButton"),
  generalSettingsDialog: $("#generalSettingsDialog"),
  generalSettingsCloseButton: $("#generalSettingsCloseButton"),
  generalSettingsLoading: $("#generalSettingsLoading"),
  generalSettingsContent: $("#generalSettingsContent"),
  generalSettingsError: $("#generalSettingsError"),
  toolbarDisplayModeControl: $("#toolbarDisplayModeControl"),
  generalSettingsModelToggle: $("#generalSettingsModelToggle"),
  generalSettingsModelState: $("#generalSettingsModelState"),
  generalSettingsModelName: $("#generalSettingsModelName"),
  generalSettingsModelRuntime: $("#generalSettingsModelRuntime"),
  generalSettingsModelDetail: $("#generalSettingsModelDetail"),
  generalSettingsPrewarmToggle: $("#generalSettingsPrewarmToggle"),
  generalSettingsPrewarmDetail: $("#generalSettingsPrewarmDetail"),
  generalSuggestionSection: $("#generalSuggestionSection"),
  generalSuggestionDefaults: $("#generalSuggestionDefaults"),
  suggestionOverridesButton: $("#suggestionOverridesButton"),
  suggestionOverrideCount: $("#suggestionOverrideCount"),
  suggestionThresholdDialog: $("#suggestionThresholdDialog"),
  suggestionThresholdCloseButton: $("#suggestionThresholdCloseButton"),
  suggestionThresholdSearch: $("#suggestionThresholdSearch"),
  suggestionThresholdSummary: $("#suggestionThresholdSummary"),
  suggestionThresholdList: $("#suggestionThresholdList"),
  suggestionThresholdEmpty: $("#suggestionThresholdEmpty"),
  suggestionThresholdError: $("#suggestionThresholdError"),
  storageButton: $("#storageButton"),
  sourcePrewarmStatusButton: $("#sourcePrewarmStatusButton"),
  sourcePrewarmStatusLabel: $("#sourcePrewarmStatusLabel"),
  storageDialog: $("#storageDialog"),
  storageCloseButton: $("#storageCloseButton"),
  storageRefreshButton: $("#storageRefreshButton"),
  storagePending: $("#storagePending"),
  storageLoading: $("#storageLoading"),
  storageContent: $("#storageContent"),
  storageError: $("#storageError"),
  previewCacheSize: $("#previewCacheSize"),
  previewCacheEntries: $("#previewCacheEntries"),
  photosOriginalsSize: $("#photosOriginalsSize"),
  photosOriginalsEntries: $("#photosOriginalsEntries"),
  appStorageKind: $("#appStorageKind"),
  appStorageDetail: $("#appStorageDetail"),
  clearPreviewCacheButton: $("#clearPreviewCacheButton"),
  clearPhotosOriginalsButton: $("#clearPhotosOriginalsButton"),
  chooseExternalStorageButton: $("#chooseExternalStorageButton"),
  exportPortableDataButton: $("#exportPortableDataButton"),
  storageHistorySection: $("#storageHistorySection"),
  storageHistory: $("#storageHistory"),
  allAssetCount: $("#allAssetCount"),
  allMediaLabel: $("#allMediaLabel"),
  galleryOverviewNavigationButton: $("#galleryOverviewNavigationButton"),
  galleryOverviewNavigationCount: $("#galleryOverviewNavigationCount"),
  untaggedNavigationButton: $("#untaggedNavigationButton"),
  reviewNavigationButton: $("#reviewNavigationButton"),
  reviewNavigationCount: $("#reviewNavigationCount"),
  trainingNavigationButton: $("#trainingNavigationButton"),
  trainingNavigationCount: $("#trainingNavigationCount"),
  slimmingNavigationButton: $("#slimmingNavigationButton"),
  slimmingNavigationCount: $("#slimmingNavigationCount"),
  worldMapNavigationButton: $("#worldMapNavigationButton"),
  worldMapNavigationCount: $("#worldMapNavigationCount"),
  galleryOverviewWorkspace: $("#galleryOverviewWorkspace"),
  closeGalleryOverviewButton: $("#closeGalleryOverviewButton"),
  refreshGalleryOverviewButton: $("#refreshGalleryOverviewButton"),
  retryGalleryOverviewButton: $("#retryGalleryOverviewButton"),
  galleryOverviewScroll: $("#galleryOverviewScroll"),
  galleryOverviewSummary: $("#galleryOverviewSummary"),
  galleryOverviewRefreshedAt: $("#galleryOverviewRefreshedAt"),
  galleryOverviewStatus: $("#galleryOverviewStatus"),
  galleryOverviewBody: $("#galleryOverviewBody"),
  galleryOverviewTotalMetric: $("#galleryOverviewTotalMetric"),
  galleryOverviewUniqueMetric: $("#galleryOverviewUniqueMetric"),
  galleryOverviewRedundantMetric: $("#galleryOverviewRedundantMetric"),
  galleryOverviewPositiveMetric: $("#galleryOverviewPositiveMetric"),
  galleryOverviewAcceptedMetric: $("#galleryOverviewAcceptedMetric"),
  galleryOverviewMediaLedger: $("#galleryOverviewMediaLedger"),
  galleryOverviewSourceSubtitle: $("#galleryOverviewSourceSubtitle"),
  galleryOverviewSources: $("#galleryOverviewSources"),
  galleryOverviewAvailability: $("#galleryOverviewAvailability"),
  galleryOverviewTags: $("#galleryOverviewTags"),
  galleryOverviewTimelineSubtitle: $("#galleryOverviewTimelineSubtitle"),
  galleryOverviewTimeline: $("#galleryOverviewTimeline"),
  galleryOverviewUndated: $("#galleryOverviewUndated"),
  galleryOverviewCoverage: $("#galleryOverviewCoverage"),
  tagNavigation: $("#tagNavigation"),
  tagNavigationSearch: $("#tagNavigationSearch"),
  tagNavigationEmpty: $("#tagNavigationEmpty"),
  tagNavigationEmptyText: $("#tagNavigationEmptyText"),
  sidebarInstallPresetTagsButton: $("#sidebarInstallPresetTagsButton"),
  sidebarNewTagButton: $("#sidebarNewTagButton"),
  tagManagerButton: $("#tagManagerButton"),
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
  emptyStateActions: $("#emptyStateActions"),
  emptyConnectFolderButton: $("#emptyConnectFolderButton"),
  emptyConnectPhotosButton: $("#emptyConnectPhotosButton"),
  emptyInstallPresetTagsButton: $("#emptyInstallPresetTagsButton"),
  emptySourceRecoveryButton: $("#emptySourceRecoveryButton"),
  emptyOpenSourceManagerButton: $("#emptyOpenSourceManagerButton"),
  loadMoreButton: $("#loadMoreButton"),
  gridDensitySlider: $("#gridDensitySlider"),
  thumbnailAspectButton: $("#thumbnailAspectButton"),
  inspector: $("#inspector"),
  inspectorPlaceholder: $("#inspectorPlaceholder"),
  inspectorPlaceholderText: $("#inspectorPlaceholderText"),
  selectionInspector: $("#selectionInspector"),
  selectionInspectorTitle: $("#selectionInspectorTitle"),
  selectionInspectorTags: $("#selectionInspectorTags"),
  selectionInspectorNewTagButton: $("#selectionInspectorNewTagButton"),
  selectionInspectorPrepareFeaturesButton: $("#selectionInspectorPrepareFeaturesButton"),
  selectionInspectorGenerateSuggestionsButton: $("#selectionInspectorGenerateSuggestionsButton"),
  selectionInspectorFindSimilarButton: $("#selectionInspectorFindSimilarButton"),
  selectionInspectorToolStatus: $("#selectionInspectorToolStatus"),
  selectionInspectorCancelPreparationButton: $("#selectionInspectorCancelPreparationButton"),
  selectionTagSearch: $("#selectionTagSearch"),
  inspectorContent: $("#inspectorContent"),
  previewPlaceholderImage: $("#previewPlaceholderImage"),
  previewImage: $("#previewImage"),
  previewVideo: $("#previewVideo"),
  previewLoading: $("#previewLoading"),
  cloudPreviewRecovery: $("#cloudPreviewRecovery"),
  cloudPreviewIcon: $("#cloudPreviewIcon"),
  cloudPreviewTitle: $("#cloudPreviewTitle"),
  cloudPreviewMessage: $("#cloudPreviewMessage"),
  cloudPreviewButton: $("#cloudPreviewButton"),
  openLightboxButton: $("#openLightboxButton"),
  inspectorSuggestionsSection: $("#inspectorSuggestionsSection"),
  inspectorSuggestionsTitle: $("#inspectorSuggestionsTitle"),
  inspectorSuggestionCount: $("#inspectorSuggestionCount"),
  inspectorSuggestions: $("#inspectorSuggestions"),
  expandInspectorSuggestionsButton: $("#expandInspectorSuggestionsButton"),
  assetFileName: $("#assetFileName"),
  assetMetadata: $("#assetMetadata"),
  openOriginalButton: $("#openOriginalButton"),
  openOriginalButtonIcon: $("#openOriginalButtonIcon"),
  openOriginalButtonLabel: $("#openOriginalButtonLabel"),
  openOriginalHint: $("#openOriginalHint"),
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
  trainingButton: $("#trainingButton"),
  slimmingButton: $("#slimmingButton"),
  worldMapButton: $("#worldMapButton"),
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
  activeFilterBar: $("#activeFilterBar"),
  activeFilterSummary: $("#activeFilterSummary"),
  activeFilterRelation: $("#activeFilterRelation"),
  clearActiveFiltersButton: $("#clearActiveFiltersButton"),
  selectionModeButton: $("#selectionModeButton"),
  personalModelButton: $("#personalModelButton"),
  personalModelPopover: $("#personalModelPopover"),
  personalModelScopeSummary: $("#personalModelScopeSummary"),
  rebuildPersonalModelButton: $("#rebuildPersonalModelButton"),
  rebuildPersonalAdamWButton: $("#rebuildPersonalAdamWButton"),
  batchBar: $("#batchBar"),
  selectionSummary: $("#selectionSummary"),
  selectAllLoadedButton: $("#selectAllLoadedButton"),
  batchTagSelect: $("#batchTagSelect"),
  batchAggregate: $("#batchAggregate"),
  batchNewTagButton: $("#batchNewTagButton"),
  prepareSelectedFeaturesButton: $("#prepareSelectedFeaturesButton"),
  generateSelectedSuggestionsButton: $("#generateSelectedSuggestionsButton"),
  findSimilarSelectionButton: $("#findSimilarSelectionButton"),
  embeddingPreparationStatus: $("#embeddingPreparationStatus"),
  cancelEmbeddingPreparationButton: $("#cancelEmbeddingPreparationButton"),
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
  reviewBackButton: $("#reviewBackButton"),
  reviewSummary: $("#reviewSummary"),
  reviewTagControl: $("#reviewTagControl"),
  reviewTagSelect: $("#reviewTagSelect"),
  reviewCurrentSourceOnly: $("#reviewCurrentSourceOnly"),
  refreshReviewButton: $("#refreshReviewButton"),
  reviewUndoButton: $("#reviewUndoButton"),
  generateLibrarySuggestionsButton: $("#generateLibrarySuggestionsButton"),
  cancelSampleSuggestionsButton: $("#cancelSampleSuggestionsButton"),
  sampleSuggestionReviewStatus: $("#sampleSuggestionReviewStatus"),
  reviewOverview: $("#reviewOverview"),
  reviewOverviewGrid: $("#reviewOverviewGrid"),
  reviewOverviewEmpty: $("#reviewOverviewEmpty"),
  tagSuggestionDialog: $("#tagSuggestionDialog"),
  tagSuggestionForm: $("#tagSuggestionForm"),
  tagSuggestionDialogTitle: $("#tagSuggestionDialogTitle"),
  tagSuggestionDialogSubtitle: $("#tagSuggestionDialogSubtitle"),
  tagSuggestionMethodSummary: $("#tagSuggestionMethodSummary"),
  tagSuggestionLimitSummary: $("#tagSuggestionLimitSummary"),
  tagSuggestionThresholdSummary: $("#tagSuggestionThresholdSummary"),
  tagSuggestionSourceOptions: $("#tagSuggestionSourceOptions"),
  tagSuggestionError: $("#tagSuggestionError"),
  tagSuggestionSelectionSummary: $("#tagSuggestionSelectionSummary"),
  closeTagSuggestionDialogButton: $("#closeTagSuggestionDialogButton"),
  cancelTagSuggestionDialogButton: $("#cancelTagSuggestionDialogButton"),
  selectAllTagSuggestionSourcesButton: $("#selectAllTagSuggestionSourcesButton"),
  clearTagSuggestionSourcesButton: $("#clearTagSuggestionSourcesButton"),
  launchTagSuggestionButton: $("#launchTagSuggestionButton"),
  reviewQueueLayout: $("#reviewQueueLayout"),
  reviewQueuePane: $("#reviewQueuePane"),
  reviewMarqueeSelection: $("#reviewMarqueeSelection"),
  reviewGrid: $("#reviewGrid"),
  reviewEmpty: $("#reviewEmpty"),
  loadMoreReviewButton: $("#loadMoreReviewButton"),
  reviewPlaceholder: $("#reviewPlaceholder"),
  reviewDetail: $("#reviewDetail"),
  reviewPreviewImage: $("#reviewPreviewImage"),
  reviewOpenLightboxButton: $("#reviewOpenLightboxButton"),
  reviewFileName: $("#reviewFileName"),
  reviewOrigin: $("#reviewOrigin"),
  reviewSelectionSummary: $("#reviewSelectionSummary"),
  reviewPosition: $("#reviewPosition"),
  previousReviewButton: $("#previousReviewButton"),
  nextReviewButton: $("#nextReviewButton"),
  trainingWorkspace: $("#trainingWorkspace"),
  closeTrainingButton: $("#closeTrainingButton"),
  trainingSummary: $("#trainingSummary"),
  trainingMediaKindTabs: $("#trainingMediaKindTabs"),
  trainingMethodFilter: $("#trainingMethodFilter"),
  trainingRecordScopeFilter: $("#trainingRecordScopeFilter"),
  trainingFeatureMethodOption: $("#trainingFeatureMethodOption"),
  newTrainingButton: $("#newTrainingButton"),
  toggleTrainingNavigatorButton: $("#toggleTrainingNavigatorButton"),
  refreshTrainingButton: $("#refreshTrainingButton"),
  trainingActivityStrip: $("#trainingActivityStrip"),
  trainingSlotStrip: $("#trainingSlotStrip"),
  trainingBatchHistory: $("#trainingBatchHistory"),
  trainingBatchCount: $("#trainingBatchCount"),
  trainingBatchList: $("#trainingBatchList"),
  trainingRunCount: $("#trainingRunCount"),
  trainingRunList: $("#trainingRunList"),
  trainingEmpty: $("#trainingEmpty"),
  trainingDetailPlaceholder: $("#trainingDetailPlaceholder"),
  trainingDetail: $("#trainingDetail"),
  trainingDetailTitle: $("#trainingDetailTitle"),
  trainingDetailSubtitle: $("#trainingDetailSubtitle"),
  trainingDetailContext: $("#trainingDetailContext"),
  trainingDetailState: $("#trainingDetailState"),
  trainingDetailActions: $("#trainingDetailActions"),
  trainingFactLedger: $("#trainingFactLedger"),
  trainingErrorSection: $("#trainingErrorSection"),
  trainingErrorTitle: $("#trainingErrorTitle"),
  trainingErrorMessage: $("#trainingErrorMessage"),
  trainingErrorAction: $("#trainingErrorAction"),
  trainingErrorCode: $("#trainingErrorCode"),
  trainingMetricsSummary: $("#trainingMetricsSummary"),
  trainingMetricsJSON: $("#trainingMetricsJSON"),
  trainingArtifactLedger: $("#trainingArtifactLedger"),
  trainingTechnicalBlocks: $("#trainingTechnicalBlocks"),
  trainingSetupDialog: $("#trainingSetupDialog"),
  trainingSetupForm: $("#trainingSetupForm"),
  closeTrainingSetupButton: $("#closeTrainingSetupButton"),
  cancelTrainingSetupButton: $("#cancelTrainingSetupButton"),
  trainingSetupMethods: $("#trainingSetupMethods"),
  trainingSetupLoading: $("#trainingSetupLoading"),
  trainingSetupConfiguration: $("#trainingSetupConfiguration"),
  trainingSetupConfigTitle: $("#trainingSetupConfigTitle"),
  trainingSetupConfigHint: $("#trainingSetupConfigHint"),
  trainingTagSearch: $("#trainingTagSearch"),
  trainingTagOptions: $("#trainingTagOptions"),
  trainingScopeTitle: $("#trainingScopeTitle"),
  trainingScopeHint: $("#trainingScopeHint"),
  trainingScopeOptions: $("#trainingScopeOptions"),
  trainingLaunchSummary: $("#trainingLaunchSummary"),
  trainingSetupError: $("#trainingSetupError"),
  trainingSetupNotice: $("#trainingSetupNotice"),
  launchTrainingButton: $("#launchTrainingButton"),
  slimmingWorkspace: $("#slimmingWorkspace"),
  closeSlimmingButton: $("#closeSlimmingButton"),
  slimmingSummary: $("#slimmingSummary"),
  slimmingWorkspaceTabs: $("#slimmingWorkspaceTabs"),
  slimmingMediaKindTabs: $("#slimmingMediaKindTabs"),
  slimmingNoticeText: $("#slimmingNoticeText"),
  newSlimmingAnalysisButton: $("#newSlimmingAnalysisButton"),
  slimmingIdenticalCleanupButton: $("#slimmingIdenticalCleanupButton"),
  refreshSlimmingButton: $("#refreshSlimmingButton"),
  slimmingAnalysisBody: $("#slimmingAnalysisBody"),
  slimmingJobCount: $("#slimmingJobCount"),
  previousSlimmingJobButton: $("#previousSlimmingJobButton"),
  slimmingJobPosition: $("#slimmingJobPosition"),
  nextSlimmingJobButton: $("#nextSlimmingJobButton"),
  slimmingJobActions: $("#slimmingJobActions"),
  slimmingJobList: $("#slimmingJobList"),
  slimmingEmpty: $("#slimmingEmpty"),
  slimmingClusterCount: $("#slimmingClusterCount"),
  slimmingClusterList: $("#slimmingClusterList"),
  slimmingLoadMoreClustersButton: $("#slimmingLoadMoreClustersButton"),
  slimmingClusterEmpty: $("#slimmingClusterEmpty"),
  slimmingMemberTitle: $("#slimmingMemberTitle"),
  slimmingMemberSummary: $("#slimmingMemberSummary"),
  slimmingJobStatus: $("#slimmingJobStatus"),
  slimmingInspector: $("#slimmingInspector"),
  slimmingInspectorSummary: $("#slimmingInspectorSummary"),
  slimmingInspectorContent: $("#slimmingInspectorContent"),
  slimmingSelectionSummary: $("#slimmingSelectionSummary"),
  slimmingSelectionBar: $("#slimmingSelectionBar"),
  slimmingSelectionBarSummary: $("#slimmingSelectionBarSummary"),
  slimmingMoveToRecycleButton: $("#slimmingMoveToRecycleButton"),
  slimmingReleaseSpaceButton: $("#slimmingReleaseSpaceButton"),
  slimmingRemovalStatus: $("#slimmingRemovalStatus"),
  slimmingMemberGrid: $("#slimmingMemberGrid"),
  slimmingLoadMoreMembersButton: $("#slimmingLoadMoreMembersButton"),
  slimmingMemberEmpty: $("#slimmingMemberEmpty"),
  slimmingRecycleBody: $("#slimmingRecycleBody"),
  slimmingRecycleSearchInput: $("#slimmingRecycleSearchInput"),
  slimmingRecycleSourceSelect: $("#slimmingRecycleSourceSelect"),
  slimmingRecycleCount: $("#slimmingRecycleCount"),
  slimmingRecycleRequestStatus: $("#slimmingRecycleRequestStatus"),
  slimmingRecycleList: $("#slimmingRecycleList"),
  slimmingRecycleLoadMoreButton: $("#slimmingRecycleLoadMoreButton"),
  slimmingRecycleEmpty: $("#slimmingRecycleEmpty"),
  slimmingSetupDialog: $("#slimmingSetupDialog"),
  slimmingSetupForm: $("#slimmingSetupForm"),
  closeSlimmingSetupButton: $("#closeSlimmingSetupButton"),
  cancelSlimmingSetupButton: $("#cancelSlimmingSetupButton"),
  slimmingSetupLoading: $("#slimmingSetupLoading"),
  slimmingSetupConfiguration: $("#slimmingSetupConfiguration"),
  slimmingModeOptions: $("#slimmingModeOptions"),
  slimmingSourceSection: $("#slimmingSourceSection"),
  slimmingSourceHint: $("#slimmingSourceHint"),
  toggleAllSlimmingSourcesButton: $("#toggleAllSlimmingSourcesButton"),
  slimmingSourceOptions: $("#slimmingSourceOptions"),
  slimmingRecallMode: $("#slimmingRecallMode"),
  slimmingRecallTopK: $("#slimmingRecallTopK"),
  slimmingL2Mode: $("#slimmingL2Mode"),
  slimmingL2Distance: $("#slimmingL2Distance"),
  slimmingDINOMode: $("#slimmingDINOMode"),
  slimmingDINOSimilarity: $("#slimmingDINOSimilarity"),
  slimmingBucketingMode: $("#slimmingBucketingMode"),
  slimmingBucketActivationCount: $("#slimmingBucketActivationCount"),
  resetSlimmingThresholdsButton: $("#resetSlimmingThresholdsButton"),
  slimmingExtremeWarning: $("#slimmingExtremeWarning"),
  slimmingLaunchSummary: $("#slimmingLaunchSummary"),
  slimmingSetupError: $("#slimmingSetupError"),
  saveSlimmingThresholdsButton: $("#saveSlimmingThresholdsButton"),
  launchSlimmingButton: $("#launchSlimmingButton"),
  worldMapWorkspace: $("#worldMapWorkspace"),
  closeWorldMapButton: $("#closeWorldMapButton"),
  refreshWorldMapButton: $("#refreshWorldMapButton"),
  openWorldMapPlaceTagsButton: $("#openWorldMapPlaceTagsButton"),
  worldMapPlaceTagDialog: $("#worldMapPlaceTagDialog"),
  worldMapPlaceTagBody: $("#worldMapPlaceTagBody"),
  closeWorldMapPlaceTagButton: $("#closeWorldMapPlaceTagButton"),
  worldMapPlaceTagError: $("#worldMapPlaceTagError"),
  worldMapPlaceTagLoading: $("#worldMapPlaceTagLoading"),
  worldMapPlaceTagEmpty: $("#worldMapPlaceTagEmpty"),
  worldMapPlaceTagItems: $("#worldMapPlaceTagItems"),
  openWorldMapLocationBackfillButton: $("#openWorldMapLocationBackfillButton"),
  worldMapLocationBackfillDialog: $("#worldMapLocationBackfillDialog"),
  closeWorldMapLocationBackfillButton: $("#closeWorldMapLocationBackfillButton"),
  worldMapLocationBackfillError: $("#worldMapLocationBackfillError"),
  worldMapLocationBackfillLoading: $("#worldMapLocationBackfillLoading"),
  worldMapLocationBackfillEmpty: $("#worldMapLocationBackfillEmpty"),
  worldMapLocationBackfillSources: $("#worldMapLocationBackfillSources"),
  closeWorldMapDetailButton: $("#closeWorldMapDetailButton"),
  worldMapFrame: $("#worldMapFrame"),
  worldMapSummary: $("#worldMapSummary"),
  worldMapClusterMetric: $("#worldMapClusterMetric"),
  worldMapLocatedMetric: $("#worldMapLocatedMetric"),
  worldMapUnlocatedMetric: $("#worldMapUnlocatedMetric"),
  worldMapRendererMetric: $("#worldMapRendererMetric"),
  worldMapStatus: $("#worldMapStatus"),
  worldMapDetail: $("#worldMapDetail"),
  worldMapDetailName: $("#worldMapDetailName"),
  worldMapDetailComposition: $("#worldMapDetailComposition"),
  worldMapPhotoStrip: $("#worldMapPhotoStrip"),
  worldMapDetailCount: $("#worldMapDetailCount"),
  worldMapSelectionSummary: $("#worldMapSelectionSummary"),
  slimmingIdenticalCleanupDialog: $("#slimmingIdenticalCleanupDialog"),
  slimmingIdenticalCleanupLoading: $("#slimmingIdenticalCleanupLoading"),
  slimmingIdenticalCleanupContent: $("#slimmingIdenticalCleanupContent"),
  slimmingIdenticalCleanupMetrics: $("#slimmingIdenticalCleanupMetrics"),
  slimmingIdenticalCleanupSources: $("#slimmingIdenticalCleanupSources"),
  slimmingIdenticalCleanupNotice: $("#slimmingIdenticalCleanupNotice"),
  slimmingIdenticalCleanupError: $("#slimmingIdenticalCleanupError"),
  cancelSlimmingIdenticalCleanupButton: $("#cancelSlimmingIdenticalCleanupButton"),
  recoverableSlimmingIdenticalCleanupButton:
    $("#recoverableSlimmingIdenticalCleanupButton"),
  fastSlimmingIdenticalCleanupButton: $("#fastSlimmingIdenticalCleanupButton"),
  slimmingVerificationDialog: $("#slimmingVerificationDialog"),
  slimmingVerificationIcon: $("#slimmingVerificationIcon"),
  slimmingVerificationTitle: $("#slimmingVerificationTitle"),
  slimmingVerificationSubtitle: $("#slimmingVerificationSubtitle"),
  slimmingVerificationScore: $("#slimmingVerificationScore"),
  slimmingVerificationGoal: $("#slimmingVerificationGoal"),
  slimmingVerificationMetrics: $("#slimmingVerificationMetrics"),
  slimmingVerificationResult: $("#slimmingVerificationResult"),
  closeSlimmingVerificationButton: $("#closeSlimmingVerificationButton"),
  lightbox: $("#lightbox"),
  lightboxTitle: $("#lightboxTitle"),
  lightboxImage: $("#lightboxImage"),
  lightboxVideo: $("#lightboxVideo"),
  lightboxReviewActions: $("#lightboxReviewActions"),
  lightboxPreviousButton: $("#lightboxPreviousButton"),
  lightboxNextButton: $("#lightboxNextButton"),
  lightboxPosition: $("#lightboxPosition"),
  lightboxBackButton: $("#lightboxBackButton"),
  lightboxBackLabel: $("#lightboxBackLabel"),
  closeLightboxButton: $("#closeLightboxButton"),
  commandButton: $("#commandButton"),
  shortcutButton: $("#shortcutButton"),
  undoTagButton: $("#undoTagButton"),
  undoReviewButton: $("#undoReviewButton"),
  commandPalette: $("#commandPalette"),
  commandSearchInput: $("#commandSearchInput"),
  commandList: $("#commandList"),
  shortcutDialog: $("#shortcutDialog"),
  closeShortcutButton: $("#closeShortcutButton"),
  assetContextMenu: $("#assetContextMenu"),
  sourceContextMenu: $("#sourceContextMenu"),
  sourceContextMenuTitle: $("#sourceContextMenuTitle"),
  sourceContextMenuActions: $("#sourceContextMenuActions"),
  tagContextMenu: $("#tagContextMenu"),
  tagContextMenuTitle: $("#tagContextMenuTitle"),
  tagContextMenuActions: $("#tagContextMenuActions"),
  toast: $("#toast"),
  toastMessage: $("#toastMessage"),
  undoToastButton: $("#undoToastButton"),
  tagManagerDialog: $("#tagManagerDialog"),
  closeTagManagerButton: $("#closeTagManagerButton"),
  tagManagerTagSelect: $("#tagManagerTagSelect"),
  tagManagerTagName: $("#tagManagerTagName"),
  tagManagerTagGroupSelect: $("#tagManagerTagGroupSelect"),
  renameManagedTagButton: $("#renameManagedTagButton"),
  moveManagedTagButton: $("#moveManagedTagButton"),
  archiveManagedTagButton: $("#archiveManagedTagButton"),
  tagManagerGroupSelect: $("#tagManagerGroupSelect"),
  tagManagerGroupName: $("#tagManagerGroupName"),
  createTagGroupButton: $("#createTagGroupButton"),
  installPresetTagsButton: $("#installPresetTagsButton"),
  renameTagGroupButton: $("#renameTagGroupButton"),
  deleteTagGroupButton: $("#deleteTagGroupButton"),
  tagManagerError: $("#tagManagerError"),
  confirmDialog: $("#confirmDialog"),
  confirmDialogTitle: $("#confirmDialogTitle"),
  confirmDialogMessage: $("#confirmDialogMessage"),
  cancelConfirmButton: $("#cancelConfirmButton"),
  confirmActionButton: $("#confirmActionButton"),
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
  tagGroups: [],
  jobs: [],
  sourceManagement: {
    snapshot: null,
    loading: false,
    submitting: false,
    pollTimer: null,
    requestGeneration: 0,
    seenTerminalRequestIDs: new Set(),
  },
  generalSettings: {
    snapshot: null,
    loading: false,
    submitting: false,
    requestGeneration: 0,
    returnFocus: null,
    thresholdReturnFocus: null,
    pendingDefaultFocus: null,
    pendingThresholdFocus: null,
  },
  storageMaintenance: {
    snapshot: null,
    loading: false,
    submitting: false,
    pollTimer: null,
    requestGeneration: 0,
    seenTerminalRequestIDs: new Set(),
  },
  sourceManagerReturnFocus: null,
  storageReturnFocus: null,
  assets: [],
  nextCursor: null,
  selectedSourceID: "",
  selectedAssetID: null,
  selectedDetail: null,
  cloudPreview: {
    assetID: null,
    status: "hidden",
    requestGeneration: 0,
  },
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
  embeddingPreparation: {
    isAvailable: false,
    activities: [],
    loading: false,
    submitting: false,
    cancelling: false,
    requestGeneration: 0,
    pollTimer: null,
    seenTerminalOperationIDs: new Set(),
  },
  sampleSuggestions: {
    isAvailable: false,
    maximumSampleCount: 500,
    activities: [],
    loading: false,
    submitting: false,
    cancelling: false,
    requestGeneration: 0,
    pollTimer: null,
    seenTerminalOperationIDs: new Set(),
  },
  tagLibrarySuggestions: {
    snapshot: null,
    loading: false,
    submitting: false,
    cancellingIDs: new Set(),
    requestGeneration: 0,
    pollTimer: null,
    seenTerminalOperationIDs: new Set(),
    dialog: {
      tagID: null,
      method: "personalCentroid",
      selectedSourceIDs: new Set(),
      returnFocus: null,
    },
  },
  inspectorDismissed: false,
  online: false,
  authMode: null,
  accountAuthorization: null,
  loadingAssets: false,
  loadingAggregate: false,
  selectionAggregates: [],
  aggregateGeneration: 0,
  tagMutating: false,
  tagManagementMutating: false,
  installingPresetTags: false,
  presetTagOperationID: null,
  openingOriginal: false,
  jobMutatingIDs: new Set(),
  focusedActivityJobID: null,
  inspectorTagSearchText: "",
  selectionTagSearchText: "",
  review: {
    mode: "overview",
    overview: [],
    overviewTotal: 0,
    overviewLoading: false,
    overviewGeneration: 0,
    items: [],
    nextCursor: null,
    selectedIndex: -1,
    selectedAssetIDs: new Set(),
    selectionAnchorIndex: -1,
    marquee: null,
    loading: false,
    mutating: false,
    requestGeneration: 0,
    loadedScopeKey: null,
    returnTarget: null,
    pendingFocusTrainingJobID: null,
  },
  training: {
    mediaKind: "image",
    method: "",
    runScope: "all",
    runs: [],
    slots: [],
    activities: [],
    selectedRunID: null,
    loading: false,
    requestGeneration: 0,
    activityMutatingIDs: new Set(),
    focusedRunID: null,
    focusedJobID: null,
    focusedTagID: null,
    pendingReturnFocusRunID: null,
    returnTarget: null,
    setup: {
      loading: false,
      launching: false,
      snapshot: null,
      method: "featureKnn",
      selectedTagIDs: new Set(),
      selectedSourceIDs: new Set(),
      scope: "allSources",
      tagSearchText: "",
      error: "",
      notice: "",
      requestGeneration: 0,
      operationID: null,
      returnFocus: null,
    },
  },
  slimming: {
    view: "analysis",
    mediaKind: "image",
    jobs: [],
    selectedJobID: null,
    clusters: [],
    selectedClusterID: null,
    members: [],
    pendingAnalysisCount: 0,
    analyzedAssetCount: 0,
    policyVersion: null,
    selectedMemberIDs: new Set(),
    selectionAnchorID: null,
    loading: false,
    requestGeneration: 0,
    clusterLimit: 48,
    memberLimit: 96,
    inspectorCompactInitialized: false,
    jobMutatingIDs: new Set(),
    removal: {
      requests: [],
      loading: false,
      submitting: false,
      requestGeneration: 0,
      pollTimer: null,
      lastTerminalRequestID: null,
    },
    identicalCleanup: {
      plan: null,
      requests: [],
      preparing: false,
      submitting: false,
      requestGeneration: 0,
      pollTimer: null,
      lastTerminalRequestID: null,
      lastPresentedVerificationID: null,
    },
    recycle: {
      entries: [],
      totalCount: 0,
      requests: [],
      sourceID: "",
      searchText: "",
      limit: 60,
      loading: false,
      mutatingEntryIDs: new Set(),
      requestGeneration: 0,
      pollTimer: null,
      searchTimer: null,
      lastTerminalRequestID: null,
    },
    setup: {
      loading: false,
      saving: false,
      launching: false,
      snapshot: null,
      mode: "catalog",
      selectedSourceIDs: new Set(),
      thresholds: null,
      error: "",
      requestGeneration: 0,
      thresholdOperationID: null,
      launchOperationID: null,
    },
  },
  worldMap: {
    snapshot: null,
    selection: null,
    selectedClusterID: null,
    viewport: null,
    loading: false,
    selectionLoading: false,
    rendererReady: false,
    rendererError: false,
    loadError: "",
    requestGeneration: 0,
    selectionGeneration: 0,
    cameraTimer: null,
    locationBackfill: {
      snapshots: [],
      loading: false,
      error: "",
      busySourceIDs: new Set(),
      operationIDs: new Map(),
      requestGeneration: 0,
      pollTimer: null,
      returnFocus: null,
    },
    placeTags: {
      items: [],
      maximumQueryLength: 160,
      loading: false,
      error: "",
      busyTagIDs: new Set(),
      operationIDs: new Map(),
      queryByTagID: new Map(),
      submittedQueryByTagID: new Map(),
      activeQueryByTagID: new Map(),
      requestGeneration: 0,
      mutationGeneration: 0,
      returnFocus: null,
    },
  },
  galleryOverview: {
    snapshot: null,
    loading: false,
    error: "",
    requestGeneration: 0,
    refreshedAt: null,
  },
  lightboxContext: null,
  lightboxAssetID: null,
  lightboxRequestGeneration: 0,
  lightboxNavigating: false,
  lightboxPendingDirection: 0,
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
  undo: {
    tag: { id: null, operationID: null, mutating: false },
    review: { id: null, operationID: null, mutating: false },
  },
  toastUndoKind: null,
  pendingConfirmAction: null,
  newTagOperationID: null,
  autoLoadObserver: null,
  searchTimer: null,
  commandItems: [],
  commandIndex: 0,
  contextAssetID: null,
  contextSourceID: null,
  contextTagID: null,
  contextTagGroupID: null,
  tagManagerReturnFocus: null,
  confirmationReturnFocus: null,
  sidebarDrag: {
    sourceID: null,
    tagID: null,
    tagSurface: null,
    pendingSelectionRender: false,
    dropTarget: null,
    suppressClickUntil: 0,
  },
  marquee: null,
  pendingInspectorTagFocus: null,
  inspectorSuggestionsExpanded: false,
  pendingInspectorSuggestionFocus: null,
  reviewReturnFocus: null,
  trainingReturnFocus: null,
  jobsReturnFocus: null,
  jobsReturnTarget: null,
  slimmingReturnFocus: null,
  worldMapReturnFocus: null,
  galleryOverviewReturnFocus: null,
  lightboxReturnFocus: null,
  layout: {
    sidebarVisible: true,
    inspectorVisible: true,
    trainingNavigatorVisible: true,
    density: 4,
    aspectMode: "square",
    collapsedSidebarTagGroupIDs: new Set(),
    collapsedInspectorTagGroupIDs: new Set(),
    collapsedReviewTagGroupIDs: new Set(),
    sourceOrderIDs: [],
    tagOrderIDsByGroup: {},
  },
};

const densityWidths = [74, 86, 100, 116, 132, 156, 184, 220, 268];
const protectedImageRequests = new WeakMap();
const protectedImageAbortControllers = new WeakMap();
let protectedImageRequestSequence = 0;
let mediaWorkerRegistrationPromise = null;
const mediaWorkerURL = "/service-worker.js?v=20260805-2";
let assetHoverVideoGeneration = 0;
let assetHoverVideoTimer = null;
let activeAssetHoverCard = null;
const protectedImageIntersectionObserver = "IntersectionObserver" in globalThis
  ? new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const image = entry.target;
      protectedImageIntersectionObserver.unobserve(image);
      const requestID = Number(image.dataset.protectedRequestId);
      const path = image.dataset.protectedPath;
      if (!path || protectedImageRequests.get(image) !== requestID) continue;
      startProtectedImageRequest(image, path, requestID, "low");
    }
  }, {
    root: elements.libraryScroll,
    rootMargin: "600px",
  })
  : null;

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

function ensureMediaWorker() {
  if (!("serviceWorker" in navigator)) return null;
  if (!mediaWorkerRegistrationPromise) {
    mediaWorkerRegistrationPromise = navigator.serviceWorker
      .register(mediaWorkerURL, {
        scope: "/",
        updateViaCache: "none",
      })
      .then(async (registration) => {
        await registration.update();
        await navigator.serviceWorker.ready;
        const expectedURL = new URL(mediaWorkerURL, location.href).href;
        if (navigator.serviceWorker.controller?.scriptURL !== expectedURL) {
          await new Promise((resolve) => {
            const timeout = setTimeout(resolve, 5000);
            navigator.serviceWorker.addEventListener("controllerchange", () => {
              clearTimeout(timeout);
              resolve();
            }, { once: true });
          });
        }
        return registration;
      })
      .catch(() => null);
  }
  return mediaWorkerRegistrationPromise;
}

async function updateMediaWorkerAuthorization(authorization) {
  if (!("serviceWorker" in navigator)) return false;
  await ensureMediaWorker();
  // An installed-but-not-controlling worker cannot intercept this page's
  // native <video> requests, so do not report the auth bridge as ready.
  const worker = navigator.serviceWorker.controller;
  if (!worker) return false;
  return new Promise((resolve) => {
    const channel = new MessageChannel();
    const timeout = setTimeout(() => resolve(false), 2000);
    channel.port1.onmessage = () => {
      clearTimeout(timeout);
      resolve(true);
    };
    worker.postMessage({
      type: "imageall-media-authorization",
      authorization: authorization || null,
    }, [channel.port2]);
  });
}

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.addEventListener("message", (event) => {
    if (event.data?.type !== "imageall-media-authorization-request") return;
    event.ports[0]?.postMessage({
      authorization: state.accountAuthorization || null,
    });
  });
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

function dispatchProtectedImageEvent(image, type, requestID, detail = {}) {
  if (protectedImageRequests.get(image) !== requestID) return;
  image.dispatchEvent(new CustomEvent(type, {
    detail: { requestID, ...detail },
  }));
}

function failProtectedImage(image, requestID, error = null) {
  if (protectedImageRequests.get(image) !== requestID) return;
  delete image.dataset.protectedPath;
  image.dataset.protectedAssignedRequestId = String(requestID);
  image.removeAttribute("src");
  dispatchProtectedImageEvent(image, "imageall-protected-error", requestID, {
    status: error?.status || 0,
    code: error?.code || "",
    message: error?.message || "",
  });
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

function startProtectedImageRequest(image, path, requestID, priority = "auto") {
  if (protectedImageRequests.get(image) !== requestID) return;
  const controller = new AbortController();
  protectedImageAbortControllers.set(image, controller);
  rawFetch(path, { signal: controller.signal, priority })
    .then(async (response) => {
      if (!response.ok) {
        let payload = null;
        try {
          payload = await parseResponse(response);
        } catch {
          // Preserve the HTTP status even if a proxy returned a non-JSON body.
        }
        throw new APIError(response.status, typeof payload === "object" ? payload : {
          message: `图片请求失败（${response.status}）`,
        });
      }
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
      failProtectedImage(image, requestID, error);
    })
    .finally(() => {
      if (protectedImageAbortControllers.get(image) === controller) {
        protectedImageAbortControllers.delete(image);
      }
    });
}

function setProtectedImageSource(image, path, { priority = "auto", forceFetch = false } = {}) {
  if (image.dataset.protectedPath === path) return;
  protectedImageIntersectionObserver?.unobserve(image);
  protectedImageAbortControllers.get(image)?.abort();
  protectedImageAbortControllers.delete(image);
  const requestID = ++protectedImageRequestSequence;
  protectedImageRequests.set(image, requestID);
  image.dataset.protectedRequestId = String(requestID);
  image.dataset.protectedPath = path;
  delete image.dataset.protectedAssignedRequestId;
  image.removeAttribute("src");
  if (!state.accountAuthorization && !forceFetch) {
    image.dataset.protectedAssignedRequestId = String(requestID);
    image.src = path;
    void monitorProtectedImageDecode(image, requestID);
    return;
  }
  if (image.loading === "lazy" && protectedImageIntersectionObserver) {
    protectedImageIntersectionObserver.observe(image);
    return;
  }
  startProtectedImageRequest(image, path, requestID, priority);
}

function clearProtectedImageSource(image) {
  protectedImageIntersectionObserver?.unobserve(image);
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
  closePersonalModelPopover({ restoreFocus: false });
  closeJobsPopover({ restoreFocus: false });
  elements.sourceSidebar.classList.remove("open");
  hideContextMenus();
  if (elements.commandPalette.open) elements.commandPalette.close();
  if (elements.shortcutDialog.open) elements.shortcutDialog.close();
  if (elements.newTagDialog.open) closeNewTagDialog();
  if (elements.tagManagerDialog.open) elements.tagManagerDialog.close();
  if (elements.confirmDialog.open) elements.confirmDialog.close();
  if (elements.generalSettingsDialog.open) closeGeneralSettings({ restoreFocus: false });
  if (elements.sourceManagerDialog.open) closeSourceManager({ restoreFocus: false });
  if (elements.storageDialog.open) closeStorageMaintenance({ restoreFocus: false });
  if (elements.trainingSetupDialog.open) elements.trainingSetupDialog.close();
  if (elements.tagSuggestionDialog.open) elements.tagSuggestionDialog.close();
  if (elements.worldMapLocationBackfillDialog.open) {
    closeWorldMapLocationBackfill({ restoreFocus: false });
  }
  if (elements.worldMapPlaceTagDialog.open) {
    closeWorldMapPlaceTags({ restoreFocus: false });
  }
  state.pendingConfirmAction = null;
  elements.reviewWorkspace.classList.add("hidden");
  elements.reviewWorkspace.inert = false;
  elements.trainingWorkspace.classList.add("hidden");
  elements.trainingWorkspace.inert = false;
  clearTimeout(state.worldMap.cameraTimer);
  state.worldMap.cameraTimer = null;
  elements.worldMapWorkspace.classList.add("hidden");
  elements.worldMapWorkspace.inert = false;
  elements.galleryOverviewWorkspace.classList.add("hidden");
  elements.galleryOverviewWorkspace.inert = false;
  elements.lightbox.classList.add("hidden");
  elements.lightbox.classList.remove("reviewing");
  elements.appView.inert = false;
  clearProtectedImageSource(elements.lightboxImage);
  stopLightboxVideo();
  elements.lightboxReviewActions.classList.add("hidden");
  state.lightboxContext = null;
  state.lightboxAssetID = null;
  state.reviewReturnFocus = null;
  state.trainingReturnFocus = null;
  state.training.setup.returnFocus = null;
  state.review.returnTarget = null;
  state.review.pendingFocusTrainingJobID = null;
  state.training.returnTarget = null;
  state.training.pendingReturnFocusRunID = null;
  state.jobsReturnFocus = null;
  state.jobsReturnTarget = null;
  state.generalSettings.returnFocus = null;
  state.generalSettings.thresholdReturnFocus = null;
  state.generalSettings.pendingDefaultFocus = null;
  state.generalSettings.pendingThresholdFocus = null;
  state.sourceManagerReturnFocus = null;
  state.storageReturnFocus = null;
  state.worldMapReturnFocus = null;
  state.galleryOverviewReturnFocus = null;
  state.lightboxReturnFocus = null;
}

function restoreOverlayFocus(target) {
  if (!(target instanceof HTMLElement) || !document.contains(target)) return;
  requestAnimationFrame(() => target.focus({ preventScroll: true }));
}

function stabilizeDismissedOverlayFocus(resolveTarget, dismissedContainer, isStillValid) {
  // Selection aggregates may finish after dragend and repaint the inspector.
  // Keep a bounded recovery window, but stop immediately when the user moves
  // focus anywhere other than the transiently removed/recreated tag chip.
  let remainingFrames = 120;
  let hasRestored = false;
  const restore = () => {
    if (!isStillValid()) return;
    const target = resolveTarget();
    if (!(target instanceof HTMLElement) || !document.contains(target)) {
      remainingFrames -= 1;
      if (remainingFrames > 0) requestAnimationFrame(restore);
      return;
    }
    const active = document.activeElement;
    if (hasRestored
      && active !== document.body
      && active !== document.documentElement
      && !dismissedContainer.contains(active)
      && active !== target) return;
    target.focus({ preventScroll: true });
    target.scrollIntoView({ block: "nearest" });
    hasRestored = true;
    remainingFrames -= 1;
    if (remainingFrames > 0) requestAnimationFrame(restore);
  };
  restore();
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
  if (elements.tagSuggestionDialog.open) closeTagSuggestionDialog();
  finishReviewMarqueeSelection();
  elements.reviewWorkspace.classList.add("hidden");
  elements.reviewWorkspace.inert = false;
  elements.appView.inert = false;
  const returnFocus = state.reviewReturnFocus;
  state.reviewReturnFocus = null;
  const returnTarget = state.review.returnTarget;
  state.review.returnTarget = null;
  state.review.pendingFocusTrainingJobID = null;
  syncReviewClosePresentation();
  if (returnTarget?.workspace === "training") {
    elements.trainingWorkspace.classList.remove("hidden");
    elements.appView.inert = true;
    if (state.training.runs.some((run) => run.id === returnTarget.runID)) {
      state.training.selectedRunID = returnTarget.runID;
    }
    state.training.pendingReturnFocusRunID = state.training.loading
      ? state.training.selectedRunID
      : null;
    renderTrainingWorkspace();
    stabilizeDismissedOverlayFocus(
      () => {
        const runID = state.training.selectedRunID;
        if (!runID) return null;
        return elements.trainingRunList.querySelector(
          `[data-training-run-id="${CSS.escape(runID)}"]`
        );
      },
      elements.reviewWorkspace,
      () => !elements.trainingWorkspace.classList.contains("hidden")
    );
    return;
  }
  restoreOverlayFocus(returnFocus);
}

function closeTrainingWorkspace() {
  if (elements.trainingSetupDialog.open) closeTrainingSetupDialog();
  elements.trainingWorkspace.classList.add("hidden");
  elements.trainingWorkspace.inert = false;
  elements.appView.inert = false;
  const returnFocus = state.trainingReturnFocus;
  state.trainingReturnFocus = null;
  const returnTarget = state.training.returnTarget;
  state.training.returnTarget = null;
  state.training.pendingReturnFocusRunID = null;
  syncTrainingClosePresentation();
  if (returnTarget?.workspace === "review") {
    elements.reviewWorkspace.classList.remove("hidden");
    elements.appView.inert = true;
    const returnMode = returnTarget.mode || "overview";
    if (state.review.mode !== returnMode) {
      state.review.mode = returnMode;
      renderReviewMode();
    }
    stabilizeDismissedOverlayFocus(
      () => {
        if (returnTarget.jobID) state.review.pendingFocusTrainingJobID = returnTarget.jobID;
        const trainingControl = returnTarget.jobID
          ? elements.reviewOverviewGrid.querySelector(
            `[data-review-training-job-id="${CSS.escape(returnTarget.jobID)}"]`
          )
          : null;
        const card = !trainingControl && returnTarget.tagID
          ? elements.reviewOverviewGrid.querySelector(
            `[data-review-overview-tag-id="${CSS.escape(returnTarget.tagID)}"]:not(:disabled)`
          )
          : null;
        const focusFallback = returnFocus instanceof HTMLElement && document.contains(returnFocus)
          ? returnFocus
          : elements.closeReviewButton;
        const target = trainingControl || card || focusFallback;
        if (trainingControl && !state.review.overviewLoading) {
          state.review.pendingFocusTrainingJobID = null;
        }
        return target;
      },
      elements.trainingWorkspace,
      () => !elements.reviewWorkspace.classList.contains("hidden")
    );
    return;
  }
  restoreOverlayFocus(returnFocus);
}

function syncReviewClosePresentation() {
  const returnsToTraining = state.review.returnTarget?.workspace === "training";
  elements.closeReviewButton.textContent = returnsToTraining ? "‹" : "×";
  const label = returnsToTraining ? "返回训练记录" : "关闭审核";
  elements.closeReviewButton.setAttribute("aria-label", label);
  elements.closeReviewButton.title = label;
}

function syncTrainingClosePresentation() {
  const returnsToReview = state.training.returnTarget?.workspace === "review";
  elements.closeTrainingButton.textContent = returnsToReview ? "‹" : "×";
  const label = returnsToReview ? "返回建议审核" : "关闭训练工程";
  elements.closeTrainingButton.setAttribute("aria-label", label);
  elements.closeTrainingButton.title = label;
}

function closeSlimmingWorkspace() {
  if (elements.slimmingIdenticalCleanupDialog.open) {
    closeSlimmingIdenticalCleanupDialog();
  }
  closeSlimmingVerificationReport();
  clearTimeout(state.slimming.recycle.pollTimer);
  clearTimeout(state.slimming.recycle.searchTimer);
  clearTimeout(state.slimming.removal.pollTimer);
  clearTimeout(state.slimming.identicalCleanup.pollTimer);
  state.slimming.recycle.pollTimer = null;
  state.slimming.recycle.searchTimer = null;
  state.slimming.removal.pollTimer = null;
  state.slimming.identicalCleanup.pollTimer = null;
  elements.slimmingWorkspace.classList.add("hidden");
  elements.slimmingWorkspace.inert = false;
  elements.appView.inert = false;
  const returnFocus = state.slimmingReturnFocus;
  state.slimmingReturnFocus = null;
  restoreOverlayFocus(returnFocus);
}

function galleryOverviewCount(value) {
  return Number(value || 0).toLocaleString("zh-CN");
}

function galleryOverviewTotal(item) {
  return Number(item?.imageCount || 0) + Number(item?.videoCount || 0);
}

function galleryOverviewEmpty(message) {
  const empty = document.createElement("p");
  empty.className = "gallery-overview-empty";
  empty.textContent = message;
  return empty;
}

function galleryOverviewMediaSummary(kind) {
  return state.galleryOverview.snapshot?.media?.find((item) => item.mediaKind === kind) || {
    mediaKind: kind,
    totalCount: 0,
    exactUniqueCount: 0,
    exactRedundantCount: 0,
    exactFingerprintCount: 0,
  };
}

function renderGalleryOverviewMediaCard(summary) {
  const kind = summary.mediaKind === "video" ? "video" : "image";
  const card = document.createElement("button");
  card.type = "button";
  card.className = "gallery-overview-media-card";
  card.dataset.galleryOverviewMediaKind = kind;
  card.style.setProperty("--media-tint", kind === "video" ? "#f07d30" : "#2e8cd1");

  const heading = document.createElement("div");
  heading.className = "gallery-overview-media-heading";
  const title = document.createElement("span");
  title.textContent = kind === "video" ? "▶ 视频" : "▧ 照片";
  const total = document.createElement("strong");
  total.textContent = galleryOverviewCount(summary.totalCount);
  heading.append(title, total);

  const facts = document.createElement("div");
  facts.className = "gallery-overview-media-facts";
  for (const [label, value] of [
    ["保守去重后", summary.exactUniqueCount],
    ["确认冗余", summary.exactRedundantCount],
  ]) {
    const fact = document.createElement("div");
    const factValue = document.createElement("strong");
    factValue.textContent = galleryOverviewCount(value);
    const factLabel = document.createElement("small");
    factLabel.textContent = label;
    fact.append(factValue, factLabel);
    facts.append(fact);
  }

  const coverageLabel = document.createElement("div");
  coverageLabel.className = "gallery-overview-coverage-label";
  const coverageTitle = document.createElement("span");
  coverageTitle.textContent = "精确摘要覆盖";
  const coverageValue = document.createElement("span");
  coverageValue.textContent = `${galleryOverviewCount(summary.exactFingerprintCount)} / ${galleryOverviewCount(summary.totalCount)}`;
  coverageLabel.append(coverageTitle, coverageValue);
  const progress = document.createElement("div");
  progress.className = "gallery-overview-progress";
  const fill = document.createElement("i");
  const coverage = summary.totalCount > 0
    ? Math.min(100, Math.max(0, summary.exactFingerprintCount / summary.totalCount * 100))
    : 0;
  fill.style.setProperty("--coverage", `${coverage}%`);
  progress.append(fill);
  card.append(heading, facts, coverageLabel, progress);
  return card;
}

function renderGalleryOverviewBars(container, items, kind) {
  clearElement(container);
  if (!items.length) {
    container.append(galleryOverviewEmpty(kind === "source" ? "暂无来源数据" : "还没有人工接受的标签"));
    return;
  }
  const maximum = Math.max(1, ...items.map(galleryOverviewTotal));
  for (const item of items) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "gallery-overview-bar-row";
    if (kind === "source") button.dataset.galleryOverviewSourceId = item.id;
    else button.dataset.galleryOverviewTagId = item.id;
    button.title = kind === "source" ? `打开来源：${item.displayName}` : `筛选标签：${item.displayName}`;

    const label = document.createElement("span");
    label.className = "gallery-overview-bar-label";
    label.textContent = item.displayName;
    const track = document.createElement("span");
    track.className = "gallery-overview-bar-track";
    const photo = document.createElement("i");
    photo.className = "photo";
    photo.style.setProperty("--photo-width", `${Math.max(0, Number(item.imageCount || 0)) / maximum * 100}%`);
    const video = document.createElement("i");
    video.className = "video";
    video.style.setProperty("--video-width", `${Math.max(0, Number(item.videoCount || 0)) / maximum * 100}%`);
    track.append(photo, video);
    const count = document.createElement("span");
    count.className = "gallery-overview-bar-count";
    count.textContent = galleryOverviewCount(galleryOverviewTotal(item));
    button.append(label, track, count);
    container.append(button);
  }
}

function galleryOverviewAvailabilityPresentation(availability) {
  return {
    available: ["可用", "#34a853"],
    missing: ["缺失", "#d94747"],
    unreadable: ["不可读", "#f07d30"],
    unsupported: ["不支持", "#8e8e93"],
  }[availability] || [availability || "未知", "#8e8e93"];
}

function renderGalleryOverviewAvailability(items, totalCount) {
  clearElement(elements.galleryOverviewAvailability);
  if (!items.length) {
    elements.galleryOverviewAvailability.append(galleryOverviewEmpty("暂无状态数据"));
    return;
  }
  let angle = 0;
  const stops = [];
  for (const item of items) {
    const share = totalCount > 0 ? galleryOverviewTotal(item) / totalCount * 100 : 0;
    const color = galleryOverviewAvailabilityPresentation(item.availability)[1];
    stops.push(`${color} ${angle}% ${Math.min(100, angle + share)}%`);
    angle += share;
  }
  if (angle < 100) stops.push(`var(--separator) ${angle}% 100%`);

  const donut = document.createElement("div");
  donut.className = "gallery-overview-donut";
  donut.style.setProperty("--donut", `conic-gradient(${stops.join(", ")})`);
  const donutLabel = document.createElement("span");
  donutLabel.className = "gallery-overview-donut-label";
  const total = document.createElement("strong");
  total.textContent = galleryOverviewCount(totalCount);
  const caption = document.createElement("span");
  caption.textContent = "当前媒体";
  donutLabel.append(total, caption);
  donut.append(donutLabel);

  const list = document.createElement("div");
  list.className = "gallery-overview-availability-list";
  for (const item of items) {
    const [title, color] = galleryOverviewAvailabilityPresentation(item.availability);
    const row = document.createElement("div");
    row.className = "gallery-overview-availability-row";
    row.style.setProperty("--status-color", color);
    const dot = document.createElement("i");
    const label = document.createElement("span");
    label.textContent = title;
    const count = document.createElement("strong");
    count.textContent = galleryOverviewCount(galleryOverviewTotal(item));
    row.append(dot, label, count);
    list.append(row);
  }
  elements.galleryOverviewAvailability.append(donut, list);
}

function renderGalleryOverviewTimeline(years) {
  clearElement(elements.galleryOverviewTimeline);
  if (!years.length) {
    elements.galleryOverviewTimeline.append(galleryOverviewEmpty("没有可用的媒体时间"));
    return;
  }
  const maximum = Math.max(1, ...years.map(galleryOverviewTotal));
  for (const item of years) {
    const year = document.createElement("div");
    year.className = "gallery-overview-year";
    year.title = `${item.year}：${galleryOverviewCount(item.imageCount)} 张照片，${galleryOverviewCount(item.videoCount)} 个视频`;
    const bars = document.createElement("div");
    bars.className = "gallery-overview-year-bars";
    const photo = document.createElement("i");
    photo.className = "photo";
    photo.style.setProperty("--photo-height", `${Math.max(2, Number(item.imageCount || 0) / maximum * 100)}%`);
    const video = document.createElement("i");
    video.className = "video";
    video.style.setProperty("--video-height", `${Math.max(2, Number(item.videoCount || 0) / maximum * 100)}%`);
    bars.append(photo, video);
    const label = document.createElement("span");
    label.textContent = String(item.year);
    year.append(bars, label);
    elements.galleryOverviewTimeline.append(year);
  }
}

function renderGalleryOverview() {
  const overview = state.galleryOverview;
  const snapshot = overview.snapshot;
  elements.galleryOverviewWorkspace.setAttribute("aria-busy", String(overview.loading));
  elements.refreshGalleryOverviewButton.disabled = overview.loading;
  elements.galleryOverviewNavigationButton.classList.toggle(
    "selected",
    !elements.galleryOverviewWorkspace.classList.contains("hidden")
  );
  elements.galleryOverviewStatus.classList.toggle("hidden", Boolean(snapshot));
  elements.galleryOverviewBody.classList.toggle("hidden", !snapshot);
  elements.retryGalleryOverviewButton.classList.toggle("hidden", !overview.error);
  elements.galleryOverviewStatus.dataset.state = overview.error ? "error" : "loading";
  elements.galleryOverviewStatus.querySelector("strong").textContent = overview.error
    ? "无法读取图库统计"
    : "正在汇总图库…";
  elements.galleryOverviewStatus.querySelector("span").textContent = overview.error
    ? "目录库没有被修改。请稍后重试。"
    : "只读取 ImageAll 目录库，不访问原照片。";
  if (!snapshot) return;

  const totalCount = (snapshot.media || []).reduce((sum, item) => sum + Number(item.totalCount || 0), 0);
  const exactUniqueCount = (snapshot.media || []).reduce((sum, item) => sum + Number(item.exactUniqueCount || 0), 0);
  const exactRedundantCount = (snapshot.media || []).reduce((sum, item) => sum + Number(item.exactRedundantCount || 0), 0);
  const exactFingerprintCount = (snapshot.media || []).reduce((sum, item) => sum + Number(item.exactFingerprintCount || 0), 0);
  elements.galleryOverviewNavigationCount.textContent = galleryOverviewCount(totalCount);
  elements.galleryOverviewSummary.textContent = `${galleryOverviewCount(totalCount)} 个媒体 · 保守去重后 ${galleryOverviewCount(exactUniqueCount)}`;
  elements.galleryOverviewRefreshedAt.textContent = overview.refreshedAt
    ? `更新于 ${overview.refreshedAt.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })}`
    : "";
  elements.galleryOverviewTotalMetric.textContent = galleryOverviewCount(totalCount);
  elements.galleryOverviewUniqueMetric.textContent = galleryOverviewCount(exactUniqueCount);
  elements.galleryOverviewRedundantMetric.textContent = galleryOverviewCount(exactRedundantCount);
  elements.galleryOverviewPositiveMetric.textContent = galleryOverviewCount(snapshot.positiveLabeledAssetCount);
  elements.galleryOverviewAcceptedMetric.textContent = `${galleryOverviewCount(snapshot.acceptedDecisionCount)} 条人工接受标签`;

  clearElement(elements.galleryOverviewMediaLedger);
  elements.galleryOverviewMediaLedger.append(
    renderGalleryOverviewMediaCard(galleryOverviewMediaSummary("image")),
    renderGalleryOverviewMediaCard(galleryOverviewMediaSummary("video"))
  );
  const displayedSources = (snapshot.sources || []).slice(0, 8);
  elements.galleryOverviewSourceSubtitle.textContent = (snapshot.sources || []).length > displayedSources.length
    ? `按媒体数最多的前 ${displayedSources.length} 个来源`
    : "每个来源中的照片与视频";
  renderGalleryOverviewBars(elements.galleryOverviewSources, displayedSources, "source");
  renderGalleryOverviewAvailability(snapshot.availability || [], totalCount);
  renderGalleryOverviewBars(elements.galleryOverviewTags, snapshot.positiveTags || [], "tag");
  const years = (snapshot.years || []).slice(-16);
  elements.galleryOverviewTimelineSubtitle.textContent = (snapshot.years || []).length > years.length
    ? `最近 ${years.length} 个有媒体记录的年份`
    : "按拍摄时间优先、修改时间补充";
  renderGalleryOverviewTimeline(years);
  elements.galleryOverviewUndated.textContent = snapshot.undatedCount > 0
    ? `另有 ${galleryOverviewCount(snapshot.undatedCount)} 个无日期媒体`
    : "";
  elements.galleryOverviewCoverage.textContent = `当前精确摘要覆盖 ${galleryOverviewCount(exactFingerprintCount)} / ${galleryOverviewCount(totalCount)}。刷新只读取 ImageAll 目录库，不访问原照片。`;
}

async function loadGalleryOverview({ quiet = false, throwOnError = false } = {}) {
  if (state.galleryOverview.loading) return;
  const generation = ++state.galleryOverview.requestGeneration;
  state.galleryOverview.loading = true;
  state.galleryOverview.error = "";
  renderGalleryOverview();
  try {
    const snapshot = await api("/v1/gallery-overview");
    if (generation !== state.galleryOverview.requestGeneration) return;
    state.galleryOverview.snapshot = snapshot;
    state.galleryOverview.refreshedAt = new Date();
  } catch (error) {
    if (generation !== state.galleryOverview.requestGeneration) return;
    state.galleryOverview.error = error.message || "图库统计读取失败";
    if (!quiet && state.galleryOverview.snapshot) toast(state.galleryOverview.error);
    if (throwOnError) throw error;
  } finally {
    if (generation === state.galleryOverview.requestGeneration) {
      state.galleryOverview.loading = false;
      renderGalleryOverview();
    }
  }
}

async function openGalleryOverviewWorkspace() {
  if (elements.trainingSetupDialog.open) closeTrainingSetupDialog();
  elements.reviewWorkspace.classList.add("hidden");
  state.reviewReturnFocus = null;
  elements.trainingWorkspace.classList.add("hidden");
  state.trainingReturnFocus = null;
  elements.slimmingWorkspace.classList.add("hidden");
  state.slimmingReturnFocus = null;
  elements.worldMapWorkspace.classList.add("hidden");
  state.worldMapReturnFocus = null;
  closeJobsPopover({ restoreFocus: false });
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  if (elements.galleryOverviewWorkspace.classList.contains("hidden")) {
    state.galleryOverviewReturnFocus = document.activeElement;
  }
  elements.appView.inert = true;
  elements.galleryOverviewWorkspace.classList.remove("hidden");
  renderGalleryOverview();
  requestAnimationFrame(() => elements.closeGalleryOverviewButton.focus({ preventScroll: true }));
  if (!state.galleryOverview.snapshot) await loadGalleryOverview();
}

function closeGalleryOverviewWorkspace() {
  elements.galleryOverviewWorkspace.classList.add("hidden");
  elements.galleryOverviewWorkspace.inert = false;
  elements.appView.inert = false;
  renderGalleryOverview();
  const returnFocus = state.galleryOverviewReturnFocus;
  state.galleryOverviewReturnFocus = null;
  restoreOverlayFocus(returnFocus);
}

async function drillDownFromGalleryOverview({ mediaKind = null, sourceID = null, tagID = null }) {
  closeGalleryOverviewWorkspace();
  if (mediaKind && mediaKind !== state.mediaKind) await switchMediaKind(mediaKind);
  state.filters = emptyFilters();
  state.filters.mediaKind = state.mediaKind;
  state.filterDraft = null;
  syncFilterControlsFromState();
  renderTagNavigation();
  if (sourceID) {
    await selectSource(sourceID);
  } else {
    await selectSource("");
    if (tagID) await applyQuickTagFilter(tagID);
  }
}

function worldMapRenderer() {
  return elements.worldMapFrame.contentWindow?.ImageAllWorldMap || null;
}

function pushWorldMapClusters() {
  if (!state.worldMap.rendererReady || !state.worldMap.snapshot) return;
  worldMapRenderer()?.updateClusters({
    clusters: state.worldMap.snapshot.clusters || [],
  });
  worldMapRenderer()?.restoreSelection(state.worldMap.selectedClusterID);
}

function selectedWorldMapCluster() {
  return state.worldMap.snapshot?.clusters?.find(
    (cluster) => cluster.id === state.worldMap.selectedClusterID
  ) || null;
}

function worldMapCount(value) {
  return Number(value || 0).toLocaleString("zh-CN");
}

function renderWorldMapDetail() {
  const cluster = selectedWorldMapCluster();
  const selection = state.worldMap.selection;
  elements.worldMapDetail.classList.toggle("hidden", !cluster);
  clearElement(elements.worldMapPhotoStrip);
  if (!cluster) return;

  elements.worldMapDetailName.textContent = cluster.displayName || "未命名地点";
  elements.worldMapDetailComposition.textContent = [
    `GPS ${worldMapCount(cluster.gpsCount)}`,
    `地点标签 ${worldMapCount(cluster.tagCount)}`,
  ].join(" · ");
  elements.worldMapDetailCount.textContent = `${worldMapCount(cluster.photoCount)} 张照片`;

  if (state.worldMap.selectionLoading) {
    elements.worldMapSelectionSummary.textContent = "正在载入预览";
    const loading = document.createElement("div");
    loading.className = "world-map-photo-empty";
    loading.textContent = "正在读取这个地点的照片…";
    elements.worldMapPhotoStrip.append(loading);
    return;
  }

  const assets = selection?.assets || [];
  elements.worldMapSelectionSummary.textContent = assets.length < Number(selection?.totalPhotoCount || 0)
    ? `显示前 ${worldMapCount(assets.length)} 张`
    : `${worldMapCount(assets.length)} 张可预览`;
  if (!assets.length) {
    const empty = document.createElement("div");
    empty.className = "world-map-photo-empty";
    empty.textContent = "这个地点暂时没有可预览照片";
    elements.worldMapPhotoStrip.append(empty);
    return;
  }

  for (const asset of assets) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "world-map-photo-button";
    button.dataset.worldMapAssetId = asset.id;
    button.title = asset.fileName || "查看照片";
    button.setAttribute("aria-label", `查看 ${asset.fileName || "地点照片"}`);
    const image = document.createElement("img");
    image.alt = "";
    setProtectedImageSource(
      image,
      `/v1/assets/${encodeURIComponent(asset.id)}/thumbnail?w=180`,
      { priority: "high" }
    );
    const label = document.createElement("span");
    label.textContent = asset.fileName || "未命名照片";
    button.append(image, label);
    elements.worldMapPhotoStrip.append(button);
  }
}

function renderWorldMap() {
  const snapshot = state.worldMap.snapshot;
  const clusters = snapshot?.clusters || [];
  elements.worldMapClusterMetric.textContent = snapshot ? worldMapCount(clusters.length) : "—";
  elements.worldMapLocatedMetric.textContent = snapshot
    ? worldMapCount(snapshot.locatedPhotoCount)
    : "—";
  elements.worldMapUnlocatedMetric.textContent = snapshot
    ? worldMapCount(snapshot.unlocatedPhotoCount)
    : "—";
  elements.worldMapRendererMetric.textContent = state.worldMap.rendererError
    ? "不可用"
    : (state.worldMap.rendererReady ? "已就绪" : "连接中");
  elements.worldMapNavigationCount.textContent = snapshot
    ? worldMapCount(snapshot.locatedPhotoCount)
    : "";
  elements.worldMapSummary.textContent = snapshot
    ? `${worldMapCount(snapshot.locatedPhotoCount)} 张已定位 · ${worldMapCount(clusters.length)} 座照片塔`
    : "按地点探索照片";

  const showStatus = state.worldMap.loading || state.worldMap.rendererError
    || Boolean(state.worldMap.loadError)
    || (snapshot && !clusters.length);
  elements.worldMapStatus.classList.toggle("hidden", !showStatus);
  if (state.worldMap.rendererError) {
    elements.worldMapStatus.dataset.state = "error";
    elements.worldMapStatus.querySelector("strong").textContent = "地图引擎暂时不可用";
    elements.worldMapStatus.querySelector("span:last-child").textContent = "可刷新重试，照片目录没有受到影响";
  } else if (state.worldMap.loading) {
    delete elements.worldMapStatus.dataset.state;
    elements.worldMapStatus.querySelector("strong").textContent = "正在整理照片地图";
    elements.worldMapStatus.querySelector("span:last-child").textContent = "照片仍保留在这台 Mac";
  } else if (state.worldMap.loadError) {
    elements.worldMapStatus.dataset.state = "error";
    elements.worldMapStatus.querySelector("strong").textContent = "照片地图暂时无法读取";
    elements.worldMapStatus.querySelector("span:last-child").textContent = "请点击右上角刷新重试，照片目录没有受到影响";
  } else if (snapshot && !clusters.length) {
    delete elements.worldMapStatus.dataset.state;
    elements.worldMapStatus.querySelector("strong").textContent = "当前范围没有已定位照片";
    elements.worldMapStatus.querySelector("span:last-child").textContent = "缩小地图或回到全球视图后再试";
  }
  renderWorldMapDetail();
  pushWorldMapClusters();
}

function normalizedWorldMapBounds(viewport) {
  if (!viewport) return null;
  const values = [viewport.west, viewport.south, viewport.east, viewport.north];
  if (!values.every(Number.isFinite)) return null;
  const south = Math.max(-90, Math.min(90, viewport.south));
  const north = Math.max(-90, Math.min(90, viewport.north));
  if (south >= north) return null;
  return {
    west: viewport.west,
    south,
    east: viewport.east,
    north,
  };
}

async function loadWorldMapSnapshot({ bounds = null, quiet = false } = {}) {
  const generation = ++state.worldMap.requestGeneration;
  state.worldMap.loading = !quiet;
  if (!quiet) state.worldMap.loadError = "";
  if (!quiet) renderWorldMap();
  const query = new URLSearchParams({ maximumClusters: "2000" });
  const normalizedBounds = normalizedWorldMapBounds(bounds);
  if (normalizedBounds) {
    for (const [key, value] of Object.entries(normalizedBounds)) {
      query.set(key, String(value));
    }
  }
  try {
    const snapshot = await api(`/v1/world-map/snapshot?${query}`);
    if (generation !== state.worldMap.requestGeneration) return;
    state.worldMap.snapshot = snapshot;
    state.worldMap.loadError = "";
    if (state.worldMap.selectedClusterID
      && !(snapshot.clusters || []).some(
        (cluster) => cluster.id === state.worldMap.selectedClusterID
      )) {
      state.worldMap.selectedClusterID = null;
      state.worldMap.selection = null;
    }
  } catch (error) {
    if (generation !== state.worldMap.requestGeneration) return;
    if (!quiet || !state.worldMap.snapshot) {
      state.worldMap.snapshot = null;
      state.worldMap.loadError = error.message || "世界地图载入失败";
      toast(error.message || "世界地图载入失败");
    }
  } finally {
    if (generation === state.worldMap.requestGeneration) {
      state.worldMap.loading = false;
      renderWorldMap();
    }
  }
}

async function loadWorldMapSelection(clusterID) {
  const cluster = state.worldMap.snapshot?.clusters?.find((item) => item.id === clusterID);
  if (!cluster) return;
  const generation = ++state.worldMap.selectionGeneration;
  state.worldMap.selectedClusterID = clusterID;
  state.worldMap.selection = null;
  state.worldMap.selectionLoading = true;
  worldMapRenderer()?.restoreSelection(clusterID);
  renderWorldMapDetail();
  try {
    const selection = await api("/v1/world-map/selection", {
      method: "POST",
      body: JSON.stringify({ query: cluster.selectionQuery }),
    });
    if (generation !== state.worldMap.selectionGeneration
      || state.worldMap.selectedClusterID !== clusterID) return;
    state.worldMap.selection = selection;
  } catch (error) {
    if (generation === state.worldMap.selectionGeneration) {
      toast(error.message || "地点照片载入失败");
    }
  } finally {
    if (generation === state.worldMap.selectionGeneration) {
      state.worldMap.selectionLoading = false;
      renderWorldMapDetail();
    }
  }
}

async function openWorldMapWorkspace() {
  if (elements.trainingSetupDialog.open) closeTrainingSetupDialog();
  elements.reviewWorkspace.classList.add("hidden");
  state.reviewReturnFocus = null;
  elements.trainingWorkspace.classList.add("hidden");
  state.trainingReturnFocus = null;
  elements.slimmingWorkspace.classList.add("hidden");
  state.slimmingReturnFocus = null;
  closeJobsPopover({ restoreFocus: false });
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  if (elements.worldMapWorkspace.classList.contains("hidden")) {
    state.worldMapReturnFocus = document.activeElement;
  }
  elements.appView.inert = true;
  elements.worldMapWorkspace.classList.remove("hidden");
  renderWorldMap();
  requestAnimationFrame(() => elements.closeWorldMapButton.focus({ preventScroll: true }));
  if (!state.worldMap.snapshot) await loadWorldMapSnapshot();
  else pushWorldMapClusters();
}

function closeWorldMapWorkspace() {
  if (elements.worldMapLocationBackfillDialog.open) {
    closeWorldMapLocationBackfill({ restoreFocus: false });
  }
  if (elements.worldMapPlaceTagDialog.open) {
    closeWorldMapPlaceTags({ restoreFocus: false });
  }
  clearTimeout(state.worldMap.cameraTimer);
  state.worldMap.cameraTimer = null;
  elements.worldMapWorkspace.classList.add("hidden");
  elements.worldMapWorkspace.inert = false;
  elements.appView.inert = false;
  const returnFocus = state.worldMapReturnFocus;
  state.worldMapReturnFocus = null;
  restoreOverlayFocus(returnFocus);
}

function clearWorldMapSelection() {
  ++state.worldMap.selectionGeneration;
  state.worldMap.selectedClusterID = null;
  state.worldMap.selection = null;
  state.worldMap.selectionLoading = false;
  worldMapRenderer()?.restoreSelection(null);
  renderWorldMapDetail();
}

function worldMapLocationPhasePresentation(phase) {
  return {
    ready: ["待检查", "default"],
    queued: ["等待中", "warning"],
    running: ["检查中", "default"],
    cancelling: ["取消中", "warning"],
    retryableFailed: ["可重试", "warning"],
    completed: ["已完成", "success"],
    cancelled: ["已取消", "muted"],
    terminalFailed: ["检查失败", "error"],
    unavailable: ["来源不可用", "muted"],
  }[phase] || ["待检查", "default"];
}

function appendWorldMapLocationMetric(parent, value, label) {
  const metric = document.createElement("span");
  metric.className = "world-map-location-metric";
  const count = document.createElement("strong");
  count.textContent = value;
  const caption = document.createElement("span");
  caption.textContent = label;
  metric.append(count, caption);
  parent.append(metric);
}

function renderWorldMapLocationBackfill() {
  const backfill = state.worldMap.locationBackfill;
  elements.worldMapLocationBackfillLoading.classList.toggle("hidden", !backfill.loading);
  elements.worldMapLocationBackfillError.classList.toggle("hidden", !backfill.error);
  elements.worldMapLocationBackfillError.textContent = backfill.error;
  const showEmpty = !backfill.loading && !backfill.error && backfill.snapshots.length === 0;
  elements.worldMapLocationBackfillEmpty.classList.toggle("hidden", !showEmpty);
  clearElement(elements.worldMapLocationBackfillSources);
  if (backfill.loading && backfill.snapshots.length === 0) return;

  for (const snapshot of backfill.snapshots) {
    const card = document.createElement("article");
    card.className = "world-map-location-source-card";
    card.dataset.kind = snapshot.sourceKind;
    card.dataset.phase = snapshot.phase;
    card.dataset.sourceId = snapshot.sourceID;

    const heading = document.createElement("div");
    heading.className = "world-map-location-source-heading";
    const icon = document.createElement("span");
    icon.className = "world-map-location-source-icon";
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = snapshot.sourceKind === "photos" ? "▧" : "▰";
    const title = document.createElement("span");
    title.className = "world-map-location-source-title";
    const name = document.createElement("strong");
    name.textContent = snapshot.sourceDisplayName;
    const kind = document.createElement("span");
    kind.textContent = snapshot.sourceKind === "photos" ? "APPLE PHOTOS" : "文件夹来源";
    title.append(name, kind);
    const [phaseLabel, phaseTone] = worldMapLocationPhasePresentation(snapshot.phase);
    const phase = document.createElement("span");
    phase.className = "world-map-location-phase";
    phase.dataset.tone = phaseTone;
    phase.textContent = phaseLabel;
    heading.append(icon, title, phase);

    const progress = document.createElement("div");
    progress.className = "world-map-location-progress";
    progress.setAttribute("role", "progressbar");
    progress.setAttribute("aria-label", `${snapshot.sourceDisplayName} 位置检查进度`);
    const total = Math.max(0, Number(snapshot.totalPhotoCount || 0));
    const inspected = Math.max(0, Number(snapshot.inspectedPhotoCount || 0));
    const fraction = total === 0 ? 1 : Math.min(1, inspected / total);
    progress.setAttribute("aria-valuemin", "0");
    progress.setAttribute("aria-valuemax", String(total));
    progress.setAttribute("aria-valuenow", String(Math.min(inspected, total)));
    const progressFill = document.createElement("span");
    progressFill.style.setProperty("--location-progress", `${Math.round(fraction * 100)}%`);
    progress.append(progressFill);

    const footer = document.createElement("div");
    footer.className = "world-map-location-source-footer";
    const metrics = document.createElement("span");
    metrics.className = "world-map-location-metrics";
    appendWorldMapLocationMetric(
      metrics,
      `${worldMapCount(inspected)} / ${worldMapCount(total)}`,
      "已检查"
    );
    appendWorldMapLocationMetric(metrics, worldMapCount(snapshot.locatedPhotoCount), "已定位");
    appendWorldMapLocationMetric(
      metrics,
      worldMapCount(Math.max(0, inspected - Number(snapshot.locatedPhotoCount || 0))),
      "无坐标"
    );
    footer.append(metrics);

    const busy = backfill.busySourceIDs.has(snapshot.sourceID);
    if (snapshot.canCancel) {
      const button = document.createElement("button");
      button.className = "button world-map-location-source-action";
      button.type = "button";
      button.dataset.locationBackfillAction = "cancel";
      button.dataset.sourceId = snapshot.sourceID;
      button.disabled = busy;
      button.textContent = busy ? "正在提交…" : "取消";
      footer.append(button);
    } else if (snapshot.canStart) {
      const button = document.createElement("button");
      button.className = "button button-primary world-map-location-source-action";
      button.type = "button";
      button.dataset.locationBackfillAction = "start";
      button.dataset.sourceId = snapshot.sourceID;
      button.disabled = busy;
      const retry = ["retryableFailed", "cancelled", "terminalFailed"].includes(snapshot.phase);
      button.textContent = busy ? "正在提交…" : (retry ? "重试" : "开始检查");
      footer.append(button);
    } else {
      const status = document.createElement("span");
      status.className = "world-map-location-scan-progress world-map-location-source-action";
      if (snapshot.phase === "cancelling") status.textContent = "正在取消…";
      else if (snapshot.phase === "completed") status.textContent = "✓ 目录已更新";
      else if (snapshot.phase === "unavailable") status.textContent = "请先恢复来源访问";
      footer.append(status);
    }

    const scan = document.createElement("div");
    scan.className = "world-map-location-scan-progress";
    if (snapshot.scanProgress) {
      const completed = worldMapCount(snapshot.scanProgress.completedUnitCount);
      scan.textContent = snapshot.scanProgress.totalUnitCount == null
        ? `来源扫描已处理 ${completed} 项`
        : `来源扫描 ${completed} / ${worldMapCount(snapshot.scanProgress.totalUnitCount)}`;
    }
    card.append(heading, progress, footer, scan);
    elements.worldMapLocationBackfillSources.append(card);
  }
}

function scheduleWorldMapLocationBackfillPoll() {
  const backfill = state.worldMap.locationBackfill;
  clearTimeout(backfill.pollTimer);
  backfill.pollTimer = null;
  if (!elements.worldMapLocationBackfillDialog.open) return;
  backfill.pollTimer = setTimeout(() => {
    void loadWorldMapLocationBackfill({ quiet: true });
  }, 1_500);
}

async function loadWorldMapLocationBackfill({ quiet = false } = {}) {
  const backfill = state.worldMap.locationBackfill;
  const generation = ++backfill.requestGeneration;
  if (!quiet) backfill.loading = true;
  backfill.error = "";
  renderWorldMapLocationBackfill();
  try {
    const snapshots = await api("/v1/world-map/location-backfill");
    if (generation !== backfill.requestGeneration) return;
    backfill.snapshots = Array.isArray(snapshots) ? snapshots : [];
  } catch (error) {
    if (generation !== backfill.requestGeneration) return;
    backfill.error = error.message || "位置目录状态读取失败，请稍后重试。";
  } finally {
    if (generation === backfill.requestGeneration) {
      backfill.loading = false;
      renderWorldMapLocationBackfill();
      scheduleWorldMapLocationBackfillPoll();
    }
  }
}

async function submitWorldMapLocationBackfill(sourceID, action) {
  const backfill = state.worldMap.locationBackfill;
  if (!sourceID || backfill.busySourceIDs.has(sourceID)) return;
  const operationKey = `${action}:${sourceID}`;
  const operationID = backfill.operationIDs.get(operationKey) || crypto.randomUUID();
  backfill.operationIDs.set(operationKey, operationID);
  backfill.busySourceIDs.add(sourceID);
  backfill.error = "";
  renderWorldMapLocationBackfill();
  try {
    const response = await api("/v1/world-map/location-backfill/requests", {
      method: "POST",
      body: JSON.stringify({ operationID, sourceID, action }),
    });
    backfill.operationIDs.delete(operationKey);
    const index = backfill.snapshots.findIndex((item) => item.sourceID === sourceID);
    if (index >= 0 && response.snapshot) backfill.snapshots[index] = response.snapshot;
    if (action === "cancel") toast("已提交取消请求");
  } catch (error) {
    backfill.error = error.message || "位置目录操作提交失败，请稍后重试。";
  } finally {
    backfill.busySourceIDs.delete(sourceID);
    renderWorldMapLocationBackfill();
    scheduleWorldMapLocationBackfillPoll();
  }
}

function openWorldMapLocationBackfill() {
  const backfill = state.worldMap.locationBackfill;
  if (!elements.worldMapLocationBackfillDialog.open) {
    backfill.returnFocus = document.activeElement;
    elements.worldMapLocationBackfillDialog.showModal();
  }
  renderWorldMapLocationBackfill();
  requestAnimationFrame(() => {
    elements.closeWorldMapLocationBackfillButton.focus({ preventScroll: true });
  });
  void loadWorldMapLocationBackfill();
}

function closeWorldMapLocationBackfill({ restoreFocus = true } = {}) {
  const backfill = state.worldMap.locationBackfill;
  clearTimeout(backfill.pollTimer);
  backfill.pollTimer = null;
  ++backfill.requestGeneration;
  if (elements.worldMapLocationBackfillDialog.open) {
    elements.worldMapLocationBackfillDialog.close();
  }
  const returnFocus = backfill.returnFocus;
  backfill.returnFocus = null;
  if (restoreFocus) restoreOverlayFocus(returnFocus);
}

function worldMapPlaceStatusPresentation(status) {
  return {
    unresolved: ["未识别", "muted"],
    resolved: ["已确认", "success"],
    ambiguous: ["待选择", "warning"],
    ignored: ["已忽略", "muted"],
    failed: ["未找到", "error"],
  }[status] || ["未识别", "muted"];
}

function normalizedWorldMapPlaceQuery(item) {
  const value = state.worldMap.placeTags.queryByTagID.get(item.tagID) ?? item.tagName ?? "";
  return value.trim().split(/\s+/u).filter(Boolean).join(" ");
}

function worldMapPlaceQueryHint(item) {
  const placeTags = state.worldMap.placeTags;
  const query = normalizedWorldMapPlaceQuery(item);
  if (!query) return ["请输入至少一个地点线索。", true];
  if (query.length > placeTags.maximumQueryLength) {
    return [`地点描述请控制在 ${placeTags.maximumQueryLength} 个字符以内。`, true];
  }
  return [`将在全球范围搜索；本次只会发送：${query}`, false];
}

function worldMapPlaceProvenance(item) {
  const placeTags = state.worldMap.placeTags;
  const query = normalizedWorldMapPlaceQuery(item);
  if (placeTags.busyTagIDs.has(item.tagID)) {
    const activeQuery = placeTags.activeQueryByTagID.get(item.tagID) || query;
    return query === activeQuery
      ? [`正在用“${activeQuery}”搜索；下方旧结果会在完成后替换。`, "busy"]
      : [`正在用“${activeQuery}”搜索；你可以继续编辑，完成后再搜索“${query}”。`, "busy"];
  }
  const submitted = placeTags.submittedQueryByTagID.get(item.tagID);
  if (submitted) {
    return submitted === query
      ? [`下方结果已用“${submitted}”刷新。`, "success"]
      : [`输入已改为“${query}”；下方仍是“${submitted}”的结果，请点击重新搜索。`, "warning"];
  }
  if (item.candidates?.length) {
    return ["下方是本地缓存结果；修改描述后需点击重新搜索才会替换。", "muted"];
  }
  return ["", "muted"];
}

function updateWorldMapPlaceQueryState(tagID) {
  const placeTags = state.worldMap.placeTags;
  const item = placeTags.items.find((candidate) => candidate.tagID === tagID);
  const card = [...elements.worldMapPlaceTagItems.querySelectorAll("[data-place-tag-card]")]
    .find((candidate) => candidate.dataset.placeTagCard === tagID);
  if (!item || !card) return;
  const [hintText, hintIsError] = worldMapPlaceQueryHint(item);
  const hint = card.querySelector("[data-place-tag-hint]");
  hint.textContent = hintText;
  hint.dataset.tone = hintIsError ? "error" : "muted";
  const query = normalizedWorldMapPlaceQuery(item);
  const searchButton = card.querySelector("[data-place-tag-action=search]");
  if (searchButton) {
    searchButton.disabled = hintIsError || placeTags.busyTagIDs.has(tagID);
  }
  const [provenanceText, provenanceTone] = worldMapPlaceProvenance(item);
  const provenance = card.querySelector("[data-place-tag-provenance]");
  provenance.textContent = provenanceText;
  provenance.dataset.tone = provenanceTone;
  provenance.classList.toggle("hidden", !provenanceText);
  const input = card.querySelector("[data-place-tag-query]");
  if (input) input.setAttribute("aria-invalid", hintIsError ? "true" : "false");
  card.dataset.query = query;
}

function worldMapPlaceCandidateRow(item, candidate, { interactive = true } = {}) {
  const row = document.createElement(interactive ? "button" : "div");
  row.className = "world-map-place-candidate";
  const candidateDetail = candidate.subtitle
    || `${Number(candidate.latitude).toFixed(3)}°, ${Number(candidate.longitude).toFixed(3)}°`;
  if (interactive) {
    row.type = "button";
    row.dataset.placeTagAction = "confirm";
    row.dataset.tagId = item.tagID;
    row.dataset.placeId = candidate.placeID;
    row.disabled = state.worldMap.placeTags.busyTagIDs.has(item.tagID);
    row.setAttribute("aria-label", `确认地点：${candidate.displayName}，${candidateDetail}`);
    row.setAttribute("aria-keyshortcuts", "ArrowUp ArrowDown Home End");
  }
  const mark = document.createElement("span");
  mark.className = "world-map-place-candidate-mark";
  mark.setAttribute("aria-hidden", "true");
  mark.textContent = candidate.kind === "poi" ? "●" : "▦";
  const copy = document.createElement("span");
  copy.className = "world-map-place-candidate-copy";
  const name = document.createElement("strong");
  name.textContent = candidate.displayName;
  const detail = document.createElement("span");
  detail.textContent = candidateDetail;
  copy.append(name, detail);
  const affordance = document.createElement("span");
  affordance.className = "world-map-place-candidate-affordance";
  affordance.setAttribute("aria-hidden", "true");
  affordance.textContent = interactive ? "→" : "✓";
  row.append(mark, copy, affordance);
  return row;
}

function captureWorldMapPlaceFocus() {
  if (!elements.worldMapPlaceTagDialog.open) return null;
  const active = document.activeElement;
  if (!(active instanceof HTMLElement) || !elements.worldMapPlaceTagItems.contains(active)) {
    return null;
  }
  const query = active.closest("[data-place-tag-query]");
  const viewportOffset = active.getBoundingClientRect().top
    - elements.worldMapPlaceTagBody.getBoundingClientRect().top;
  if (query) {
    return {
      kind: "query",
      tagID: query.dataset.placeTagQuery,
      selectionStart: query.selectionStart,
      selectionEnd: query.selectionEnd,
      viewportOffset,
    };
  }
  const candidate = active.closest("[data-place-tag-action=confirm]");
  if (candidate) {
    return {
      kind: "candidate",
      tagID: candidate.dataset.tagId,
      placeID: candidate.dataset.placeId,
      viewportOffset,
    };
  }
  const search = active.closest("[data-place-tag-action=search]");
  return search ? {
    kind: "search",
    tagID: search.dataset.tagId,
    viewportOffset,
  } : null;
}

function restoreWorldMapPlaceFocus(snapshot, preservedScrollTop) {
  if (!snapshot || !elements.worldMapPlaceTagDialog.open) return;
  let target = null;
  if (snapshot.kind === "query") {
    target = elements.worldMapPlaceTagItems.querySelector(
      `[data-place-tag-query="${CSS.escape(snapshot.tagID)}"]`
    );
  } else if (snapshot.kind === "candidate") {
    target = elements.worldMapPlaceTagItems.querySelector(
      `[data-place-tag-action="confirm"][data-tag-id="${CSS.escape(snapshot.tagID)}"]`
      + `[data-place-id="${CSS.escape(snapshot.placeID)}"]`
    );
  } else if (snapshot.kind === "search") {
    target = elements.worldMapPlaceTagItems.querySelector(
      `[data-place-tag-action="search"][data-tag-id="${CSS.escape(snapshot.tagID)}"]`
    );
  }
  if (!(target instanceof HTMLElement) || target.matches(":disabled")) return;
  let remainingFrames = 2;
  const restore = () => {
    if (!target.isConnected || !elements.worldMapPlaceTagDialog.open) return;
    if (Number.isFinite(snapshot.viewportOffset)) {
      const currentOffset = target.getBoundingClientRect().top
        - elements.worldMapPlaceTagBody.getBoundingClientRect().top;
      elements.worldMapPlaceTagBody.scrollTop += currentOffset - snapshot.viewportOffset;
    } else {
      elements.worldMapPlaceTagBody.scrollTop = preservedScrollTop;
    }
    target.focus({ preventScroll: true });
    if (snapshot.kind === "query" && typeof target.setSelectionRange === "function") {
      const end = target.value.length;
      target.setSelectionRange(
        Math.min(snapshot.selectionStart ?? end, end),
        Math.min(snapshot.selectionEnd ?? end, end)
      );
    }
    remainingFrames -= 1;
    if (remainingFrames > 0) requestAnimationFrame(restore);
  };
  restore();
}

function renderWorldMapPlaceTags({ focusTagID = null } = {}) {
  const placeTags = state.worldMap.placeTags;
  const preservedScrollTop = elements.worldMapPlaceTagBody.scrollTop;
  const preservedFocus = captureWorldMapPlaceFocus();
  const showBlockingLoading = placeTags.loading && placeTags.items.length === 0;
  elements.worldMapPlaceTagBody.setAttribute("aria-busy", placeTags.loading ? "true" : "false");
  elements.worldMapPlaceTagLoading.classList.toggle("hidden", !showBlockingLoading);
  elements.worldMapPlaceTagError.classList.toggle("hidden", !placeTags.error);
  elements.worldMapPlaceTagError.textContent = placeTags.error;
  const showEmpty = !placeTags.loading && !placeTags.error && placeTags.items.length === 0;
  elements.worldMapPlaceTagEmpty.classList.toggle("hidden", !showEmpty);
  clearElement(elements.worldMapPlaceTagItems);
  if (showBlockingLoading) return;

  for (const item of placeTags.items) {
    const busy = placeTags.busyTagIDs.has(item.tagID);
    const card = document.createElement("article");
    card.className = "world-map-place-card";
    card.dataset.placeTagCard = item.tagID;
    card.dataset.status = item.status;
    card.setAttribute("aria-busy", busy ? "true" : "false");

    const heading = document.createElement("header");
    const title = document.createElement("span");
    title.className = "world-map-place-card-title";
    const name = document.createElement("strong");
    name.textContent = item.tagName;
    const group = document.createElement("span");
    group.textContent = item.groupName;
    title.append(name, group);
    const count = document.createElement("span");
    count.className = "world-map-place-photo-count";
    count.textContent = `${worldMapCount(item.acceptedPhotoCount)} 张`;
    const [statusLabel, statusTone] = worldMapPlaceStatusPresentation(item.status);
    const status = document.createElement("span");
    status.className = "world-map-place-status";
    status.dataset.tone = statusTone;
    status.textContent = statusLabel;
    heading.append(title, count, status);

    const editor = document.createElement("form");
    editor.className = "world-map-place-editor";
    editor.dataset.placeTagForm = item.tagID;
    const editorLabel = document.createElement("label");
    editorLabel.htmlFor = `worldMapPlaceQuery-${item.tagID}`;
    editorLabel.innerHTML = "<strong>地点描述</strong><span>全球搜索 · 可补充城市 · 州/省 · 国家 · 景区</span>";
    const field = document.createElement("div");
    field.className = "world-map-place-field";
    const input = document.createElement("input");
    input.id = `worldMapPlaceQuery-${item.tagID}`;
    input.type = "search";
    input.autocomplete = "off";
    input.spellcheck = false;
    input.dataset.placeTagQuery = item.tagID;
    input.placeholder = "例如：大皇宫 曼谷 泰国 / Central Park New York USA";
    input.value = placeTags.queryByTagID.get(item.tagID) ?? item.tagName;
    const searchButton = document.createElement("button");
    searchButton.className = "button button-primary";
    searchButton.type = "submit";
    searchButton.dataset.placeTagAction = "search";
    searchButton.dataset.tagId = item.tagID;
    searchButton.textContent = busy ? "正在搜索…" : (item.status === "unresolved" ? "搜索" : "重新搜索");
    field.append(input, searchButton);
    const hint = document.createElement("span");
    hint.className = "world-map-place-query-hint";
    hint.dataset.placeTagHint = item.tagID;
    const provenance = document.createElement("span");
    provenance.className = "world-map-place-provenance hidden";
    provenance.dataset.placeTagProvenance = item.tagID;
    editor.append(editorLabel, field, hint, provenance);

    const result = document.createElement("section");
    result.className = "world-map-place-result";
    if (item.status === "ambiguous") {
      result.setAttribute("role", "group");
      result.setAttribute("aria-label", `${item.tagName}的地点候选`);
      const copy = document.createElement("p");
      copy.textContent = "找到多个可能地点；如果都不对，请修改描述后重新搜索：";
      result.append(copy);
      for (const candidate of item.candidates || []) {
        result.append(worldMapPlaceCandidateRow(item, candidate));
      }
    } else if (item.status === "resolved") {
      const candidate = (item.candidates || []).find(
        (value) => value.placeID === item.confirmedPlaceID
      );
      if (candidate) result.append(worldMapPlaceCandidateRow(item, candidate, { interactive: false }));
      const copy = document.createElement("p");
      copy.textContent = candidate
        ? "地点不对？补充更多信息后重新搜索，新结果会替换当前地点。"
        : "地点已经确认并写入地图目录。";
      result.append(copy);
    } else {
      const copy = document.createElement("p");
      if (item.status === "failed") {
        copy.textContent = "没有找到合适地点。补充更具体的信息后可以立即重新搜索。";
      } else if (item.status === "ignored") {
        copy.textContent = "这个标签已标记为非地点；输入地点信息后可重新启用定位。";
      } else {
        copy.textContent = "标签名已作为初始线索填入；也可以补充城市、省份、国家或景区名称。";
      }
      result.append(copy);
    }

    card.append(heading, editor, result);
    elements.worldMapPlaceTagItems.append(card);
    updateWorldMapPlaceQueryState(item.tagID);
  }

  elements.worldMapPlaceTagBody.scrollTop = preservedScrollTop;

  const focusSnapshot = focusTagID
    ? (preservedFocus?.tagID === focusTagID && preservedFocus.kind === "query"
      ? { ...preservedFocus, kind: "query", tagID: focusTagID }
      : { kind: "query", tagID: focusTagID })
    : preservedFocus;
  if (focusSnapshot && elements.worldMapPlaceTagDialog.open) {
    requestAnimationFrame(() => restoreWorldMapPlaceFocus(focusSnapshot, preservedScrollTop));
  }
}

function replaceWorldMapPlaceTagResolution(resolution) {
  const items = state.worldMap.placeTags.items;
  const index = items.findIndex((item) => item.tagID === resolution.tagID);
  if (index >= 0) items[index] = resolution;
}

async function loadWorldMapPlaceTags() {
  const placeTags = state.worldMap.placeTags;
  const generation = ++placeTags.requestGeneration;
  const mutationGeneration = placeTags.mutationGeneration;
  placeTags.loading = true;
  placeTags.error = "";
  renderWorldMapPlaceTags();
  try {
    const snapshot = await api("/v1/world-map/place-tags");
    if (generation !== placeTags.requestGeneration) return;
    if (mutationGeneration === placeTags.mutationGeneration) {
      placeTags.items = Array.isArray(snapshot.items) ? snapshot.items : [];
      placeTags.maximumQueryLength = Number(snapshot.maximumQueryLength) || 160;
      for (const item of placeTags.items) {
        if (!placeTags.queryByTagID.has(item.tagID)) {
          placeTags.queryByTagID.set(item.tagID, item.tagName);
        }
      }
    }
  } catch (error) {
    if (generation !== placeTags.requestGeneration) return;
    placeTags.error = error.message || "地点标签缓存读取失败。";
  } finally {
    if (generation === placeTags.requestGeneration) {
      placeTags.loading = false;
      renderWorldMapPlaceTags();
    }
  }
}

async function submitWorldMapPlaceTagSearch(tagID) {
  const placeTags = state.worldMap.placeTags;
  const item = placeTags.items.find((candidate) => candidate.tagID === tagID);
  if (!item || placeTags.busyTagIDs.has(tagID)) return;
  const query = normalizedWorldMapPlaceQuery(item);
  if (!query || query.length > placeTags.maximumQueryLength) {
    updateWorldMapPlaceQueryState(tagID);
    return;
  }
  const operationKey = `search:${tagID}:${query}`;
  const operationID = placeTags.operationIDs.get(operationKey) || crypto.randomUUID();
  placeTags.operationIDs.set(operationKey, operationID);
  placeTags.busyTagIDs.add(tagID);
  placeTags.activeQueryByTagID.set(tagID, query);
  placeTags.error = "";
  renderWorldMapPlaceTags({ focusTagID: tagID });
  try {
    const response = await api("/v1/world-map/place-tags/requests", {
      method: "POST",
      body: JSON.stringify({ operationID, tagID, action: "search", query }),
    });
    placeTags.operationIDs.delete(operationKey);
    placeTags.submittedQueryByTagID.set(tagID, query);
    if (response.resolution) {
      placeTags.mutationGeneration += 1;
      replaceWorldMapPlaceTagResolution(response.resolution);
    }
    void loadWorldMapSnapshot({ bounds: state.worldMap.viewport, quiet: true });
  } catch (error) {
    placeTags.error = error.message || `“${query}”的地点搜索失败，请检查描述后重试。`;
  } finally {
    placeTags.busyTagIDs.delete(tagID);
    placeTags.activeQueryByTagID.delete(tagID);
    renderWorldMapPlaceTags({ focusTagID: tagID });
  }
}

async function confirmWorldMapPlaceTag(tagID, placeID) {
  const placeTags = state.worldMap.placeTags;
  if (!tagID || !placeID || placeTags.busyTagIDs.has(tagID)) return;
  const operationKey = `confirm:${tagID}:${placeID}`;
  const operationID = placeTags.operationIDs.get(operationKey) || crypto.randomUUID();
  placeTags.operationIDs.set(operationKey, operationID);
  placeTags.busyTagIDs.add(tagID);
  placeTags.error = "";
  renderWorldMapPlaceTags();
  try {
    const response = await api("/v1/world-map/place-tags/requests", {
      method: "POST",
      body: JSON.stringify({ operationID, tagID, action: "confirm", placeID }),
    });
    placeTags.operationIDs.delete(operationKey);
    if (response.resolution) {
      placeTags.mutationGeneration += 1;
      replaceWorldMapPlaceTagResolution(response.resolution);
    }
    toast("地点已确认并写入地图目录");
    void loadWorldMapSnapshot({ bounds: state.worldMap.viewport, quiet: true });
  } catch (error) {
    placeTags.error = error.message || "地点候选已变化，请重新搜索。";
  } finally {
    placeTags.busyTagIDs.delete(tagID);
    renderWorldMapPlaceTags({ focusTagID: tagID });
  }
}

function openWorldMapPlaceTags() {
  const placeTags = state.worldMap.placeTags;
  if (!elements.worldMapPlaceTagDialog.open) {
    placeTags.returnFocus = document.activeElement;
    elements.worldMapPlaceTagDialog.showModal();
  }
  renderWorldMapPlaceTags();
  requestAnimationFrame(() => {
    elements.closeWorldMapPlaceTagButton.focus({ preventScroll: true });
  });
  void loadWorldMapPlaceTags();
}

function closeWorldMapPlaceTags({ restoreFocus = true } = {}) {
  const placeTags = state.worldMap.placeTags;
  ++placeTags.requestGeneration;
  if (elements.worldMapPlaceTagDialog.open) elements.worldMapPlaceTagDialog.close();
  const returnFocus = placeTags.returnFocus;
  placeTags.returnFocus = null;
  if (restoreFocus) restoreOverlayFocus(returnFocus);
}

function handleWorldMapMessage(event) {
  if (event.origin !== globalThis.location.origin
    || event.source !== elements.worldMapFrame.contentWindow
    || event.data?.type !== "imageall-world-map-event") return;
  const message = event.data.payload || {};
  switch (message.type) {
  case "ready":
    state.worldMap.rendererReady = true;
    state.worldMap.rendererError = false;
    renderWorldMap();
    break;
  case "renderError":
    state.worldMap.rendererError = true;
    renderWorldMap();
    break;
  case "clusterClicked":
    if (typeof message.clusterID === "string") {
      void loadWorldMapSelection(message.clusterID);
    }
    break;
  case "cameraChanged":
    state.worldMap.viewport = message.viewport || null;
    clearTimeout(state.worldMap.cameraTimer);
    state.worldMap.cameraTimer = setTimeout(() => {
      void loadWorldMapSnapshot({ bounds: state.worldMap.viewport, quiet: true });
    }, 240);
    break;
  default:
    break;
  }
}

function closeLightbox() {
  elements.lightbox.classList.add("hidden");
  elements.lightbox.classList.remove("reviewing");
  elements.lightbox.removeAttribute("aria-busy");
  state.lightboxNavigating = false;
  state.lightboxPendingDirection = 0;
  ++state.lightboxRequestGeneration;
  clearProtectedImageSource(elements.lightboxImage);
  stopLightboxVideo();
  elements.lightboxReviewActions.classList.add("hidden");
  state.lightboxContext = null;
  state.lightboxAssetID = null;
  elements.reviewWorkspace.inert = false;
  elements.slimmingWorkspace.inert = false;
  elements.worldMapWorkspace.inert = false;
  if (elements.reviewWorkspace.classList.contains("hidden")
    && elements.slimmingWorkspace.classList.contains("hidden")
    && elements.worldMapWorkspace.classList.contains("hidden")) {
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
  updateMediaWorkerAuthorization(null);
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
  renderPersonalModelControls();
  renderEmbeddingPreparation();
  renderSampleSuggestions();
  renderReviewOverview();
  renderSourcePrewarmStatus();
  if (elements.generalSettingsDialog.open) renderGeneralSettings();
  if (elements.tagSuggestionDialog.open) renderTagSuggestionDialog();
}

function toast(message) {
  clearTimeout(state.toastTimer);
  state.toastUndoKind = null;
  elements.toastMessage.textContent = message;
  elements.undoToastButton.classList.add("hidden");
  elements.toast.classList.remove("hidden");
  state.toastTimer = setTimeout(() => elements.toast.classList.add("hidden"), 2600);
}

function undoToast(message, undoID, kind = "tag") {
  clearTimeout(state.toastTimer);
  const channel = state.undo[kind];
  if (!channel) return;
  const nextUndoID = undoID || null;
  if (channel.id !== nextUndoID) {
    channel.operationID = nextUndoID ? crypto.randomUUID() : null;
  } else if (nextUndoID && !channel.operationID) {
    channel.operationID = crypto.randomUUID();
  }
  channel.id = nextUndoID;
  state.toastUndoKind = nextUndoID ? kind : null;
  elements.toastMessage.textContent = message;
  elements.undoToastButton.classList.toggle("hidden", !undoID);
  elements.undoToastButton.disabled = !undoID || channel.mutating;
  elements.toast.classList.remove("hidden");
  state.toastTimer = setTimeout(() => elements.toast.classList.add("hidden"), 7000);
  renderUndoControls();
}

function renderUndoControls() {
  const tag = state.undo.tag;
  const review = state.undo.review;
  elements.undoTagButton.disabled = !state.online || !tag.id || tag.mutating;
  elements.undoTagButton.setAttribute("aria-disabled", String(elements.undoTagButton.disabled));
  elements.undoReviewButton.classList.toggle("hidden", !review.id);
  elements.undoReviewButton.disabled = !state.online || !review.id || review.mutating;
  elements.undoReviewButton.setAttribute(
    "aria-disabled",
    String(elements.undoReviewButton.disabled)
  );
  elements.reviewUndoButton.classList.toggle("hidden", !review.id);
  elements.reviewUndoButton.disabled = !state.online || !review.id || review.mutating;
  elements.reviewUndoButton.setAttribute(
    "aria-disabled",
    String(elements.reviewUndoButton.disabled)
  );
  if (state.toastUndoKind) {
    const channel = state.undo[state.toastUndoKind];
    elements.undoToastButton.disabled = !state.online || !channel?.id || channel.mutating;
  }
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
    if (button.closest("#sourceManagerDialog")) return;
    if (button.closest("#generalSettingsDialog")) return;
    const isReviewAction = button.classList.contains("review-action");
    const isJobAction = button.classList.contains("job-action");
    const isBatchAction = button.classList.contains("batch-action");
    const isSelectionTagAction = Boolean(button.closest("#selectionInspectorTags"));
    const isSelectionTagOrderingChip = button.matches(
      '[data-tag-reorder-surface="selection"]'
    );
    const reviewLocked = isReviewAction
      && (state.review.loading || state.review.mutating);
    const jobLocked = isJobAction
      && state.jobMutatingIDs.has(button.dataset.jobId);
    const tagLocked = !isReviewAction
      && !isJobAction
      && (state.tagMutating || state.tagManagementMutating || state.installingPresetTags);
    const batchUnavailable = isBatchAction
      && (!state.selectedAssetIDs.size || !elements.batchTagSelect.value);
    const aggregateUnavailable = isSelectionTagAction
      && !isSelectionTagOrderingChip
      && (!state.selectedAssetIDs.size || state.loadingAggregate);
    const trainingLaunchUnavailable = button === elements.launchTrainingButton
      && !canLaunchTrainingSetup();
    const trainingActivityUnavailable = Boolean(button.dataset.trainingActivityId)
      && state.training.activityMutatingIDs.has(button.dataset.trainingActivityId);
    const slimmingLaunchUnavailable = button === elements.launchSlimmingButton
      && !canLaunchSlimmingSetup();
    const slimmingSaveUnavailable = button === elements.saveSlimmingThresholdsButton
      && !canSaveSlimmingThresholds();
    const slimmingJobUnavailable = Boolean(button.dataset.slimmingJobActionId)
      && state.slimming.jobMutatingIDs.has(button.dataset.slimmingJobActionId);
    const slimmingRecycleUnavailable = Boolean(button.dataset.slimmingRecycleEntryId)
      && state.slimming.recycle.mutatingEntryIDs.has(button.dataset.slimmingRecycleEntryId);
    button.disabled = !state.online
      || reviewLocked
      || jobLocked
      || tagLocked
      || batchUnavailable
      || aggregateUnavailable
      || trainingLaunchUnavailable
      || trainingActivityUnavailable
      || slimmingLaunchUnavailable
      || slimmingSaveUnavailable
      || slimmingJobUnavailable
      || slimmingRecycleUnavailable;
  });
  if (elements.sourceManagerDialog.open) renderSourceManagement();
  if (elements.storageDialog.open) renderStorageMaintenance();
  renderUndoControls();
  elements.openOriginalButton.disabled = !state.online
    || state.selectedDetail?.availability !== "available"
    || state.openingOriginal;
  syncManagedTagFields({ updateValues: false });
  syncManagedGroupFields({ updateValues: false });
}

function persistWorkspacePreferences() {
  localStorage.setItem("imageall.web.workspace-preferences", JSON.stringify({
    sidebarVisible: state.layout.sidebarVisible,
    inspectorVisible: state.layout.inspectorVisible,
    trainingNavigatorVisible: state.layout.trainingNavigatorVisible,
    density: state.layout.density,
    aspectMode: state.layout.aspectMode,
    collapsedSidebarTagGroupIDs: [...state.layout.collapsedSidebarTagGroupIDs],
    collapsedInspectorTagGroupIDs: [...state.layout.collapsedInspectorTagGroupIDs],
    collapsedReviewTagGroupIDs: [...state.layout.collapsedReviewTagGroupIDs],
    sourceOrderIDs: state.layout.sourceOrderIDs,
    tagOrderIDsByGroup: state.layout.tagOrderIDsByGroup,
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
    if (typeof saved.trainingNavigatorVisible === "boolean") {
      state.layout.trainingNavigatorVisible = saved.trainingNavigatorVisible;
    }
    if (Number.isInteger(saved.density) && saved.density >= 0 && saved.density <= 8) {
      state.layout.density = saved.density;
    }
    if (["square", "original"].includes(saved.aspectMode)) {
      state.layout.aspectMode = saved.aspectMode;
    }
    if (Array.isArray(saved.collapsedSidebarTagGroupIDs)) {
      state.layout.collapsedSidebarTagGroupIDs = new Set(
        saved.collapsedSidebarTagGroupIDs.filter((value) => typeof value === "string")
      );
    }
    if (Array.isArray(saved.collapsedInspectorTagGroupIDs)) {
      state.layout.collapsedInspectorTagGroupIDs = new Set(
        saved.collapsedInspectorTagGroupIDs.filter((value) => typeof value === "string")
      );
    }
    if (Array.isArray(saved.collapsedReviewTagGroupIDs)) {
      state.layout.collapsedReviewTagGroupIDs = new Set(
        saved.collapsedReviewTagGroupIDs.filter((value) => typeof value === "string")
      );
    }
    if (Array.isArray(saved.sourceOrderIDs)) {
      state.layout.sourceOrderIDs = saved.sourceOrderIDs.filter(
        (value) => typeof value === "string"
      );
    }
    if (saved.tagOrderIDsByGroup && typeof saved.tagOrderIDsByGroup === "object") {
      state.layout.tagOrderIDsByGroup = Object.fromEntries(
        Object.entries(saved.tagOrderIDsByGroup)
          .filter(([key, value]) => typeof key === "string" && Array.isArray(value))
          .map(([key, value]) => [
            key,
            value.filter((item) => typeof item === "string"),
          ])
      );
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
  const originalAspect = state.layout.aspectMode === "original";
  elements.assetGrid.classList.toggle("original-aspect", originalAspect);
  elements.thumbnailAspectButton.setAttribute("aria-pressed", String(originalAspect));
  elements.thumbnailAspectButton.textContent = originalAspect ? "填充" : "适应";
  elements.thumbnailAspectButton.title = originalAspect
    ? "裁切为方形缩略图"
    : "完整显示照片宽高比";
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
  renderLibraryEmptyState();
  elements.inspector.setAttribute("aria-label", `${noun}检查器`);
  elements.inspectorPlaceholderText.textContent = `选择一个${noun}以查看详细信息和标签`;
  elements.inspectorNavigation.setAttribute("aria-label", `${noun}导航`);
  elements.inspectorPreviousButton.setAttribute("aria-label", `上一个${noun}`);
  elements.inspectorNextButton.setAttribute("aria-label", `下一个${noun}`);
  elements.sidebarNewTagButton.title = `为所选${noun}新增标签`;
  elements.lightbox.setAttribute("aria-label", `${noun}全屏预览`);
}

function renderLibraryEmptyState() {
  const noun = currentMediaNoun();
  const noSources = state.sources.length === 0;
  const noTags = activeTags().length === 0;
  const selectedSource = state.sources.find((source) => source.id === state.selectedSourceID);
  const constrained = Boolean(
    state.searchText
      || state.filters.tagConditions.length
      || state.filters.availability
      || state.filters.mediaTypes.length
      || state.filters.tagPresence !== "any"
  );
  let recoveryAction = null;

  if (noSources && noTags) {
    elements.emptyStateTitle.textContent = "开始建立你的照片资料库";
    elements.emptyStateCopy.textContent = "连接一个照片来源，也可以添加一组可编辑的常用标签。常用标签不会分析照片，也不会自动应用到任何照片。";
  } else if (noSources) {
    elements.emptyStateTitle.textContent = "ImageAll 在原位置读取照片";
    elements.emptyStateCopy.textContent = "连接照片文件夹或 Apple Photos 后即可开始；ImageAll 不会导入、移动或重命名原图。";
  } else if (constrained) {
    elements.emptyStateTitle.textContent = `没有找到${noun}`;
    elements.emptyStateCopy.textContent = `尝试选择其他来源或清除${noun}筛选条件。`;
  } else if (selectedSource?.kind === "photos" && selectedSource.state === "unavailable") {
    elements.emptyStateTitle.textContent = "系统照片图库已更换";
    elements.emptyStateCopy.textContent = "旧来源的索引、人工标签和历史仍保留；可在 Mac 上确认后连接当前系统照片图库。";
    recoveryAction = "rebindPhotos";
  } else if (selectedSource?.kind === "photos"
    && ["authorizationRequired", "disabled"].includes(selectedSource.state)) {
    elements.emptyStateTitle.textContent = "需要照片访问权限";
    elements.emptyStateCopy.textContent = "请在 Mac 上重新请求或检查照片权限；网页不会绕过 macOS 授权面板。";
    recoveryAction = "reauthorize";
  } else if (selectedSource?.kind === "photos" && selectedSource.state === "active") {
    elements.emptyStateTitle.textContent = "系统照片图库中没有可访问的照片";
    elements.emptyStateCopy.textContent = "可在 Mac 上立即同步当前系统照片图库，更新索引和可用状态。";
    recoveryAction = "syncPhotos";
  } else if (selectedSource?.kind === "folder"
    && ["unavailable", "authorizationRequired"].includes(selectedSource.state)) {
    elements.emptyStateTitle.textContent = "需要重新授权文件夹";
    elements.emptyStateCopy.textContent = "请在 Mac 系统选择器中重新选择原文件夹；网页不会接收路径或安全作用域书签。";
    recoveryAction = "reauthorize";
  } else if (selectedSource?.kind === "folder" && selectedSource.state === "active") {
    elements.emptyStateTitle.textContent = `没有支持的${noun}`;
    elements.emptyStateCopy.textContent = "可在 Mac 上立即重扫当前文件夹，寻找支持的媒体并更新索引。";
    recoveryAction = "rescan";
  } else {
    elements.emptyStateTitle.textContent = `还没有可显示的${noun}`;
    elements.emptyStateCopy.textContent = "来源仍保留在原位置；可以等待扫描完成，或从来源菜单立即同步。";
  }

  const showsSourceRecovery = Boolean(selectedSource && recoveryAction);
  elements.emptyStateActions.classList.toggle("hidden", !noSources && !showsSourceRecovery);
  elements.emptyConnectFolderButton.classList.toggle("hidden", !noSources);
  elements.emptyConnectPhotosButton.classList.toggle("hidden", !noSources);
  elements.emptyInstallPresetTagsButton.classList.toggle("hidden", !noSources || !noTags);
  elements.emptySourceRecoveryButton.classList.toggle("hidden", !showsSourceRecovery);
  elements.emptyOpenSourceManagerButton.classList.toggle("hidden", !showsSourceRecovery);
  elements.emptySourceRecoveryButton.dataset.sourceAction = recoveryAction || "";
  elements.emptySourceRecoveryButton.dataset.sourceId = selectedSource?.id || "";
  elements.emptySourceRecoveryButton.textContent = recoveryAction
    ? sourceManagementActionLabel(recoveryAction)
    : "";
  elements.emptyConnectFolderButton.disabled = !state.online;
  elements.emptyConnectPhotosButton.disabled = !state.online;
  elements.emptyInstallPresetTagsButton.disabled = !state.online || state.installingPresetTags;
  elements.emptySourceRecoveryButton.disabled = !state.online || !showsSourceRecovery;
  elements.emptyOpenSourceManagerButton.disabled = !state.online || !showsSourceRecovery;
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
  stopAssetHoverVideo();
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
  await loadEmbeddingPreparation({ quiet: true });
  await loadSampleSuggestions({ quiet: true });
  await loadTagLibrarySuggestions({ quiet: true });
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

function formatDuration(milliseconds) {
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) return "—";
  const totalSeconds = Math.round(milliseconds / 1000);
  const seconds = totalSeconds % 60;
  const totalMinutes = Math.floor(totalSeconds / 60);
  const minutes = totalMinutes % 60;
  const hours = Math.floor(totalMinutes / 60);
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  }
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function formatFileSize(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  const units = ["字节", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex += 1;
  }
  const maximumFractionDigits = unitIndex === 0 || value >= 10 ? 0 : 1;
  return `${new Intl.NumberFormat("zh-CN", { maximumFractionDigits }).format(value)} ${units[unitIndex]}`;
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

function orderedByPreference(items, preferredIDs, identifier = (item) => item.id) {
  const byID = new Map(items.map((item) => [identifier(item), item]));
  const result = [];
  for (const id of preferredIDs || []) {
    const item = byID.get(id);
    if (!item) continue;
    result.push(item);
    byID.delete(id);
  }
  for (const item of items) {
    const id = identifier(item);
    if (!byID.has(id)) continue;
    result.push(item);
    byID.delete(id);
  }
  return result;
}

function orderedSources() {
  return orderedByPreference(state.sources, state.layout.sourceOrderIDs);
}

function tagOrderPreferenceKey(groupID) {
  return groupID || "__ungrouped__";
}

function orderedTagsInGroup(tags, groupID) {
  return orderedByPreference(
    tags,
    state.layout.tagOrderIDsByGroup[tagOrderPreferenceKey(groupID)] || [],
    (tag) => tag.tagID || tag.id
  );
}

function orderedActiveTags() {
  const tags = activeTags();
  const ordered = [];
  const seen = new Set();
  for (const group of orderedTagGroups()) {
    for (const tag of orderedTagsInGroup(
      tags.filter((item) => item.groupID === group.id),
      group.id
    )) {
      ordered.push(tag);
      seen.add(tag.id);
    }
  }
  for (const tag of orderedTagsInGroup(
    tags.filter((item) => !seen.has(item.id)),
    null
  )) {
    ordered.push(tag);
  }
  return ordered;
}

function moveIDBefore(ids, movingID, beforeID) {
  const result = ids.filter((id) => id !== movingID);
  const targetIndex = beforeID ? result.indexOf(beforeID) : -1;
  result.splice(targetIndex >= 0 ? targetIndex : result.length, 0, movingID);
  return result;
}

function moveIDByOffset(ids, movingID, offset) {
  const currentIndex = ids.indexOf(movingID);
  if (currentIndex < 0) return ids;
  const destination = Math.max(0, Math.min(ids.length - 1, currentIndex + offset));
  if (destination === currentIndex) return ids;
  const result = [...ids];
  result.splice(currentIndex, 1);
  result.splice(destination, 0, movingID);
  return result;
}

function orderedTagGroups() {
  return [...state.tagGroups].sort((left, right) => (
    left.sortOrder - right.sortOrder
      || left.displayName.localeCompare(right.displayName, "zh-CN")
  ));
}

function groupByID(groupID) {
  return state.tagGroups.find((group) => group.id === groupID);
}

function inspectorTagGroupSections(tags) {
  const knownGroups = orderedTagGroups();
  if (!knownGroups.length) {
    return tags.length ? [{ id: "all", displayName: "标签", tags }] : [];
  }
  const sections = knownGroups.map((group) => ({
    id: group.id,
    displayName: group.displayName,
    tags: orderedTagsInGroup(
      tags.filter((tag) => tagByID(tag.tagID || tag.id)?.groupID === group.id),
      group.id
    ),
  })).filter((section) => section.tags.length);
  const groupedTagIDs = new Set(sections.flatMap((section) => (
    section.tags.map((tag) => tag.tagID || tag.id)
  )));
  const ungrouped = orderedTagsInGroup(
    tags.filter((tag) => !groupedTagIDs.has(tag.tagID || tag.id)),
    null
  );
  if (ungrouped.length) sections.push({ id: "other", displayName: "其他", tags: ungrouped });
  return sections;
}

function appendInspectorTagGroups(container, tags, appendTagRow) {
  const sections = inspectorTagGroupSections(tags);
  for (const section of sections) {
    const collapsed = state.layout.collapsedInspectorTagGroupIDs.has(section.id);
    const group = document.createElement("section");
    group.className = "inspector-tag-group";
    group.dataset.inspectorTagGroupId = section.id;
    if (groupByID(section.id)) group.dataset.inspectorTagDropGroupId = section.id;
    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.className = "inspector-tag-group-toggle";
    toggle.dataset.inspectorTagGroupToggle = section.id;
    toggle.setAttribute("aria-expanded", String(!collapsed));
    toggle.title = collapsed ? `展开“${section.displayName}”` : `折叠“${section.displayName}”`;
    const chevron = document.createElement("span");
    chevron.setAttribute("aria-hidden", "true");
    chevron.textContent = collapsed ? "›" : "⌄";
    const title = document.createElement("strong");
    title.textContent = section.displayName;
    const count = document.createElement("span");
    count.className = "secondary";
    count.textContent = String(section.tags.length);
    toggle.append(chevron, title, count);
    const rows = document.createElement("div");
    rows.className = "inspector-tag-group-rows";
    rows.classList.toggle("hidden", collapsed);
    for (const tag of section.tags) appendTagRow(rows, tag);
    group.append(toggle, rows);
    container.append(group);
  }
}

function toggleInspectorTagGroup(groupID) {
  if (state.layout.collapsedInspectorTagGroupIDs.has(groupID)) {
    state.layout.collapsedInspectorTagGroupIDs.delete(groupID);
  } else {
    state.layout.collapsedInspectorTagGroupIDs.add(groupID);
  }
  persistWorkspacePreferences();
  if (state.selectionMode && state.selectedAssetIDs.size) renderSelectionInspector();
  else if (state.selectedDetail) renderInspector(state.selectedDetail);
}

function rememberInspectorTagFocus(surface, kind, id, action = null) {
  state.pendingInspectorTagFocus = { surface, kind, id, action };
}

function setupInspectorTagInteractions(container, surface, batch) {
  const applyDecision = (action, tagID, kind = "chip") => {
    rememberInspectorTagFocus(surface, kind, tagID, action);
    if (batch) applyBatchTagDecision(action, tagID);
    else mutateTag(tagID, action);
  };

  container.addEventListener("click", (event) => {
    if (performance.now() < state.sidebarDrag.suppressClickUntil) return;
    const groupToggle = event.target.closest("[data-inspector-tag-group-toggle]");
    if (groupToggle) {
      const groupID = groupToggle.dataset.inspectorTagGroupToggle;
      rememberInspectorTagFocus(surface, "group", groupID);
      toggleInspectorTagGroup(groupID);
      return;
    }
    const decisionButton = event.target.closest("[data-action][data-tag-id]");
    if (decisionButton) {
      applyDecision(decisionButton.dataset.action, decisionButton.dataset.tagId, "decision");
      return;
    }
    const chip = event.target.closest("[data-tag-chip-action][data-tag-id]");
    if (chip) applyDecision("accept", chip.dataset.tagId);
  });

  container.addEventListener("contextmenu", (event) => {
    const chip = event.target.closest("[data-tag-chip-action][data-tag-id]");
    if (!chip || chip.disabled) return;
    event.preventDefault();
    applyDecision("clear", chip.dataset.tagId);
  });

  container.addEventListener("keydown", (event) => {
    const groupToggle = event.target.closest("[data-inspector-tag-group-toggle]");
    if (groupToggle && ["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) {
      const toggles = [...container.querySelectorAll("[data-inspector-tag-group-toggle]")];
      const currentIndex = toggles.indexOf(groupToggle);
      const nextIndex = event.key === "Home"
        ? 0
        : event.key === "End"
          ? toggles.length - 1
          : Math.max(0, Math.min(
            toggles.length - 1,
            currentIndex + (event.key === "ArrowDown" ? 1 : -1)
          ));
      event.preventDefault();
      toggles[nextIndex]?.focus({ preventScroll: true });
      return;
    }
    const chip = event.target.closest("[data-tag-chip-action][data-tag-id]");
    if (!chip || chip.disabled) return;
    if (event.altKey && ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.key)) {
      event.preventDefault();
      if (event.key === "ArrowUp" || event.key === "ArrowDown") {
        reorderSidebarTagByOffset(
          chip.dataset.tagId,
          event.key === "ArrowDown" ? 1 : -1,
          surface
        );
      } else {
        moveSidebarTagToAdjacentGroup(
          chip.dataset.tagId,
          event.key === "ArrowRight" ? 1 : -1,
          surface
        );
      }
    } else if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      applyDecision("clear", chip.dataset.tagId);
    } else if (!event.metaKey && !event.ctrlKey && !event.altKey
      && event.key.toLocaleLowerCase("en-US") === "x") {
      event.preventDefault();
      applyDecision("reject", chip.dataset.tagId);
    }
  });

  container.addEventListener("dragstart", (event) => {
    const chip = event.target.closest(`[data-tag-reorder-surface="${surface}"]`);
    if (!chip?.draggable) return;
    state.sidebarDrag.tagID = chip.dataset.tagId;
    state.sidebarDrag.tagSurface = surface;
    container.dataset.activeTagDrag = chip.dataset.tagId;
    chip.classList.add("dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("application/x-imageall-tag", chip.dataset.tagId);
  }, true);
  container.addEventListener("dragover", (event) => {
    if (!state.sidebarDrag.tagID) return;
    const section = event.target.closest("[data-inspector-tag-drop-group-id]");
    if (!section) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    clearSidebarDropIndicators();
    const target = event.target.closest(`[data-tag-reorder-surface="${surface}"]`);
    if (target && target.dataset.tagId !== state.sidebarDrag.tagID) {
      const rect = target.getBoundingClientRect();
      const after = event.clientY > rect.top + rect.height / 2;
      target.classList.add(after ? "drop-after" : "drop-before");
      state.sidebarDrag.dropTarget = target;
    } else {
      section.classList.add("drag-over-group");
      state.sidebarDrag.dropTarget = section;
    }
  });
  container.addEventListener("drop", (event) => {
    const tagID = state.sidebarDrag.tagID;
    const section = event.target.closest("[data-inspector-tag-drop-group-id]");
    if (!tagID || !section) return;
    event.preventDefault();
    const target = event.target.closest(`[data-tag-reorder-surface="${surface}"]`);
    let beforeTagID = null;
    if (target && target.dataset.tagId !== tagID) {
      if (target.classList.contains("drop-after")) {
        const siblings = [...section.querySelectorAll(
          `[data-tag-reorder-surface="${surface}"]`
        )];
        const targetIndex = siblings.indexOf(target);
        beforeTagID = siblings[targetIndex + 1]?.dataset.tagId || null;
      } else {
        beforeTagID = target.dataset.tagId;
      }
    }
    // Release the drag render lock before applying the optimistic order. This
    // lets the drop itself repaint immediately while still protecting the live
    // drag from an unrelated aggregate response.
    state.sidebarDrag.tagID = null;
    state.sidebarDrag.tagSurface = null;
    delete container.dataset.activeTagDrag;
    moveSidebarTag(
      tagID,
      section.dataset.inspectorTagDropGroupId,
      beforeTagID,
      surface
    );
    state.sidebarDrag.suppressClickUntil = performance.now() + 250;
    clearSidebarDropIndicators();
  });
  container.addEventListener("dragend", (event) => {
    const chip = event.target.closest(`[data-tag-reorder-surface="${surface}"]`);
    const tagID = chip?.dataset.tagId;
    chip?.classList.remove("dragging");
    state.sidebarDrag.tagID = null;
    state.sidebarDrag.tagSurface = null;
    delete container.dataset.activeTagDrag;
    state.sidebarDrag.suppressClickUntil = performance.now() + 250;
    clearSidebarDropIndicators();
    if (surface === "selection" && state.sidebarDrag.pendingSelectionRender) {
      renderSelectionInspector();
    }
    if (tagID) focusTagOrderingSurface(tagID, surface);
  });
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
  const tags = orderedActiveTags();
  setSelectOptions(elements.filterTagSelect, tags, tags.length ? "选择标签" : "尚无活动标签");
  setSelectOptions(elements.batchTagSelect, tags, tags.length ? "批量标签…" : "尚无活动标签");
  setSelectOptions(elements.reviewTagSelect, tags, tags.length ? "选择审核标签" : "尚无活动标签");
  elements.filterTagSelect.disabled = tags.length === 0;
  elements.batchTagSelect.disabled = tags.length === 0 || state.tagMutating;
  elements.reviewTagSelect.disabled = tags.length === 0
    || state.review.loading
    || state.review.mutating;
  renderTagNavigation();
  renderActiveFilterBar();
  renderTagManager();
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

function toggleSidebarTagGroup(groupID) {
  if (state.layout.collapsedSidebarTagGroupIDs.has(groupID)) {
    state.layout.collapsedSidebarTagGroupIDs.delete(groupID);
  } else {
    state.layout.collapsedSidebarTagGroupIDs.add(groupID);
  }
  persistWorkspacePreferences();
  renderTagNavigation();
  requestAnimationFrame(() => {
    elements.tagNavigation.querySelector(
      `[data-sidebar-tag-group-toggle="${CSS.escape(groupID)}"]`
    )?.focus({ preventScroll: true });
  });
}

function configureSidebarTagFilterState(button, tag, query) {
  const condition = state.filters.tagConditions.find((item) => item.tagID === tag.id);
  const included = condition?.decision === "accepted";
  const excluded = condition?.decision === "excluded";
  const stateLabel = excluded
    ? "已排除"
    : included
      ? (state.filters.tagMatchMode === "all" ? "交集筛选" : "并集筛选")
      : "未筛选";
  button.dataset.tagFilterState = excluded ? "excluded" : included ? "included" : "none";
  button.classList.toggle("selected", included);
  button.classList.toggle("excluded", excluded);
  button.setAttribute("aria-pressed", String(included || excluded));
  button.setAttribute("aria-label", `${tag.displayName}，${stateLabel}`);
  button.title = query
    ? "清除标签搜索后可拖放排序"
    : excluded
      ? "已从当前范围排除；⌘⌥点击取消排除；拖动可排序"
      : included
        ? `${stateLabel}；点击切换；⌘⌥点击排除；拖动可排序`
        : "点击并集筛选；⌘点击交集筛选；⌘⌥点击排除；拖动可排序";
}

function renderTagNavigation() {
  const query = elements.tagNavigationSearch.value.trim().toLocaleLowerCase("zh-CN");
  const allActiveTags = activeTags();
  const tags = allActiveTags.filter((tag) => (
    !query || tag.displayName.toLocaleLowerCase("zh-CN").includes(query)
  ));
  clearElement(elements.tagNavigation);
  elements.tagNavigationEmpty.classList.toggle("hidden", tags.length > 0);
  elements.tagNavigationEmptyText.textContent = allActiveTags.length
    ? "没有匹配的标签"
    : "尚未添加标签";
  const offersPresets = allActiveTags.length === 0 && !query;
  elements.sidebarInstallPresetTagsButton.classList.toggle("hidden", !offersPresets);
  elements.sidebarInstallPresetTagsButton.disabled = !state.online || state.installingPresetTags;

  const knownGroups = orderedTagGroups();
  const groups = knownGroups.length
    ? knownGroups
    : [{ id: "", displayName: "标签", sortOrder: 0, isSystem: true }];
  for (const group of groups) {
    const groupTags = orderedTagsInGroup(
      tags.filter((tag) => (
        knownGroups.length ? tag.groupID === group.id : true
      )),
      knownGroups.length ? group.id : null
    );
    if (!groupTags.length) continue;
    const preferenceID = knownGroups.length ? group.id : "__all__";
    const collapsed = !query && state.layout.collapsedSidebarTagGroupIDs.has(preferenceID);
    const section = document.createElement("section");
    section.className = "tag-navigation-group";
    section.dataset.tagDropGroupId = group.id;
    section.dataset.sidebarTagGroupId = preferenceID;
    const title = document.createElement("button");
    title.type = "button";
    title.className = "tag-navigation-group-title";
    title.dataset.sidebarTagGroupToggle = preferenceID;
    title.setAttribute("aria-expanded", String(!collapsed));
    title.title = collapsed ? `展开“${group.displayName}”` : `折叠“${group.displayName}”`;
    const chevron = document.createElement("span");
    chevron.className = "tag-navigation-group-chevron";
    chevron.setAttribute("aria-hidden", "true");
    chevron.textContent = collapsed ? "›" : "⌄";
    const name = document.createElement("strong");
    name.textContent = group.displayName;
    const count = document.createElement("span");
    count.className = "tag-navigation-group-count";
    count.textContent = String(groupTags.length);
    title.append(chevron, name, count);
    const list = document.createElement("div");
    list.className = "tag-navigation-group-tags";
    list.classList.toggle("hidden", collapsed);
    for (const tag of groupTags) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "sidebar-tag-chip";
      button.dataset.quickTagId = tag.id;
      button.draggable = !query && !state.tagManagementMutating;
      button.setAttribute(
        "aria-keyshortcuts",
        "Meta+Enter Meta+Alt+Enter Shift+F10 Alt+ArrowLeft Alt+ArrowRight Alt+ArrowUp Alt+ArrowDown"
      );
      button.textContent = tag.displayName;
      configureSidebarTagFilterState(button, tag, query);
      list.append(button);
    }
    section.append(title, list);
    elements.tagNavigation.append(section);
  }
  const orphanedTags = knownGroups.length
    ? orderedTagsInGroup(tags.filter((tag) => !groupByID(tag.groupID)), null)
    : [];
  if (orphanedTags.length) {
    const preferenceID = "__other__";
    const collapsed = !query && state.layout.collapsedSidebarTagGroupIDs.has(preferenceID);
    const section = document.createElement("section");
    section.className = "tag-navigation-group";
    section.dataset.tagDropGroupId = "";
    section.dataset.sidebarTagGroupId = preferenceID;
    const title = document.createElement("button");
    title.type = "button";
    title.className = "tag-navigation-group-title";
    title.dataset.sidebarTagGroupToggle = preferenceID;
    title.setAttribute("aria-expanded", String(!collapsed));
    title.title = collapsed ? "展开“其他”" : "折叠“其他”";
    const chevron = document.createElement("span");
    chevron.className = "tag-navigation-group-chevron";
    chevron.setAttribute("aria-hidden", "true");
    chevron.textContent = collapsed ? "›" : "⌄";
    const name = document.createElement("strong");
    name.textContent = "其他";
    const count = document.createElement("span");
    count.className = "tag-navigation-group-count";
    count.textContent = String(orphanedTags.length);
    title.append(chevron, name, count);
    const list = document.createElement("div");
    list.className = "tag-navigation-group-tags";
    list.classList.toggle("hidden", collapsed);
    for (const tag of orphanedTags) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "sidebar-tag-chip";
      button.dataset.quickTagId = tag.id;
      button.draggable = !query && !state.tagManagementMutating;
      button.setAttribute(
        "aria-keyshortcuts",
        "Meta+Enter Meta+Alt+Enter Shift+F10 Alt+ArrowLeft Alt+ArrowRight"
      );
      button.textContent = tag.displayName;
      configureSidebarTagFilterState(button, tag, query);
      list.append(button);
    }
    section.append(title, list);
    elements.tagNavigation.append(section);
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

async function filterToSingleSidebarTag(tagID) {
  state.filters.tagConditions = [{ tagID, decision: "accepted" }];
  state.filters.tagPresence = "any";
  state.filters.tagMatchMode = "all";
  state.filterDraft = null;
  renderTagNavigation();
  syncFilterControlsFromState();
  await loadAssets();
  focusSidebarTag(tagID);
}

async function toggleSidebarTagFilter(tagID, { matchMode = "any", excluded = false } = {}) {
  const current = state.filters.tagConditions.find((item) => item.tagID === tagID);
  const togglesOff = excluded
    ? current?.decision === "excluded"
    : current?.decision === "accepted";
  state.filters.tagConditions = state.filters.tagConditions.filter(
    (condition) => condition.tagID !== tagID
  );
  if (!togglesOff) {
    state.filters.tagConditions.push({
      tagID,
      decision: excluded ? "excluded" : "accepted",
    });
    state.filters.tagPresence = "any";
    if (!excluded) state.filters.tagMatchMode = matchMode;
  }
  state.filterDraft = null;
  renderTagNavigation();
  syncFilterControlsFromState();
  await loadAssets();
  focusSidebarTag(tagID);
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

function renderTagManager() {
  const previousTagID = elements.tagManagerTagSelect.value;
  const previousGroupID = elements.tagManagerGroupSelect.value;
  setSelectOptions(
    elements.tagManagerTagSelect,
    orderedActiveTags(),
    activeTags().length ? null : "尚无活动标签"
  );
  setSelectOptions(
    elements.tagManagerTagGroupSelect,
    orderedTagGroups(),
    state.tagGroups.length ? null : "尚无标签分组"
  );
  setSelectOptions(
    elements.tagManagerGroupSelect,
    orderedTagGroups(),
    state.tagGroups.length ? null : "尚无标签分组"
  );
  if (previousTagID && tagByID(previousTagID)) {
    elements.tagManagerTagSelect.value = previousTagID;
  }
  if (previousGroupID && groupByID(previousGroupID)) {
    elements.tagManagerGroupSelect.value = previousGroupID;
  }
  syncManagedTagFields();
  syncManagedGroupFields();
  elements.installPresetTagsButton.disabled = state.installingPresetTags
    || state.tagManagementMutating
    || !state.online;
  elements.installPresetTagsButton.textContent = state.installingPresetTags
    ? "正在添加…"
    : "添加常用标签";
}

function syncManagedTagFields({ updateValues = true } = {}) {
  const tag = tagByID(elements.tagManagerTagSelect.value);
  if (updateValues) {
    elements.tagManagerTagName.value = tag?.displayName || "";
    elements.tagManagerTagGroupSelect.value = tag?.groupID || "";
  }
  const disabled = !tag || state.tagManagementMutating;
  elements.tagManagerTagName.disabled = disabled;
  elements.tagManagerTagGroupSelect.disabled = disabled;
  elements.renameManagedTagButton.disabled = disabled || !state.online;
  elements.moveManagedTagButton.disabled = disabled || !state.online;
  elements.archiveManagedTagButton.disabled = disabled || !state.online;
}

function syncManagedGroupFields({ updateValues = true } = {}) {
  const group = groupByID(elements.tagManagerGroupSelect.value);
  if (updateValues) elements.tagManagerGroupName.value = group?.displayName || "";
  const protectedGroup = !group || group.isSystem;
  elements.renameTagGroupButton.disabled = protectedGroup
    || state.tagManagementMutating
    || !state.online;
  elements.deleteTagGroupButton.disabled = protectedGroup
    || state.tagManagementMutating
    || !state.online;
  elements.createTagGroupButton.disabled = state.tagManagementMutating || !state.online;
}

function openTagManager() {
  state.tagManagerReturnFocus = { element: document.activeElement };
  elements.tagManagerError.textContent = "";
  renderTagManager();
  elements.tagManagerDialog.showModal();
  elements.tagManagerTagSelect.focus({ preventScroll: true });
}

function openTagManagerForTag(tagID) {
  const tag = tagByID(tagID);
  if (!tag) return;
  state.tagManagerReturnFocus = { tagID };
  elements.tagManagerError.textContent = "";
  renderTagManager();
  elements.tagManagerTagSelect.value = tagID;
  syncManagedTagFields();
  elements.tagManagerDialog.showModal();
  elements.tagManagerTagName.focus({ preventScroll: true });
  elements.tagManagerTagName.select();
}

function openTagManagerForGroup(groupID) {
  const group = groupByID(groupID);
  if (!group) return;
  state.tagManagerReturnFocus = { groupID };
  elements.tagManagerError.textContent = "";
  renderTagManager();
  elements.tagManagerGroupSelect.value = groupID;
  syncManagedGroupFields();
  elements.tagManagerDialog.showModal();
  elements.tagManagerGroupName.focus({ preventScroll: true });
  elements.tagManagerGroupName.select();
}

function restoreTagManagerReturnFocus() {
  const pending = state.tagManagerReturnFocus;
  state.tagManagerReturnFocus = null;
  if (!pending) return;
  if (pending.tagID) {
    focusSidebarTag(pending.tagID);
    return;
  }
  if (pending.groupID) {
    requestAnimationFrame(() => {
      elements.tagNavigation.querySelector(
        `[data-sidebar-tag-group-toggle="${CSS.escape(pending.groupID)}"]`
      )?.focus({ preventScroll: true });
    });
    return;
  }
  requestAnimationFrame(() => {
    if (pending.element?.isConnected) pending.element.focus({ preventScroll: true });
  });
}

function requestConfirmation({
  title,
  message,
  actionLabel,
  action,
  returnFocus = { element: document.activeElement },
}) {
  state.pendingConfirmAction = action;
  state.confirmationReturnFocus = returnFocus;
  elements.confirmDialogTitle.textContent = title;
  elements.confirmDialogMessage.textContent = message;
  elements.confirmActionButton.textContent = actionLabel;
  elements.confirmDialog.showModal();
  elements.confirmActionButton.focus({ preventScroll: true });
}

function restoreConfirmationReturnFocus(pending) {
  if (!pending) return;
  if (pending.tagID) {
    requestAnimationFrame(() => {
      const tagTarget = elements.tagNavigation.querySelector(
        `[data-quick-tag-id="${CSS.escape(pending.tagID)}"]`
      );
      const groupTarget = pending.groupID
        ? elements.tagNavigation.querySelector(
          `[data-sidebar-tag-group-toggle="${CSS.escape(pending.groupID)}"]`
        )
        : null;
      (tagTarget || groupTarget || elements.tagManagerButton)?.focus({ preventScroll: true });
    });
    return;
  }
  if (pending.groupID) {
    requestAnimationFrame(() => {
      (elements.tagNavigation.querySelector(
        `[data-sidebar-tag-group-toggle="${CSS.escape(pending.groupID)}"]`
      ) || elements.tagManagerButton)?.focus({ preventScroll: true });
    });
    return;
  }
  requestAnimationFrame(() => {
    if (pending.element?.isConnected) pending.element.focus({ preventScroll: true });
  });
}

function closeConfirmation({ restoreFocus = true } = {}) {
  const pendingFocus = state.confirmationReturnFocus;
  state.pendingConfirmAction = null;
  state.confirmationReturnFocus = null;
  elements.confirmDialog.close();
  if (restoreFocus) restoreConfirmationReturnFocus(pendingFocus);
}

async function refreshTagCatalogAfterMutation() {
  const [tags, groups] = await Promise.all([
    api("/v1/tags"),
    api("/v1/tag-groups"),
  ]);
  state.tags = tags;
  state.tagGroups = groups;
  const activeTagIDs = new Set(activeTags().map((tag) => tag.id));
  state.filters.tagConditions = state.filters.tagConditions.filter(
    (condition) => activeTagIDs.has(condition.tagID)
  );
  renderTagSelects();
  renderFilterChips();
  renderLibraryEmptyState();
}

async function installPresetTags(returnFocus = document.activeElement) {
  if (!state.online || state.installingPresetTags) return;
  const generation = state.workspaceGeneration;
  const operationID = state.presetTagOperationID || crypto.randomUUID();
  state.presetTagOperationID = operationID;
  state.installingPresetTags = true;
  elements.tagManagerError.textContent = "";
  renderTagNavigation();
  renderTagManager();
  renderLibraryEmptyState();
  syncWriteActionControls();
  try {
    const response = await api("/v1/tags/install-presets", {
      method: "POST",
      body: JSON.stringify({ operationID }),
    });
    if (generation !== state.workspaceGeneration) return;
    state.presetTagOperationID = null;
    await refreshTagCatalogAfterMutation();
    if (generation !== state.workspaceGeneration) return;
    if (state.selectionMode && state.selectedAssetIDs.size) {
      scheduleSelectionAggregate();
    } else if (state.selectedAssetID) {
      await loadInspector(state.selectedAssetID, {
        preserveExisting: false,
        quiet: true,
      });
    }
    const count = response.createdTags?.length || 0;
    toast(count ? `已添加 ${count} 个常用标签` : "常用标签已全部存在");
  } catch (error) {
    const message = error.message || "无法添加常用标签";
    if (elements.tagManagerDialog.open) elements.tagManagerError.textContent = message;
    toast(message);
  } finally {
    if (generation === state.workspaceGeneration) {
      state.installingPresetTags = false;
      renderTagNavigation();
      renderTagManager();
      renderLibraryEmptyState();
      syncWriteActionControls();
      requestAnimationFrame(() => {
        const returnIsVisible = returnFocus?.isConnected
          && !returnFocus.disabled
          && !returnFocus.classList?.contains("hidden")
          && !returnFocus.closest?.(".hidden");
        const target = returnIsVisible
          ? returnFocus
          : (elements.tagNavigation.querySelector("[data-quick-tag-id]")
            || elements.tagManagerButton);
        target?.focus?.({ preventScroll: true });
      });
    }
  }
}

async function performTagCatalogMutation(path, body, successMessage) {
  if (!state.online || state.tagManagementMutating) return false;
  const generation = state.workspaceGeneration;
  state.tagManagementMutating = true;
  elements.tagManagerError.textContent = "";
  syncWriteActionControls();
  renderTagNavigation();
  renderTagManager();
  try {
    await api(path, { method: "POST", body: JSON.stringify(body) });
    if (generation !== state.workspaceGeneration) return false;
    await refreshTagCatalogAfterMutation();
    if (generation !== state.workspaceGeneration) return false;
    await loadAssets({
      preserveSelection: true,
      preserveUnchangedGrid: true,
      preserveLoadedWindow: true,
    });
    toast(successMessage);
    return true;
  } catch (error) {
    if (generation === state.workspaceGeneration) {
      elements.tagManagerError.textContent = error.message || "标签操作失败";
      toast(error.message || "标签操作失败");
    }
    return false;
  } finally {
    if (generation === state.workspaceGeneration) {
      state.tagManagementMutating = false;
      renderTagNavigation();
      renderTagManager();
      syncWriteActionControls();
    }
  }
}

async function renameManagedTag() {
  const tag = tagByID(elements.tagManagerTagSelect.value);
  const name = elements.tagManagerTagName.value.trim();
  if (!tag || !name) return;
  await performTagCatalogMutation(
    `/v1/tags/${tag.id}/rename`,
    { operationID: crypto.randomUUID(), name },
    `已将标签重命名为“${name}”`
  );
}

async function moveManagedTag() {
  const tag = tagByID(elements.tagManagerTagSelect.value);
  const group = groupByID(elements.tagManagerTagGroupSelect.value);
  if (!tag || !group) return;
  await performTagCatalogMutation(
    `/v1/tags/${tag.id}/move`,
    { operationID: crypto.randomUUID(), groupID: group.id },
    `已将“${tag.displayName}”移动到“${group.displayName}”`
  );
}

function confirmArchiveManagedTag(tagOverride = null, returnFocus = null) {
  const tag = tagOverride?.id
    ? tagOverride
    : tagByID(elements.tagManagerTagSelect.value);
  if (!tag) return;
  requestConfirmation({
    title: "归档标签？",
    message: `“${tag.displayName}”会从活动标签和网页筛选中移除，已有照片决定仍保留。`,
    actionLabel: "归档",
    action: () => performTagCatalogMutation(
      `/v1/tags/${tag.id}/archive`,
      { operationID: crypto.randomUUID() },
      `已归档标签“${tag.displayName}”`
    ),
    ...(returnFocus ? { returnFocus } : {}),
  });
}

async function createManagedTagGroup() {
  const name = elements.tagManagerGroupName.value.trim();
  if (!name) return;
  await performTagCatalogMutation(
    "/v1/tag-groups",
    { operationID: crypto.randomUUID(), name },
    `已新建分组“${name}”`
  );
}

async function renameManagedTagGroup() {
  const group = groupByID(elements.tagManagerGroupSelect.value);
  const name = elements.tagManagerGroupName.value.trim();
  if (!group || group.isSystem || !name) return;
  await performTagCatalogMutation(
    `/v1/tag-groups/${group.id}/rename`,
    { operationID: crypto.randomUUID(), name },
    `已将分组重命名为“${name}”`
  );
}

function confirmDeleteManagedTagGroup(groupOverride = null, returnFocus = null) {
  const group = groupOverride?.id
    ? groupOverride
    : groupByID(elements.tagManagerGroupSelect.value);
  if (!group || group.isSystem) return;
  requestConfirmation({
    title: "删除标签分组？",
    message: `“${group.displayName}”会被删除，其中的标签会移到 Mac 端默认分组，标签本身不会归档。`,
    actionLabel: "删除分组",
    action: () => performTagCatalogMutation(
      `/v1/tag-groups/${group.id}/delete`,
      { operationID: crypto.randomUUID() },
      `已删除分组“${group.displayName}”`
    ),
    ...(returnFocus ? { returnFocus } : {}),
  });
}

async function undoLatestDecision(kind) {
  const channel = state.undo[kind];
  const undoID = channel?.id;
  if (!channel || !state.online || !undoID || channel.mutating) return;
  if (!channel.operationID) {
    channel.operationID = crypto.randomUUID();
  }
  const operationID = channel.operationID;
  const generation = state.workspaceGeneration;
  channel.mutating = true;
  syncWriteActionControls();
  try {
    const endpoint = kind === "review"
      ? "/v1/review/decisions/undo"
      : "/v1/tag-decisions/undo";
    const result = await api(endpoint, {
      method: "POST",
      body: JSON.stringify({ operationID, undoID }),
    });
    if (generation !== state.workspaceGeneration) return;
    channel.id = null;
    channel.operationID = null;
    if (state.toastUndoKind === kind) state.toastUndoKind = null;
    await refreshWorkspace({
      quiet: true,
      kinds: ["assetsChanged", "tagsChanged", "reviewChanged"],
    });
    if (kind === "review" && state.review.mode === "queue") {
      await loadReviewQueue({ preserveLoadedWindow: true });
    }
    toast(`已撤销 ${result.restoredAssetCount} 项${kind === "review" ? "审核" : "标签"}决定`);
  } catch (error) {
    if (generation === state.workspaceGeneration) {
      undoToast(error.message || "撤销失败，可重试", undoID, kind);
    }
  } finally {
    if (generation === state.workspaceGeneration) {
      channel.mutating = false;
      syncWriteActionControls();
    }
  }
}

function renderSources() {
  clearElement(elements.sourceList);
  elements.sourceEmpty.classList.toggle("hidden", state.sources.length > 0);

  for (const source of orderedSources()) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "sidebar-row";
    button.dataset.sourceId = source.id;
    button.draggable = true;
    button.setAttribute("aria-keyshortcuts", "Alt+ArrowUp Alt+ArrowDown");
    button.setAttribute("aria-haspopup", "menu");
    button.title = "拖动可调整顺序；右键或 Shift-F10 查看来源操作";
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

function focusSidebarSource(sourceID) {
  requestAnimationFrame(() => {
    elements.sourceList.querySelector(`[data-source-id="${CSS.escape(sourceID)}"]`)
      ?.focus({ preventScroll: true });
  });
}

function focusSidebarTag(tagID) {
  requestAnimationFrame(() => {
    elements.tagNavigation.querySelector(`[data-quick-tag-id="${CSS.escape(tagID)}"]`)
      ?.focus({ preventScroll: true });
  });
}

function focusTagOrderingSurface(tagID, surface = "sidebar") {
  if (surface === "sidebar") {
    focusSidebarTag(tagID);
    return;
  }
  // The selection aggregate request can repaint this surface shortly after a
  // drag completes. Keep recovering the same logical chip for a bounded
  // window so the later repaint neither drops keyboard focus nor makes the
  // next command target a detached element.
  let remainingFrames = 120;
  let hasRestored = false;
  const restore = () => {
    const container = surface === "selection"
      ? elements.selectionInspectorTags
      : elements.inspectorTags;
    const target = container.querySelector(
      `[data-tag-reorder-surface="${CSS.escape(surface)}"]`
        + `[data-tag-id="${CSS.escape(tagID)}"]`
    );
    const active = document.activeElement;
    if (hasRestored
      && active !== document.body
      && active !== document.documentElement
      && active !== target) return;
    if (target && active !== target) {
      target.focus({ preventScroll: true });
      hasRestored = true;
    }
    remainingFrames -= 1;
    if (remainingFrames > 0) requestAnimationFrame(restore);
  };
  requestAnimationFrame(restore);
}

function renderTagOrderingSurfaces(focusTagID = null, focusSurface = "sidebar") {
  renderTagSelects();
  if (state.selectionMode && state.selectedAssetIDs.size) {
    renderSelectionInspector();
  } else if (state.selectedDetail) {
    renderInspector(state.selectedDetail);
  }
  if (focusTagID) focusTagOrderingSurface(focusTagID, focusSurface);
}

function applySourceOrder(sourceIDs, focusSourceID) {
  state.layout.sourceOrderIDs = sourceIDs;
  persistWorkspacePreferences();
  renderSources();
  focusSidebarSource(focusSourceID);
}

function reorderSourceBefore(sourceID, beforeSourceID) {
  const ids = orderedSources().map((source) => source.id);
  const reordered = moveIDBefore(ids, sourceID, beforeSourceID);
  if (reordered.join("|") === ids.join("|")) return;
  applySourceOrder(reordered, sourceID);
}

function reorderSourceByOffset(sourceID, offset) {
  const ids = orderedSources().map((source) => source.id);
  const reordered = moveIDByOffset(ids, sourceID, offset);
  if (reordered.join("|") === ids.join("|")) return;
  applySourceOrder(reordered, sourceID);
}

function tagIDsForGroup(groupID) {
  return orderedTagsInGroup(
    activeTags().filter((tag) => (tag.groupID || "") === (groupID || "")),
    groupID || null
  ).map((tag) => tag.id);
}

function applyLocalTagOrder(groupID, ids) {
  state.layout.tagOrderIDsByGroup = {
    ...state.layout.tagOrderIDsByGroup,
    [tagOrderPreferenceKey(groupID)]: ids,
  };
  persistWorkspacePreferences();
}

function tagReorderSearchActive(surface) {
  if (surface === "single") return Boolean(state.inspectorTagSearchText.trim());
  if (surface === "selection") return Boolean(state.selectionTagSearchText.trim());
  return Boolean(elements.tagNavigationSearch.value.trim());
}

async function moveSidebarTag(
  tagID,
  targetGroupID,
  beforeTagID = null,
  focusSurface = "sidebar"
) {
  const tag = tagByID(tagID);
  if (!tag || state.tagManagementMutating || tagReorderSearchActive(focusSurface)) return;
  const currentGroupID = tag.groupID || "";
  const normalizedTargetGroupID = targetGroupID || "";
  if (currentGroupID === normalizedTargetGroupID) {
    const ids = tagIDsForGroup(currentGroupID);
    const reordered = moveIDBefore(ids, tagID, beforeTagID);
    if (reordered.join("|") === ids.join("|")) {
      focusTagOrderingSurface(tagID, focusSurface);
      return;
    }
    applyLocalTagOrder(currentGroupID, reordered);
    renderTagOrderingSurfaces(tagID, focusSurface);
    return;
  }
  const targetGroup = groupByID(normalizedTargetGroupID);
  if (!targetGroup) return;

  const previousOrders = structuredClone(state.layout.tagOrderIDsByGroup);
  const previousGroupID = currentGroupID;
  const sourceIDs = tagIDsForGroup(currentGroupID).filter((id) => id !== tagID);
  const targetIDs = moveIDBefore(tagIDsForGroup(normalizedTargetGroupID), tagID, beforeTagID);
  applyLocalTagOrder(currentGroupID, sourceIDs);
  applyLocalTagOrder(normalizedTargetGroupID, targetIDs);
  tag.groupID = normalizedTargetGroupID;
  renderTagOrderingSurfaces(tagID, focusSurface);

  const succeeded = await performTagCatalogMutation(
    `/v1/tags/${tag.id}/move`,
    { operationID: crypto.randomUUID(), groupID: normalizedTargetGroupID },
    `已将“${tag.displayName}”移动到“${targetGroup.displayName}”`
  );
  if (succeeded) {
    renderTagOrderingSurfaces(tagID, focusSurface);
    return;
  }
  const currentTag = tagByID(tagID);
  if (currentTag) currentTag.groupID = previousGroupID;
  state.layout.tagOrderIDsByGroup = previousOrders;
  persistWorkspacePreferences();
  renderTagOrderingSurfaces(tagID, focusSurface);
}

function reorderSidebarTagByOffset(tagID, offset, focusSurface = "sidebar") {
  const tag = tagByID(tagID);
  if (!tag || tagReorderSearchActive(focusSurface)) return;
  const groupID = tag.groupID || "";
  const ids = tagIDsForGroup(groupID);
  const reordered = moveIDByOffset(ids, tagID, offset);
  if (reordered.join("|") === ids.join("|")) return;
  applyLocalTagOrder(groupID, reordered);
  renderTagOrderingSurfaces(tagID, focusSurface);
}

function moveSidebarTagToAdjacentGroup(tagID, offset, focusSurface = "sidebar") {
  const tag = tagByID(tagID);
  if (!tag || tagReorderSearchActive(focusSurface)) return;
  const groups = orderedTagGroups();
  const currentIndex = groups.findIndex((group) => group.id === tag.groupID);
  const target = groups[currentIndex + offset];
  if (!target) return;
  moveSidebarTag(tagID, target.id, null, focusSurface);
}

function clearSidebarDropIndicators() {
  state.sidebarDrag.dropTarget?.classList.remove(
    "drop-before",
    "drop-after",
    "drag-over-group"
  );
  state.sidebarDrag.dropTarget = null;
  elements.sourceList.querySelectorAll(".drop-before, .drop-after").forEach((item) => {
    item.classList.remove("drop-before", "drop-after");
  });
  elements.tagNavigation.querySelectorAll(
    ".drop-before, .drop-after, .drag-over-group"
  ).forEach((item) => {
    item.classList.remove("drop-before", "drop-after", "drag-over-group");
  });
  [elements.inspectorTags, elements.selectionInspectorTags].forEach((container) => {
    container.querySelectorAll(
      ".drop-before, .drop-after, .drag-over-group"
    ).forEach((item) => {
      item.classList.remove("drop-before", "drop-after", "drag-over-group");
    });
  });
}

function sourceManagementActions(source) {
  const prewarm = ["active", "unavailable"].includes(source.state)
    ? ["prewarmThumbnails", "prewarmOriginalAspect"]
    : [];
  if (source.kind === "photos") {
    if (source.state === "active") {
      return [
        "syncPhotos",
        ...prewarm,
        "fullRepair",
        "requestPhotosWriteAuthorization",
        "delete",
      ];
    }
    if (source.state === "unavailable") return ["rebindPhotos", ...prewarm, "delete"];
    if (["authorizationRequired", "disabled"].includes(source.state)) {
      return ["reauthorize", "delete"];
    }
    return ["delete"];
  }
  if (source.state === "active") {
    return ["rescan", ...prewarm, "refreshFolderMutationAuthorization", "delete"];
  }
  if (source.state === "unavailable") {
    return ["reauthorize", ...prewarm, "delete"];
  }
  if (source.state === "authorizationRequired") {
    return ["reauthorize", "delete"];
  }
  return ["delete"];
}

function supportsGeneralSettings() {
  return state.capabilities?.capabilities?.includes("generalSettings") === true;
}

function supportsSourceManagement() {
  return state.capabilities?.capabilities?.includes("sourceManagement") === true;
}

function generalSettingsModelStateText(model) {
  return {
    disabled: "已关闭",
    validating: "正在校验",
    ready: "模型已就绪",
    unavailable: "模型不可用",
  }[model?.state] || "—";
}

function applyToolbarDisplayMode(mode) {
  const normalized = mode === "iconAndTitle" ? "iconAndTitle" : "iconOnly";
  elements.appView.dataset.toolbarDisplayMode = normalized;
  for (const button of elements.toolbarDisplayModeControl.querySelectorAll(
    "[data-toolbar-display-mode]"
  )) {
    const selected = button.dataset.toolbarDisplayMode === normalized;
    button.setAttribute("aria-checked", String(selected));
    button.tabIndex = selected ? 0 : -1;
  }
}

const suggestionThresholdMethodLabels = {
  featureKnn: "特征向量",
  personalCentroid: "个人模型",
  personalAdamW: "超级个人模型",
};

function formatSuggestionThreshold(value) {
  return Number.isFinite(Number(value)) ? Number(value).toFixed(2) : "0.00";
}

function suggestionThresholdSnapshot() {
  return state.generalSettings.snapshot?.suggestionThresholds || null;
}

function renderSuggestionThresholdDefaults(unavailable) {
  const thresholds = suggestionThresholdSnapshot();
  elements.generalSuggestionSection.classList.toggle("hidden", !thresholds);
  if (!thresholds) return;
  const defaults = new Map(thresholds.defaults.map((item) => [item.method, item.minScore]));
  for (const input of elements.generalSuggestionDefaults.querySelectorAll(
    "[data-suggestion-default]"
  )) {
    input.disabled = unavailable;
    if (document.activeElement !== input) {
      input.value = formatSuggestionThreshold(defaults.get(input.dataset.suggestionDefault));
    }
    input.dataset.persistedValue = formatSuggestionThreshold(
      defaults.get(input.dataset.suggestionDefault)
    );
  }
  const overrideCount = thresholds.tags.reduce(
    (count, tag) => count + tag.methods.filter((method) => method.overrideMinScore != null).length,
    0
  );
  elements.suggestionOverrideCount.textContent = String(overrideCount);
  elements.suggestionOverridesButton.disabled = unavailable;
}

function suggestionReferenceText(reference) {
  if (!reference) {
    return "暂无参考建议；至少需要同轨 5 个可追溯拒绝分数，或正负样本各 5 个。";
  }
  if (reference.acceptedSampleCount >= 5 && reference.rejectedSampleCount >= 5) {
    return `参考建议：${formatSuggestionThreshold(reference.minScore)}（${reference.acceptedSampleCount} 确认 / ${reference.rejectedSampleCount} 拒绝的中位分隔）`;
  }
  return `参考建议：${formatSuggestionThreshold(reference.minScore)}（最近 ${reference.rejectedSampleCount} 个拒绝分数的第 90 百分位）`;
}

function thresholdFocusSelector(target) {
  const control = target instanceof Element ? target.closest("[data-threshold-focus]") : null;
  if (!control) return null;
  return [
    control.dataset.thresholdFocus,
    control.dataset.thresholdTagId || "",
    control.dataset.thresholdMethod || "",
  ];
}

function restoreThresholdFocus(key) {
  if (!key) return;
  const [kind, tagID, method] = key;
  const selector = `[data-threshold-focus="${CSS.escape(kind)}"]`
    + `[data-threshold-tag-id="${CSS.escape(tagID)}"]`
    + `[data-threshold-method="${CSS.escape(method)}"]`;
  restoreOverlayFocus(elements.suggestionThresholdList.querySelector(selector));
}

function renderSuggestionThresholdDialog() {
  if (!elements.suggestionThresholdDialog.open) return;
  const manager = state.generalSettings;
  const thresholds = suggestionThresholdSnapshot();
  const unavailable = manager.loading || manager.submitting || !state.online || !thresholds;
  elements.suggestionThresholdDialog.setAttribute("aria-busy", String(manager.submitting));
  if (manager.submitting) {
    for (const control of elements.suggestionThresholdDialog.querySelectorAll("input, button")) {
      control.disabled = true;
    }
    return;
  }
  const focusKey = thresholdFocusSelector(document.activeElement)
    || manager.pendingThresholdFocus;
  const query = elements.suggestionThresholdSearch.value.trim().toLocaleLowerCase();
  const tags = (thresholds?.tags || []).filter(
    (tag) => !query || tag.displayName.toLocaleLowerCase().includes(query)
  );
  elements.suggestionThresholdSummary.textContent = thresholds
    ? `显示 ${tags.length} / ${thresholds.tags.length} 个活动标签`
    : "这台 Mac 暂未提供建议阈值设置。";
  elements.suggestionThresholdList.replaceChildren();
  elements.suggestionThresholdEmpty.classList.toggle("hidden", tags.length > 0);
  for (const tag of tags) {
    const card = document.createElement("section");
    card.className = "suggestion-threshold-card";
    const title = document.createElement("h3");
    title.textContent = tag.displayName;
    card.append(title);
    for (const method of tag.methods) {
      const block = document.createElement("div");
      block.className = "suggestion-threshold-method";
      const row = document.createElement("div");
      row.className = "suggestion-threshold-method-row";
      const label = document.createElement("label");
      label.textContent = suggestionThresholdMethodLabels[method.method] || method.method;
      const input = document.createElement("input");
      input.type = "number";
      input.inputMode = "decimal";
      input.step = "0.05";
      input.value = formatSuggestionThreshold(method.effectiveMinScore);
      input.dataset.persistedValue = input.value;
      input.disabled = unavailable;
      input.setAttribute("aria-label", `${tag.displayName} ${label.textContent}最低门槛`);
      input.dataset.thresholdFocus = "input";
      input.dataset.thresholdTagId = tag.tagID;
      input.dataset.thresholdMethod = method.method;
      label.append(input);
      const badge = document.createElement("span");
      badge.className = `threshold-source-badge${method.overrideMinScore == null ? " inherited" : ""}`;
      badge.textContent = method.overrideMinScore == null ? "继承默认" : "单独设置";
      row.append(label, badge);
      if (method.overrideMinScore != null) {
        const inherit = document.createElement("button");
        inherit.type = "button";
        inherit.className = "button button-small";
        inherit.textContent = "继承默认";
        inherit.disabled = unavailable;
        inherit.dataset.thresholdAction = "clearOverride";
        inherit.dataset.thresholdFocus = "inherit";
        inherit.dataset.thresholdTagId = tag.tagID;
        inherit.dataset.thresholdMethod = method.method;
        row.append(inherit);
      }
      const referenceRow = document.createElement("div");
      referenceRow.className = `suggestion-threshold-reference${method.reference ? "" : " unavailable"}`;
      const referenceText = document.createElement("span");
      referenceText.textContent = suggestionReferenceText(method.reference);
      referenceRow.append(referenceText);
      if (method.reference) {
        const adopt = document.createElement("button");
        adopt.type = "button";
        adopt.className = "button button-small";
        adopt.textContent = "采用";
        adopt.disabled = unavailable;
        adopt.dataset.thresholdAction = "setOverride";
        adopt.dataset.thresholdScore = String(method.reference.minScore);
        adopt.dataset.thresholdFocus = "adopt";
        adopt.dataset.thresholdTagId = tag.tagID;
        adopt.dataset.thresholdMethod = method.method;
        referenceRow.append(adopt);
      }
      block.append(row, referenceRow);
      card.append(block);
    }
    elements.suggestionThresholdList.append(card);
  }
  for (const control of [elements.suggestionThresholdSearch, elements.suggestionThresholdCloseButton]) {
    control.disabled = unavailable && control !== elements.suggestionThresholdCloseButton;
  }
  restoreThresholdFocus(focusKey);
}

function renderGeneralSettings() {
  const manager = state.generalSettings;
  const snapshot = manager.snapshot;
  const unavailable = manager.loading || !state.online || !snapshot;
  elements.generalSettingsDialog.setAttribute("aria-busy", String(manager.submitting));
  elements.generalSettingsLoading.classList.toggle("hidden", Boolean(snapshot) || !manager.loading);
  elements.generalSettingsContent.classList.toggle("hidden", !snapshot);
  for (const button of elements.toolbarDisplayModeControl.querySelectorAll("button")) {
    button.disabled = unavailable;
  }
  elements.generalSettingsModelToggle.disabled = unavailable;
  elements.generalSettingsPrewarmToggle.disabled = unavailable;
  renderSuggestionThresholdDefaults(unavailable);
  if (!snapshot) return;

  applyToolbarDisplayMode(snapshot.toolbarDisplayMode);
  const model = snapshot.localModel;
  elements.generalSettingsModelToggle.setAttribute("aria-checked", String(model.isEnabled));
  elements.generalSettingsModelState.textContent = generalSettingsModelStateText(model);
  elements.generalSettingsModelName.textContent = model.modelName;
  elements.generalSettingsModelRuntime.textContent = model.runtimeName;
  elements.generalSettingsModelDetail.textContent = model.detail;
  elements.generalSettingsPrewarmToggle.setAttribute(
    "aria-checked",
    String(snapshot.idleThumbnailPrewarmEnabled)
  );
  const minutes = Math.max(1, Math.round(snapshot.idleThresholdSeconds / 60));
  elements.generalSettingsPrewarmDetail.textContent =
    `连续 ${minutes} 分钟无操作后，会在后台预热缩略图、特征向量与本地模型嵌入缓存；任意操作立即让路给浏览。`;
  renderSuggestionThresholdDialog();
}

async function loadGeneralSettings({ quiet = false } = {}) {
  if (!supportsGeneralSettings()) return;
  const manager = state.generalSettings;
  if (manager.loading || manager.submitting) return;
  const generation = ++manager.requestGeneration;
  manager.loading = true;
  if (!quiet) elements.generalSettingsError.classList.add("hidden");
  renderGeneralSettings();
  try {
    const snapshot = await api("/v1/settings/general");
    if (generation !== manager.requestGeneration) return;
    manager.snapshot = snapshot;
    applyToolbarDisplayMode(snapshot.toolbarDisplayMode);
  } catch (error) {
    if (generation !== manager.requestGeneration) return;
    if (!quiet || elements.generalSettingsDialog.open) {
      elements.generalSettingsError.textContent = error.message || "无法读取 Mac 通用设置";
      elements.generalSettingsError.classList.remove("hidden");
    }
  } finally {
    if (generation === manager.requestGeneration) {
      manager.loading = false;
      renderGeneralSettings();
    }
  }
}

async function submitGeneralSettingsPatch(patch) {
  const manager = state.generalSettings;
  if (!state.online || manager.loading || manager.submitting || !manager.snapshot) return;
  const activeDefault = document.activeElement?.closest?.("[data-suggestion-default]");
  manager.pendingDefaultFocus = activeDefault?.dataset.suggestionDefault || null;
  manager.pendingThresholdFocus = thresholdFocusSelector(document.activeElement);
  manager.submitting = true;
  elements.generalSettingsError.classList.add("hidden");
  elements.suggestionThresholdError.classList.add("hidden");
  renderGeneralSettings();
  try {
    const response = await api("/v1/settings/general", {
      method: "PUT",
      body: JSON.stringify({ operationID: crypto.randomUUID(), ...patch }),
    });
    manager.snapshot = response.settings;
    applyToolbarDisplayMode(response.settings.toolbarDisplayMode);
  } catch (error) {
    const message = error.message || "Mac 未能保存通用设置";
    elements.generalSettingsError.textContent = message;
    elements.generalSettingsError.classList.remove("hidden");
    if (elements.suggestionThresholdDialog.open) {
      elements.suggestionThresholdError.textContent = message;
      elements.suggestionThresholdError.classList.remove("hidden");
    }
  } finally {
    manager.submitting = false;
    renderGeneralSettings();
    if (manager.pendingDefaultFocus) {
      restoreOverlayFocus(elements.generalSuggestionDefaults.querySelector(
        `[data-suggestion-default="${CSS.escape(manager.pendingDefaultFocus)}"]`
      ));
    }
    manager.pendingDefaultFocus = null;
    manager.pendingThresholdFocus = null;
  }
}

function commitSuggestionDefault(input) {
  const minScore = Number(input.value);
  if (!Number.isFinite(minScore)) {
    renderGeneralSettings();
    return;
  }
  input.value = formatSuggestionThreshold(minScore);
  if (input.value === input.dataset.persistedValue) return;
  submitGeneralSettingsPatch({
    suggestionThresholdMutation: {
      action: "setDefault",
      method: input.dataset.suggestionDefault,
      minScore,
    },
  });
}

function commitSuggestionOverride(input) {
  const minScore = Number(input.value);
  if (!Number.isFinite(minScore)) {
    renderSuggestionThresholdDialog();
    return;
  }
  input.value = formatSuggestionThreshold(minScore);
  if (input.value === input.dataset.persistedValue) return;
  submitGeneralSettingsPatch({
    suggestionThresholdMutation: {
      action: "setOverride",
      method: input.dataset.thresholdMethod,
      tagID: input.dataset.thresholdTagId,
      minScore,
    },
  });
}

function openSuggestionThresholdDialog() {
  if (!suggestionThresholdSnapshot() || state.generalSettings.submitting) return;
  state.generalSettings.thresholdReturnFocus = document.activeElement;
  elements.suggestionThresholdSearch.value = "";
  elements.suggestionThresholdError.classList.add("hidden");
  elements.suggestionThresholdDialog.showModal();
  renderSuggestionThresholdDialog();
  restoreOverlayFocus(elements.suggestionThresholdSearch);
}

function closeSuggestionThresholdDialog({ restoreFocus = true } = {}) {
  const returnFocus = state.generalSettings.thresholdReturnFocus;
  state.generalSettings.thresholdReturnFocus = null;
  if (elements.suggestionThresholdDialog.open) elements.suggestionThresholdDialog.close();
  if (restoreFocus) restoreOverlayFocus(returnFocus || elements.suggestionOverridesButton);
}

async function openGeneralSettings() {
  if (!state.online || !supportsGeneralSettings()) return;
  state.generalSettings.returnFocus = document.activeElement;
  elements.generalSettingsDialog.showModal();
  elements.generalSettingsError.classList.add("hidden");
  restoreOverlayFocus(elements.generalSettingsCloseButton);
  await loadGeneralSettings();
  const selected = elements.toolbarDisplayModeControl.querySelector('[aria-checked="true"]');
  restoreOverlayFocus(selected || elements.generalSettingsCloseButton);
}

function closeGeneralSettings({ restoreFocus = true } = {}) {
  if (elements.suggestionThresholdDialog.open) {
    closeSuggestionThresholdDialog({ restoreFocus: false });
  }
  state.generalSettings.requestGeneration += 1;
  state.generalSettings.loading = false;
  const returnFocus = state.generalSettings.returnFocus;
  state.generalSettings.returnFocus = null;
  if (elements.generalSettingsDialog.open) elements.generalSettingsDialog.close();
  if (restoreFocus) restoreOverlayFocus(returnFocus || elements.settingsButton);
}

function moveDialogButtonFocus(event, dialog) {
  if (isTextInputTarget(event.target)) return false;
  if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) {
    return false;
  }
  const buttons = [...dialog.querySelectorAll("button:not(:disabled)")]
    .filter((button) => button.offsetParent !== null);
  if (!buttons.length) return false;
  const currentIndex = Math.max(0, buttons.indexOf(document.activeElement));
  let nextIndex = currentIndex;
  if (event.key === "Home") nextIndex = 0;
  else if (event.key === "End") nextIndex = buttons.length - 1;
  else nextIndex = (currentIndex
    + (["ArrowLeft", "ArrowUp"].includes(event.key) ? -1 : 1)
    + buttons.length) % buttons.length;
  event.preventDefault();
  buttons[nextIndex].focus({ preventScroll: true });
  buttons[nextIndex].scrollIntoView({ block: "nearest" });
  return true;
}

function sourceManagementActionLabel(action) {
  return {
    rebindPhotos: "连接当前图库…",
    reauthorize: "重新授权…",
    rescan: "立即重扫",
    syncPhotos: "立即同步",
    fullRepair: "完整修复…",
    requestPhotosWriteAuthorization: "请求照片写入权限…",
    refreshFolderMutationAuthorization: "更新回收权限…",
    prewarmThumbnails: "预热缩略图缓存",
    prewarmOriginalAspect: "专门用于原比例的缓存",
    cancelPrewarm: "取消缓存预热",
    delete: "删除来源…",
  }[action] || action;
}

function sourceManagementIsPrewarmAction(action) {
  return ["prewarmThumbnails", "prewarmOriginalAspect"].includes(action);
}

function sourceManagementActiveRequest() {
  return (state.sourceManagement.snapshot?.requests || [])
    .find((request) => ["awaitingMac", "running"].includes(request.phase)) || null;
}

function sourceManagementHasActiveRequest() {
  return Boolean(sourceManagementActiveRequest());
}

function sourceManagementActionsForCurrentState(source) {
  const actions = sourceManagementActions(source);
  const active = sourceManagementActiveRequest();
  if (!active || active.sourceID !== source.id || !sourceManagementIsPrewarmAction(active.action)) {
    return actions;
  }
  return [
    "cancelPrewarm",
    ...actions.filter((action) => !sourceManagementIsPrewarmAction(action)),
  ];
}

function renderSourcePrewarmStatus() {
  const active = sourceManagementActiveRequest();
  const shows = Boolean(active && sourceManagementIsPrewarmAction(active.action));
  elements.sourcePrewarmStatusButton.classList.toggle("hidden", !shows);
  elements.sourcePrewarmStatusButton.disabled = !state.online;
  if (!shows) {
    elements.sourcePrewarmStatusLabel.textContent = "缓存";
    elements.sourcePrewarmStatusButton.removeAttribute("aria-label");
    return;
  }
  const hasProgress = Number.isInteger(active.completedCount)
    && Number.isInteger(active.totalCount);
  const progress = hasProgress ? ` ${active.completedCount}/${active.totalCount}` : "";
  elements.sourcePrewarmStatusLabel.textContent = `缓存${progress}`;
  elements.sourcePrewarmStatusButton.setAttribute(
    "aria-label",
    `${active.sourceDisplayName || "来源"}缩略图预热${progress}，打开来源管理`
  );
  elements.sourcePrewarmStatusButton.title = active.message || "查看来源缩略图预热";
}

function renderSourceManagement() {
  const manager = state.sourceManagement;
  const snapshot = manager.snapshot;
  const activeRequest = sourceManagementActiveRequest();
  const busy = manager.loading || manager.submitting || Boolean(activeRequest);
  elements.sourceConnectFolderButton.disabled = busy || !state.online;
  elements.sourceConnectPhotosButton.disabled = busy || !state.online || !snapshot?.canConnectPhotos;
  elements.sourceConnectPhotosButton.title = snapshot?.canConnectPhotos
    ? "在 Mac 上确认并请求 Apple Photos 权限"
    : "已有 Apple Photos 来源；请在对应来源上恢复或重新绑定";
  elements.sourceManagerRefreshButton.disabled = manager.loading;
  elements.sourceManagerPending.classList.toggle("hidden", !activeRequest);
  elements.sourceManagerPending.replaceChildren();
  if (activeRequest) {
    const copy = document.createElement("span");
    copy.textContent = `${activeRequest.message}（可切回网页等待，完成后会自动更新）`;
    elements.sourceManagerPending.append(copy);
    if (sourceManagementIsPrewarmAction(activeRequest.action)) {
      if (Number.isInteger(activeRequest.completedCount)
        && Number.isInteger(activeRequest.totalCount)) {
        const progress = document.createElement("progress");
        progress.className = "source-prewarm-progress";
        progress.max = Math.max(1, activeRequest.totalCount);
        progress.value = Math.min(activeRequest.completedCount, progress.max);
        progress.setAttribute(
          "aria-label",
          `缩略图预热 ${activeRequest.completedCount} / ${activeRequest.totalCount}`
        );
        elements.sourceManagerPending.append(progress);
        const counts = document.createElement("small");
        counts.textContent = `成功 ${activeRequest.warmedCount || 0} · 失败 ${activeRequest.failedCount || 0}`;
        elements.sourceManagerPending.append(counts);
      }
      const cancel = document.createElement("button");
      cancel.type = "button";
      cancel.className = "button button-small";
      cancel.dataset.sourcePendingAction = "cancelPrewarm";
      cancel.dataset.sourceId = activeRequest.sourceID || "";
      cancel.textContent = "取消";
      cancel.disabled = manager.submitting || !state.online;
      cancel.addEventListener("click", () => {
        submitSourceManagementAction("cancelPrewarm", activeRequest.sourceID);
      });
      elements.sourceManagerPending.append(cancel);
    }
  }
  renderSourcePrewarmStatus();

  clearElement(elements.sourceManagerList);
  const sources = snapshot?.sources || [];
  elements.sourceManagerEmpty.classList.toggle("hidden", sources.length > 0 || manager.loading);
  for (const source of sources) {
    const row = document.createElement("article");
    row.className = "source-manager-row";
    row.dataset.sourceManagerId = source.id;

    const identity = document.createElement("div");
    identity.className = "source-manager-identity";
    const icon = document.createElement("span");
    icon.className = "source-manager-icon";
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = sourceIcon(source.kind);
    const copy = document.createElement("div");
    const name = document.createElement("div");
    name.className = "source-manager-name";
    name.textContent = source.displayName;
    const status = document.createElement("div");
    status.className = "source-manager-state";
    status.textContent = `${source.kind === "photos" ? "Apple Photos" : "文件夹"} · ${sourceStateText(source.state) || "可用"}`;
    copy.append(name, status);
    identity.append(icon, copy);

    const actions = document.createElement("div");
    actions.className = "source-manager-actions";
    for (const action of sourceManagementActionsForCurrentState(source)) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `button button-small write-action${action === "delete" ? " button-danger" : ""}`;
      button.dataset.sourceAction = action;
      button.dataset.sourceId = source.id;
      button.textContent = sourceManagementActionLabel(action);
      const canCancelPrewarm = action === "cancelPrewarm"
        && activeRequest?.sourceID === source.id
        && sourceManagementIsPrewarmAction(activeRequest.action);
      button.disabled = !state.online
        || manager.submitting
        || (action === "cancelPrewarm" ? !canCancelPrewarm : busy);
      actions.append(button);
    }
    row.append(identity, actions);
    elements.sourceManagerList.append(row);
  }
}

function scheduleSourceManagementPoll() {
  clearTimeout(state.sourceManagement.pollTimer);
  state.sourceManagement.pollTimer = null;
  if (!sourceManagementHasActiveRequest()) return;
  state.sourceManagement.pollTimer = setTimeout(() => {
    loadSourceManagement({ quiet: true, notifyTerminal: true });
  }, 1_000);
}

async function loadSourceManagement({ quiet = false, notifyTerminal = false } = {}) {
  const manager = state.sourceManagement;
  if (manager.loading) return;
  const generation = ++manager.requestGeneration;
  const hadSnapshot = Boolean(manager.snapshot);
  manager.loading = !quiet;
  renderSourceManagement();
  try {
    const snapshot = await api("/v1/source-management");
    if (generation !== manager.requestGeneration) return;
    manager.snapshot = snapshot;
    const sourceProjectionChanged = projectionFingerprint(snapshot.sources)
      !== projectionFingerprint(state.sources);
    if (sourceProjectionChanged) {
      state.sources = snapshot.sources;
      if (state.selectedSourceID
        && !state.sources.some((source) => source.id === state.selectedSourceID)) {
        state.selectedSourceID = "";
        state.selectedAssetID = null;
        state.selectedDetail = null;
      }
      renderSources();
      updateLibraryTitle();
      refreshWorkspace({ quiet: true, kinds: ["sourcesChanged"] });
    }
    for (const request of snapshot.requests || []) {
      if (!["completed", "cancelled", "failed"].includes(request.phase)) continue;
      const firstSeen = !manager.seenTerminalRequestIDs.has(request.id);
      manager.seenTerminalRequestIDs.add(request.id);
      if (notifyTerminal && hadSnapshot && firstSeen) toast(request.message);
    }
  } catch (error) {
    if (!quiet) toast(error.message || "无法读取来源管理状态");
  } finally {
    if (generation === manager.requestGeneration) {
      manager.loading = false;
      renderSourceManagement();
      scheduleSourceManagementPoll();
    }
  }
}

async function openSourceManager() {
  if (!state.online) return;
  state.sourceManagerReturnFocus = document.activeElement;
  elements.sourceManagerDialog.showModal();
  state.sourceManagement.snapshot = null;
  restoreOverlayFocus(elements.sourceManagerCloseButton);
  await loadSourceManagement();
  restoreOverlayFocus(elements.sourceConnectFolderButton.disabled
    ? elements.sourceManagerCloseButton
    : elements.sourceConnectFolderButton);
}

function closeSourceManager({ restoreFocus = true } = {}) {
  clearTimeout(state.sourceManagement.pollTimer);
  state.sourceManagement.pollTimer = null;
  state.sourceManagement.requestGeneration += 1;
  state.sourceManagement.loading = false;
  const returnFocus = state.sourceManagerReturnFocus;
  state.sourceManagerReturnFocus = null;
  if (elements.sourceManagerDialog.open) elements.sourceManagerDialog.close();
  if (restoreFocus) restoreOverlayFocus(returnFocus || elements.sourceManagerButton);
  renderSourcePrewarmStatus();
  scheduleSourceManagementPoll();
}

async function submitSourceManagementAction(action, sourceID = null) {
  const manager = state.sourceManagement;
  const cancellingPrewarm = action === "cancelPrewarm";
  if (!state.online
    || manager.submitting
    || (sourceManagementHasActiveRequest() && !cancellingPrewarm)) return;
  manager.submitting = true;
  renderSourceManagement();
  try {
    const request = await api("/v1/source-management/requests", {
      method: "POST",
      body: JSON.stringify({ operationID: crypto.randomUUID(), action, sourceID }),
    });
    const snapshot = manager.snapshot || { sources: state.sources, canConnectPhotos: false, requests: [] };
    manager.snapshot = {
      ...snapshot,
      requests: [request, ...(snapshot.requests || []).filter((item) => item.id !== request.id)],
    };
    renderSourceManagement();
    if (["completed", "cancelled", "failed"].includes(request.phase)) {
      manager.seenTerminalRequestIDs.add(request.id);
      toast(request.message || "来源操作已结束");
    }
    scheduleSourceManagementPoll();
  } catch (error) {
    toast(error.message || "Mac 未能接收来源操作");
  } finally {
    manager.submitting = false;
    renderSourceManagement();
  }
}

function requestSourceManagementAction(action, sourceID) {
  const source = state.sourceManagement.snapshot?.sources
    ?.find((item) => item.id === sourceID);
  if (action !== "delete") {
    submitSourceManagementAction(action, sourceID || null);
    return;
  }
  requestConfirmation({
    title: `删除来源“${source?.displayName || ""}”？`,
    message: "网页提交后，Mac 还会再次确认。只删除 ImageAll 的来源记录、相关索引和 App 缓存；不会删除磁盘或 Apple Photos 中的原始媒体。",
    actionLabel: "交给 Mac 确认",
    action: () => submitSourceManagementAction(action, sourceID),
  });
}

function storageMaintenanceHasActiveRequest() {
  return (state.storageMaintenance.snapshot?.requests || [])
    .some((request) => ["awaitingMac", "running"].includes(request.phase));
}

function storageActionLabel(action) {
  return {
    exportPortableData: "导出用户数据",
    chooseExternalStorage: "选择外置存储",
    clearPreviewCache: "清理预览缓存",
    clearPhotosOriginals: "清理 Photos 原图副本",
  }[action] || action;
}

function storageRequestMark(phase) {
  return {
    awaitingMac: "◷",
    running: "↻",
    completed: "✓",
    cancelled: "−",
    failed: "!",
  }[phase] || "•";
}

function renderStorageMaintenance() {
  const manager = state.storageMaintenance;
  const snapshot = manager.snapshot;
  const activeRequest = snapshot?.requests?.find(
    (request) => ["awaitingMac", "running"].includes(request.phase)
  );
  const busy = manager.loading || manager.submitting || Boolean(activeRequest);
  const hasSnapshot = Boolean(snapshot);

  elements.storageLoading.classList.toggle("hidden", hasSnapshot || !manager.loading);
  elements.storageContent.classList.toggle("hidden", !hasSnapshot);
  elements.storageRefreshButton.disabled = manager.loading;
  for (const button of [
    elements.clearPreviewCacheButton,
    elements.clearPhotosOriginalsButton,
    elements.chooseExternalStorageButton,
    elements.exportPortableDataButton,
  ]) {
    button.disabled = busy || !state.online || !hasSnapshot;
  }
  elements.storagePending.classList.toggle("hidden", !activeRequest);
  elements.storagePending.textContent = activeRequest
    ? `${activeRequest.message}（完成 Mac 上的操作后，本页会自动更新）`
    : "";

  if (!snapshot) return;
  elements.previewCacheSize.textContent = formatFileSize(snapshot.previewCache.registeredBytes);
  elements.previewCacheEntries.textContent = `${snapshot.previewCache.entryCount.toLocaleString("zh-CN")} 条可重建记录`;
  elements.photosOriginalsSize.textContent = formatFileSize(snapshot.photosOriginals.registeredBytes);
  elements.photosOriginalsEntries.textContent = `${snapshot.photosOriginals.entryCount.toLocaleString("zh-CN")} 条 ImageAll 副本`;
  elements.appStorageKind.textContent = snapshot.appStorage.kind === "externalStorage"
    ? "外置存储" : "Mac 内置存储";
  if (snapshot.appStorage.requiresRestart) {
    const name = snapshot.appStorage.pendingExternalRootName;
    elements.appStorageDetail.textContent = name
      ? `已选择“${name}” · 重启 ImageAll 后迁移`
      : "已选择新的外置位置 · 重启 ImageAll 后迁移";
  } else {
    elements.appStorageDetail.textContent = snapshot.appStorage.kind === "externalStorage"
      ? "应用资料和缓存由 Mac 在外置位置管理"
      : "应用资料和缓存保留在这台 Mac";
  }
  elements.chooseExternalStorageButton.textContent = snapshot.appStorage.requiresRestart
    ? "重新选择外置位置…" : "选择外置存储位置…";

  clearElement(elements.storageHistory);
  const requests = (snapshot.requests || []).slice(0, 6);
  elements.storageHistorySection.classList.toggle("hidden", !requests.length);
  for (const request of requests) {
    const row = document.createElement("article");
    row.className = "storage-history-row";
    row.dataset.phase = request.phase;
    const mark = document.createElement("span");
    mark.className = "storage-history-mark";
    mark.textContent = storageRequestMark(request.phase);
    const message = document.createElement("span");
    message.className = "storage-history-message";
    message.textContent = request.message;
    message.title = `${storageActionLabel(request.action)}：${request.message}`;
    const time = document.createElement("small");
    time.textContent = formatDate(request.updatedAtMs);
    row.append(mark, message, time);
    elements.storageHistory.append(row);
  }
}

function scheduleStorageMaintenancePoll() {
  clearTimeout(state.storageMaintenance.pollTimer);
  state.storageMaintenance.pollTimer = null;
  if (!elements.storageDialog.open || !storageMaintenanceHasActiveRequest()) return;
  state.storageMaintenance.pollTimer = setTimeout(() => {
    loadStorageMaintenance({ quiet: true, notifyTerminal: true });
  }, 1_000);
}

async function loadStorageMaintenance({ quiet = false, notifyTerminal = false } = {}) {
  const manager = state.storageMaintenance;
  if (manager.loading) return;
  const generation = ++manager.requestGeneration;
  const hadSnapshot = Boolean(manager.snapshot);
  manager.loading = true;
  if (!quiet) elements.storageError.classList.add("hidden");
  renderStorageMaintenance();
  try {
    const snapshot = await api("/v1/storage-maintenance");
    if (generation !== manager.requestGeneration || !elements.storageDialog.open) return;
    manager.snapshot = snapshot;
    for (const request of snapshot.requests || []) {
      if (!["completed", "cancelled", "failed"].includes(request.phase)) continue;
      const firstSeen = !manager.seenTerminalRequestIDs.has(request.id);
      manager.seenTerminalRequestIDs.add(request.id);
      if (notifyTerminal && hadSnapshot && firstSeen) toast(request.message);
    }
  } catch (error) {
    if (generation !== manager.requestGeneration) return;
    elements.storageError.textContent = error.message || "无法读取 Mac 存储状态";
    elements.storageError.classList.remove("hidden");
  } finally {
    if (generation === manager.requestGeneration) {
      manager.loading = false;
      renderStorageMaintenance();
      scheduleStorageMaintenancePoll();
    }
  }
}

async function openStorageMaintenance() {
  if (!state.online) return;
  state.storageReturnFocus = document.activeElement;
  elements.storageDialog.showModal();
  state.storageMaintenance.snapshot = null;
  elements.storageError.classList.add("hidden");
  restoreOverlayFocus(elements.storageCloseButton);
  await loadStorageMaintenance();
  restoreOverlayFocus(elements.storageRefreshButton);
}

function closeStorageMaintenance({ restoreFocus = true } = {}) {
  clearTimeout(state.storageMaintenance.pollTimer);
  state.storageMaintenance.pollTimer = null;
  state.storageMaintenance.requestGeneration += 1;
  state.storageMaintenance.loading = false;
  const returnFocus = state.storageReturnFocus;
  state.storageReturnFocus = null;
  if (elements.storageDialog.open) elements.storageDialog.close();
  if (restoreFocus) restoreOverlayFocus(returnFocus || elements.storageButton);
}

async function submitStorageMaintenanceAction(action) {
  const manager = state.storageMaintenance;
  if (!state.online || manager.submitting || storageMaintenanceHasActiveRequest()) return;
  manager.submitting = true;
  elements.storageError.classList.add("hidden");
  renderStorageMaintenance();
  try {
    const request = await api("/v1/storage-maintenance/requests", {
      method: "POST",
      body: JSON.stringify({ operationID: crypto.randomUUID(), action }),
    });
    const snapshot = manager.snapshot;
    if (snapshot) {
      manager.snapshot = {
        ...snapshot,
        requests: [request, ...(snapshot.requests || []).filter((item) => item.id !== request.id)],
      };
    }
    renderStorageMaintenance();
    scheduleStorageMaintenancePoll();
  } catch (error) {
    elements.storageError.textContent = error.message || "Mac 未能接收存储操作";
    elements.storageError.classList.remove("hidden");
  } finally {
    manager.submitting = false;
    renderStorageMaintenance();
  }
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

function stopAssetHoverVideo(card = activeAssetHoverCard) {
  assetHoverVideoGeneration += 1;
  clearTimeout(assetHoverVideoTimer);
  assetHoverVideoTimer = null;
  if (!card) return;
  const video = card.querySelector(":scope > .asset-hover-video");
  if (video) {
    video.pause();
    video.removeAttribute("src");
    video.load();
    video.remove();
  }
  card.classList.remove("hover-video-loading", "hover-video-ready");
  if (activeAssetHoverCard === card) activeAssetHoverCard = null;
}

async function mountAssetHoverVideo(card, asset, generation) {
  if (generation !== assetHoverVideoGeneration || activeAssetHoverCard !== card) return;
  if (state.authMode === "account") {
    const workerReady = await updateMediaWorkerAuthorization(state.accountAuthorization);
    if (!workerReady
      || generation !== assetHoverVideoGeneration
      || activeAssetHoverCard !== card) {
      stopAssetHoverVideo(card);
      return;
    }
  }
  const video = document.createElement("video");
  video.className = "asset-hover-video";
  video.muted = true;
  video.defaultMuted = true;
  video.loop = true;
  video.playsInline = true;
  video.preload = "metadata";
  video.disableRemotePlayback = true;
  video.tabIndex = -1;
  video.setAttribute("aria-hidden", "true");
  video.addEventListener("loadeddata", () => {
    if (generation !== assetHoverVideoGeneration || activeAssetHoverCard !== card) return;
    card.classList.remove("hover-video-loading");
    card.classList.add("hover-video-ready");
    void video.play().catch(() => stopAssetHoverVideo(card));
  }, { once: true });
  video.addEventListener("error", () => {
    if (generation === assetHoverVideoGeneration && activeAssetHoverCard === card) {
      stopAssetHoverVideo(card);
    }
  }, { once: true });
  const revision = asset.contentRevision == null ? "" : `?r=${asset.contentRevision}`;
  video.src = `/v1/assets/${asset.id}/media${revision}`;
  card.insertBefore(video, card.querySelector(".asset-card-meta, .asset-video-badge"));
  video.load();
}

function beginAssetHoverVideo(card) {
  const asset = state.assets.find((item) => item.id === card?.dataset.assetId);
  const mediaKind = asset?.mediaKind || state.mediaKind;
  if (!asset
    || mediaKind !== "video"
    || asset.availability !== "available"
    || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
  const hoverKey = `${asset.id}:${asset.contentRevision ?? ""}`;
  if (activeAssetHoverCard === card
    && card.dataset.hoverVideoKey === hoverKey
    && card.querySelector(":scope > .asset-hover-video")) return;
  stopAssetHoverVideo();
  activeAssetHoverCard = card;
  card.dataset.hoverVideoKey = hoverKey;
  card.classList.add("hover-video-loading");
  const generation = ++assetHoverVideoGeneration;
  assetHoverVideoTimer = setTimeout(() => {
    assetHoverVideoTimer = null;
    void mountAssetHoverVideo(card, asset, generation);
  }, 180);
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

function syncAssetCardMediaBadge(button, asset) {
  const mediaKind = asset.mediaKind || state.mediaKind;
  let badge = button.querySelector(":scope > .asset-video-badge");
  if (mediaKind !== "video") {
    badge?.remove();
    return;
  }
  if (!badge) {
    badge = document.createElement("span");
    badge.className = "asset-video-badge";
    badge.setAttribute("aria-hidden", "true");
    button.append(badge);
  }
  badge.textContent = `▶${asset.durationMs == null ? "" : ` ${formatDuration(asset.durationMs)}`}`;
}

function syncAssetCard(button, asset) {
  const mediaKind = asset.mediaKind || state.mediaKind;
  const nextHoverKey = `${asset.id}:${asset.contentRevision ?? ""}`;
  if (activeAssetHoverCard === button && button.dataset.hoverVideoKey !== nextHoverKey) {
    stopAssetHoverVideo(button);
  }
  button.type = "button";
  button.className = "asset-card";
  if (activeAssetHoverCard === button) {
    const hoverVideo = button.querySelector(":scope > .asset-hover-video");
    button.classList.add(hoverVideo?.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
      ? "hover-video-ready"
      : "hover-video-loading");
  }
  button.dataset.assetId = asset.id;
  button.dataset.mediaKind = mediaKind;
  button.classList.toggle("selected", state.selectedAssetID === asset.id && !state.selectionMode);
  button.classList.toggle("batch-selected", state.selectedAssetIDs.has(asset.id));
  button.setAttribute(
    "aria-label",
    `${asset.fileName || (mediaKind === "video" ? "未命名视频" : "未命名照片")}，`
      + `${mediaKind === "video" ? "视频" : "照片"}，${asset.sourceName}，`
      + (mediaKind === "video" && asset.durationMs != null
        ? `时长 ${formatDuration(asset.durationMs)}，`
        : "")
      + `已确认 ${asset.acceptedTagCount} 个标签`
  );
  button.setAttribute(
    "aria-pressed",
    String(state.selectionMode
      ? state.selectedAssetIDs.has(asset.id)
      : state.selectedAssetID === asset.id)
  );
  button.title = [
    asset.fileName || (mediaKind === "video" ? "未命名视频" : "未命名照片"),
    `来源：${asset.sourceName}`,
    `媒体：${mediaKind === "video" ? "视频" : "照片"}`,
    mediaKind === "video" && asset.durationMs != null
      ? `时长：${formatDuration(asset.durationMs)}`
      : "",
    mediaKind === "video" ? "悬停静音播放；双击打开单图" : "双击打开单图",
    asset.width && asset.height ? `尺寸：${asset.width} × ${asset.height}` : "",
    `标签：已确认 ${asset.acceptedTagCount} · 已拒绝 ${asset.rejectedTagCount}`,
  ].filter(Boolean).join("\n");
  syncAssetCardImage(button, asset);
  syncAssetCardSelectionMark(button);
  syncAssetCardMeta(button, asset);
  syncAssetCardMediaBadge(button, asset);
}

function syncAssetCardPosition(button, index) {
  const currentButton = elements.assetGrid.children[index] || null;
  if (currentButton !== button) {
    elements.assetGrid.insertBefore(button, currentButton);
  }
}

function renderAssets() {
  renderLibraryEmptyState();
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
      if (activeAssetHoverCard === button) stopAssetHoverVideo(button);
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

function assetThumbnailPlaceholder(assetID) {
  const card = [...elements.assetGrid.querySelectorAll(":scope > .asset-card")]
    .find((candidate) => candidate.dataset.assetId === assetID);
  const thumbnail = card?.querySelector("img");
  if (!thumbnail?.complete || thumbnail.naturalWidth <= 0 || thumbnail.naturalHeight <= 0) {
    return null;
  }
  try {
    const canvas = document.createElement("canvas");
    canvas.width = thumbnail.naturalWidth;
    canvas.height = thumbnail.naturalHeight;
    canvas.getContext("2d")?.drawImage(thumbnail, 0, 0);
    return canvas.toDataURL("image/jpeg", 0.84);
  } catch {
    return null;
  }
}

function showPreviewPlaceholder(assetID) {
  const source = assetThumbnailPlaceholder(assetID);
  if (!source) {
    elements.previewPlaceholderImage.classList.add("hidden");
    elements.previewPlaceholderImage.removeAttribute("src");
    delete elements.previewPlaceholderImage.dataset.assetId;
    return false;
  }
  elements.previewPlaceholderImage.dataset.assetId = assetID;
  elements.previewPlaceholderImage.src = source;
  elements.previewPlaceholderImage.classList.remove("hidden");
  return true;
}

function hidePreviewPlaceholder() {
  elements.previewPlaceholderImage.classList.add("hidden");
  elements.previewPlaceholderImage.removeAttribute("src");
  delete elements.previewPlaceholderImage.dataset.assetId;
}

function resetCloudPreviewRecovery() {
  state.cloudPreview.requestGeneration += 1;
  state.cloudPreview.assetID = null;
  state.cloudPreview.status = "hidden";
  renderCloudPreviewRecovery();
}

function renderCloudPreviewRecovery() {
  const recovery = state.cloudPreview;
  const visible = recovery.status !== "hidden"
    && recovery.assetID === state.selectedDetail?.assetID
    && state.mediaKind === "image";
  elements.cloudPreviewRecovery.classList.toggle("hidden", !visible);
  if (!visible) return;

  const downloading = recovery.status === "downloading";
  const failed = recovery.status === "failed";
  elements.cloudPreviewIcon.classList.toggle("spinner", downloading);
  elements.cloudPreviewIcon.textContent = downloading ? "" : (failed ? "⚠︎" : "☁︎");
  elements.cloudPreviewTitle.textContent = downloading
    ? "正在从 iCloud 获取预览"
    : (failed ? "无法获取 iCloud 预览" : "此照片仅存储在 iCloud");
  elements.cloudPreviewMessage.textContent = downloading
    ? "只获取当前照片的标准预览；完成后会自动显示。"
    : (failed
      ? "请确认网络与“照片”访问权限后重试。"
      : "仅在你明确操作后，才会从 iCloud 获取这张照片的标准预览。");
  elements.cloudPreviewButton.classList.toggle("hidden", downloading);
  elements.cloudPreviewButton.textContent = failed ? "重试" : "从 iCloud 获取预览";
  elements.cloudPreviewButton.disabled = downloading || !state.online;
}

function showCloudPreviewRecovery(assetID, status = "available") {
  state.cloudPreview.requestGeneration += 1;
  state.cloudPreview.assetID = assetID;
  state.cloudPreview.status = status;
  elements.previewLoading.classList.add("hidden");
  elements.previewImage.classList.add("hidden");
  elements.openLightboxButton.classList.add("hidden");
  renderCloudPreviewRecovery();
}

async function downloadSelectedCloudPreview() {
  const detail = state.selectedDetail;
  if (!detail || state.mediaKind !== "image" || !state.online) return;
  const assetID = detail.assetID;
  const generation = ++state.cloudPreview.requestGeneration;
  state.cloudPreview.assetID = assetID;
  state.cloudPreview.status = "downloading";
  renderCloudPreviewRecovery();

  try {
    const response = await rawFetch(`/v1/assets/${assetID}/cloud-preview`, {
      method: "POST",
    });
    if (!response.ok) {
      const payload = await parseResponse(response).catch(() => null);
      throw new APIError(response.status, typeof payload === "object" ? payload : {
        message: `获取预览失败（${response.status}）`,
      });
    }
    // Consume and validate the response before reusing the ordinary local-only
    // preview route. The Host has atomically cached the bounded preview by now.
    const downloaded = await response.blob();
    if (!downloaded.type.startsWith("image/")) {
      throw new Error("Host 未返回可显示的预览");
    }
    if (generation !== state.cloudPreview.requestGeneration
      || state.selectedDetail?.assetID !== assetID) return;

    state.cloudPreview.status = "hidden";
    renderCloudPreviewRecovery();
    elements.previewLoading.classList.remove("hidden");
    const previewPath = `/v1/assets/${assetID}/preview?r=${detail.contentRevision}&cloud=1`;
    setProtectedImageSource(elements.previewImage, previewPath, {
      priority: "high",
      forceFetch: true,
    });
    toast("iCloud 预览已获取");
  } catch (error) {
    if (generation !== state.cloudPreview.requestGeneration
      || state.selectedDetail?.assetID !== assetID) return;
    state.cloudPreview.status = "failed";
    renderCloudPreviewRecovery();
    toast(error.message || "无法获取 iCloud 预览");
  }
}

function stopInspectorVideo() {
  elements.previewVideo.pause();
  elements.previewVideo.removeAttribute("src");
  elements.previewVideo.removeAttribute("poster");
  delete elements.previewVideo.dataset.assetId;
  delete elements.previewVideo.dataset.contentRevision;
  elements.previewVideo.load();
  elements.previewVideo.classList.add("hidden");
}

function stopLightboxVideo() {
  state.lightboxRequestGeneration += 1;
  elements.lightboxVideo.pause();
  elements.lightboxVideo.removeAttribute("src");
  elements.lightboxVideo.removeAttribute("poster");
  delete elements.lightboxVideo.dataset.assetId;
  delete elements.lightboxVideo.dataset.contentRevision;
  elements.lightboxVideo.load();
  elements.lightboxVideo.classList.add("hidden");
}

async function showInspectorVideo(detail) {
  const assetID = detail.assetID;
  const contentRevision = String(detail.contentRevision);
  if (elements.previewVideo.dataset.assetId === assetID
    && elements.previewVideo.dataset.contentRevision === contentRevision
    && elements.previewVideo.hasAttribute("src")
    && !elements.previewVideo.error) {
    elements.previewVideo.classList.remove("hidden");
    elements.previewLoading.classList.add("hidden");
    return;
  }
  stopInspectorVideo();
  clearProtectedImageSource(elements.previewImage);
  elements.previewImage.classList.add("hidden");
  elements.previewPlaceholderImage.classList.add("hidden");
  resetCloudPreviewRecovery();
  elements.openLightboxButton.classList.add("hidden");
  elements.previewLoading.classList.remove("hidden");

  const poster = assetThumbnailPlaceholder(assetID);
  if (poster) elements.previewVideo.poster = poster;
  elements.previewVideo.dataset.assetId = assetID;
  elements.previewVideo.dataset.contentRevision = contentRevision;
  if (state.authMode === "account") {
    const workerReady = await updateMediaWorkerAuthorization(state.accountAuthorization);
    if (!workerReady || state.selectedDetail?.assetID !== assetID) {
      if (state.selectedDetail?.assetID === assetID) {
        elements.previewLoading.classList.add("hidden");
        toast("当前浏览器无法建立视频播放通道");
      }
      return;
    }
  }
  if (state.selectedDetail?.assetID !== assetID) return;
  elements.previewVideo.src = `/v1/assets/${assetID}/media?r=${contentRevision}`;
  elements.previewVideo.classList.remove("hidden");
  elements.previewVideo.load();
}

function createInspectorTagChip({
  tagID,
  displayName,
  decision,
  summary = "",
  batch = false,
  disabled = false,
}) {
  const chip = document.createElement("button");
  chip.type = "button";
  chip.className = `inspector-tag-chip write-action${batch ? " batch" : ""}`;
  chip.dataset.tagChipAction = "accept";
  chip.dataset.tagId = tagID;
  chip.dataset.decision = decision;
  chip.setAttribute("aria-pressed", String(decision === "accepted"));
  chip.setAttribute(
    "aria-label",
    `${displayName}，${summary || ({ accepted: "已确认", rejected: "已拒绝", unknown: "未决定", mixed: "混合状态" }[decision] || decision)}；点击确认，右键清除`
  );
  chip.title = `点击确认“${displayName}”；右键清除`;
  chip.disabled = !state.online || state.tagMutating || disabled;
  const icon = document.createElement("span");
  icon.className = "inspector-tag-chip-icon";
  icon.setAttribute("aria-hidden", "true");
  icon.textContent = "#";
  const copy = document.createElement("span");
  copy.className = "inspector-tag-chip-copy";
  const name = document.createElement("strong");
  name.textContent = displayName;
  copy.append(name);
  if (summary) {
    const detail = document.createElement("small");
    detail.textContent = summary;
    copy.append(detail);
  }
  const marker = document.createElement("span");
  marker.className = "inspector-tag-chip-marker";
  marker.setAttribute("aria-hidden", "true");
  marker.textContent = { accepted: "✓", rejected: "×", mixed: "混" }[decision] || "";
  chip.append(icon, copy, marker);
  return chip;
}

function configureInspectorTagReordering(chip, surface, searchActive) {
  chip.dataset.tagReorderSurface = surface;
  chip.draggable = !searchActive
    && !state.tagManagementMutating
    && !state.tagMutating
    && !chip.disabled;
  chip.setAttribute(
    "aria-keyshortcuts",
    "Alt+ArrowUp Alt+ArrowDown Alt+ArrowLeft Alt+ArrowRight"
  );
  chip.title += searchActive
    ? "；清除标签搜索后可拖放排序"
    : "；拖动可排序或移动分组";
}

function inspectorTagFocusSelector(pending) {
  if (!pending) return null;
  if (pending.kind === "group") {
    return `[data-inspector-tag-group-toggle="${CSS.escape(pending.id)}"]`;
  }
  if (pending.kind === "decision") {
    return `[data-action="${CSS.escape(pending.action)}"]`
      + `[data-tag-id="${CSS.escape(pending.id)}"]`;
  }
  return `[data-tag-chip-action][data-tag-id="${CSS.escape(pending.id)}"]`;
}

function restoreInspectorTagFocus(surface) {
  const pending = state.pendingInspectorTagFocus;
  if (!pending || pending.surface !== surface) return;
  requestAnimationFrame(() => {
    const container = surface === "selection"
      ? elements.selectionInspectorTags
      : elements.inspectorTags;
    const selector = inspectorTagFocusSelector(pending);
    const target = selector ? container.querySelector(selector) : null;
    if (!target) return;
    target.focus({ preventScroll: true });
    if (document.activeElement === target) state.pendingInspectorTagFocus = null;
  });
}

function appendTagDecisionButtons(actions, tagID, states) {
  for (const [action, symbol, label, active] of [
    ["accept", "✓", "确认", states.accepted],
    ["reject", "×", "拒绝", states.rejected],
    ["clear", "−", "清除", states.unknown],
  ]) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "tag-action write-action";
    button.dataset.action = action;
    button.dataset.tagId = tagID;
    button.title = label;
    button.setAttribute("aria-label", label);
    button.setAttribute("aria-pressed", String(Boolean(active)));
    button.classList.toggle("active", Boolean(active));
    button.disabled = !state.online || state.tagMutating || Boolean(states.disabled);
    button.textContent = symbol;
    actions.append(button);
  }
}

function suggestionOriginText(origin) {
  return {
    featurePrint: "特征向量",
    standardModel: "标准模型",
    personalModel: "个人模型",
    personalAdamW: "超级个人模型",
  }[origin] || "模型建议";
}

function inspectorSuggestionKey(suggestion) {
  return `${suggestion.tagID}|${suggestion.suggestionOrigin}`;
}

function restoreInspectorSuggestionFocus(suggestions) {
  const pending = state.pendingInspectorSuggestionFocus;
  if (!pending) return;
  requestAnimationFrame(() => {
    let target = elements.inspectorSuggestions.querySelector(
      `[data-inspector-suggestion-key="${CSS.escape(pending.key)}"]`
        + `[data-action="${CSS.escape(pending.action)}"]`
    );
    if (!target && suggestions.length) {
      const index = Math.min(pending.index, suggestions.length - 1);
      const key = inspectorSuggestionKey(suggestions[index]);
      target = elements.inspectorSuggestions.querySelector(
        `[data-inspector-suggestion-key="${CSS.escape(key)}"]`
          + `[data-action="${CSS.escape(pending.action)}"]`
      );
    }
    if (!target) target = elements.inspectorSuggestionsTitle;
    target.focus({ preventScroll: true });
    if (document.activeElement === target) state.pendingInspectorSuggestionFocus = null;
  });
}

function renderInspectorSuggestions(detail) {
  const suggestions = detail.pendingSuggestions || [];
  const visible = state.inspectorSuggestionsExpanded ? suggestions : suggestions.slice(0, 5);
  elements.inspectorSuggestionsSection.classList.toggle("hidden", suggestions.length === 0);
  elements.inspectorSuggestionCount.textContent = suggestions.length ? String(suggestions.length) : "";
  clearElement(elements.inspectorSuggestions);

  for (const [index, suggestion] of visible.entries()) {
    const row = document.createElement("div");
    row.className = "inspector-suggestion-row";
    const copy = document.createElement("div");
    copy.className = "inspector-suggestion-copy";
    const name = document.createElement("strong");
    name.textContent = suggestion.displayName;
    const origin = document.createElement("span");
    origin.className = "inspector-suggestion-origin";
    origin.textContent = suggestionOriginText(suggestion.suggestionOrigin);
    copy.append(name, origin);

    const actions = document.createElement("div");
    actions.className = "inspector-suggestion-actions";
    actions.setAttribute("role", "group");
    actions.setAttribute("aria-label", `${suggestion.displayName} AI 建议`);
    const key = inspectorSuggestionKey(suggestion);
    for (const [action, label, className] of [
      ["accept", "属于", "accept"],
      ["reject", "不属于", "reject"],
    ]) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `button button-plain inspector-suggestion-action ${className} write-action`;
      button.dataset.action = action;
      button.dataset.tagId = suggestion.tagID;
      button.dataset.inspectorSuggestionKey = key;
      button.dataset.inspectorSuggestionIndex = String(index);
      button.disabled = !state.online || state.tagMutating;
      button.textContent = label;
      actions.append(button);
    }
    row.append(copy, actions);
    elements.inspectorSuggestions.append(row);
  }

  const remaining = suggestions.length - visible.length;
  elements.expandInspectorSuggestionsButton.classList.toggle(
    "hidden",
    state.inspectorSuggestionsExpanded || remaining <= 0
  );
  elements.expandInspectorSuggestionsButton.textContent = remaining > 0
    ? `另外 ${remaining} 条建议`
    : "";
  restoreInspectorSuggestionFocus(visible);
}

function renderInspector(detail) {
  if (state.selectedDetail?.assetID !== detail.assetID) {
    state.inspectorSuggestionsExpanded = false;
    state.pendingInspectorSuggestionFocus = null;
    resetCloudPreviewRecovery();
  }
  state.selectedDetail = detail;
  if (!state.inspectorDismissed) elements.inspector.classList.add("open");
  elements.assetFileName.textContent = detail.fileName || "未命名照片";
  renderInspectorSuggestions(detail);

  if (state.mediaKind === "video") {
    showInspectorVideo(detail);
  } else {
    stopInspectorVideo();
    elements.openLightboxButton.classList.remove("hidden");
    elements.previewImage.alt = detail.fileName || `所选${currentMediaNoun()}预览`;
    const previewPath = `/v1/assets/${detail.assetID}/preview?r=${detail.contentRevision}`;
    const previewReady = elements.previewImage.dataset.protectedPath === previewPath
      && elements.previewImage.hasAttribute("src")
      && elements.previewImage.dataset.protectedAssignedRequestId
        === elements.previewImage.dataset.protectedRequestId
      && elements.previewImage.complete
      && elements.previewImage.naturalWidth > 0;
    if (!previewReady) {
      const showsPlaceholder = showPreviewPlaceholder(detail.assetID);
      elements.previewLoading.classList.toggle("hidden", showsPlaceholder);
      elements.previewImage.classList.add("hidden");
      setProtectedImageSource(elements.previewImage, previewPath, {
        priority: "high",
        forceFetch: true,
      });
    } else {
      elements.previewLoading.classList.add("hidden");
      elements.previewImage.classList.remove("hidden");
      hidePreviewPlaceholder();
      resetCloudPreviewRecovery();
    }
  }

  clearElement(elements.assetMetadata);
  const isVideo = state.mediaKind === "video";
  const rows = [
    metadataRow("来源", detail.sourceName),
    metadataRow("相对位置", detail.relativePath),
    metadataRow("媒体", isVideo ? "视频" : "照片"),
    metadataRow("尺寸", detail.width && detail.height ? `${detail.width} × ${detail.height}` : "—"),
    ...(isVideo ? [metadataRow("时长", formatDuration(detail.durationMs))] : []),
    metadataRow("文件大小", formatFileSize(detail.fingerprintSizeBytes)),
    metadataRow("拍摄时间", formatDate(detail.mediaCreatedAtMs)),
    metadataRow("修改时间", formatDate(detail.mediaModifiedAtMs)),
    metadataRow("格式", detail.mediaType),
    metadataRow("状态", availabilityText(detail.availability)),
  ];
  for (const pair of rows) elements.assetMetadata.append(...pair);
  elements.openOriginalButtonLabel.textContent = isVideo
    ? "在 Mac 上用系统播放器打开"
    : "在 Mac 上用“预览”打开原图";
  elements.openOriginalButtonIcon.textContent = isVideo ? "▶" : "↗";
  elements.openOriginalButton.classList.remove("busy");
  elements.openOriginalHint.textContent = isVideo
    ? "以只读方式在运行 ImageAll 的这台 Mac 上播放原始视频"
    : "以只读方式在运行 ImageAll 的这台 Mac 上打开原始照片";
  elements.openOriginalButton.disabled = !state.online
    || detail.availability !== "available"
    || state.openingOriginal;

  clearElement(elements.inspectorTags);
  const tagQuery = state.inspectorTagSearchText.toLocaleLowerCase("zh-CN");
  const tags = detail.tags.filter((tag) => (
    tagByID(tag.tagID)?.state !== "archived"
      && (!tagQuery || tag.displayName.toLocaleLowerCase("zh-CN").includes(tagQuery))
  ));
  elements.tagEmpty.classList.toggle("hidden", tags.length > 0);
  elements.tagSummary.textContent = `已确认 ${detail.acceptedTagCount} · 已拒绝 ${detail.rejectedTagCount}`;

  appendInspectorTagGroups(elements.inspectorTags, tags, (parent, tag) => {
    const row = document.createElement("div");
    row.className = "tag-row";
    const chip = createInspectorTagChip({
      tagID: tag.tagID,
      displayName: tag.displayName,
      decision: tag.decision,
    });
    configureInspectorTagReordering(chip, "single", Boolean(tagQuery));
    const actions = document.createElement("div");
    actions.className = "tag-actions";
    actions.setAttribute("role", "group");
    actions.setAttribute("aria-label", `${tag.displayName} 标签决定`);
    appendTagDecisionButtons(actions, tag.tagID, {
      accepted: tag.decision === "accepted",
      rejected: tag.decision === "rejected",
      unknown: tag.decision === "unknown",
    });
    row.append(chip, actions);
    parent.append(row);
  });
  restoreInspectorTagFocus("single");
  updateInspectorNavigation();
  renderInspectorSurface();
}

async function openSelectedOriginalOnMac() {
  const detail = state.selectedDetail;
  if (!detail || detail.availability !== "available" || !state.online || state.openingOriginal) {
    return;
  }
  state.openingOriginal = true;
  elements.openOriginalButton.disabled = true;
  elements.openOriginalButton.classList.add("busy");
  elements.openOriginalButtonLabel.textContent = "正在 Mac 上打开…";
  try {
    await api(`/v1/assets/${detail.assetID}/open-original`, { method: "POST" });
    toast(state.mediaKind === "video" ? "已交给 Mac 系统播放器" : "已交给 Mac“预览”打开");
  } catch (error) {
    toast(error.message || "无法在 Mac 上打开原始文件");
  } finally {
    state.openingOriginal = false;
    if (state.selectedDetail?.assetID === detail.assetID) renderInspector(state.selectedDetail);
  }
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
  if (elements.selectionInspectorTags.dataset.activeTagDrag) {
    // Loading the batch aggregate must not replace the DOM node that currently
    // owns the native drag session. Apply the latest counts as soon as the drop
    // or cancellation ends.
    state.sidebarDrag.pendingSelectionRender = true;
    return;
  }
  state.sidebarDrag.pendingSelectionRender = false;
  const total = state.selectedAssetIDs.size;
  elements.selectionInspectorTitle.textContent = `已选择 ${mediaItemCountText(total)}`;
  clearElement(elements.selectionInspectorTags);
  const aggregates = new Map(
    state.selectionAggregates.map((aggregate) => [aggregate.tagID, aggregate])
  );
  const query = state.selectionTagSearchText.toLocaleLowerCase("zh-CN");
  const tags = orderedActiveTags().filter((tag) => (
    !query || tag.displayName.toLocaleLowerCase("zh-CN").includes(query)
  ));

  appendInspectorTagGroups(elements.selectionInspectorTags, tags, (parent, tag) => {
    const aggregate = aggregates.get(tag.id);
    const row = document.createElement("div");
    row.className = "selection-tag-row";
    const summary = state.loadingAggregate
      ? "正在统计…"
      : selectionAggregateText(aggregate, total);
    const decision = aggregate?.acceptedCount === total
      ? "accepted"
      : aggregate?.rejectedCount === total
        ? "rejected"
        : aggregate?.unknownCount === total
          ? "unknown"
          : "mixed";
    const chip = createInspectorTagChip({
      tagID: tag.id,
      displayName: tag.displayName,
      decision,
      summary,
      batch: true,
      // Reordering is independent from the aggregate counts. Leaving the chip
      // interactive while counts refresh prevents an in-flight aggregate
      // repaint from cancelling a drag that the user already started. The
      // explicit decision buttons remain disabled until the counts settle.
      disabled: !total,
    });
    configureInspectorTagReordering(chip, "selection", Boolean(query));

    const actions = document.createElement("div");
    actions.className = "tag-actions";
    actions.setAttribute("role", "group");
    actions.setAttribute("aria-label", `${tag.displayName} 批量标签决定`);
    appendTagDecisionButtons(actions, tag.id, {
      accepted: aggregate?.acceptedCount === total,
      rejected: aggregate?.rejectedCount === total,
      unknown: aggregate?.unknownCount === total,
      disabled: !total || state.loadingAggregate,
    });
    row.append(chip, actions);
    parent.append(row);
  });

  if (!tags.length) {
    const empty = document.createElement("p");
    empty.className = "sidebar-empty";
    empty.textContent = "没有匹配的标签";
    elements.selectionInspectorTags.append(empty);
  }
  restoreInspectorTagFocus("selection");
}

function renderInspectorSurface() {
  const showsSelection = state.selectionMode && state.selectedAssetIDs.size > 0;
  const showsDetail = !showsSelection && Boolean(state.selectedDetail);
  elements.inspectorPlaceholder.classList.toggle("hidden", showsSelection || showsDetail);
  elements.selectionInspector.classList.toggle("hidden", !showsSelection);
  elements.inspectorContent.classList.toggle("hidden", !showsDetail);
  if (!showsDetail) {
    hidePreviewPlaceholder();
    stopInspectorVideo();
    resetCloudPreviewRecovery();
  }
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

function filterMediaTypeText(mediaTypes) {
  const key = mediaTypes.join(",");
  return {
    "public.jpeg": "JPEG",
    "public.png": "PNG",
    "public.heic,public.heif": "HEIC / HEIF",
    "public.tiff": "TIFF",
    "org.webmproject.webp": "WebP",
    "com.compuserve.gif": "GIF",
    "public.mpeg-4,com.apple.quicktime-movie": "MP4 / MOV",
  }[key] || mediaTypes.join("、");
}

function activeFilterSummaryText() {
  const filters = state.filters;
  const positive = filters.tagConditions.filter(
    (condition) => condition.decision !== "excluded"
  );
  const separator = positive.length > 1
    ? (filters.tagMatchMode === "any" ? " 或 " : " 且 ")
    : " · ";
  const parts = filters.tagConditions.map((condition) => {
    const name = tagByID(condition.tagID)?.displayName || "未知标签";
    return `${name} ${filterDecisionText(condition.decision)}`;
  });
  let tagSummary = "";
  if (parts.length) {
    const positiveParts = filters.tagConditions
      .filter((condition) => condition.decision !== "excluded")
      .map((condition) => {
        const name = tagByID(condition.tagID)?.displayName || "未知标签";
        return `${name} ${filterDecisionText(condition.decision)}`;
      });
    const excludedParts = filters.tagConditions
      .filter((condition) => condition.decision === "excluded")
      .map((condition) => {
        const name = tagByID(condition.tagID)?.displayName || "未知标签";
        return `${name} ${filterDecisionText(condition.decision)}`;
      });
    tagSummary = [...(positiveParts.length ? [positiveParts.join(separator)] : []), ...excludedParts]
      .join(" · ");
  }
  const scopeSummary = {
    tagged: "仅已有标签",
    untagged: "仅无标签",
  }[filters.tagPresence];
  if (tagSummary) parts.splice(0, parts.length, tagSummary);
  else parts.length = 0;
  if (scopeSummary) parts.push(scopeSummary);
  if (filters.availability) parts.push(availabilityText(filters.availability));
  if (filters.mediaTypes.length) parts.push(filterMediaTypeText(filters.mediaTypes));
  return parts.join(" · ");
}

function renderActiveFilterBar() {
  const count = filterCount();
  const positiveTagCount = state.filters.tagConditions.filter(
    (condition) => condition.decision !== "excluded"
  ).length;
  elements.activeFilterBar.classList.toggle("hidden", count === 0);
  elements.activeFilterSummary.textContent = activeFilterSummaryText();
  elements.activeFilterRelation.classList.toggle("hidden", positiveTagCount < 2);
  for (const button of elements.activeFilterRelation.querySelectorAll("[data-active-filter-match]")) {
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.activeFilterMatch === state.filters.tagMatchMode)
    );
  }
  renderPersonalModelControls();
}

function libraryPersonalTrainingTagIDs() {
  return state.filters.tagConditions
    .filter((condition) => condition.decision === "accepted")
    .map((condition) => condition.tagID);
}

function renderPersonalModelControls() {
  const tagIDs = libraryPersonalTrainingTagIDs();
  const tagNames = tagIDs
    .map((tagID) => tagByID(tagID)?.displayName)
    .filter(Boolean);
  const noun = state.mediaKind === "video" ? "视频" : "照片";
  const scope = state.selectedAssetIDs.size
    ? `当前选择 ${state.selectedAssetIDs.size} 项`
    : `全库${noun}`;
  elements.personalModelScopeSummary.textContent = tagNames.length
    ? `${tagNames.join("、")} · ${scope}`
    : `请先选择已确认标签 · ${scope}`;
  const disabled = !state.online;
  elements.personalModelButton.disabled = disabled;
  elements.rebuildPersonalModelButton.disabled = disabled;
  elements.rebuildPersonalAdamWButton.disabled = disabled;
}

function closePersonalModelPopover({ restoreFocus = true } = {}) {
  const wasOpen = !elements.personalModelPopover.classList.contains("hidden");
  elements.personalModelPopover.classList.add("hidden");
  elements.personalModelButton.setAttribute("aria-expanded", "false");
  if (restoreFocus && wasOpen) restoreOverlayFocus(elements.personalModelButton);
}

function togglePersonalModelPopover() {
  const willOpen = elements.personalModelPopover.classList.contains("hidden");
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  closeJobsPopover({ restoreFocus: false });
  if (!willOpen) {
    closePersonalModelPopover();
    return;
  }
  renderPersonalModelControls();
  elements.personalModelPopover.classList.remove("hidden");
  elements.personalModelButton.setAttribute("aria-expanded", "true");
  requestAnimationFrame(() => {
    elements.personalModelPopover.querySelector("button:not(:disabled)")?.focus({ preventScroll: true });
  });
}

async function openLibraryPersonalTraining(method) {
  const tagIDs = libraryPersonalTrainingTagIDs();
  const selectedCount = state.selectedAssetIDs.size;
  const noun = state.mediaKind === "video" ? "视频" : "照片";
  state.training.mediaKind = state.mediaKind;
  closePersonalModelPopover({ restoreFocus: false });
  await openTrainingSetupDialog({
    method,
    tagIDs,
    requireExplicitTag: !tagIDs.length,
    scope: selectedCount ? "currentSelection" : "allSources",
    returnFocus: elements.personalModelButton,
    note: tagIDs.length
      ? `已从图库筛选带入 ${tagIDs.length} 个已确认标签；${selectedCount ? `只使用当前选中的 ${selectedCount} 项${noun}` : `使用全库已确认${noun}`}。`
      : "请选择要训练的标签；只会使用已确认样本。",
  });
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
  renderActiveFilterBar();
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
      undoToast(result.replayed ? "标签操作已恢复" : "标签已更新", result.undoID);
    } catch {
      if (generation !== state.workspaceGeneration) return;
      void refreshWorkspace({ quiet: true, kinds: ["assetsChanged"] });
      undoToast("标签已更新，界面同步暂时失败，正在重试", result.undoID);
    }
  } catch (error) {
    if (generation === state.workspaceGeneration) {
      toast(error.message || "标签更新失败");
    }
  } finally {
    if (generation === state.workspaceGeneration) {
      state.tagMutating = false;
      syncWriteActionControls();
      if (state.selectedDetail?.assetID === assetID && !state.selectionMode) {
        renderInspector(state.selectedDetail);
      }
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
      undoToast(
        `已新增标签“${result.displayName}”并应用到 ${mediaItemCountText(result.appliedAssetCount)}`,
        result.undoID
      );
    } catch {
      if (generation !== state.workspaceGeneration) return;
      closeNewTagDialog();
      void refreshWorkspace({
        quiet: true,
        kinds: ["tagsChanged", "assetsChanged"],
      });
      undoToast(
        `标签“${result.displayName}”已创建并应用，界面同步暂时失败，正在重试`,
        result.undoID
      );
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
  renderPersonalModelControls();
  renderEmbeddingPreparation();
  renderSampleSuggestions();
  if (updateInspector) renderInspectorSurface();
}

function activeEmbeddingPreparation() {
  return state.embeddingPreparation.activities.find((activity) => activity.phase === "running")
    || null;
}

function embeddingPreparationTerminalText(activity) {
  if (activity.phase === "cancelled") return "照片特征准备已停止";
  if (activity.phase === "failed") {
    return activity.errorCode === "modelUnavailable"
      ? "个人模型特征当前不可用"
      : "照片特征准备未完成";
  }
  const parts = [`新准备 ${activity.preparedCount || 0}`, `已有缓存 ${activity.cachedCount || 0}`];
  if (activity.cloudOnlyCount) parts.push(`仅云端 ${activity.cloudOnlyCount}`);
  if (activity.failedCount) parts.push(`失败 ${activity.failedCount}`);
  return `照片特征准备完成 · ${parts.join(" · ")}`;
}

function renderEmbeddingPreparation() {
  const preparation = state.embeddingPreparation;
  const activity = activeEmbeddingPreparation();
  const count = state.selectedAssetIDs.size;
  elements.prepareSelectedFeaturesButton.disabled = !state.online
    || !preparation.isAvailable
    || preparation.loading
    || preparation.submitting
    || Boolean(activity)
    || count === 0;
  elements.findSimilarSelectionButton.disabled = !state.online || count === 0;
  elements.prepareSelectedFeaturesButton.textContent = preparation.submitting
    ? "正在交给 Mac…"
    : "准备特征";
  elements.selectionInspectorPrepareFeaturesButton.disabled =
    elements.prepareSelectedFeaturesButton.disabled;
  elements.selectionInspectorFindSimilarButton.disabled =
    elements.findSimilarSelectionButton.disabled;
  elements.selectionInspectorPrepareFeaturesButton.textContent =
    elements.prepareSelectedFeaturesButton.textContent;
  elements.embeddingPreparationStatus.classList.toggle("hidden", !activity);
  elements.cancelEmbeddingPreparationButton.classList.toggle("hidden", !activity);
  elements.selectionInspectorToolStatus.classList.toggle("hidden", !activity);
  elements.selectionInspectorCancelPreparationButton.classList.toggle("hidden", !activity);
  elements.cancelEmbeddingPreparationButton.disabled = !state.online || preparation.cancelling;
  elements.selectionInspectorCancelPreparationButton.disabled =
    elements.cancelEmbeddingPreparationButton.disabled;
  elements.cancelEmbeddingPreparationButton.textContent = preparation.cancelling
    ? "正在停止…"
    : "停止准备";
  elements.selectionInspectorCancelPreparationButton.textContent = preparation.cancelling
    ? "正在停止…"
    : "停止";
  if (activity) {
    const status = `正在准备 ${activity.completedUnitCount}/${activity.totalUnitCount}`;
    elements.embeddingPreparationStatus.textContent = status;
    elements.selectionInspectorToolStatus.textContent = status;
  }
}

function scheduleEmbeddingPreparationPoll() {
  clearTimeout(state.embeddingPreparation.pollTimer);
  state.embeddingPreparation.pollTimer = null;
  if (!activeEmbeddingPreparation()) return;
  state.embeddingPreparation.pollTimer = setTimeout(
    () => loadEmbeddingPreparation({ quiet: true }),
    900
  );
}

async function loadEmbeddingPreparation({ quiet = false } = {}) {
  const preparation = state.embeddingPreparation;
  const generation = ++preparation.requestGeneration;
  const activeIDs = new Set(
    preparation.activities.filter((activity) => activity.phase === "running")
      .map((activity) => activity.operationID)
  );
  preparation.loading = true;
  try {
    const query = new URLSearchParams({ mediaKind: state.mediaKind });
    const snapshot = await api(`/v1/embedding-preparation?${query}`);
    if (generation !== preparation.requestGeneration) return;
    preparation.isAvailable = Boolean(snapshot.isAvailable);
    preparation.activities = snapshot.activities || [];
    const terminal = preparation.activities.find((activity) =>
      activeIDs.has(activity.operationID) && activity.phase !== "running"
    );
    if (terminal && !preparation.seenTerminalOperationIDs.has(terminal.operationID)) {
      preparation.seenTerminalOperationIDs.add(terminal.operationID);
      toast(embeddingPreparationTerminalText(terminal));
    }
  } catch (error) {
    if (generation === preparation.requestGeneration && !quiet) {
      toast(error.message || "无法读取照片特征状态");
    }
  } finally {
    if (generation === preparation.requestGeneration) {
      preparation.loading = false;
      renderEmbeddingPreparation();
      scheduleEmbeddingPreparationPoll();
    }
  }
}

async function prepareSelectedFeatures() {
  const preparation = state.embeddingPreparation;
  const assetIDs = [...state.selectedAssetIDs];
  if (!assetIDs.length || preparation.submitting || activeEmbeddingPreparation()) return;
  preparation.submitting = true;
  renderEmbeddingPreparation();
  try {
    const response = await api("/v1/embedding-preparation/requests", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        mediaKind: state.mediaKind,
        assetIDs,
      }),
    });
    preparation.activities = [
      response.activity,
      ...preparation.activities.filter(
        (activity) => activity.operationID !== response.activity.operationID
      ),
    ];
    toast(`已交给 Mac 准备 ${assetIDs.length} 项特征`);
  } catch (error) {
    toast(error.message || "无法准备所选项目特征");
  } finally {
    preparation.submitting = false;
    renderEmbeddingPreparation();
    scheduleEmbeddingPreparationPoll();
  }
}

async function cancelEmbeddingPreparation() {
  const preparation = state.embeddingPreparation;
  const activity = activeEmbeddingPreparation();
  if (!activity || preparation.cancelling) return;
  preparation.cancelling = true;
  renderEmbeddingPreparation();
  try {
    const response = await api(
      `/v1/embedding-preparation/requests/${activity.operationID}/actions`,
      { method: "POST", body: JSON.stringify({ action: "cancel" }) }
    );
    preparation.activities = preparation.activities.map((item) =>
      item.operationID === response.activity.operationID ? response.activity : item
    );
    state.embeddingPreparation.seenTerminalOperationIDs.add(response.activity.operationID);
    toast(embeddingPreparationTerminalText(response.activity));
  } catch (error) {
    toast(error.message || "无法停止照片特征准备");
  } finally {
    preparation.cancelling = false;
    renderEmbeddingPreparation();
    scheduleEmbeddingPreparationPoll();
  }
}

function activeSampleSuggestion() {
  return state.sampleSuggestions.activities.find((activity) => activity.phase === "running")
    || null;
}

function sampleSuggestionTerminalText(activity) {
  if (activity.phase === "cancelled") return "个人建议抽检已停止";
  if (activity.phase === "failed") {
    return {
      personalUnavailable: "还没有可用的个人模型，请先训练个人模型",
      modelUnavailable: "个人模型当前不可用",
      identityMismatch: "个人模型与当前图库不匹配，请重新训练",
      embeddingUnavailable: "照片特征准备失败",
    }[activity.errorCode] || "个人建议生成未完成";
  }
  return `已抽检 ${activity.totalUnitCount} 项 · 写入 ${activity.suggestedCount || 0} 条建议`
    + (activity.skippedCount ? ` · 跳过 ${activity.skippedCount}` : "");
}

function renderSampleSuggestions() {
  const suggestions = state.sampleSuggestions;
  const activity = activeSampleSuggestion();
  const selectedCount = state.selectedAssetIDs.size;
  const available = state.online
    && state.mediaKind === "image"
    && suggestions.isAvailable;
  const locked = suggestions.loading || suggestions.submitting || Boolean(activity);
  elements.generateSelectedSuggestionsButton.disabled = !available || locked || selectedCount === 0;
  elements.selectionInspectorGenerateSuggestionsButton.disabled =
    elements.generateSelectedSuggestionsButton.disabled;
  elements.generateLibrarySuggestionsButton.disabled = !available || locked;
  elements.generateSelectedSuggestionsButton.textContent = suggestions.submitting
    ? "正在交给 Mac…"
    : "生成建议";
  elements.selectionInspectorGenerateSuggestionsButton.textContent =
    elements.generateSelectedSuggestionsButton.textContent;
  elements.generateLibrarySuggestionsButton.textContent = suggestions.submitting
    ? "正在开始抽检…"
    : `抽 ${suggestions.maximumSampleCount} 张生成建议`;
  elements.cancelSampleSuggestionsButton.classList.toggle("hidden", !activity);
  elements.cancelSampleSuggestionsButton.disabled = !state.online || suggestions.cancelling;
  elements.cancelSampleSuggestionsButton.textContent = suggestions.cancelling
    ? "正在停止…"
    : "停止抽检";
  elements.sampleSuggestionReviewStatus.classList.toggle("hidden", !activity);
  if (activity) {
    const status = `Mac 正在抽检 ${activity.completedUnitCount}/${activity.totalUnitCount}`;
    elements.sampleSuggestionReviewStatus.textContent = status;
    if (!activeEmbeddingPreparation()) {
      elements.embeddingPreparationStatus.classList.remove("hidden");
      elements.embeddingPreparationStatus.textContent = status;
      elements.selectionInspectorToolStatus.classList.remove("hidden");
      elements.selectionInspectorToolStatus.textContent = status;
    }
  }
}

function scheduleSampleSuggestionPoll() {
  clearTimeout(state.sampleSuggestions.pollTimer);
  state.sampleSuggestions.pollTimer = null;
  if (!activeSampleSuggestion()) return;
  state.sampleSuggestions.pollTimer = setTimeout(
    () => loadSampleSuggestions({ quiet: true }),
    900
  );
}

async function loadSampleSuggestions({ quiet = false } = {}) {
  const suggestions = state.sampleSuggestions;
  const generation = ++suggestions.requestGeneration;
  const activeIDs = new Set(
    suggestions.activities.filter((activity) => activity.phase === "running")
      .map((activity) => activity.operationID)
  );
  suggestions.loading = true;
  try {
    const query = new URLSearchParams({ mediaKind: state.mediaKind });
    const snapshot = await api(`/v1/sample-suggestions?${query}`);
    if (generation !== suggestions.requestGeneration) return;
    suggestions.isAvailable = Boolean(snapshot.isAvailable);
    suggestions.maximumSampleCount = snapshot.maximumSampleCount || 500;
    suggestions.activities = snapshot.activities || [];
    const terminal = suggestions.activities.find((activity) =>
      activeIDs.has(activity.operationID) && activity.phase !== "running"
    );
    if (terminal && !suggestions.seenTerminalOperationIDs.has(terminal.operationID)) {
      suggestions.seenTerminalOperationIDs.add(terminal.operationID);
      toast(sampleSuggestionTerminalText(terminal));
      if (terminal.phase === "completed"
        && !elements.reviewWorkspace.classList.contains("hidden")) {
        await loadReviewOverview();
      }
    }
  } catch (error) {
    if (generation === suggestions.requestGeneration && !quiet) {
      toast(error.message || "无法读取个人建议抽检状态");
    }
  } finally {
    if (generation === suggestions.requestGeneration) {
      suggestions.loading = false;
      renderSampleSuggestions();
      scheduleSampleSuggestionPoll();
    }
  }
}

function selectedAssetIDsInGridOrder(limit) {
  const inGrid = state.assets
    .filter((asset) => state.selectedAssetIDs.has(asset.id))
    .map((asset) => asset.id);
  const included = new Set(inGrid);
  const remaining = [...state.selectedAssetIDs]
    .filter((assetID) => !included.has(assetID))
    .sort();
  return [...inGrid, ...remaining].slice(0, limit);
}

async function generateSampleSuggestions({ useSelection = false } = {}) {
  const suggestions = state.sampleSuggestions;
  const assetIDs = useSelection
    ? selectedAssetIDsInGridOrder(suggestions.maximumSampleCount)
    : [];
  if ((useSelection && !assetIDs.length)
    || suggestions.submitting
    || activeSampleSuggestion()) return;
  suggestions.submitting = true;
  renderSampleSuggestions();
  try {
    const response = await api("/v1/sample-suggestions/requests", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        mediaKind: state.mediaKind,
        assetIDs,
      }),
    });
    suggestions.activities = [
      response.activity,
      ...suggestions.activities.filter(
        (activity) => activity.operationID !== response.activity.operationID
      ),
    ];
    toast(useSelection
      ? `已交给 Mac 为 ${assetIDs.length} 项生成建议`
      : `已交给 Mac 抽取最多 ${suggestions.maximumSampleCount} 张生成建议`);
    await openReviewWorkspace();
  } catch (error) {
    toast(error.message || "无法开始个人建议抽检");
  } finally {
    suggestions.submitting = false;
    renderSampleSuggestions();
    scheduleSampleSuggestionPoll();
  }
}

async function cancelSampleSuggestions() {
  const suggestions = state.sampleSuggestions;
  const activity = activeSampleSuggestion();
  if (!activity || suggestions.cancelling) return;
  suggestions.cancelling = true;
  renderSampleSuggestions();
  try {
    const response = await api(
      `/v1/sample-suggestions/requests/${activity.operationID}/actions`,
      { method: "POST", body: JSON.stringify({ action: "cancel" }) }
    );
    suggestions.activities = suggestions.activities.map((item) =>
      item.operationID === response.activity.operationID ? response.activity : item
    );
    suggestions.seenTerminalOperationIDs.add(response.activity.operationID);
    toast(sampleSuggestionTerminalText(response.activity));
  } catch (error) {
    toast(error.message || "无法停止个人建议抽检");
  } finally {
    suggestions.cancelling = false;
    renderSampleSuggestions();
    scheduleSampleSuggestionPoll();
  }
}

function tagLibrarySuggestionActivities() {
  return state.tagLibrarySuggestions.snapshot?.activities || [];
}

function activeTagLibrarySuggestion(tagID = null) {
  const activePhases = new Set(["preparingCandidates", "scoring", "publishing"]);
  return tagLibrarySuggestionActivities().find((activity) =>
    activePhases.has(activity.phase) && (!tagID || activity.tagID === tagID)
  ) || null;
}

function tagLibrarySuggestionMethodText(method) {
  return method === "personalAdamW" ? "超级个人模型" : "个人模型";
}

function tagLibrarySuggestionPhaseText(activity) {
  const checked = activity.totalUnitCount > 0
    ? `${activity.completedUnitCount}/${activity.totalUnitCount}`
    : `${activity.completedUnitCount}`;
  return {
    preparingCandidates: "正在整理未审核照片…",
    scoring: `正在评分 ${checked}`,
    publishing: `正在写入 ${activity.aboveThresholdCount} 条候选…`,
    completed: `已检查 ${activity.totalUnitCount} 项 · 写入 ${activity.insertedCount} 条`,
    failed: "生成未完成",
    cancelled: "已停止",
  }[activity.phase] || "正在处理…";
}

function tagLibrarySuggestionTerminalText(activity) {
  if (activity.phase === "cancelled") {
    return `${tagLibrarySuggestionMethodText(activity.method)}扫描已停止`;
  }
  if (activity.phase === "failed") {
    const reason = {
      noCandidates: "没有需要扫描的照片",
      personalUnavailable: "还没有可用的个人模型",
      tagNotInPersonalModel: "这个标签尚未进入个人模型",
      modelUnavailable: "个人模型当前不可用",
      identityMismatch: "个人模型与当前图库不匹配，请重新训练",
      activeConflict: "另一个个人模型任务仍在运行",
    }[activity.errorCode] || "请在 Mac 端检查模型状态";
    return `${tagLibrarySuggestionMethodText(activity.method)}生成未完成：${reason}`;
  }
  return `${tagLibrarySuggestionMethodText(activity.method)}已检查 ${activity.totalUnitCount} 项`
    + ` · 超过阈值 ${activity.aboveThresholdCount} 项 · 写入 ${activity.insertedCount} 条`
    + (activity.skippedCount ? ` · 跳过 ${activity.skippedCount}` : "");
}

function tagLibrarySuggestionOption(tagID) {
  return state.tagLibrarySuggestions.snapshot?.tags?.find((option) => option.tagID === tagID)
    || null;
}

function tagLibrarySuggestionThreshold(option, method) {
  if (!option) return null;
  return method === "personalAdamW"
    ? option.personalAdamWMinScore
    : option.personalCentroidMinScore;
}

function activeTagSuggestionSources() {
  return state.sources.filter((source) => source.state === "active");
}

function renderTagSuggestionDialog() {
  const suggestions = state.tagLibrarySuggestions;
  const dialog = suggestions.dialog;
  const tag = tagByID(dialog.tagID);
  const option = tagLibrarySuggestionOption(dialog.tagID);
  const threshold = tagLibrarySuggestionThreshold(option, dialog.method);
  const sources = activeTagSuggestionSources();
  const validSourceIDs = new Set(sources.map((source) => source.id));
  dialog.selectedSourceIDs = new Set(
    [...dialog.selectedSourceIDs].filter((sourceID) => validSourceIDs.has(sourceID))
  );

  elements.tagSuggestionDialogTitle.textContent = tag
    ? `为“${tag.displayName}”生成建议`
    : "生成标签建议";
  elements.tagSuggestionDialogSubtitle.textContent =
    "使用这台 Mac 上已训练的个人模型扫描所选来源。";
  elements.tagSuggestionMethodSummary.textContent = tagLibrarySuggestionMethodText(dialog.method);
  elements.tagSuggestionLimitSummary.textContent =
    `Top ${suggestions.snapshot?.maximumPendingCount || 500}`;
  elements.tagSuggestionThresholdSummary.textContent = Number.isFinite(threshold)
    ? threshold.toFixed(3)
    : "由 Mac 设置";
  elements.tagSuggestionSelectionSummary.textContent =
    `已选择 ${dialog.selectedSourceIDs.size} 个来源`;

  clearElement(elements.tagSuggestionSourceOptions);
  for (const source of sources) {
    const label = document.createElement("label");
    label.className = "tag-suggestion-source-option";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.value = source.id;
    input.checked = dialog.selectedSourceIDs.has(source.id);
    input.disabled = suggestions.submitting;
    const name = document.createElement("span");
    name.textContent = source.displayName;
    label.append(input, name);
    elements.tagSuggestionSourceOptions.append(label);
  }

  const locked = suggestions.submitting || suggestions.loading;
  elements.selectAllTagSuggestionSourcesButton.disabled = locked || sources.length === 0;
  elements.clearTagSuggestionSourcesButton.disabled = locked || dialog.selectedSourceIDs.size === 0;
  elements.launchTagSuggestionButton.disabled = !state.online
    || locked
    || !tag
    || !option?.personalEligible
    || !Number.isFinite(threshold)
    || dialog.selectedSourceIDs.size === 0
    || Boolean(activeTagLibrarySuggestion());
  elements.launchTagSuggestionButton.textContent = suggestions.submitting
    ? "正在交给 Mac…"
    : "开始扫描";
}

function closeTagSuggestionDialog() {
  if (!elements.tagSuggestionDialog.open) return;
  elements.tagSuggestionDialog.close();
  const returnFocus = state.tagLibrarySuggestions.dialog.returnFocus;
  state.tagLibrarySuggestions.dialog.returnFocus = null;
  restoreOverlayFocus(returnFocus);
}

function openTagSuggestionDialog(tagID, method, returnFocus = null) {
  const suggestions = state.tagLibrarySuggestions;
  const option = tagLibrarySuggestionOption(tagID);
  const available = method === "personalAdamW"
    ? suggestions.snapshot?.personalAdamWAvailable
    : suggestions.snapshot?.personalCentroidAvailable;
  if (!option?.personalEligible || !available || activeTagLibrarySuggestion()) return;
  const selectedSourceIDs = elements.reviewCurrentSourceOnly.checked && state.selectedSourceID
    ? new Set([state.selectedSourceID])
    : new Set(activeTagSuggestionSources().map((source) => source.id));
  suggestions.dialog.tagID = tagID;
  suggestions.dialog.method = method;
  suggestions.dialog.selectedSourceIDs = selectedSourceIDs;
  suggestions.dialog.returnFocus = returnFocus || document.activeElement;
  elements.tagSuggestionError.textContent = "";
  renderTagSuggestionDialog();
  elements.tagSuggestionDialog.showModal();
  requestAnimationFrame(() => elements.closeTagSuggestionDialogButton.focus({ preventScroll: true }));
}

function scheduleTagLibrarySuggestionPoll() {
  clearTimeout(state.tagLibrarySuggestions.pollTimer);
  state.tagLibrarySuggestions.pollTimer = null;
  if (!activeTagLibrarySuggestion()) return;
  state.tagLibrarySuggestions.pollTimer = setTimeout(
    () => loadTagLibrarySuggestions({ quiet: true }),
    900
  );
}

async function loadTagLibrarySuggestions({ quiet = false } = {}) {
  const suggestions = state.tagLibrarySuggestions;
  const generation = ++suggestions.requestGeneration;
  const activeIDs = new Set(tagLibrarySuggestionActivities()
    .filter((activity) => activeTagLibrarySuggestion(activity.tagID)?.operationID === activity.operationID)
    .map((activity) => activity.operationID));
  suggestions.loading = true;
  try {
    const query = new URLSearchParams({ mediaKind: state.mediaKind });
    const snapshot = await api(`/v1/tag-library-suggestions?${query}`);
    if (generation !== suggestions.requestGeneration) return;
    suggestions.snapshot = snapshot;
    const terminal = (snapshot.activities || []).find((activity) =>
      activeIDs.has(activity.operationID)
      && !["preparingCandidates", "scoring", "publishing"].includes(activity.phase)
    );
    if (terminal && !suggestions.seenTerminalOperationIDs.has(terminal.operationID)) {
      suggestions.seenTerminalOperationIDs.add(terminal.operationID);
      toast(tagLibrarySuggestionTerminalText(terminal));
      if (!elements.reviewWorkspace.classList.contains("hidden")) {
        await loadReviewOverview();
        if (terminal.phase === "completed" && terminal.insertedCount > 0) {
          await enterReviewQueue(terminal.tagID);
        }
      }
    }
  } catch (error) {
    if (generation === suggestions.requestGeneration && !quiet) {
      toast(error.message || "无法读取按标签生成建议状态");
    }
  } finally {
    if (generation === suggestions.requestGeneration) {
      suggestions.loading = false;
      renderReviewOverview();
      if (elements.tagSuggestionDialog.open) renderTagSuggestionDialog();
      scheduleTagLibrarySuggestionPoll();
    }
  }
}

async function generateTagLibrarySuggestions() {
  const suggestions = state.tagLibrarySuggestions;
  const dialog = suggestions.dialog;
  if (suggestions.submitting || !dialog.tagID || !dialog.selectedSourceIDs.size) return;
  suggestions.submitting = true;
  elements.tagSuggestionError.textContent = "";
  renderTagSuggestionDialog();
  try {
    const response = await api("/v1/tag-library-suggestions/requests", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        mediaKind: state.mediaKind,
        method: dialog.method,
        tagID: dialog.tagID,
        sourceIDs: [...dialog.selectedSourceIDs].sort(),
      }),
    });
    suggestions.snapshot = {
      ...suggestions.snapshot,
      activities: [
        response.activity,
        ...tagLibrarySuggestionActivities().filter(
          (activity) => activity.operationID !== response.activity.operationID
        ),
      ],
    };
    closeTagSuggestionDialog();
    toast(`已交给 Mac 用${tagLibrarySuggestionMethodText(dialog.method)}扫描所选来源`);
  } catch (error) {
    elements.tagSuggestionError.textContent = error.message || "无法开始生成标签建议";
  } finally {
    suggestions.submitting = false;
    renderReviewOverview();
    if (elements.tagSuggestionDialog.open) renderTagSuggestionDialog();
    scheduleTagLibrarySuggestionPoll();
  }
}

async function cancelTagLibrarySuggestions(operationID) {
  const suggestions = state.tagLibrarySuggestions;
  if (!operationID || suggestions.cancellingIDs.has(operationID)) return;
  suggestions.cancellingIDs.add(operationID);
  renderReviewOverview();
  try {
    const response = await api(
      `/v1/tag-library-suggestions/requests/${operationID}/actions`,
      { method: "POST", body: JSON.stringify({ action: "cancel" }) }
    );
    suggestions.snapshot = {
      ...suggestions.snapshot,
      activities: tagLibrarySuggestionActivities().map((activity) =>
        activity.operationID === operationID ? response.activity : activity
      ),
    };
    suggestions.seenTerminalOperationIDs.add(operationID);
    toast(tagLibrarySuggestionTerminalText(response.activity));
  } catch (error) {
    toast(error.message || "无法停止按标签生成建议");
  } finally {
    suggestions.cancellingIDs.delete(operationID);
    renderReviewOverview();
    scheduleTagLibrarySuggestionPoll();
  }
}

async function findSimilarFromSelection() {
  const seedAssetIDs = [...state.selectedAssetIDs];
  if (!seedAssetIDs.length || !state.online) return;
  state.slimming.mediaKind = state.mediaKind;
  elements.findSimilarSelectionButton.disabled = true;
  try {
    const result = await api("/v1/library-slimming/launch", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        mediaKind: state.mediaKind,
        mode: "seeds",
        sourceIDs: null,
        seedAssetIDs,
        filter: currentSlimmingFilterRequest(),
      }),
    });
    state.slimming.selectedJobID = result.jobID;
    toast(`正在从所选 ${seedAssetIDs.length} 项查找相似内容`);
    await openSlimmingWorkspace();
    await loadSlimmingWorkspace({ jobID: result.jobID, quiet: true });
  } catch (error) {
    toast(error.message || "无法从所选项目查找相似内容");
  } finally {
    renderEmbeddingPreparation();
  }
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

async function applyBatchTagDecision(action, requestedTagID = null) {
  const tagID = requestedTagID || elements.batchTagSelect.value;
  const assetIDs = [...state.selectedAssetIDs];
  if (!state.online || !tagID || !assetIDs.length || state.tagMutating) return;
  const generation = state.workspaceGeneration;
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
      undoToast(`已更新 ${result.appliedAssetCount} 项`, result.undoID);
    } catch {
      if (generation !== state.workspaceGeneration) return;
      void refreshWorkspace({
        quiet: true,
        kinds: ["tagsChanged", "assetsChanged"],
      });
      undoToast(
        `已更新 ${result.appliedAssetCount} 项，界面同步暂时失败，正在重试`,
        result.undoID
      );
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
      if (state.selectionMode && state.selectedAssetIDs.size) renderSelectionInspector();
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
  if (job?.state === "running" && job.controlRequest === "pause") return "正在暂停";
  if (job?.state === "running" && job.controlRequest === "cancel") return "正在取消";
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

function jobFailureGuidance(job) {
  const guidance = {
    interrupted: "Mac 上次退出时任务被中断；继续后会从已保存进度恢复。",
    attemptsExhausted: "已达到最大尝试次数；请检查来源状态，再删除记录并重新分析。",
    librarySlimmingAnalysisFailed: "分析遇到可恢复错误；可继续任务并沿用已保存进度。",
    librarySlimmingSourceIndexFailed: "来源索引构建失败；请确认来源在线后重试。",
    folderAuthorizationRequired: "文件夹授权已失效；请先在来源管理中重新授权。",
    folderSourceUnavailable: "文件夹来源当前不可用；重新连接磁盘或来源后再继续。",
    photosAuthorizationRequired: "照片图库授权不足；请在 Mac 系统设置中允许照片访问。",
    photosSourceUnavailable: "照片图库当前不可用；请确认系统照片图库可访问。",
  };
  return guidance[job?.lastErrorCode]
    || (job?.state === "retryableFailed" ? "任务可安全重试，并会尽量沿用已保存进度。" : "请在 Mac 端检查来源和任务状态。");
}

function jobActionText(action) {
  return { pause: "暂停", resume: "继续", cancel: "取消" }[action] || action;
}

function jobRows() {
  return [...elements.jobsList.querySelectorAll("[data-job-row-id]")];
}

function selectJobRow(jobID, { focus = false } = {}) {
  if (!state.jobs.some((job) => job.id === jobID)) return;
  state.focusedActivityJobID = jobID;
  for (const row of jobRows()) {
    const selected = row.dataset.jobRowId === jobID;
    row.classList.toggle("focused", selected);
    if (selected) row.setAttribute("aria-current", "true");
    else row.removeAttribute("aria-current");
    row.tabIndex = selected ? 0 : -1;
  }
  if (focus) {
    requestAnimationFrame(() => {
      elements.jobsList.querySelector(
        `[data-job-row-id="${CSS.escape(jobID)}"]`
      )?.focus({ preventScroll: true });
    });
  }
}

function moveJobSelection(key) {
  const rows = jobRows();
  if (!rows.length) return;
  const current = Math.max(
    0,
    rows.findIndex((row) => row.dataset.jobRowId === state.focusedActivityJobID)
  );
  const next = key === "Home"
    ? 0
    : key === "End"
      ? rows.length - 1
      : Math.max(0, Math.min(rows.length - 1, current + (key === "ArrowUp" ? -1 : 1)));
  selectJobRow(rows[next].dataset.jobRowId, { focus: true });
  rows[next].scrollIntoView({ block: "nearest" });
}

function closeJobsPopover({ restoreFocus = true } = {}) {
  elements.jobsPopover.classList.add("hidden");
  const returnFocus = state.jobsReturnFocus;
  const returnTarget = state.jobsReturnTarget;
  state.jobsReturnFocus = null;
  state.jobsReturnTarget = null;
  if (!restoreFocus) return;
  const resolveReturnFocus = () => {
    const target = returnTarget?.trainingRunID
      ? elements.trainingRunList.querySelector(
        `[data-training-run-id="${CSS.escape(returnTarget.trainingRunID)}"]`
      )
      : (returnTarget?.reviewTrainingJobID
        ? elements.reviewOverviewGrid.querySelector(
          `[data-review-training-job-id="${CSS.escape(returnTarget.reviewTrainingJobID)}"]`
        )
        : (returnTarget?.slimmingJobID
          ? elements.slimmingJobList.querySelector(
            `[data-slimming-job-id="${CSS.escape(returnTarget.slimmingJobID)}"]`
          )
          : null));
    const fallback = returnFocus instanceof HTMLElement && document.contains(returnFocus)
      ? returnFocus
      : elements.jobsButton;
    return target || fallback;
  };
  stabilizeDismissedOverlayFocus(
    resolveReturnFocus,
    elements.jobsPopover,
    () => elements.jobsPopover.classList.contains("hidden")
  );
}

function openJobsPopover({ jobID = null } = {}) {
  if (elements.jobsPopover.classList.contains("hidden")) {
    state.jobsReturnFocus = document.activeElement;
    state.jobsReturnTarget = {
      trainingRunID: document.activeElement?.closest?.("[data-training-run-id]")
        ?.dataset.trainingRunId || null,
      reviewTrainingJobID: document.activeElement?.closest?.("[data-review-training-job-id]")
        ?.dataset.reviewTrainingJobId || null,
      slimmingJobID: document.activeElement?.closest?.("[data-slimming-job-id]")
        ?.dataset.slimmingJobId || null,
    };
  }
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  closePersonalModelPopover({ restoreFocus: false });
  elements.jobsPopover.classList.remove("hidden");
  const targetID = jobID && state.jobs.some((job) => job.id === jobID)
    ? jobID
    : (state.focusedActivityJobID && state.jobs.some((job) => job.id === state.focusedActivityJobID)
      ? state.focusedActivityJobID
      : state.jobs[0]?.id);
  if (targetID) selectJobRow(targetID, { focus: true });
  else requestAnimationFrame(() => elements.closeJobsButton.focus({ preventScroll: true }));
}

function toggleJobsPopover() {
  if (elements.jobsPopover.classList.contains("hidden")) openJobsPopover();
  else closeJobsPopover();
}

function renderJobs() {
  clearElement(elements.jobsList);
  elements.jobsEmpty.classList.toggle("hidden", state.jobs.length > 0);
  const activeCount = state.jobs.filter((job) =>
    ["pending", "running", "paused", "retryableFailed"].includes(job.state)
  ).length;
  elements.jobsBadge.textContent = String(activeCount);
  elements.jobsBadge.classList.toggle("hidden", activeCount === 0);
  if (!state.jobs.some((job) => job.id === state.focusedActivityJobID)) {
    state.focusedActivityJobID = state.jobs[0]?.id || null;
  }

  for (const job of state.jobs) {
    const row = document.createElement("article");
    row.className = "job-row";
    const selected = state.focusedActivityJobID === job.id;
    row.tabIndex = selected ? 0 : -1;
    row.setAttribute("role", "listitem");
    if (selected) row.setAttribute("aria-current", "true");
    row.dataset.jobRowId = job.id;
    row.classList.toggle("focused", selected);
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

    if (job.attempts != null || job.lastErrorCode) {
      const diagnostic = document.createElement("div");
      diagnostic.className = "job-diagnostic";
      if (job.attempts != null) {
        const attempts = document.createElement("span");
        attempts.textContent = `尝试 ${job.attempts}/${job.maxAttempts ?? "—"}`;
        diagnostic.append(attempts);
      }
      if (job.lastErrorCode) {
        const guidance = document.createElement("span");
        guidance.textContent = jobFailureGuidance(job);
        const code = document.createElement("code");
        code.textContent = job.lastErrorCode;
        diagnostic.append(guidance, code);
      }
      row.append(diagnostic);
    }

    if (job.availableActions?.length || job.navigationTarget?.workspace === "librarySlimming") {
      const actions = document.createElement("div");
      actions.className = "job-actions";
      if (job.navigationTarget?.workspace === "librarySlimming") {
        const open = document.createElement("button");
        open.type = "button";
        open.className = "button job-action job-context-action";
        open.dataset.openSlimmingJobId = job.id;
        open.textContent = "在图库瘦身中查看";
        actions.append(open);
      }
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
      if (!elements.trainingWorkspace.classList.contains("hidden")) {
        await loadTrainingWorkspace({ quiet: true });
      }
      if (!elements.reviewWorkspace.classList.contains("hidden")) {
        await loadReviewOverview();
      }
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

async function openAssociatedJob(jobID) {
  state.training.focusedJobID = jobID;
  await openAssociatedActivity(jobID);
}

async function openAssociatedActivity(jobID) {
  state.focusedActivityJobID = jobID;
  try {
    state.jobs = await api("/v1/jobs");
    renderJobs();
  } catch (error) {
    toast(error.message || "关联任务载入失败");
    return;
  }
  openJobsPopover({ jobID });
  const row = elements.jobsList.querySelector(`[data-job-row-id="${CSS.escape(jobID)}"]`);
  if (!row) {
    toast("关联任务已不在当前任务列表中，历史记录仍会保留");
    return;
  }
  row.scrollIntoView({ block: "nearest" });
}

async function openSlimmingJobFromActivity(jobID) {
  const job = state.jobs.find((item) => item.id === jobID);
  const target = job?.navigationTarget;
  if (!target || target.workspace !== "librarySlimming") {
    toast("这个任务没有可打开的图库瘦身记录");
    return;
  }
  state.focusedActivityJobID = jobID;
  state.slimming.view = "analysis";
  state.slimming.mediaKind = target.mediaKind || "image";
  state.slimming.selectedJobID = target.recordID;
  state.slimming.selectedClusterID = null;
  state.slimming.selectedMemberIDs.clear();
  state.slimming.selectionAnchorID = null;
  state.slimming.clusterLimit = 48;
  state.slimming.memberLimit = 96;
  await openSlimmingWorkspace();
  focusSelectedSlimmingJob();
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
  const controlsLocked = state.review.loading
    || state.review.overviewLoading
    || state.review.mutating;
  const hasSelection = state.review.selectedAssetIDs.size > 0;
  elements.loadMoreReviewButton.disabled = controlsLocked;
  elements.reviewTagSelect.disabled = controlsLocked || activeTags().length === 0;
  elements.reviewCurrentSourceOnly.disabled = controlsLocked || !state.selectedSourceID;
  elements.refreshReviewButton.disabled = controlsLocked;
  elements.reviewBackButton.disabled = controlsLocked;
  document.querySelectorAll(".review-action").forEach((button) => {
    button.disabled = !state.online || controlsLocked || !hasSelection;
  });
}

function reviewTaskStatusText(status, overview) {
  const progress = overview.totalCount == null
    ? `${overview.checkedCount} 项已检查`
    : `${overview.checkedCount} / ${overview.totalCount} 项已检查`;
  return {
    notReady: `样本尚未就绪 · ${progress}`,
    ready: `可以生成建议 · ${progress}`,
    waiting: `等待处理 · ${progress}`,
    running: `正在生成建议 · ${progress}`,
    paused: `生成已暂停 · ${progress}`,
    retryableFailure: `生成遇到问题，可在 Mac 端重试 · ${progress}`,
    completed: `本轮生成完成 · ${progress}`,
    terminalFailure: `生成失败，请在 Mac 端检查 · ${progress}`,
    cancelled: `生成已取消 · ${progress}`,
  }[status] || progress;
}

function reviewOverviewGroupSections() {
  const remaining = new Map(state.review.overview.map((overview) => [overview.id, overview]));
  const sections = [];
  for (const group of orderedTagGroups()) {
    const overviews = orderedTagsInGroup(
      activeTags().filter((tag) => tag.groupID === group.id),
      group.id
    ).map((tag) => remaining.get(tag.id)).filter(Boolean);
    for (const overview of overviews) remaining.delete(overview.id);
    if (overviews.length) {
      sections.push({ id: group.id, displayName: group.displayName, overviews });
    }
  }
  const unmatched = state.review.overview.filter((overview) => remaining.has(overview.id));
  if (unmatched.length) {
    sections.push({ id: "other", displayName: "其他", overviews: unmatched });
  }
  return sections.length
    ? sections
    : (state.review.overview.length
      ? [{ id: "all", displayName: "标签", overviews: state.review.overview }]
      : []);
}

function organizeReviewOverviewGroups() {
  const cardsByTagID = new Map(
    [...elements.reviewOverviewGrid.querySelectorAll(".review-overview-card")].map((card) => [
      card.querySelector("[data-review-overview-tag-id]")?.dataset.reviewOverviewTagId,
      card,
    ])
  );
  clearElement(elements.reviewOverviewGrid);
  for (const section of reviewOverviewGroupSections()) {
    const collapsed = state.layout.collapsedReviewTagGroupIDs.has(section.id);
    const group = document.createElement("section");
    group.className = "review-overview-group";
    group.dataset.reviewOverviewGroupId = section.id;
    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.className = "review-overview-group-toggle";
    toggle.dataset.reviewOverviewGroupToggle = section.id;
    toggle.setAttribute("aria-expanded", String(!collapsed));
    toggle.setAttribute("aria-keyshortcuts", "ArrowUp ArrowDown Home End");
    const chevron = document.createElement("span");
    chevron.setAttribute("aria-hidden", "true");
    chevron.textContent = collapsed ? "›" : "⌄";
    const title = document.createElement("strong");
    title.textContent = section.displayName;
    const count = document.createElement("span");
    count.textContent = `${section.overviews.length} 个标签`;
    const pending = document.createElement("span");
    pending.className = "review-overview-group-pending";
    pending.textContent = `${section.overviews.reduce(
      (total, overview) => total + (overview.pendingSuggestionCount || 0),
      0
    )} 条待审`;
    toggle.append(chevron, title, count, pending);

    const grid = document.createElement("div");
    grid.className = "review-overview-group-grid";
    grid.hidden = collapsed;
    for (const overview of section.overviews) {
      const card = cardsByTagID.get(overview.id);
      if (card) grid.append(card);
    }
    group.append(toggle, grid);
    elements.reviewOverviewGrid.append(group);
  }
}

function renderReviewOverview() {
  const activeControl = elements.reviewOverviewGrid.contains(document.activeElement)
    ? document.activeElement
    : null;
  const focusedTrainingJobID = state.review.pendingFocusTrainingJobID
    || activeControl?.dataset?.reviewTrainingJobId
    || null;
  const focusedTagID = !focusedTrainingJobID
    ? (activeControl?.dataset?.reviewOverviewTagId || null)
    : null;
  const focusedGroupID = !focusedTrainingJobID && !focusedTagID
    ? (activeControl?.dataset?.reviewOverviewGroupToggle || null)
    : null;
  const loading = state.review.overviewLoading;
  if (state.review.mode === "overview") {
    elements.reviewSummary.textContent = loading
      ? "正在载入审核总览…"
      : `${state.review.overviewTotal} 条待审 · ${currentMediaNoun()}`;
    elements.reviewNavigationCount.textContent = state.review.overviewTotal
      ? String(state.review.overviewTotal)
      : "";
  }
  elements.reviewOverviewEmpty.classList.toggle(
    "hidden",
    loading || state.review.overview.length > 0
  );
  clearElement(elements.reviewOverviewGrid);
  for (const overview of state.review.overview) {
    const card = document.createElement("article");
    card.className = "review-overview-card";
    const openButton = document.createElement("button");
    openButton.type = "button";
    openButton.className = "review-overview-open";
    openButton.dataset.reviewOverviewTagId = overview.id;
    openButton.disabled = !overview.canReview || overview.pendingSuggestionCount === 0;
    openButton.setAttribute("aria-disabled", String(openButton.disabled));

    const heading = document.createElement("div");
    heading.className = "review-overview-card-heading";
    const name = document.createElement("strong");
    name.textContent = overview.displayName;
    const pending = document.createElement("span");
    pending.className = "review-pending-count";
    pending.textContent = String(overview.pendingSuggestionCount);
    heading.append(name, pending);

    const stats = document.createElement("div");
    stats.className = "review-overview-stats";
    stats.textContent = `已确认 ${overview.acceptedSampleCount} · 已拒绝 ${overview.rejectedSampleCount}`;

    const origins = document.createElement("div");
    origins.className = "review-origin-counts";
    const originLabels = [
      ["personalAdamW", "超级个人"],
      ["personalModel", "个人模型"],
      ["featurePrint", "特征向量"],
      ["standardModel", "标准模型"],
    ];
    for (const [key, label] of originLabels) {
      const count = overview.pendingSuggestionCounts?.[key] || 0;
      if (!count) continue;
      const badge = document.createElement("span");
      badge.textContent = `${label} ${count}`;
      origins.append(badge);
    }

    const status = document.createElement("div");
    status.className = "review-overview-status";
    status.textContent = reviewTaskStatusText(overview.taskStatus, overview);
    openButton.append(heading, stats);
    if (origins.childElementCount) openButton.append(origins);
    openButton.append(status);
    card.append(openButton);

    const hasFeatureAction = Boolean(overview.canGenerate || overview.canUpdate);
    const hasFeatureJob = Boolean(overview.activeJobID);
    if (hasFeatureAction || hasFeatureJob) {
      const feature = document.createElement("div");
      feature.className = "review-overview-generate review-overview-feature";
      const label = document.createElement("span");
      label.textContent = "FEATURE PRINT 建议";
      feature.append(label);

      if (hasFeatureAction) {
        const actions = document.createElement("div");
        actions.className = "review-overview-generate-actions";
        const generate = document.createElement("button");
        generate.type = "button";
        generate.className = "button button-plain";
        generate.dataset.reviewFeatureTagId = overview.id;
        generate.dataset.reviewFeatureMode = overview.canUpdate ? "update" : "generate";
        generate.disabled = !state.online || state.review.overviewLoading;
        generate.textContent = overview.canUpdate ? "更新特征向量" : "生成特征向量";
        actions.append(generate);
        feature.append(actions);
      }

      if (hasFeatureJob) {
        const jobRow = document.createElement("div");
        jobRow.className = "review-tag-activity review-feature-job";
        const jobStatus = document.createElement("span");
        jobStatus.textContent = reviewTaskStatusText(overview.taskStatus, overview);
        jobRow.append(jobStatus);

        const viewRun = document.createElement("button");
        viewRun.type = "button";
        viewRun.className = "button button-plain";
        viewRun.dataset.reviewTrainingTagId = overview.id;
        viewRun.dataset.reviewTrainingJobId = overview.activeJobID;
        viewRun.textContent = "训练记录";
        jobRow.append(viewRun);

        const jobActions = [
          ["pause", overview.canPause, "暂停"],
          ["resume", overview.canResume, "继续"],
          ["cancel", overview.canCancel, "取消"],
        ];
        for (const [action, available, title] of jobActions) {
          if (!available) continue;
          const button = document.createElement("button");
          button.type = "button";
          button.className = `button button-plain job-action write-action${action === "cancel" ? " button-danger" : ""}`;
          button.dataset.jobId = overview.activeJobID;
          button.dataset.action = action;
          button.disabled = !state.online || state.jobMutatingIDs.has(overview.activeJobID);
          button.textContent = state.jobMutatingIDs.has(overview.activeJobID)
            ? "处理中…"
            : title;
          jobRow.append(button);
        }
        feature.append(jobRow);
      }
      card.append(feature);
    }

    const option = tagLibrarySuggestionOption(overview.id);
    const suggestions = state.tagLibrarySuggestions;
    const activeActivity = activeTagLibrarySuggestion(overview.id);
    const canGeneratePersonal = Boolean(
      state.online
      && state.mediaKind === "image"
      && overview.canGeneratePersonalModel
      && option?.personalEligible
    );
    if (canGeneratePersonal || activeActivity) {
      const generation = document.createElement("div");
      generation.className = "review-overview-generate";
      const label = document.createElement("span");
      label.textContent = "全库个人建议";
      generation.append(label);
      if (activeActivity) {
        const activityRow = document.createElement("div");
        activityRow.className = "review-tag-activity";
        const activityText = document.createElement("span");
        activityText.textContent = `${tagLibrarySuggestionMethodText(activeActivity.method)} · ${tagLibrarySuggestionPhaseText(activeActivity)}`;
        activityRow.append(activityText);
        if (activeActivity.availableActions?.includes("cancel")) {
          const cancelButton = document.createElement("button");
          cancelButton.type = "button";
          cancelButton.className = "button button-plain";
          cancelButton.dataset.cancelTagSuggestionId = activeActivity.operationID;
          cancelButton.disabled = !state.online
            || suggestions.cancellingIDs.has(activeActivity.operationID);
          cancelButton.textContent = suggestions.cancellingIDs.has(activeActivity.operationID)
            ? "停止中…"
            : "停止";
          activityRow.append(cancelButton);
        }
        generation.append(activityRow);
      } else {
        const actions = document.createElement("div");
        actions.className = "review-overview-generate-actions";
        const methods = [
          ["personalCentroid", "个人模型"],
          ["personalAdamW", "超级个人"],
        ];
        for (const [method, labelText] of methods) {
          const available = method === "personalAdamW"
            ? suggestions.snapshot?.personalAdamWAvailable
            : suggestions.snapshot?.personalCentroidAvailable;
          if (!available) continue;
          const button = document.createElement("button");
          button.type = "button";
          button.className = "button button-plain";
          button.dataset.tagSuggestionMethod = method;
          button.dataset.tagId = overview.id;
          button.disabled = suggestions.loading
            || suggestions.submitting
            || Boolean(activeTagLibrarySuggestion());
          button.textContent = `${labelText} Top ${suggestions.snapshot?.maximumPendingCount || 500}`;
          actions.append(button);
        }
        if (actions.childElementCount) generation.append(actions);
      }
      if (generation.childElementCount > 1) card.append(generation);
    }
    elements.reviewOverviewGrid.append(card);
  }
  organizeReviewOverviewGroups();
  syncReviewControls();
  const focusAfterRender = () => {
    const target = focusedTrainingJobID
      ? elements.reviewOverviewGrid.querySelector(
        `[data-review-training-job-id="${CSS.escape(focusedTrainingJobID)}"]`
      )
      : (focusedTagID
        ? elements.reviewOverviewGrid.querySelector(
          `[data-review-overview-tag-id="${CSS.escape(focusedTagID)}"]`
        )
        : (focusedGroupID
          ? elements.reviewOverviewGrid.querySelector(
            `[data-review-overview-group-toggle="${CSS.escape(focusedGroupID)}"]`
          )
          : null));
    if (!(target instanceof HTMLElement) || target.disabled) return;
    target.focus({ preventScroll: true });
    if (focusedTrainingJobID && !state.review.overviewLoading) {
      state.review.pendingFocusTrainingJobID = null;
    }
  };
  focusAfterRender();
  requestAnimationFrame(focusAfterRender);
}

function renderReviewMode() {
  const overviewMode = state.review.mode === "overview";
  elements.reviewOverview.classList.toggle("hidden", !overviewMode);
  elements.reviewQueueLayout.classList.toggle("hidden", overviewMode);
  elements.reviewBackButton.classList.toggle("hidden", overviewMode);
  elements.reviewTagControl.classList.toggle("hidden", overviewMode);
  if (overviewMode) {
    renderReviewOverview();
  } else {
    renderReview();
  }
}

async function loadReviewOverview({ throwOnError = false } = {}) {
  const generation = ++state.review.overviewGeneration;
  const workspaceGeneration = state.workspaceGeneration;
  state.review.overviewLoading = true;
  renderReviewOverview();
  const query = new URLSearchParams({ mediaKind: state.mediaKind });
  if (elements.reviewCurrentSourceOnly.checked && state.selectedSourceID) {
    query.set("sourceIDs", state.selectedSourceID);
  }
  try {
    const overview = await api(`/v1/review/overview?${query}`);
    if (generation !== state.review.overviewGeneration
      || workspaceGeneration !== state.workspaceGeneration) return false;
    state.review.overview = overview.tags || [];
    state.review.overviewTotal = overview.totalPendingSuggestionCount || 0;
    return true;
  } catch (error) {
    if (generation === state.review.overviewGeneration && !throwOnError) {
      toast(error.message || "审核总览载入失败");
    }
    if (throwOnError) throw error;
    return false;
  } finally {
    if (generation === state.review.overviewGeneration) {
      state.review.overviewLoading = false;
      renderReviewOverview();
    }
  }
}

async function enterReviewQueue(tagID) {
  const overview = state.review.overview.find((item) => item.id === tagID);
  if (!overview) return;
  state.review.mode = "queue";
  elements.reviewTagSelect.value = tagID;
  renderReviewMode();
  await loadReviewQueue({ preserveLoadedWindow: true });
}

async function openTrainingWorkspaceForReviewTag(tagID, jobID = null) {
  state.training.mediaKind = state.mediaKind;
  state.training.method = "featureKnn";
  state.training.focusedJobID = jobID;
  state.training.focusedTagID = tagID;
  await openTrainingWorkspace({
    returnToReview: {
      mode: state.review.mode,
      tagID,
      jobID,
    },
  });
  const selected = state.training.runs.find(
    (run) => run.id === state.training.selectedRunID
      && (run.jobID === jobID || run.tagID === tagID)
  );
  if (!selected) toast("对应训练记录尚未写入，任务进度仍可在审核卡片和任务面板查看");
}

async function returnToReviewOverview() {
  finishReviewMarqueeSelection();
  state.review.mode = "overview";
  renderReviewMode();
  await loadReviewOverview();
}

function selectedReviewItems() {
  return state.review.items.filter((item) => state.review.selectedAssetIDs.has(item.assetID));
}

function syncReviewCardSelection(button, item, index) {
  const selected = state.review.selectedAssetIDs.has(item.assetID);
  const primary = selected && index === state.review.selectedIndex;
  button.classList.toggle("selected", selected);
  button.classList.toggle("primary", primary);
  button.setAttribute("aria-pressed", String(selected));
  if (primary) {
    button.setAttribute("aria-current", "true");
  } else {
    button.removeAttribute("aria-current");
  }
  let mark = button.querySelector(".review-selection-mark");
  if (selected) {
    if (!mark) {
      mark = document.createElement("span");
      mark.className = "review-selection-mark";
      mark.setAttribute("aria-hidden", "true");
      mark.textContent = "✓";
      button.append(mark);
    }
  } else {
    mark?.remove();
  }
}

function renderReviewSelectionState({ renderDetail = true } = {}) {
  state.review.items.forEach((item, index) => {
    const button = elements.reviewGrid.querySelector(`[data-review-index="${index}"]`);
    if (button) syncReviewCardSelection(button, item, index);
  });
  const count = state.review.selectedAssetIDs.size;
  elements.reviewSummary.textContent = state.review.loading
    ? "正在载入…"
    : `待审核 ${state.review.items.length} 项${state.review.nextCursor ? " · 还有更多" : ""}`
      + (count > 1 ? ` · 已选择 ${count} 项` : "");
  if (renderDetail) renderReviewDetail();
}

function selectAllReviewItems() {
  if (!state.review.items.length) return;
  state.review.selectedAssetIDs = new Set(state.review.items.map((item) => item.assetID));
  if (state.review.selectedIndex < 0) state.review.selectedIndex = 0;
  state.review.selectionAnchorIndex = state.review.selectedIndex;
  renderReviewSelectionState();
  elements.reviewGrid.querySelector(`[data-review-index="${state.review.selectedIndex}"]`)
    ?.focus({ preventScroll: true });
}

function renderReview() {
  elements.reviewEmpty.classList.toggle("hidden", state.review.items.length > 0);
  elements.loadMoreReviewButton.classList.toggle("hidden", !state.review.nextCursor);
  elements.reviewSummary.textContent = state.review.loading
    ? "正在载入…"
    : `待审核 ${state.review.items.length} 项${state.review.nextCursor ? " · 还有更多" : ""}`;
  elements.reviewNavigationCount.textContent = state.review.overviewTotal
    ? String(state.review.overviewTotal)
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
    button.setAttribute("aria-label", `${item.fileName || "未命名照片"}，${reviewOriginText(item.suggestionOrigin)}`);
    syncAssetCardImage(button, item);
    syncReviewCardSelection(button, item, index);
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
  const selectedItems = selectedReviewItems();
  const hasDetail = Boolean(item) && state.review.selectedAssetIDs.has(item.assetID);
  elements.reviewPlaceholder.classList.toggle("hidden", hasDetail);
  elements.reviewDetail.classList.toggle("hidden", !hasDetail);
  if (!hasDetail) {
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
  elements.reviewSelectionSummary.textContent = selectedItems.length > 1
    ? `已选择 ${mediaItemCountText(selectedItems.length)} · 下方操作应用到全部选中项`
    : "当前 1 项";
  elements.reviewPosition.textContent = `${state.review.selectedIndex + 1} / ${state.review.items.length}`;
  elements.previousReviewButton.disabled = state.review.selectedIndex <= 0;
  elements.nextReviewButton.disabled = state.review.selectedIndex >= state.review.items.length - 1;
  const actionCount = selectedItems.length;
  for (const button of elements.reviewDetail.querySelectorAll(".review-action")) {
    const label = button.querySelector("span");
    if (!label) continue;
    label.textContent = {
      accept: actionCount > 1 ? `属于 ${actionCount} 项` : "属于",
      reject: actionCount > 1 ? `不属于 ${actionCount} 项` : "不属于",
      defer: actionCount > 1 ? `稍后处理 ${actionCount} 项` : "稍后",
    }[button.dataset.action] || label.textContent;
  }
  syncReviewControls();
}

function selectReviewIndex(index, { additive = false, extendRange = false } = {}) {
  if (!state.review.items.length) {
    state.review.selectedIndex = -1;
    state.review.selectedAssetIDs.clear();
    state.review.selectionAnchorIndex = -1;
  } else {
    const bounded = Math.max(0, Math.min(index, state.review.items.length - 1));
    const assetID = state.review.items[bounded].assetID;
    if (extendRange) {
      const anchor = state.review.selectionAnchorIndex >= 0
        ? state.review.selectionAnchorIndex
        : (state.review.selectedIndex >= 0 ? state.review.selectedIndex : bounded);
      const next = additive ? new Set(state.review.selectedAssetIDs) : new Set();
      for (let candidate = Math.min(anchor, bounded); candidate <= Math.max(anchor, bounded); candidate += 1) {
        next.add(state.review.items[candidate].assetID);
      }
      state.review.selectedAssetIDs = next;
      state.review.selectedIndex = bounded;
      state.review.selectionAnchorIndex = anchor;
    } else if (additive) {
      if (state.review.selectedAssetIDs.has(assetID)) {
        state.review.selectedAssetIDs.delete(assetID);
        if (state.review.selectedIndex === bounded) {
          state.review.selectedIndex = state.review.items.findIndex((item) => (
            state.review.selectedAssetIDs.has(item.assetID)
          ));
        }
      } else {
        state.review.selectedAssetIDs.add(assetID);
        state.review.selectedIndex = bounded;
      }
      state.review.selectionAnchorIndex = bounded;
    } else {
      state.review.selectedAssetIDs = new Set([assetID]);
      state.review.selectedIndex = bounded;
      state.review.selectionAnchorIndex = bounded;
    }
  }
  renderReviewSelectionState();
  elements.reviewGrid.querySelector(`[data-review-index="${state.review.selectedIndex}"]`)?.scrollIntoView({
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
    mediaKind: state.mediaKind,
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
    state.review.selectedAssetIDs.clear();
    state.review.selectionAnchorIndex = -1;
  }
  const loadedTargetCount = preserveLoadedWindow
    && state.review.loadedScopeKey === scopeKey
    ? Math.max(48, state.review.items.length)
    : 48;
  const generation = ++state.review.requestGeneration;
  const selectedKey = reviewItemKey(state.review.items[state.review.selectedIndex]);
  const selectedAssetIDs = new Set(state.review.selectedAssetIDs);
  const anchorAssetID = state.review.items[state.review.selectionAnchorIndex]?.assetID || null;
  const previousIndex = state.review.selectedIndex;
  if (!tagID) {
    state.review.items = [];
    state.review.nextCursor = null;
    state.review.selectedIndex = -1;
    state.review.selectedAssetIDs.clear();
    state.review.selectionAnchorIndex = -1;
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
    const query = new URLSearchParams({ tagID, mediaKind: state.mediaKind, limit: "48" });
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
    const nextItems = append ? state.review.items.concat(page.items) : page.items;
    const nextCursor = page.nextCursor || null;
    shouldRender = shouldRender
      || reviewPageFingerprint(state.review.items, state.review.nextCursor)
        !== reviewPageFingerprint(nextItems, nextCursor);
    state.review.items = nextItems;
    state.review.nextCursor = nextCursor;
    state.review.loadedScopeKey = scopeKey;
    const validAssetIDs = new Set(state.review.items.map((item) => item.assetID));
    state.review.selectedAssetIDs = new Set(
      [...selectedAssetIDs].filter((assetID) => validAssetIDs.has(assetID))
    );
    const restoredIndex = selectedKey
      ? state.review.items.findIndex((item) => reviewItemKey(item) === selectedKey)
      : -1;
    if (state.review.selectedAssetIDs.size) {
      state.review.selectedIndex = restoredIndex >= 0
        && state.review.selectedAssetIDs.has(state.review.items[restoredIndex].assetID)
        ? restoredIndex
        : state.review.items.findIndex((item) => state.review.selectedAssetIDs.has(item.assetID));
    } else if (state.review.items.length) {
      state.review.selectedIndex = Math.max(0, Math.min(previousIndex, state.review.items.length - 1));
      state.review.selectedAssetIDs.add(state.review.items[state.review.selectedIndex].assetID);
    } else {
      state.review.selectedIndex = -1;
    }
    const restoredAnchorIndex = anchorAssetID
      ? state.review.items.findIndex((item) => item.assetID === anchorAssetID)
      : -1;
    state.review.selectionAnchorIndex = restoredAnchorIndex >= 0
      ? restoredAnchorIndex
      : state.review.selectedIndex;
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

async function openReviewWorkspace({ returnToTrainingRunID = null } = {}) {
  if (elements.trainingSetupDialog.open) closeTrainingSetupDialog();
  elements.trainingWorkspace.classList.add("hidden");
  if (returnToTrainingRunID) {
    state.review.returnTarget = {
      workspace: "training",
      runID: returnToTrainingRunID,
    };
  } else {
    state.review.returnTarget = null;
    state.review.pendingFocusTrainingJobID = null;
    state.trainingReturnFocus = null;
  }
  elements.slimmingWorkspace.classList.add("hidden");
  state.slimmingReturnFocus = null;
  closeJobsPopover({ restoreFocus: false });
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  if (!returnToTrainingRunID && elements.reviewWorkspace.classList.contains("hidden")) {
    state.reviewReturnFocus = document.activeElement;
  }
  elements.appView.inert = true;
  elements.reviewWorkspace.classList.remove("hidden");
  syncReviewClosePresentation();
  renderSampleSuggestions();
  requestAnimationFrame(() => {
    elements.closeReviewButton.focus({ preventScroll: true });
  });
  state.review.mode = "overview";
  renderReviewMode();
  await Promise.all([
    loadReviewOverview(),
    loadTagLibrarySuggestions({ quiet: true }),
  ]);
}

function trainingSetupMethodAvailability(method) {
  return state.training.setup.snapshot?.methods?.find((item) => item.method === method)?.isAvailable
    ?? false;
}

function trainingSetupEligibleTags(method = state.training.setup.method) {
  const tags = state.training.setup.snapshot?.tags || [];
  if (method === "featureKnn") return tags.filter((tag) => Boolean(tag.featureMode));
  return tags.filter((tag) => tag.personalEligible);
}

function trainingSetupMethodCopy(method) {
  const noun = state.training.mediaKind === "video" ? "视频" : "照片";
  return {
    featureKnn: {
      icon: "⌁",
      title: `寻找相似${noun}`,
      technical: "Feature Print k-NN",
      detail: `用确认的正反样本，在所选来源中寻找相似${noun}。`,
      requirement: "每个标签至少 2 个属于、2 个不属于",
    },
    personalCentroid: {
      icon: "◎",
      title: "快速个人模型",
      technical: "Personal Centroid",
      detail: "按标签建立轻量个人模型，训练快，适合频繁更新。",
      requirement: `每个标签至少 2 个已确认${noun}`,
    },
    personalAdamW: {
      icon: "✦",
      title: "增强个人模型",
      technical: "Personal AdamW",
      detail: "进行多轮优化并保留验证指标，适合样本更完整的标签。",
      requirement: `每个标签至少 2 个已确认${noun}`,
    },
  }[method];
}

function chooseInitialTrainingSetupMethod() {
  const ordered = ["featureKnn", "personalCentroid", "personalAdamW"];
  return ordered.find((method) => trainingSetupMethodAvailability(method)
    && trainingSetupEligibleTags(method).length
    && (method !== "featureKnn" || state.training.setup.snapshot.sources.length))
    || ordered.find(trainingSetupMethodAvailability)
    || "featureKnn";
}

function resetTrainingSetupSelection(method) {
  const setup = state.training.setup;
  setup.method = method;
  setup.selectedTagIDs = new Set();
  setup.selectedSourceIDs = new Set();
  setup.scope = "allSources";
  setup.tagSearchText = "";
  setup.error = "";
  setup.notice = "";
  elements.trainingTagSearch.value = "";
  const eligibleTags = trainingSetupEligibleTags(method);
  if (method === "featureKnn") {
    if (eligibleTags[0]) setup.selectedTagIDs.add(eligibleTags[0].id);
    for (const source of setup.snapshot?.sources || []) setup.selectedSourceIDs.add(source.id);
  } else if (eligibleTags.length === 1) {
    setup.selectedTagIDs.add(eligibleTags[0].id);
  }
}

function appendTrainingSetupSummary(label, value) {
  const term = document.createElement("dt");
  term.textContent = label;
  const description = document.createElement("dd");
  description.textContent = value;
  elements.trainingLaunchSummary.append(term, description);
}

function renderTrainingSetupMethods() {
  clearElement(elements.trainingSetupMethods);
  for (const method of ["featureKnn", "personalCentroid", "personalAdamW"]) {
    const copy = trainingSetupMethodCopy(method);
    const eligibleCount = trainingSetupEligibleTags(method).length;
    const available = trainingSetupMethodAvailability(method)
      && eligibleCount > 0
      && (method !== "featureKnn" || Boolean(state.training.setup.snapshot?.sources?.length));
    const button = document.createElement("button");
    button.type = "button";
    button.className = "training-method-option";
    button.classList.toggle("selected", state.training.setup.method === method);
    button.disabled = !available || state.training.setup.launching;
    button.dataset.trainingSetupMethod = method;
    button.setAttribute("role", "radio");
    button.setAttribute("aria-checked", String(state.training.setup.method === method));
    const icon = document.createElement("span");
    icon.className = "training-method-icon";
    icon.textContent = copy.icon;
    const body = document.createElement("span");
    body.className = "training-method-copy";
    const title = document.createElement("strong");
    title.textContent = copy.title;
    const technical = document.createElement("span");
    technical.textContent = `技术：${copy.technical}`;
    const detail = document.createElement("span");
    detail.textContent = copy.detail;
    const requirement = document.createElement("span");
    requirement.textContent = available
      ? `✓ ${copy.requirement}`
      : (eligibleCount ? "当前设备尚未提供此训练能力" : copy.requirement);
    body.append(title, technical, detail, requirement);
    const check = document.createElement("span");
    check.className = "training-method-check";
    check.textContent = state.training.setup.method === method ? "●" : "○";
    button.append(icon, body, check);
    elements.trainingSetupMethods.append(button);
  }
}

function renderTrainingTagOptions() {
  clearElement(elements.trainingTagOptions);
  const setup = state.training.setup;
  const isFeature = setup.method === "featureKnn";
  const query = setup.tagSearchText.trim().toLocaleLowerCase("zh-CN");
  const tags = trainingSetupEligibleTags().filter((tag) => (
    !query || tag.displayName.toLocaleLowerCase("zh-CN").includes(query)
  ));
  if (!tags.length) {
    const empty = document.createElement("div");
    empty.className = "training-options-empty";
    empty.textContent = query ? "没有匹配的可训练标签" : "还没有达到最低样本要求的标签";
    elements.trainingTagOptions.append(empty);
    return;
  }
  for (const tag of tags) {
    const row = document.createElement("label");
    row.className = "training-option-row";
    const input = document.createElement("input");
    input.type = isFeature ? "radio" : "checkbox";
    input.name = "trainingTag";
    input.value = tag.id;
    input.checked = setup.selectedTagIDs.has(tag.id);
    input.disabled = setup.launching;
    input.dataset.trainingTagId = tag.id;
    const name = document.createElement("strong");
    name.textContent = tag.displayName;
    const counts = document.createElement("span");
    counts.textContent = isFeature
      ? `属于 ${tag.acceptedSampleCount} · 不属于 ${tag.rejectedSampleCount}`
      : `已确认 ${tag.acceptedSampleCount} 个`;
    row.append(input, name, counts);
    elements.trainingTagOptions.append(row);
  }
}

function renderTrainingScopeOptions() {
  clearElement(elements.trainingScopeOptions);
  const setup = state.training.setup;
  const noun = state.training.mediaKind === "video" ? "视频" : "照片";
  if (setup.method === "featureKnn") {
    elements.trainingScopeTitle.textContent = `扫描哪些${noun}来源？`;
    elements.trainingScopeHint.textContent = "只读取所选来源；任务会冻结本次范围。";
    for (const source of setup.snapshot?.sources || []) {
      const row = document.createElement("label");
      row.className = "training-option-row";
      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = setup.selectedSourceIDs.has(source.id);
      input.disabled = setup.launching;
      input.dataset.trainingSourceId = source.id;
      const name = document.createElement("strong");
      name.textContent = source.displayName;
      const status = document.createElement("span");
      status.textContent = "可用";
      row.append(input, name, status);
      elements.trainingScopeOptions.append(row);
    }
    return;
  }
  elements.trainingScopeTitle.textContent = `使用哪些${noun}？`;
  elements.trainingScopeHint.textContent = `默认使用所有来源中的已确认${noun}；只有明确选择时才限制为图库当前选择。`;
  const choices = [{ value: "allSources", title: `所有来源中的已确认${noun}`, note: "推荐" }];
  const canUseSelection = state.mediaKind === state.training.mediaKind && state.selectedAssetIDs.size > 0;
  if (canUseSelection) {
    choices.push({
      value: "currentSelection",
      title: `图库中当前选择的 ${state.selectedAssetIDs.size} ${noun === "照片" ? "张照片" : "个视频"}`,
      note: "限制范围",
    });
  }
  for (const choice of choices) {
    const row = document.createElement("label");
    row.className = "training-option-row";
    const input = document.createElement("input");
    input.type = "radio";
    input.name = "trainingScope";
    input.value = choice.value;
    input.checked = setup.scope === choice.value;
    input.disabled = setup.launching;
    input.dataset.trainingScope = choice.value;
    const title = document.createElement("strong");
    title.textContent = choice.title;
    const note = document.createElement("span");
    note.textContent = choice.note;
    row.append(input, title, note);
    elements.trainingScopeOptions.append(row);
  }
}

function canLaunchTrainingSetup() {
  const setup = state.training.setup;
  if (setup.loading
    || setup.launching
    || !setup.snapshot
    || !trainingSetupMethodAvailability(setup.method)
    || !setup.selectedTagIDs.size) return false;
  if (setup.method === "featureKnn") {
    return setup.selectedTagIDs.size === 1 && setup.selectedSourceIDs.size > 0;
  }
  if (setup.scope === "currentSelection") {
    return state.mediaKind === state.training.mediaKind && state.selectedAssetIDs.size > 0;
  }
  return true;
}

function renderTrainingSetupSummary() {
  clearElement(elements.trainingLaunchSummary);
  const setup = state.training.setup;
  const copy = trainingSetupMethodCopy(setup.method);
  const selectedTags = (setup.snapshot?.tags || [])
    .filter((tag) => setup.selectedTagIDs.has(tag.id))
    .map((tag) => tag.displayName);
  appendTrainingSetupSummary("任务", `${copy.title}（${copy.technical}）`);
  appendTrainingSetupSummary("标签", selectedTags.length ? selectedTags.join("、") : "尚未选择");
  if (setup.method === "featureKnn") {
    appendTrainingSetupSummary("来源", `${setup.selectedSourceIDs.size} 个来源`);
  } else {
    appendTrainingSetupSummary(
      state.training.mediaKind === "video" ? "视频范围" : "照片范围",
      setup.scope === "currentSelection"
        ? `图库当前选择 ${state.selectedAssetIDs.size} 项`
        : "所有来源中的已确认样本"
    );
  }
  appendTrainingSetupSummary("最低要求", copy.requirement);
}

function renderTrainingSetup() {
  const setup = state.training.setup;
  elements.trainingSetupLoading.classList.toggle("hidden", !setup.loading);
  elements.trainingSetupConfiguration.classList.toggle("hidden", setup.loading || !setup.snapshot);
  elements.trainingSetupError.textContent = setup.error;
  elements.trainingSetupNotice.textContent = setup.notice;
  elements.trainingSetupNotice.classList.toggle("hidden", !setup.notice);
  elements.trainingTagSearch.disabled = setup.loading || setup.launching;
  elements.launchTrainingButton.disabled = !canLaunchTrainingSetup();
  elements.launchTrainingButton.textContent = setup.launching
    ? "正在交给 Mac…"
    : (setup.method === "featureKnn" ? "开始寻找" : "开始训练");
  if (!setup.snapshot) return;
  const noun = state.training.mediaKind === "video" ? "视频" : "照片";
  const isFeature = setup.method === "featureKnn";
  elements.trainingSetupConfigTitle.textContent = isFeature
    ? `选择一个标签和${noun}来源`
    : `选择标签和${noun}范围`;
  elements.trainingSetupConfigHint.textContent = isFeature
    ? `标签会显示现有正反样本数；Host 会再次检查 2 + 2 门槛。`
    : "每个标签独立训练、独立发布；一个失败不会撤销其他标签。";
  renderTrainingSetupMethods();
  renderTrainingTagOptions();
  renderTrainingScopeOptions();
  renderTrainingSetupSummary();
}

function applyTrainingSetupPrefill(prefill) {
  if (!prefill) return;
  const setup = state.training.setup;
  const requestedMethod = prefill.method;
  if (requestedMethod
    && setup.snapshot?.methods?.some((item) => item.method === requestedMethod)) {
    resetTrainingSetupSelection(requestedMethod);
  }

  const eligibleTagIDs = new Set(trainingSetupEligibleTags().map((tag) => tag.id));
  const requestedTagIDs = (prefill.tagIDs || []).filter((id) => eligibleTagIDs.has(id));
  if (requestedTagIDs.length) {
    setup.selectedTagIDs = new Set(
      setup.method === "featureKnn" ? requestedTagIDs.slice(0, 1) : requestedTagIDs
    );
    const selectedTag = requestedTagIDs.length === 1
      ? setup.snapshot?.tags?.find((tag) => tag.id === requestedTagIDs[0])
      : null;
    setup.tagSearchText = selectedTag?.displayName || "";
    elements.trainingTagSearch.value = setup.tagSearchText;
  }
  if (prefill.requireExplicitTag && !requestedTagIDs.length) {
    setup.selectedTagIDs.clear();
  }

  if (prefill.scope === "currentSelection"
    && setup.method !== "featureKnn"
    && state.mediaKind === state.training.mediaKind
    && state.selectedAssetIDs.size) {
    setup.scope = "currentSelection";
  }

  setup.notice = prefill.note || "";
  if (requestedMethod && !trainingSetupMethodAvailability(requestedMethod)) {
    setup.notice = `${setup.notice ? `${setup.notice} ` : ""}当前 Mac Host 尚未提供此训练能力。`;
  }
  if (setup.method === "featureKnn" && prefill.sourceScope === "unresolved") {
    setup.selectedSourceIDs.clear();
  } else if (setup.method === "featureKnn" && prefill.sourceScope === "selectedSources") {
    const availableSourceIDs = new Set((setup.snapshot?.sources || []).map((source) => source.id));
    const savedSourceIDs = prefill.sourceIDs || [];
    const requestedSourceIDs = savedSourceIDs.filter((id) => availableSourceIDs.has(id));
    setup.selectedSourceIDs = new Set(requestedSourceIDs);
    const unavailableCount = savedSourceIDs.length - requestedSourceIDs.length;
    if (unavailableCount > 0) {
      setup.notice = `${setup.notice ? `${setup.notice} ` : ""}${unavailableCount} 个历史来源当前不可用，已从本次配置中移除。`;
    }
  }
}

async function openTrainingSetupDialog(prefill = null) {
  const setup = state.training.setup;
  setup.loading = true;
  setup.launching = false;
  setup.snapshot = null;
  setup.error = "";
  setup.notice = "";
  setup.operationID = null;
  setup.returnFocus = prefill?.returnFocus || document.activeElement;
  const generation = ++setup.requestGeneration;
  elements.trainingSetupDialog.showModal();
  renderTrainingSetup();
  try {
    const query = new URLSearchParams({ mediaKind: state.training.mediaKind });
    const snapshot = await api(`/v1/training/setup?${query}`);
    if (generation !== setup.requestGeneration || !elements.trainingSetupDialog.open) return;
    setup.snapshot = snapshot;
    resetTrainingSetupSelection(chooseInitialTrainingSetupMethod());
    applyTrainingSetupPrefill(prefill);
  } catch (error) {
    if (generation === setup.requestGeneration) {
      setup.error = error.message || "训练设置载入失败";
    }
  } finally {
    if (generation === setup.requestGeneration) {
      setup.loading = false;
      renderTrainingSetup();
    }
  }
}

function openTrainingSetupForRun(runID) {
  const run = state.training.runs.find((item) => item.id === runID);
  if (!run) return;
  const recovery = run.recoveryContext;
  const tagIDs = recovery?.tagIDs?.length
    ? recovery.tagIDs
    : (run.tagID ? [run.tagID] : []);
  openTrainingSetupDialog({
    method: run.method,
    tagIDs,
    requireExplicitTag: !tagIDs.length,
    sourceIDs: recovery?.sourceIDs || [],
    sourceScope: recovery?.scope || "unresolved",
    note: recovery?.note || "这条旧记录只能恢复训练方法；请重新确认标签和范围。",
  });
}

function closeTrainingSetupDialog() {
  const returnFocus = state.training.setup.returnFocus;
  state.training.setup.requestGeneration += 1;
  state.training.setup.launching = false;
  state.training.setup.returnFocus = null;
  if (elements.trainingSetupDialog.open) elements.trainingSetupDialog.close();
  restoreOverlayFocus(returnFocus || elements.newTrainingButton);
}

async function submitTrainingSetup() {
  const setup = state.training.setup;
  if (!canLaunchTrainingSetup()) return;
  setup.launching = true;
  setup.error = "";
  setup.operationID ||= crypto.randomUUID();
  renderTrainingSetup();
  const assetIDs = setup.method !== "featureKnn" && setup.scope === "currentSelection"
    ? [...state.selectedAssetIDs]
    : [];
  try {
    const result = await api("/v1/training/launch", {
      method: "POST",
      body: JSON.stringify({
        operationID: setup.operationID,
        mediaKind: state.training.mediaKind,
        method: setup.method,
        tagIDs: [...setup.selectedTagIDs],
        sourceIDs: setup.method === "featureKnn" ? [...setup.selectedSourceIDs] : [],
        assetIDs,
      }),
    });
    const copy = trainingSetupMethodCopy(result.method);
    closeTrainingSetupDialog();
    toast(`${copy.title}已交给 Mac · ${result.scheduledTagCount} 个标签`);
    await loadTrainingWorkspace({ quiet: true });
  } catch (error) {
    setup.error = error.message || "训练任务创建失败";
    setup.launching = false;
    renderTrainingSetup();
  }
}

function trainingMethodPresentation(method, mediaKind = state.training.mediaKind) {
  const noun = mediaKind === "video" ? "视频" : "照片";
  return {
    featureKnn: { title: `相似${noun}`, technical: "Feature Print k-NN" },
    personalCentroid: { title: "快速个人模型", technical: "Personal Centroid" },
    personalAdamW: { title: "增强个人模型", technical: "Personal AdamW" },
  }[method] || { title: "训练任务", technical: method || "—" };
}

function trainingStateText(value) {
  return {
    queued: "等待中",
    running: "训练中",
    succeeded: "已完成",
    failed: "失败",
    cancelled: "已取消",
  }[value] || value || "未知";
}

function trainingDate(milliseconds) {
  if (!Number.isFinite(milliseconds)) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(milliseconds));
}

function prettyTrainingJSON(value, fallback) {
  if (!value) return fallback;
  try {
    return JSON.stringify(JSON.parse(value), null, 2);
  } catch {
    return fallback;
  }
}

function trainingMetricsSummary(value) {
  if (!value) return "当前记录没有可概括的评估口径。";
  try {
    const metrics = JSON.parse(value);
    const trainCount = Number(metrics.trainSampleCount || 0);
    const validationCount = Number(metrics.validationSampleCount || 0);
    if (metrics.evaluationSplit === "validation") {
      return `评估口径：验证集 · 训练样本 ${trainCount} · 验证样本 ${validationCount}`;
    }
    if (metrics.evaluationSplit === "trainFallback") {
      return `评估口径：训练集回退（样本不足，未建立验证集）· 训练样本 ${trainCount}`;
    }
    if (metrics.evaluationSplit) return `评估口径：${metrics.evaluationSplit}`;
    if ("validationLoss" in metrics || "bestValidationLoss" in metrics) {
      return "历史指标：评估切分未记录，不能把该 loss 判定为验证损失。";
    }
  } catch {
    // Host already sanitized the projection; malformed historical JSON is shown as absent.
  }
  return "当前记录没有可概括的评估口径。";
}

function appendTrainingFact(container, label, value, className = "training-fact") {
  const wrapper = document.createElement("div");
  wrapper.className = className;
  const term = document.createElement("dt");
  term.textContent = label;
  const description = document.createElement("dd");
  description.textContent = value || "—";
  wrapper.append(term, description);
  container.append(wrapper);
}

function isActiveTrainingActivity(activity) {
  return !["completed", "failed", "cancelled"].includes(activity?.phase);
}

function isRecentTrainingActivity(activity) {
  const updatedAtMs = Number(activity?.updatedAtMs || 0);
  return updatedAtMs > 0 && Date.now() - updatedAtMs < 15_000;
}

function trainingBatchCounts(activity) {
  const tags = activity?.tagActivities || [];
  return {
    succeeded: tags.filter((tag) => tag.phase === "succeeded").length,
    skipped: tags.filter((tag) => tag.phase === "skipped").length,
    failed: tags.filter((tag) => tag.phase === "failed").length,
    cancelled: tags.filter((tag) => tag.phase === "cancelled").length,
    pending: tags.filter((tag) => !["succeeded", "skipped", "failed", "cancelled"]
      .includes(tag.phase)).length,
  };
}

function trainingBatchPresentation(activity) {
  const counts = trainingBatchCounts(activity);
  if (isActiveTrainingActivity(activity)) {
    return { label: "进行中", className: "running", counts };
  }
  if (activity.phase === "cancelled") {
    return { label: "已取消", className: "cancelled", counts };
  }
  if (activity.phase === "failed") {
    const interrupted = activity.errorCode === "hostRestartInterrupted";
    return {
      label: interrupted ? "被 App 重启中断" : "未完成",
      className: "failed",
      counts,
    };
  }
  if (counts.failed || counts.skipped || counts.cancelled || counts.pending) {
    return { label: "部分完成", className: "partial", counts };
  }
  return { label: "全部完成", className: "completed", counts };
}

function trainingRunBatchID(run) {
  if (run?.batchID) return run.batchID;
  try {
    return JSON.parse(run?.sampleSummaryJSON || "{}").batchID || null;
  } catch {
    return null;
  }
}

function isBatchTrainingRun(run) {
  return Boolean(trainingRunBatchID(run));
}

function visibleTrainingRuns() {
  if (state.training.runScope === "batch") {
    return state.training.runs.filter(isBatchTrainingRun);
  }
  if (state.training.runScope === "single") {
    return state.training.runs.filter((run) => !isBatchTrainingRun(run));
  }
  return state.training.runs;
}

function trainingRunTagName(run) {
  if (run?.tagDisplayName) return run.tagDisplayName;
  const current = run?.tagID ? tagByID(run.tagID)?.displayName : null;
  if (current) return current;
  return run?.tagID ? `历史标签 ${run.tagID.slice(0, 8)}` : "未关联标签";
}

function trainingRunBatchPosition(run) {
  if (!isBatchTrainingRun(run)) return null;
  const index = run.batchTagIndex == null ? Number.NaN : Number(run.batchTagIndex);
  const count = run.batchTagCount == null ? Number.NaN : Number(run.batchTagCount);
  if (Number.isInteger(index) && index >= 0 && Number.isInteger(count) && count > 0) {
    return `${Math.min(index + 1, count)} / ${count}`;
  }
  return "批次成员";
}

function trainingRunDuration(run) {
  const startedAtMs = run?.startedAtMs == null ? Number.NaN : Number(run.startedAtMs);
  const endAtMs = Number(run?.finishedAtMs ?? Date.now());
  if (!Number.isFinite(startedAtMs) || !Number.isFinite(endAtMs) || endAtMs < startedAtMs) {
    return null;
  }
  const seconds = Math.max(0, Math.round((endAtMs - startedAtMs) / 1000));
  if (seconds < 60) return `${seconds} 秒`;
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return remainder ? `${minutes} 分 ${remainder} 秒` : `${minutes} 分钟`;
}

function trainingRunScopeText(run) {
  const scope = run?.recoveryContext?.scope;
  if (scope === "allSources") return "所有可用来源";
  if (scope === "selectedSources") {
    const count = run.recoveryContext?.sourceIDs?.length || 0;
    return count ? `${count} 个选定来源` : "选定来源";
  }
  if (scope === "selectedAssets") return "当时选择的媒体";
  if (scope === "unresolved") return "历史范围未保存";
  return "训练时目录快照";
}

function setTrainingRunScope(scope, { focus = false } = {}) {
  if (!["all", "batch", "single"].includes(scope)) return;
  state.training.runScope = scope;
  const visible = visibleTrainingRuns();
  if (!visible.some((run) => run.id === state.training.selectedRunID)) {
    state.training.selectedRunID = visible[0]?.id || null;
  }
  renderTrainingWorkspace();
  if (focus) focusTrainingRun(state.training.selectedRunID, { reveal: true });
}

function cycleTrainingRunScope() {
  const scopes = ["all", "batch", "single"];
  const index = scopes.indexOf(state.training.runScope);
  setTrainingRunScope(scopes[(index + 1) % scopes.length], { focus: true });
}

function renderTrainingBatchHistory() {
  const batches = (state.training.activities || [])
    .filter((activity) =>
      ["personalCentroid", "personalAdamW"].includes(activity.method)
      && (!state.training.method || activity.method === state.training.method)
    )
    .sort((lhs, rhs) => Number(rhs.updatedAtMs || 0) - Number(lhs.updatedAtMs || 0))
    .slice(0, 12);
  elements.trainingBatchHistory.classList.toggle("hidden", batches.length === 0);
  elements.trainingBatchCount.textContent = String(batches.length);
  clearElement(elements.trainingBatchList);
  for (const activity of batches) {
    const presentation = trainingBatchPresentation(activity);
    const method = trainingMethodPresentation(activity.method, activity.mediaKind);
    const card = document.createElement("article");
    card.className = `training-batch-card ${presentation.className}`;
    card.dataset.trainingBatchId = activity.operationID;

    const heading = document.createElement("header");
    const copy = document.createElement("div");
    const title = document.createElement("strong");
    title.textContent = method.title;
    const date = document.createElement("span");
    date.className = "secondary";
    date.textContent = trainingDate(Number(activity.acceptedAtMs || activity.updatedAtMs));
    copy.append(title, date);
    const status = document.createElement("span");
    status.className = `training-batch-state ${presentation.className}`;
    status.textContent = presentation.label;
    heading.append(copy, status);

    const summary = document.createElement("p");
    const countParts = [
      presentation.counts.succeeded ? `完成 ${presentation.counts.succeeded}` : "",
      presentation.counts.skipped ? `跳过 ${presentation.counts.skipped}` : "",
      presentation.counts.failed ? `失败 ${presentation.counts.failed}` : "",
      presentation.counts.cancelled ? `取消 ${presentation.counts.cancelled}` : "",
      presentation.counts.pending ? `处理中 ${presentation.counts.pending}` : "",
    ].filter(Boolean);
    summary.textContent = countParts.join(" · ") || `${activity.totalUnitCount || 0} 个标签`;

    const tags = document.createElement("div");
    tags.className = "training-batch-tags";
    for (const tag of (activity.tagActivities || []).slice(0, 8)) {
      const chip = document.createElement("span");
      chip.className = tag.phase;
      chip.textContent = tag.displayName || tag.tagID.slice(0, 8);
      chip.title = `${chip.textContent} · ${tag.phase}`;
      tags.append(chip);
    }
    if ((activity.tagActivities || []).length > 8) {
      const more = document.createElement("span");
      more.textContent = `＋${activity.tagActivities.length - 8}`;
      tags.append(more);
    }

    const actions = document.createElement("footer");
    if (state.training.runs.some((run) => trainingRunBatchID(run) === activity.operationID)) {
      const view = document.createElement("button");
      view.type = "button";
      view.className = "button button-compact";
      view.dataset.trainingBatchViewId = activity.operationID;
      view.textContent = "查看 Run";
      actions.append(view);
    }
    const unfinished = (activity.tagActivities || []).some((tag) => tag.phase !== "succeeded");
    if (!isActiveTrainingActivity(activity) && unfinished) {
      const retry = document.createElement("button");
      retry.type = "button";
      retry.className = "button button-compact button-primary";
      retry.dataset.trainingBatchReconfigureId = activity.operationID;
      retry.textContent = "重新处理未完成标签";
      actions.append(retry);
    }
    card.append(heading, summary, tags, actions);
    elements.trainingBatchList.append(card);
  }
}

function renderTrainingActivities() {
  const activities = state.training.activities || [];
  const activity = activities.find(isActiveTrainingActivity)
    || activities.find(isRecentTrainingActivity);
  elements.trainingActivityStrip.classList.toggle("hidden", !activity);
  elements.trainingActivityStrip.classList.toggle("failed", activity?.phase === "failed");
  elements.trainingActivityStrip.classList.toggle("completed", activity?.phase === "completed");
  elements.trainingActivityStrip.classList.toggle("cancelled", activity?.phase === "cancelled");
  if (!activity) return;
  clearElement(elements.trainingActivityStrip);
  const copy = trainingMethodPresentation(activity.method, activity.mediaKind);
  const summary = document.createElement("div");
  summary.className = "training-activity-summary";
  const heading = document.createElement("strong");
  const phaseText = {
    preparingSamples: "正在准备样本",
    preparingEmbeddings: "正在准备 AI 特征",
    trainingAndPublishing: "正在训练并发布模型",
    completed: "训练已完成",
    failed: "训练失败",
    cancelled: "训练已取消",
  }[activity.phase] || "训练处理中";
  heading.textContent = `${copy.title} · ${phaseText}`;
  const detail = document.createElement("span");
  const tagActivities = activity.tagActivities || [];
  const succeededCount = tagActivities.filter((tag) => tag.phase === "succeeded").length;
  const skippedCount = tagActivities.filter((tag) => tag.phase === "skipped").length;
  const failedCount = tagActivities.filter((tag) => tag.phase === "failed").length;
  const resultParts = [
    succeededCount ? `完成 ${succeededCount}` : "",
    skippedCount ? `跳过 ${skippedCount}` : "",
    failedCount ? `失败 ${failedCount}` : "",
  ].filter(Boolean);
  detail.textContent = `${activity.completedUnitCount} / ${activity.totalUnitCount} 个标签`
    + (activity.sampleCount ? ` · 当前 ${activity.sampleCount} 个样本` : "")
    + (resultParts.length ? ` · ${resultParts.join(" · ")}` : "")
    + (activity.phase === "failed" && activity.errorCode ? ` · ${activity.errorCode}` : "");
  const progress = document.createElement("span");
  progress.className = "training-activity-progress";
  const fill = document.createElement("span");
  const ratio = activity.phase === "completed"
    ? 1
    : Math.max(0.08, activity.completedUnitCount / Math.max(activity.totalUnitCount, 1));
  fill.style.width = `${Math.round(ratio * 100)}%`;
  progress.append(fill);
  summary.append(progress, heading, detail);
  if (activity.availableActions?.includes("cancel")) {
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "button button-compact button-danger write-action";
    cancel.dataset.trainingActivityId = activity.operationID;
    cancel.dataset.action = "cancel";
    cancel.disabled = state.training.activityMutatingIDs.has(activity.operationID);
    cancel.textContent = cancel.disabled ? "正在取消…" : "取消训练";
    summary.append(cancel);
  }
  const unfinishedTags = tagActivities.filter(
    (tag) => !["succeeded"].includes(tag.phase)
  );
  if (["completed", "failed", "cancelled"].includes(activity.phase)
    && unfinishedTags.length) {
    const retry = document.createElement("button");
    retry.type = "button";
    retry.className = "button button-compact button-primary";
    retry.dataset.trainingBatchReconfigureId = activity.operationID;
    retry.textContent = "重新处理未完成标签";
    summary.append(retry);
  }
  elements.trainingActivityStrip.append(summary);

  if (tagActivities.length) {
    const list = document.createElement("ol");
    list.className = "training-tag-activity-list";
    const phaseCopy = {
      pending: "等待",
      preparingSamples: "准备样本",
      preparingEmbeddings: "准备特征",
      trainingAndPublishing: "训练发布",
      succeeded: "已完成",
      skipped: "已跳过",
      failed: "失败",
      cancelled: "已取消",
    };
    for (const tag of tagActivities) {
      const item = document.createElement("li");
      item.className = `training-tag-activity ${tag.phase}`;
      const mark = document.createElement("span");
      mark.className = "training-tag-activity-mark";
      mark.setAttribute("aria-hidden", "true");
      const name = document.createElement("strong");
      name.textContent = tag.displayName || tag.tagID.slice(0, 8);
      const status = document.createElement("span");
      status.textContent = `${phaseCopy[tag.phase] || tag.phase}`
        + (tag.sampleCount ? ` · ${tag.sampleCount} 个样本` : "")
        + (tag.errorCode ? ` · ${tag.errorCode}` : "");
      item.append(mark, name, status);
      list.append(item);
    }
    elements.trainingActivityStrip.append(list);
  }
}

function openTrainingSetupForActivity(operationID) {
  const activity = state.training.activities.find(
    (item) => item.operationID === operationID
  );
  if (!activity) return;
  const allTags = activity.tagActivities || [];
  const tagIDs = allTags
    .filter((tag) => tag.phase !== "succeeded")
    .map((tag) => tag.tagID);
  openTrainingSetupDialog({
    method: activity.method,
    tagIDs,
    requireExplicitTag: !tagIDs.length,
    note: tagIDs.length
      ? `已保留 ${allTags.length - tagIDs.length} 个完成标签，只重新选择 ${tagIDs.length} 个未完成标签。`
      : "这个批次没有未完成标签。",
  });
}

async function openTrainingRunForBatch(operationID) {
  let run = state.training.runs.find((item) => trainingRunBatchID(item) === operationID);
  if (!run) {
    const activity = state.training.activities.find(
      (item) => item.operationID === operationID
    );
    if (activity && state.training.method !== activity.method) {
      state.training.method = activity.method;
      state.training.selectedRunID = null;
      await loadTrainingWorkspace({ quiet: true });
      run = state.training.runs.find((item) => trainingRunBatchID(item) === operationID);
    }
  }
  if (!run) {
    toast("这个批次没有生成可查看的 Run");
    return;
  }
  if (state.training.runScope === "single") state.training.runScope = "batch";
  selectTrainingRun(run.id, { focus: true, reveal: true });
}

function toggleTrainingNavigator() {
  state.layout.trainingNavigatorVisible = !state.layout.trainingNavigatorVisible;
  persistWorkspacePreferences();
  renderTrainingWorkspace();
  elements.toggleTrainingNavigatorButton.focus({ preventScroll: true });
}

async function applyTrainingActivityAction(operationID, action) {
  if (!state.online || state.training.activityMutatingIDs.has(operationID)) return;
  if (action === "cancel" && !window.confirm("取消正在进行的个人模型训练？已经完成的标签会保留。")) {
    return;
  }
  state.training.activityMutatingIDs.add(operationID);
  renderTrainingActivities();
  try {
    const response = await api(`/v1/training/activities/${operationID}/actions`, {
      method: "POST",
      body: JSON.stringify({ action }),
    });
    const index = state.training.activities.findIndex(
      (activity) => activity.operationID === operationID
    );
    if (index >= 0) state.training.activities[index] = response.activity;
    renderTrainingActivities();
    toast("训练取消请求已交给 Mac");
    await loadTrainingWorkspace({ quiet: true });
  } catch (error) {
    toast(error.message || "训练任务操作失败");
  } finally {
    state.training.activityMutatingIDs.delete(operationID);
    renderTrainingActivities();
  }
}

function trainingSlotRun(slot) {
  return slot?.publishedRunID
    ? state.training.runs.find((run) => run.id === slot.publishedRunID) || null
    : null;
}

function focusTrainingSlot(method = null) {
  const selectedMethod = method
    || state.training.runs.find((run) => run.id === state.training.selectedRunID)?.method
    || state.training.slots[0]?.method;
  requestAnimationFrame(() => {
    const slot = selectedMethod
      ? elements.trainingSlotStrip.querySelector(
        `[data-training-slot-method="${CSS.escape(selectedMethod)}"]`
      )
      : elements.trainingSlotStrip.querySelector("[data-training-slot-method]");
    slot?.focus({ preventScroll: true });
  });
}

function moveTrainingSlotFocus(key) {
  const slots = [...elements.trainingSlotStrip.querySelectorAll("[data-training-slot-method]")];
  if (!slots.length) return;
  const current = Math.max(0, slots.indexOf(document.activeElement));
  const next = key === "Home"
    ? 0
    : key === "End"
      ? slots.length - 1
      : Math.max(0, Math.min(slots.length - 1, current + (key === "ArrowLeft" ? -1 : 1)));
  slots[next].focus({ preventScroll: true });
  slots[next].scrollIntoView({ block: "nearest", inline: "nearest" });
}

async function openTrainingSlot(method) {
  const slot = state.training.slots.find((item) => item.method === method);
  if (!slot?.isPublished || !slot.publishedRunID) {
    await openTrainingSetupDialog({ method, tagIDs: [], sourceIDs: [] });
    return;
  }
  state.training.method = method;
  state.training.runScope = "all";
  state.training.focusedRunID = slot.publishedRunID;
  await loadTrainingWorkspace();
  if (state.training.selectedRunID !== slot.publishedRunID) {
    toast("已发布记录不在当前历史窗口中，请切换到全部记录后刷新");
    return;
  }
  focusTrainingRun(slot.publishedRunID, { reveal: true });
}

function renderTrainingSlots() {
  clearElement(elements.trainingSlotStrip);
  const slots = state.training.slots.length
    ? state.training.slots
    : ["featureKnn", "personalCentroid", "personalAdamW"].map((method) => ({
      method,
      isPublished: false,
    }));
  for (const slot of slots) {
    const presentation = trainingMethodPresentation(slot.method, state.training.mediaKind);
    const run = trainingSlotRun(slot);
    const selectedRun = state.training.runs.find(
      (item) => item.id === state.training.selectedRunID
    );
    const item = document.createElement("button");
    item.type = "button";
    item.className = `training-slot${slot.isPublished ? " published" : ""}${selectedRun?.method === slot.method ? " selected" : ""}`;
    item.dataset.trainingSlotMethod = slot.method;
    item.setAttribute("aria-pressed", String(selectedRun?.method === slot.method));
    const mark = document.createElement("span");
    mark.className = "training-slot-mark";
    mark.setAttribute("aria-hidden", "true");
    const copy = document.createElement("span");
    copy.className = "training-slot-copy";
    const title = document.createElement("strong");
    title.textContent = presentation.title;
    const status = document.createElement("span");
    status.textContent = slot.isPublished
      ? `模型已就绪${run?.sampleCount != null ? ` · ${run.sampleCount} 个样本` : ""}`
      : "尚未训练 · 新建任务";
    const meta = document.createElement("small");
    meta.textContent = slot.isPublished
      ? `${slot.publishedRunID ? `Run ${slot.publishedRunID.slice(0, 8)}` : "已发布"}${run?.finishedAtMs != null ? ` · ${trainingDate(run.finishedAtMs)}` : ""}`
      : "选择标签、来源与训练范围";
    const disclosure = document.createElement("span");
    disclosure.className = "training-slot-disclosure";
    disclosure.setAttribute("aria-hidden", "true");
    disclosure.textContent = "›";
    copy.append(title, status, meta);
    item.append(mark, copy, disclosure);
    item.setAttribute(
      "aria-label",
      `${presentation.title}，${status.textContent}，${slot.isPublished ? "打开已发布训练记录" : "新建训练任务"}`
    );
    elements.trainingSlotStrip.append(item);
  }
}

function renderTrainingRunList() {
  const runs = visibleTrainingRuns();
  clearElement(elements.trainingRunList);
  elements.trainingRunCount.textContent = state.training.runScope === "all"
    ? String(runs.length)
    : `${runs.length} / ${state.training.runs.length}`;
  elements.trainingEmpty.classList.toggle(
    "hidden",
    state.training.loading || runs.length > 0
  );
  if (!state.training.loading && !runs.length) {
    const title = elements.trainingEmpty.querySelector("strong");
    const message = elements.trainingEmpty.querySelector("p");
    const filtered = state.training.runs.length > 0;
    title.textContent = filtered ? "没有匹配的训练记录" : "暂无训练记录";
    message.textContent = filtered
      ? "切换到“全部”或其他记录类型；筛选不会删除或停止任务。"
      : "从“新建任务”开始；失败和取消的记录也会保留。";
  }
  const activeCount = state.training.runs.filter(
    (run) => run.state === "queued" || run.state === "running"
  ).length + state.training.activities.filter(
    (activity) => !["completed", "failed", "cancelled"].includes(activity.phase)
  ).length;
  elements.trainingNavigationCount.textContent = activeCount ? String(activeCount) : "";
  if (state.training.selectedRunID) {
    elements.trainingRunList.setAttribute(
      "aria-activedescendant",
      `training-run-${state.training.selectedRunID}`
    );
  } else {
    elements.trainingRunList.removeAttribute("aria-activedescendant");
  }
  for (const run of runs) {
    const presentation = trainingMethodPresentation(run.method, run.mediaKind);
    const row = document.createElement("button");
    row.type = "button";
    row.className = "training-run-row";
    row.classList.toggle("selected", run.id === state.training.selectedRunID);
    row.dataset.trainingRunId = run.id;
    row.id = `training-run-${run.id}`;
    row.tabIndex = run.id === state.training.selectedRunID ? 0 : -1;
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", String(run.id === state.training.selectedRunID));
    row.setAttribute(
      "aria-label",
      `${presentation.title}，标签 ${trainingRunTagName(run)}，${trainingRunBatchPosition(run) ? `批次 ${trainingRunBatchPosition(run)}` : "单项"}，${trainingStateText(run.state)}`
    );
    const heading = document.createElement("span");
    heading.className = "training-run-row-heading";
    const title = document.createElement("strong");
    title.textContent = presentation.title;
    const dot = document.createElement("span");
    dot.className = `training-run-state-dot ${run.state}`;
    dot.setAttribute("aria-hidden", "true");
    const stateLabel = document.createElement("span");
    stateLabel.className = "secondary";
    stateLabel.textContent = trainingStateText(run.state);
    heading.append(title, dot, stateLabel);
    const context = document.createElement("span");
    context.className = "training-run-row-context";
    const tag = document.createElement("span");
    tag.className = "training-run-tag";
    tag.textContent = trainingRunTagName(run);
    context.append(tag);
    const position = trainingRunBatchPosition(run);
    if (position) {
      const batch = document.createElement("span");
      batch.className = "training-run-kind batch";
      batch.textContent = position === "批次成员" ? "批次" : `批次 ${position}`;
      context.append(batch);
    } else {
      const single = document.createElement("span");
      single.className = "training-run-kind";
      single.textContent = "单项";
      context.append(single);
    }
    if (run.sampleCount != null) {
      const samples = document.createElement("span");
      samples.className = "secondary";
      samples.textContent = `${run.sampleCount} 个样本`;
      context.append(samples);
    }
    const subtitle = document.createElement("span");
    subtitle.className = "training-run-row-subtitle";
    subtitle.textContent = `${presentation.technical} · ${trainingDate(run.createdAtMs)}`;
    row.append(heading, context, subtitle);
    elements.trainingRunList.append(row);
  }
}

function focusTrainingRun(runID, { reveal = false } = {}) {
  if (!runID) return;
  requestAnimationFrame(() => {
    const row = elements.trainingRunList.querySelector(
      `[data-training-run-id="${CSS.escape(runID)}"]`
    );
    if (!row) return;
    row.focus({ preventScroll: true });
    if (reveal) row.scrollIntoView({ block: "nearest" });
  });
}

function selectTrainingRun(runID, { focus = false, reveal = false } = {}) {
  if (!visibleTrainingRuns().some((run) => run.id === runID)) return;
  state.training.selectedRunID = runID;
  renderTrainingRunList();
  renderTrainingDetail();
  if (focus) focusTrainingRun(runID, { reveal });
}

function moveTrainingRunSelection(key) {
  const runs = visibleTrainingRuns();
  if (!runs.length) return;
  const currentIndex = Math.max(
    0,
    runs.findIndex((run) => run.id === state.training.selectedRunID)
  );
  const nextIndex = key === "Home"
    ? 0
    : key === "End"
      ? runs.length - 1
      : Math.max(
        0,
        Math.min(
          runs.length - 1,
          currentIndex + (key === "ArrowUp" ? -1 : 1)
        )
      );
  selectTrainingRun(runs[nextIndex].id, { focus: true, reveal: true });
}

function appendTrainingIdentifierBlock(run) {
  const block = document.createElement("section");
  block.className = "training-technical-block";
  const heading = document.createElement("h4");
  heading.textContent = "运行标识";
  const pre = document.createElement("pre");
  pre.textContent = [
    `training_run: ${run.id}`,
    run.jobID ? `job: ${run.jobID}` : "",
    run.batchID ? `batch: ${run.batchID}` : "",
    run.tagID ? `tag: ${run.tagID}` : "",
  ].filter(Boolean).join("\n");
  block.append(heading, pre);
  elements.trainingTechnicalBlocks.append(block);
}

function appendTrainingTechnicalBlock(title, value, fallback) {
  const block = document.createElement("section");
  block.className = "training-technical-block";
  const heading = document.createElement("h4");
  heading.textContent = title;
  const pre = document.createElement("pre");
  pre.textContent = prettyTrainingJSON(value, fallback);
  block.append(heading, pre);
  elements.trainingTechnicalBlocks.append(block);
}

function renderTrainingDetailActions(run) {
  clearElement(elements.trainingDetailActions);
  const job = run.jobID ? state.jobs.find((item) => item.id === run.jobID) : null;
  if (run.jobID) {
    const viewJob = document.createElement("button");
    viewJob.type = "button";
    viewJob.className = "button button-compact";
    viewJob.dataset.trainingJobId = run.jobID;
    viewJob.textContent = "查看关联任务";
    elements.trainingDetailActions.append(viewJob);

    for (const action of job?.availableActions || []) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `button button-compact job-action write-action${action === "cancel" ? " button-danger" : ""}`;
      button.dataset.jobId = run.jobID;
      button.dataset.trainingRunJobId = run.jobID;
      button.dataset.action = action;
      button.disabled = !state.online || state.jobMutatingIDs.has(run.jobID);
      button.textContent = action === "resume" && job.state === "retryableFailed"
        ? "重试任务"
        : jobActionText(action);
      elements.trainingDetailActions.append(button);
    }
  }

  if (["failed", "cancelled"].includes(run.state)) {
    const reconfigure = document.createElement("button");
    reconfigure.type = "button";
    reconfigure.className = "button button-compact button-primary";
    reconfigure.dataset.trainingReconfigureRunId = run.id;
    reconfigure.textContent = "重新配置";
    elements.trainingDetailActions.append(reconfigure);
  }

  if (run.tagID) {
    const review = document.createElement("button");
    review.type = "button";
    review.className = "button button-compact";
    review.dataset.trainingReviewRunId = run.id;
    review.textContent = "打开标签审核";
    elements.trainingDetailActions.append(review);
  }
}

async function openReviewFromTrainingRun(runID) {
  const run = state.training.runs.find((item) => item.id === runID);
  if (!run?.tagID) {
    toast("这条训练记录没有可定位的标签");
    return;
  }
  if (run.mediaKind !== state.mediaKind) await switchMediaKind(run.mediaKind);
  await openReviewWorkspace({ returnToTrainingRunID: run.id });
  let overview = state.review.overview.find((item) => item.id === run.tagID);
  if (!overview && elements.reviewCurrentSourceOnly.checked) {
    elements.reviewCurrentSourceOnly.checked = false;
    await loadReviewOverview();
    overview = state.review.overview.find((item) => item.id === run.tagID);
  }
  if (!overview) {
    toast("该标签当前没有可显示的审核记录");
    return;
  }
  if (overview.canReview && overview.pendingSuggestionCount > 0) {
    await enterReviewQueue(run.tagID);
    return;
  }
  requestAnimationFrame(() => {
    const card = elements.reviewOverviewGrid.querySelector(
      `[data-review-overview-tag-id="${CSS.escape(run.tagID)}"]`
    );
    card?.scrollIntoView({ block: "nearest" });
    card?.focus({ preventScroll: true });
  });
  toast("已定位到对应标签；当前没有待审核建议");
}

function renderTrainingDetail() {
  const run = state.training.runs.find((item) => item.id === state.training.selectedRunID);
  elements.trainingDetailPlaceholder.classList.toggle("hidden", Boolean(run));
  elements.trainingDetail.classList.toggle("hidden", !run);
  if (!run) return;

  const presentation = trainingMethodPresentation(run.method, run.mediaKind);
  elements.trainingDetailTitle.textContent = presentation.title;
  elements.trainingDetailSubtitle.textContent = `${presentation.technical} · Run ${run.id.slice(0, 8)}`;
  clearElement(elements.trainingDetailContext);
  const detailContexts = [
    { text: trainingRunTagName(run), className: "tag" },
    {
      text: trainingRunBatchPosition(run)
        ? `批次 ${trainingRunBatchPosition(run)}`
        : "单项记录",
      className: isBatchTrainingRun(run) ? "batch" : "single",
    },
    run.sampleCount != null ? { text: `${run.sampleCount} 个样本`, className: "samples" } : null,
  ].filter(Boolean);
  for (const item of detailContexts) {
    const chip = document.createElement("span");
    chip.className = item.className;
    chip.textContent = item.text;
    elements.trainingDetailContext.append(chip);
  }
  elements.trainingDetailState.textContent = trainingStateText(run.state);
  elements.trainingDetailState.className = `training-state-pill ${run.state}`;
  renderTrainingDetailActions(run);

  clearElement(elements.trainingFactLedger);
  appendTrainingFact(elements.trainingFactLedger, "标签", trainingRunTagName(run));
  appendTrainingFact(
    elements.trainingFactLedger,
    "记录类型",
    isBatchTrainingRun(run) ? "个人模型批次成员" : "单项训练"
  );
  const batchPosition = trainingRunBatchPosition(run);
  if (batchPosition) appendTrainingFact(elements.trainingFactLedger, "批次位置", batchPosition);
  if (run.sampleCount != null) {
    appendTrainingFact(elements.trainingFactLedger, "样本", `${run.sampleCount} 个`);
  }
  if (run.positiveSampleCount != null || run.negativeSampleCount != null) {
    appendTrainingFact(
      elements.trainingFactLedger,
      "标签样本",
      `属于 ${run.positiveSampleCount || 0} · 不属于 ${run.negativeSampleCount || 0}`
    );
  }
  appendTrainingFact(elements.trainingFactLedger, "媒体", run.mediaKind === "video" ? "视频" : "照片");
  appendTrainingFact(elements.trainingFactLedger, "创建", trainingDate(run.createdAtMs));
  if (run.startedAtMs != null) {
    appendTrainingFact(elements.trainingFactLedger, "开始", trainingDate(run.startedAtMs));
  }
  if (run.finishedAtMs != null) {
    appendTrainingFact(elements.trainingFactLedger, "结束", trainingDate(run.finishedAtMs));
  }
  const duration = trainingRunDuration(run);
  if (duration) appendTrainingFact(elements.trainingFactLedger, "耗时", duration);
  appendTrainingFact(elements.trainingFactLedger, "数据范围", trainingRunScopeText(run));
  if (run.mediaKind === "video") {
    appendTrainingFact(elements.trainingFactLedger, "AI 输入", "代表缩略图 videoPoster.v1");
  }
  if (run.jobID) appendTrainingFact(elements.trainingFactLedger, "关联任务", run.jobID.slice(0, 8));

  const guidance = run.failureGuidance;
  elements.trainingErrorSection.classList.toggle("hidden", !run.errorCode);
  elements.trainingErrorTitle.textContent = guidance?.title || "训练未完成";
  elements.trainingErrorMessage.textContent = guidance?.message || "这台 Mac 已保留失败记录。";
  elements.trainingErrorAction.textContent = guidance?.suggestedAction || "检查关联任务后可重新配置。";
  elements.trainingErrorCode.textContent = run.errorCode || "";
  elements.trainingMetricsSummary.textContent = trainingMetricsSummary(run.metricsJSON);
  elements.trainingMetricsJSON.textContent = prettyTrainingJSON(run.metricsJSON, "没有过程指标");

  clearElement(elements.trainingArtifactLedger);
  appendTrainingFact(
    elements.trainingArtifactLedger,
    "类型",
    run.artifactKind || "未发布",
    "training-compact-fact"
  );
  if (run.artifactRef) {
    appendTrainingFact(elements.trainingArtifactLedger, "引用", run.artifactRef, "training-compact-fact");
  }
  if (run.artifactSHA256) {
    appendTrainingFact(elements.trainingArtifactLedger, "SHA-256", run.artifactSHA256, "training-compact-fact");
  }
  if (run.sampleManifestSHA256) {
    appendTrainingFact(
      elements.trainingArtifactLedger,
      "样本清单 SHA-256",
      run.sampleManifestSHA256,
      "training-compact-fact"
    );
  }

  clearElement(elements.trainingTechnicalBlocks);
  appendTrainingIdentifierBlock(run);
  appendTrainingTechnicalBlock("数据", run.sampleSummaryJSON, "没有样本摘要");
  appendTrainingTechnicalBlock("配置", run.configJSON, "没有配置摘要");
  appendTrainingTechnicalBlock("结果", run.resultSummaryJSON, "没有结果摘要");
}

function renderTrainingWorkspace() {
  for (const button of elements.trainingMediaKindTabs.querySelectorAll(
    "[data-training-media-kind]"
  )) {
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.trainingMediaKind === state.training.mediaKind)
    );
  }
  elements.trainingMethodFilter.value = state.training.method;
  elements.trainingRecordScopeFilter.value = state.training.runScope;
  elements.trainingFeatureMethodOption.textContent = state.training.mediaKind === "video"
    ? "相似视频"
    : "相似照片";
  elements.refreshTrainingButton.disabled = state.training.loading;
  elements.refreshTrainingButton.setAttribute("aria-busy", String(state.training.loading));
  elements.trainingWorkspace.classList.toggle(
    "navigator-hidden",
    !state.layout.trainingNavigatorVisible
  );
  const navigatorAction = state.layout.trainingNavigatorVisible ? "隐藏训练记录" : "显示训练记录";
  elements.toggleTrainingNavigatorButton.title = navigatorAction;
  elements.toggleTrainingNavigatorButton.setAttribute("aria-label", navigatorAction);
  elements.toggleTrainingNavigatorButton.setAttribute(
    "aria-pressed",
    String(state.layout.trainingNavigatorVisible)
  );
  const noun = state.training.mediaKind === "video" ? "视频" : "照片";
  const visibleRunCount = visibleTrainingRuns().length;
  elements.trainingSummary.textContent = state.training.loading
    ? `正在读取${noun}训练记录…`
    : `${visibleRunCount} 条${noun}训练记录${state.training.runScope === "all" ? "" : ` · 共 ${state.training.runs.length} 条`}`;
  renderTrainingSlots();
  renderTrainingActivities();
  renderTrainingBatchHistory();
  renderTrainingRunList();
  renderTrainingDetail();
}

async function loadTrainingWorkspace({ quiet = false } = {}) {
  const activeRunRow = document.activeElement?.closest?.("[data-training-run-id]");
  const restoreFocusedRunID = elements.trainingRunList.contains(document.activeElement)
    ? (activeRunRow?.dataset.trainingRunId || state.training.selectedRunID)
    : null;
  const generation = ++state.training.requestGeneration;
  state.training.loading = true;
  renderTrainingWorkspace();
  const query = new URLSearchParams({ mediaKind: state.training.mediaKind });
  if (state.training.method) query.set("method", state.training.method);
  try {
    const snapshot = await api(`/v1/training/workspace?${query}`);
    if (generation !== state.training.requestGeneration) return;
    const previousRunID = state.training.selectedRunID;
    state.training.runs = snapshot.runs || [];
    state.training.slots = snapshot.slots || [];
    state.training.activities = snapshot.activities || [];
    const focusedRun = state.training.runs.find(
      (run) => state.training.focusedRunID && run.id === state.training.focusedRunID
    ) || state.training.runs.find(
      (run) => state.training.focusedJobID && run.jobID === state.training.focusedJobID
    ) || state.training.runs.find(
      (run) => state.training.focusedTagID && run.tagID === state.training.focusedTagID
    );
    if (focusedRun && !visibleTrainingRuns().some((run) => run.id === focusedRun.id)) {
      state.training.runScope = "all";
    }
    const visibleRuns = visibleTrainingRuns();
    state.training.selectedRunID = focusedRun?.id
      || (visibleRuns.some((run) => run.id === previousRunID)
        ? previousRunID
        : (visibleRuns[0]?.id || null));
    if (focusedRun) {
      state.training.focusedRunID = null;
      state.training.focusedJobID = null;
      state.training.focusedTagID = null;
    }
  } catch (error) {
    if (generation === state.training.requestGeneration && !quiet) {
      toast(error.message || "训练记录载入失败");
    }
  } finally {
    if (generation === state.training.requestGeneration) {
      state.training.loading = false;
      renderTrainingWorkspace();
      const pendingReturnFocusRunID = state.training.pendingReturnFocusRunID;
      state.training.pendingReturnFocusRunID = null;
      if (pendingReturnFocusRunID
        && !elements.trainingWorkspace.classList.contains("hidden")) {
        stabilizeDismissedOverlayFocus(
          () => elements.trainingRunList.querySelector(
            `[data-training-run-id="${CSS.escape(pendingReturnFocusRunID)}"]`
          ),
          elements.reviewWorkspace,
          () => !elements.trainingWorkspace.classList.contains("hidden")
        );
      } else if (restoreFocusedRunID) {
        const nextFocusID = visibleTrainingRuns().some((run) => run.id === restoreFocusedRunID)
          ? restoreFocusedRunID
          : state.training.selectedRunID;
        focusTrainingRun(nextFocusID);
      }
    }
  }
}

async function openTrainingWorkspace({ returnToReview = null } = {}) {
  elements.reviewWorkspace.classList.add("hidden");
  if (returnToReview) {
    state.training.returnTarget = {
      workspace: "review",
      mode: returnToReview.mode || "overview",
      tagID: returnToReview.tagID || null,
      jobID: returnToReview.jobID || null,
    };
  } else {
    state.training.returnTarget = null;
    state.reviewReturnFocus = null;
  }
  elements.slimmingWorkspace.classList.add("hidden");
  state.slimmingReturnFocus = null;
  closeJobsPopover({ restoreFocus: false });
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  if (elements.trainingWorkspace.classList.contains("hidden")) {
    state.trainingReturnFocus = document.activeElement;
  }
  elements.appView.inert = true;
  elements.trainingWorkspace.classList.remove("hidden");
  syncTrainingClosePresentation();
  requestAnimationFrame(() => {
    elements.closeTrainingButton.focus({ preventScroll: true });
  });
  await loadTrainingWorkspace();
}

function slimmingModeText(mode) {
  return {
    catalog: "全部来源",
    currentFilter: "当前筛选",
    seeds: "从所选项目查找",
  }[mode] || "分析";
}

function slimmingJobStateText(job) {
  if (job?.state === "running" && job.controlRequest === "pause") return "正在暂停";
  if (job?.state === "running" && job.controlRequest === "cancel") return "正在取消";
  return jobStateText(job || {});
}

function slimmingScanPhaseText(progress) {
  if (!progress) return "";
  return {
    preparingFingerprints: "补全内容指纹",
    loadingFeaturePrints: "加载 Feature Print",
    loadingEmbeddings: "加载 DINOv2 向量",
    clustering: "聚类分析",
  }[progress.phase] || "分析中";
}

function selectedSlimmingJob() {
  return state.slimming.jobs.find((job) => job.id === state.slimming.selectedJobID) || null;
}

function selectedSlimmingJobIndex() {
  return state.slimming.jobs.findIndex((job) => job.id === state.slimming.selectedJobID);
}

function focusSelectedSlimmingJob() {
  requestAnimationFrame(() => {
    const selected = elements.slimmingJobList.querySelector('[aria-selected="true"]');
    selected?.focus({ preventScroll: true });
    selected?.scrollIntoView({ block: "nearest", inline: "center" });
  });
}

async function navigateSlimmingJob(target) {
  if (!state.slimming.jobs.length || state.slimming.loading) return;
  const current = Math.max(0, selectedSlimmingJobIndex());
  const index = target === "first"
    ? 0
    : target === "last"
      ? state.slimming.jobs.length - 1
      : Math.max(0, Math.min(state.slimming.jobs.length - 1, current + Number(target)));
  const job = state.slimming.jobs[index];
  if (!job || job.id === state.slimming.selectedJobID) return;
  state.slimming.selectedJobID = job.id;
  state.slimming.selectedClusterID = null;
  state.slimming.selectedMemberIDs.clear();
  state.slimming.selectionAnchorID = null;
  state.slimming.clusterLimit = 48;
  state.slimming.memberLimit = 96;
  await loadSlimmingWorkspace({ jobID: job.id });
  focusSelectedSlimmingJob();
}

function appendSlimmingScanProgress(container, job, compact = false) {
  const scan = job?.scanProgress;
  if (!scan) return;
  const completed = Math.max(0, Number(scan.completedUnitCount || 0));
  const total = Math.max(1, Number(scan.totalUnitCount || 1));
  const wrapper = document.createElement("span");
  wrapper.className = `slimming-scan-progress${compact ? " compact" : ""}`;
  const track = document.createElement("span");
  track.className = "slimming-scan-progress-track";
  const fill = document.createElement("span");
  fill.style.width = `${Math.min(100, Math.max(0, completed / total * 100))}%`;
  track.append(fill);
  const copy = document.createElement("span");
  copy.textContent = `${slimmingScanPhaseText(scan)} ${completed}/${total}`;
  wrapper.append(track, copy);
  container.append(wrapper);
}

function slimmingClusterPresentation(cluster) {
  if (cluster.isSeedOnlyResult) {
    return {
      title: state.slimming.mediaKind === "video" ? "种子视频" : "种子照片",
      detail: "未找到相似项 · 可继续检查所选项目",
    };
  }
  const video = state.slimming.mediaKind === "video";
  const title = {
    byteIdentical: video ? "完全相同视频" : "完全相同",
    perceptualDuplicate: video ? "代表缩略图重复" : "视觉重复",
    nearDuplicateScene: video ? "相似视频" : "同场景相似",
  }[cluster.kind] || "相似项目";
  const detail = cluster.kind === "byteIdentical"
    ? (video ? "完整视频文件一致" : "内容完全一致")
    : `${cluster.kind === "nearDuplicateScene" ? "相似度" : "匹配度"} ${Math.round(cluster.score * 100)}%`;
  return { title, detail };
}

function renderSlimmingJobActions() {
  clearElement(elements.slimmingJobActions);
  const job = state.slimming.jobs.find((item) => item.id === state.slimming.selectedJobID);
  if (!job) return;
  const mutating = state.slimming.jobMutatingIDs.has(job.id);
  for (const action of job.availableActions || []) {
    if (!['pause', 'resume'].includes(action)) continue;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "button button-compact write-action slimming-job-action";
    button.dataset.slimmingJobActionId = job.id;
    button.dataset.action = action;
    button.disabled = mutating;
    button.textContent = action === "pause" ? "暂停" : "继续";
    elements.slimmingJobActions.append(button);
  }
  if (job.state !== "running") {
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "button button-compact button-danger write-action slimming-job-action";
    remove.dataset.slimmingJobActionId = job.id;
    remove.dataset.action = "deleteRecord";
    remove.disabled = mutating;
    remove.textContent = "删除记录";
    remove.title = "只删除分析记录和结果，不会删除任何原始媒体";
    elements.slimmingJobActions.append(remove);
  }
}

function renderSlimmingJobs() {
  clearElement(elements.slimmingJobList);
  elements.slimmingJobCount.textContent = `${state.slimming.jobs.length} 条`;
  const selectedIndex = selectedSlimmingJobIndex();
  elements.slimmingJobPosition.textContent = state.slimming.jobs.length
    ? `${Math.max(0, selectedIndex) + 1} / ${state.slimming.jobs.length}`
    : "0 / 0";
  elements.previousSlimmingJobButton.disabled = state.slimming.loading || selectedIndex <= 0;
  elements.nextSlimmingJobButton.disabled = state.slimming.loading
    || selectedIndex < 0
    || selectedIndex >= state.slimming.jobs.length - 1;
  elements.slimmingEmpty.classList.toggle(
    "hidden",
    state.slimming.loading || state.slimming.jobs.length > 0
  );
  const activeCount = state.slimming.jobs.filter(
    (job) => ["pending", "running", "paused", "retryableFailed"].includes(job.state)
  ).length;
  elements.slimmingNavigationCount.textContent = activeCount ? String(activeCount) : "";
  for (const job of state.slimming.jobs) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "slimming-job-row";
    row.dataset.slimmingJobId = job.id;
    row.classList.toggle("selected", job.id === state.slimming.selectedJobID);
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", String(job.id === state.slimming.selectedJobID));
    row.tabIndex = job.id === state.slimming.selectedJobID ? 0 : -1;
    const heading = document.createElement("span");
    heading.className = "slimming-row-heading";
    const title = document.createElement("strong");
    title.textContent = slimmingModeText(job.mode);
    const status = document.createElement("span");
    status.className = `slimming-state ${job.state}`;
    status.textContent = slimmingJobStateText(job);
    heading.append(title, status);
    const counts = document.createElement("span");
    counts.className = "slimming-row-detail";
    const unit = job.mediaKind === "video" ? "个视频" : "张照片";
    const countParts = [`${job.memberCount} ${unit}`];
    if (job.seedCount > 0) countParts.push(`种子 ${job.seedCount}`);
    if (job.hasResult) countParts.push(`${job.clusterCount} 个簇`);
    countParts.push(`尝试 ${job.attempts}/${job.maxAttempts}`);
    counts.textContent = countParts.join(" · ");
    const source = document.createElement("span");
    source.className = "slimming-row-detail";
    source.textContent = job.sourceNames?.length ? job.sourceNames.join(" · ") : "全部可用来源";
    const date = document.createElement("span");
    date.className = "slimming-row-date";
    date.textContent = formatDate(job.updatedAtMs);
    row.append(heading, counts);
    appendSlimmingScanProgress(row, job, true);
    row.append(source, date);
    elements.slimmingJobList.append(row);
  }
  renderSlimmingJobActions();
}

function renderSlimmingJobStatus() {
  clearElement(elements.slimmingJobStatus);
  const job = selectedSlimmingJob();
  const visible = job && [
    "pending", "running", "paused", "retryableFailed", "terminalFailed", "cancelled",
  ].includes(job.state);
  elements.slimmingJobStatus.classList.toggle("hidden", !visible);
  if (!visible) return;
  elements.slimmingJobStatus.className = `slimming-job-status ${job.state}`;
  const copy = document.createElement("div");
  copy.className = "slimming-job-status-copy";
  const heading = document.createElement("strong");
  heading.textContent = slimmingJobStateText(job);
  const detail = document.createElement("span");
  const source = job.sourceNames?.length ? job.sourceNames.join("、") : "任务来源不可用";
  detail.textContent = `${slimmingModeText(job.mode)} · ${source} · 尝试 ${job.attempts}/${job.maxAttempts}`;
  copy.append(heading, detail);
  elements.slimmingJobStatus.append(copy);
  appendSlimmingScanProgress(elements.slimmingJobStatus, job);
  const actions = document.createElement("span");
  actions.className = "slimming-job-status-actions";
  const activity = document.createElement("button");
  activity.type = "button";
  activity.className = "button button-compact";
  activity.dataset.openJobActivityId = job.id;
  activity.textContent = "在任务中查看";
  actions.append(activity);
  if (job.state === "retryableFailed" && job.availableActions?.includes("resume")) {
    const resume = document.createElement("button");
    resume.type = "button";
    resume.className = "button button-compact write-action";
    resume.dataset.slimmingJobActionId = job.id;
    resume.dataset.action = "resume";
    resume.textContent = "继续分析";
    actions.append(resume);
  }
  elements.slimmingJobStatus.append(actions);
  if (["pending", "running"].includes(job.state)) {
    const guard = document.createElement("span");
    guard.className = "slimming-job-guard";
    guard.textContent = "分析完成或暂停前，一键清理保持锁定";
    elements.slimmingJobStatus.append(guard);
  }
  if (["retryableFailed", "terminalFailed"].includes(job.state)) {
    const diagnosis = document.createElement("span");
    diagnosis.className = "slimming-job-diagnosis";
    diagnosis.textContent = jobFailureGuidance(job);
    if (job.lastErrorCode) {
      const code = document.createElement("code");
      code.textContent = job.lastErrorCode;
      diagnosis.append(" ", code);
    }
    elements.slimmingJobStatus.append(diagnosis);
  }
}

function appendSlimmingInspectorField(label, value, className = "") {
  const wrapper = document.createElement("div");
  wrapper.className = `slimming-inspector-field${className ? ` ${className}` : ""}`;
  const term = document.createElement("dt");
  term.textContent = label;
  const detail = document.createElement("dd");
  detail.textContent = value || "—";
  wrapper.append(term, detail);
  elements.slimmingInspectorContent.append(wrapper);
}

function renderSlimmingInspector() {
  clearElement(elements.slimmingInspectorContent);
  const job = selectedSlimmingJob();
  const cluster = state.slimming.clusters.find(
    (item) => item.id === state.slimming.selectedClusterID
  ) || null;
  const clusterCopy = cluster ? slimmingClusterPresentation(cluster) : null;
  const sourceNames = [...new Set(
    state.slimming.members.map((member) => member.sourceName).filter(Boolean)
  )];
  elements.slimmingInspectorSummary.textContent = clusterCopy?.title
    || (job ? `${slimmingModeText(job.mode)} · ${slimmingJobStateText(job)}` : "分析概览");

  appendSlimmingInspectorField("分析记录", `${state.slimming.jobs.length} 条`);
  appendSlimmingInspectorField("当前任务", job ? slimmingModeText(job.mode) : "未选择");
  appendSlimmingInspectorField("状态", job ? slimmingJobStateText(job) : "—");
  appendSlimmingInspectorField(
    "尝试次数",
    job ? `${job.attempts}/${job.maxAttempts}` : "—"
  );
  appendSlimmingInspectorField(
    "任务来源",
    job?.sourceNames?.length ? job.sourceNames.join("、") : "任务来源不可用",
    "technical"
  );
  appendSlimmingInspectorField(
    "分析范围",
    job ? `${job.memberCount} ${job.mediaKind === "video" ? "个" : "张"}` : "—"
  );
  appendSlimmingInspectorField("已分析", `${state.slimming.analyzedAssetCount} 项`);
  appendSlimmingInspectorField("待分析", `${state.slimming.pendingAnalysisCount} 项`);
  appendSlimmingInspectorField("策略版本", state.slimming.policyVersion || "—");

  if (cluster) {
    appendSlimmingInspectorField("类型", clusterCopy.title);
    appendSlimmingInspectorField("成员", `${cluster.memberCount} 项`);
    appendSlimmingInspectorField("已选", `${state.slimming.selectedMemberIDs.size} 项`);
    appendSlimmingInspectorField("来源", sourceNames.join("、") || "正在读取…");
    appendSlimmingInspectorField("结果", clusterCopy.detail, "technical");
    appendSlimmingInspectorField(
      "技术详情",
      cluster.technicalSummary || "技术摘要不可用",
      "technical"
    );
  }
}

function renderSlimmingClusters() {
  clearElement(elements.slimmingClusterList);
  const selectedJob = state.slimming.jobs.find((job) => job.id === state.slimming.selectedJobID);
  const totalClusterCount = selectedJob?.clusterCount ?? state.slimming.clusters.length;
  elements.slimmingClusterCount.textContent = totalClusterCount > state.slimming.clusters.length
    ? `${state.slimming.clusters.length} / ${totalClusterCount} 组`
    : `${state.slimming.clusters.length} 组`;
  elements.slimmingLoadMoreClustersButton.classList.toggle(
    "hidden",
    state.slimming.loading || state.slimming.clusters.length >= totalClusterCount
  );
  elements.slimmingClusterEmpty.classList.toggle(
    "hidden",
    state.slimming.loading || !state.slimming.selectedJobID || state.slimming.clusters.length > 0
  );
  for (const cluster of state.slimming.clusters) {
    const copy = slimmingClusterPresentation(cluster);
    const row = document.createElement("button");
    row.type = "button";
    row.className = "slimming-cluster-row";
    row.dataset.slimmingClusterId = cluster.id;
    row.classList.toggle("selected", cluster.id === state.slimming.selectedClusterID);
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", String(cluster.id === state.slimming.selectedClusterID));
    const image = document.createElement("img");
    image.loading = "lazy";
    image.alt = "";
    image.setAttribute("aria-hidden", "true");
    setProtectedImageSource(
      image,
      `/v1/assets/${cluster.representativeAssetID}/thumbnail?w=180&rev=0`
    );
    const text = document.createElement("span");
    text.className = "slimming-cluster-copy";
    const title = document.createElement("strong");
    title.textContent = `${copy.title} · ${cluster.memberCount} 项`;
    const detail = document.createElement("span");
    detail.textContent = copy.detail;
    text.append(title, detail);
    row.append(image, text);
    elements.slimmingClusterList.append(row);
  }
}

function renderSlimmingMemberSelection() {
  for (const card of elements.slimmingMemberGrid.querySelectorAll("[data-slimming-member-id]")) {
    const selected = state.slimming.selectedMemberIDs.has(card.dataset.slimmingMemberId);
    card.classList.toggle("selected", selected);
    card.setAttribute("aria-pressed", String(selected));
  }
  const selectedCount = state.slimming.selectedMemberIDs.size;
  elements.slimmingSelectionSummary.textContent = selectedCount
    ? `已选择 ${selectedCount} 项`
    : "";
  elements.slimmingSelectionBar.classList.toggle("hidden", selectedCount === 0);
  elements.slimmingSelectionBarSummary.textContent = `已选择 ${selectedCount} 项`;
  const active = currentSlimmingRemovalRequest()?.phase;
  const identicalActive = currentSlimmingIdenticalCleanupRequest()?.phase;
  const unavailable = state.slimming.removal.submitting
    || active === "awaitingMac"
    || active === "running"
    || identicalActive === "awaitingMac"
    || identicalActive === "running";
  elements.slimmingMoveToRecycleButton.disabled = unavailable || selectedCount === 0;
  elements.slimmingReleaseSpaceButton.disabled = unavailable || selectedCount === 0;
  renderSlimmingInspector();
}

function currentSlimmingRemovalRequest() {
  return state.slimming.removal.requests.find((request) =>
    request.phase === "awaitingMac" || request.phase === "running"
  ) || state.slimming.removal.requests.find((request) =>
    request.jobID === state.slimming.selectedJobID
      && request.clusterID === state.slimming.selectedClusterID
      && Date.now() - Number(request.updatedAtMs || 0) < 10 * 60 * 1000
  ) || null;
}

function currentSlimmingIdenticalCleanupRequest() {
  return state.slimming.identicalCleanup.requests.find((request) =>
    request.phase === "awaitingMac" || request.phase === "running"
  ) || state.slimming.identicalCleanup.requests.find((request) =>
    request.jobID === state.slimming.selectedJobID
      && Date.now() - Number(request.updatedAtMs || 0) < 10 * 60 * 1000
  ) || null;
}

function renderSlimmingRemovalStatus() {
  const request = currentSlimmingIdenticalCleanupRequest()
    || currentSlimmingRemovalRequest();
  elements.slimmingRemovalStatus.classList.toggle("hidden", !request);
  clearElement(elements.slimmingRemovalStatus);
  if (!request) return;

  const header = document.createElement("div");
  header.className = "slimming-removal-status-header";
  const message = document.createElement("strong");
  message.textContent = request.message || "Mac 正在处理批量操作…";
  const phase = document.createElement("span");
  phase.className = "secondary";
  phase.textContent = {
    awaitingMac: "等待 Mac 确认",
    running: "处理中",
    completed: "已完成",
    cancelled: "已取消",
    failed: "未完成",
  }[request.phase] || request.phase;
  header.append(message, phase);
  elements.slimmingRemovalStatus.append(header);

  if (request.progress && request.phase === "running") {
    const progress = document.createElement("progress");
    progress.max = Math.max(1, Number(request.progress.totalAssetCount || 1));
    progress.value = Math.max(0, Number(request.progress.completedAssetCount || 0));
    progress.setAttribute(
      "aria-label",
      `已完成 ${progress.value}/${progress.max} 项`
    );
    elements.slimmingRemovalStatus.append(progress);
  }
  if (request.audit) {
    const audit = document.createElement("div");
    audit.className = "slimming-removal-audit";
    const parts = [];
    if (request.audit.hiddenAssetIDs?.length) {
      parts.push(`已从候选结果隐藏 ${request.audit.hiddenAssetIDs.length} 项`);
    }
    if (request.audit.failedAssetIDs?.length) {
      parts.push(`失败 ${request.audit.failedAssetIDs.length} 项`);
    }
    if (request.audit.authorizationRequiredAssetIDs?.length) {
      parts.push(`待来源授权 ${request.audit.authorizationRequiredAssetIDs.length} 项`);
    }
    if (request.audit.authorizationDeniedPhotosAssetIDs?.length) {
      parts.push(`Photos 未授权 ${request.audit.authorizationDeniedPhotosAssetIDs.length} 项`);
    }
    audit.textContent = parts.join(" · ") || "逐项结果已由 Mac 安全核验";
    elements.slimmingRemovalStatus.append(audit);
  }
  if (request.verification) {
    const verification = document.createElement("div");
    verification.className = "slimming-removal-audit";
    verification.textContent = request.verification.isComplete
      ? `已独立核验：${request.verification.verifiedGroupCount}/${request.verification.targetGroupCount} 组均只保留一项`
      : `核验结果：完成 ${request.verification.verifiedGroupCount}/${request.verification.targetGroupCount} 组 · 尚有 ${request.verification.remainingRedundantAssetCount} 项冗余`;
    elements.slimmingRemovalStatus.append(verification);
    const report = document.createElement("button");
    report.type = "button";
    report.className = "button button-compact slimming-verification-button";
    report.dataset.slimmingVerificationRequestId = request.id;
    report.textContent = "查看完整核验报告";
    elements.slimmingRemovalStatus.append(report);
  }
}

function appendSlimmingVerificationMetric(label, value, tone) {
  const card = document.createElement("div");
  card.className = `identical-cleanup-metric ${tone || ""}`;
  const title = document.createElement("span");
  title.textContent = label;
  const count = document.createElement("strong");
  count.textContent = Number(value || 0).toLocaleString();
  card.append(title, count);
  elements.slimmingVerificationMetrics.append(card);
}

function openSlimmingVerificationReport(request) {
  const verification = request?.verification;
  if (!verification) return;
  const complete = Boolean(verification.isComplete);
  elements.slimmingVerificationDialog.classList.toggle("incomplete", !complete);
  elements.slimmingVerificationIcon.textContent = complete ? "✓" : "!";
  elements.slimmingVerificationTitle.textContent = complete
    ? "删除后核验完成"
    : "删除后核验存在未完成项";
  elements.slimmingVerificationSubtitle.textContent =
    "已重新读取本次处理资产的实时可用与回收状态。";
  elements.slimmingVerificationScore.textContent =
    `${verification.verifiedGroupCount} / ${verification.targetGroupCount}`;
  elements.slimmingVerificationGoal.textContent =
    `目标是每组保留 1 项，共 ${verification.targetRetainedAssetCount} 项；只把删除后确实仅剩 1 项的分组计入已完成。`;
  clearElement(elements.slimmingVerificationMetrics);
  appendSlimmingVerificationMetric("目标保留", verification.targetRetainedAssetCount, "blue");
  appendSlimmingVerificationMetric("当前实际可用", verification.currentAvailableAssetCount, "green");
  appendSlimmingVerificationMetric("完成去重", verification.verifiedGroupCount, "indigo");
  appendSlimmingVerificationMetric("尚未完成", verification.unresolvedGroupCount, complete ? "neutral" : "orange");
  clearElement(elements.slimmingVerificationResult);
  const heading = document.createElement("strong");
  heading.textContent = complete ? "核验完成" : "核验发现未完成项";
  const detail = document.createElement("p");
  detail.textContent = complete
    ? `实际读取 ${verification.observedAssetCount} 项，确认已清理 ${verification.recycledRedundantAssetCount} 项；处理范围内没有仍处于可用状态的计划删除项。`
    : `实际读取 ${verification.observedAssetCount} 项；确认已清理 ${verification.recycledRedundantAssetCount} 项；当前实际可用 ${verification.currentAvailableAssetCount} 项；仍可用冗余 ${verification.remainingRedundantAssetCount} 项；状态无法确认 ${verification.unresolvedAssetCount} 项。`;
  elements.slimmingVerificationResult.append(heading, detail);
  if (!elements.slimmingVerificationDialog.open) {
    elements.slimmingVerificationDialog.showModal();
  }
  requestAnimationFrame(() => elements.closeSlimmingVerificationButton.focus());
}

function closeSlimmingVerificationReport() {
  if (elements.slimmingVerificationDialog.open) {
    elements.slimmingVerificationDialog.close();
  }
}

function renderSlimmingMembers() {
  clearElement(elements.slimmingMemberGrid);
  const cluster = state.slimming.clusters.find(
    (item) => item.id === state.slimming.selectedClusterID
  );
  const copy = cluster ? slimmingClusterPresentation(cluster) : null;
  elements.slimmingMemberEmpty.classList.toggle("hidden", Boolean(cluster));
  elements.slimmingMemberGrid.classList.toggle("hidden", !cluster);
  elements.slimmingMemberTitle.textContent = copy?.title || "选择一个候选分组";
  const sourceNames = [...new Set(state.slimming.members.map((item) => item.sourceName).filter(Boolean))];
  elements.slimmingMemberSummary.textContent = cluster
    ? `${copy.detail} · ${state.slimming.members.length}/${cluster.memberCount} 项 · ${sourceNames.join(" · ") || "来源信息不可用"}`
    : "分组中的照片会在这里显示";
  elements.slimmingLoadMoreMembersButton.classList.toggle(
    "hidden",
    !cluster || state.slimming.loading || state.slimming.members.length >= cluster.memberCount
  );
  for (const member of state.slimming.members) {
    const card = document.createElement("button");
    card.type = "button";
    card.className = "slimming-member-card";
    card.dataset.slimmingMemberId = member.id;
    card.setAttribute("aria-label", `${member.fileName || "未命名项目"}，${member.sourceName || "来源未知"}`);
    const image = document.createElement("img");
    image.loading = "lazy";
    image.alt = "";
    image.setAttribute("aria-hidden", "true");
    setProtectedImageSource(
      image,
      `/v1/assets/${member.id}/thumbnail?w=360&rev=${member.contentRevision || 0}`
    );
    const footer = document.createElement("span");
    footer.className = "slimming-member-footer";
    const name = document.createElement("strong");
    name.textContent = member.fileName || "未命名项目";
    const source = document.createElement("span");
    source.textContent = member.sourceName || availabilityText(member.availability);
    footer.append(name, source);
    card.append(image, footer);
    elements.slimmingMemberGrid.append(card);
  }
  renderSlimmingMemberSelection();
}

function slimmingRecycleCountdown(entry) {
  if (entry.sourceKind === "photos") {
    return "实际保留期限与永久删除由系统“照片”App 管理";
  }
  const remaining = Number(entry.purgeAfterMs) - Date.now();
  if (remaining <= 0) return "即将永久删除";
  const hour = 60 * 60 * 1000;
  const day = 24 * hour;
  if (remaining < day) return `${Math.max(1, Math.ceil(remaining / hour))} 小时后永久删除`;
  return `${Math.max(1, Math.ceil(remaining / day))} 天后永久删除`;
}

function slimmingRecycleStateCopy(entry) {
  if (entry.resolution === "discardPreflightFailure") {
    return "未执行：缺少来源写入授权，可安全撤销失败意图";
  }
  if (entry.resolution === "retryInterruptedOperation") {
    return "操作曾被中断，需要重新检查原位置与隔离区";
  }
  if (entry.resolution === "inspect") {
    return `状态无法自动确定${entry.errorCode ? ` · ${entry.errorCode}` : ""}`;
  }
  return slimmingRecycleCountdown(entry);
}

function renderSlimmingRecycleSourceOptions() {
  const previous = state.slimming.recycle.sourceID;
  clearElement(elements.slimmingRecycleSourceSelect);
  const all = document.createElement("option");
  all.value = "";
  all.textContent = "全部来源";
  elements.slimmingRecycleSourceSelect.append(all);
  for (const source of state.sources) {
    const option = document.createElement("option");
    option.value = source.id;
    option.textContent = source.displayName;
    elements.slimmingRecycleSourceSelect.append(option);
  }
  elements.slimmingRecycleSourceSelect.value = previous;
  if (elements.slimmingRecycleSourceSelect.value !== previous) {
    state.slimming.recycle.sourceID = "";
  }
}

function renderSlimmingRecycleRequest() {
  const requests = state.slimming.recycle.requests || [];
  const active = requests.find((request) => ["awaitingMac", "running"].includes(request.phase));
  const latest = active || requests[0] || null;
  elements.slimmingRecycleRequestStatus.classList.toggle("hidden", !latest);
  elements.slimmingRecycleRequestStatus.textContent = latest
    ? `${latest.fileName || "回收站项目"}：${latest.message}`
    : "";
  if (!active && latest && ["completed", "cancelled", "failed"].includes(latest.phase)
    && state.slimming.recycle.lastTerminalRequestID !== latest.id) {
    state.slimming.recycle.lastTerminalRequestID = latest.id;
    toast(latest.message);
  }
}

function renderSlimmingRecycle() {
  const recycle = state.slimming.recycle;
  elements.slimmingRecycleSearchInput.value = recycle.searchText;
  renderSlimmingRecycleSourceOptions();
  elements.slimmingRecycleCount.textContent = recycle.totalCount > recycle.entries.length
    ? `${recycle.entries.length} / ${recycle.totalCount} 项`
    : `${recycle.totalCount} 项`;
  elements.slimmingRecycleLoadMoreButton.classList.toggle(
    "hidden",
    recycle.loading || recycle.entries.length >= recycle.totalCount
  );
  elements.slimmingRecycleEmpty.classList.toggle(
    "hidden",
    recycle.loading || recycle.entries.length > 0
  );
  clearElement(elements.slimmingRecycleList);
  elements.slimmingRecycleList.classList.toggle("hidden", recycle.entries.length === 0);
  for (const entry of recycle.entries) {
    const row = document.createElement("article");
    row.className = "slimming-recycle-row";
    row.dataset.slimmingRecycleRowId = entry.id;
    const image = document.createElement("img");
    image.className = "slimming-recycle-thumbnail";
    image.alt = "";
    image.setAttribute("aria-hidden", "true");
    setProtectedImageSource(image, `/v1/assets/${entry.assetID}/thumbnail?w=180`);
    const copy = document.createElement("div");
    copy.className = "slimming-recycle-copy";
    const title = document.createElement("strong");
    title.textContent = entry.fileName || "未命名媒体";
    const meta = document.createElement("span");
    meta.className = "slimming-recycle-meta";
    meta.textContent = `${entry.sourceKind === "photos" ? "Apple Photos" : "文件夹"} · ${entry.sourceDisplayName} · ${formatDate(entry.trashedAtMs)}`;
    const detail = document.createElement("span");
    detail.className = "slimming-recycle-detail";
    detail.classList.toggle("warning", entry.resolution !== "restoreOrPurge"
      && entry.resolution !== "photosManagedBySystem");
    detail.textContent = slimmingRecycleStateCopy(entry);
    copy.append(title, meta, detail);
    const actions = document.createElement("div");
    actions.className = "slimming-recycle-actions";
    if (entry.resolution === "photosManagedBySystem") {
      const info = document.createElement("button");
      info.type = "button";
      info.className = "button button-compact";
      info.dataset.slimmingRecycleInfo = "photos";
      info.textContent = "恢复说明";
      actions.append(info);
    }
    for (const action of entry.availableActions || []) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `button button-compact write-action${action === "purge" ? " button-danger" : ""}`;
      button.dataset.slimmingRecycleEntryId = entry.id;
      button.dataset.action = action;
      button.disabled = recycle.mutatingEntryIDs.has(entry.id);
      button.textContent = {
        restore: "恢复",
        discardPreflightFailure: "撤销失败记录",
        retryInterruptedOperation: "重新检查状态",
        purge: "立即删除",
      }[action];
      actions.append(button);
    }
    row.append(image, copy, actions);
    elements.slimmingRecycleList.append(row);
  }
  renderSlimmingRecycleRequest();
  syncWriteActionControls();
}

function scheduleSlimmingRecyclePoll() {
  clearTimeout(state.slimming.recycle.pollTimer);
  state.slimming.recycle.pollTimer = null;
  if (elements.slimmingWorkspace.classList.contains("hidden")
    || state.slimming.view !== "recycle") return;
  const active = state.slimming.recycle.requests.some(
    (request) => ["awaitingMac", "running"].includes(request.phase)
  );
  if (!active) return;
  state.slimming.recycle.pollTimer = setTimeout(() => {
    loadSlimmingRecycle({ quiet: true });
  }, 1000);
}

async function loadSlimmingRecycle({ quiet = false } = {}) {
  const recycle = state.slimming.recycle;
  const generation = ++recycle.requestGeneration;
  recycle.loading = true;
  renderSlimmingWorkspace();
  const query = new URLSearchParams({
    mediaKind: state.slimming.mediaKind,
    limit: String(recycle.limit),
  });
  if (recycle.sourceID) query.set("sourceID", recycle.sourceID);
  if (recycle.searchText.trim()) query.set("search", recycle.searchText.trim());
  try {
    const snapshot = await api(`/v1/library-slimming/recycle?${query}`);
    if (generation !== recycle.requestGeneration) return;
    recycle.entries = snapshot.entries || [];
    recycle.totalCount = snapshot.totalCount || 0;
    recycle.requests = snapshot.requests || [];
  } catch (error) {
    if (generation === recycle.requestGeneration && !quiet) {
      toast(error.message || "回收站载入失败");
    }
  } finally {
    if (generation === recycle.requestGeneration) {
      recycle.loading = false;
      renderSlimmingWorkspace();
      scheduleSlimmingRecyclePoll();
    }
  }
}

async function submitSlimmingRecycleAction(entryID, action) {
  const entry = state.slimming.recycle.entries.find((item) => item.id === entryID);
  if (!entry || state.slimming.recycle.mutatingEntryIDs.has(entryID)) return;
  if (action === "purge" && !window.confirm(
    `永久删除“${entry.fileName || "未命名媒体"}”？\n\n网页提交后还必须在 Mac 上再次确认。此操作完成后无法恢复。`
  )) return;
  if (action === "discardPreflightFailure" && !window.confirm(
    "撤销这条未执行的失败记录？\n\n只移除失败意图，不会读写、移动或删除原文件。"
  )) return;
  state.slimming.recycle.mutatingEntryIDs.add(entryID);
  renderSlimmingRecycle();
  try {
    const request = await api("/v1/library-slimming/recycle/requests", {
      method: "POST",
      body: JSON.stringify({ operationID: crypto.randomUUID(), entryID, action }),
    });
    state.slimming.recycle.requests = [
      request,
      ...state.slimming.recycle.requests.filter((item) => item.id !== request.id),
    ];
    toast(request.phase === "awaitingMac" ? "请回到 Mac 完成确认" : request.message);
  } catch (error) {
    toast(error.message || "回收站操作提交失败");
  } finally {
    state.slimming.recycle.mutatingEntryIDs.delete(entryID);
    renderSlimmingRecycle();
    scheduleSlimmingRecyclePoll();
  }
}

async function setSlimmingView(view) {
  if (!['analysis', 'recycle'].includes(view) || view === state.slimming.view) return;
  state.slimming.view = view;
  renderSlimmingWorkspace();
  if (view === "recycle") await loadSlimmingRecycle();
  else {
    await loadSlimmingWorkspace();
    await loadSlimmingRemovals({ quiet: true });
    await loadSlimmingIdenticalCleanupRequests({ quiet: true });
  }
}

function renderSlimmingWorkspace() {
  const recycleView = state.slimming.view === "recycle";
  for (const button of elements.slimmingWorkspaceTabs.querySelectorAll("[data-slimming-view]")) {
    button.setAttribute("aria-pressed", String(button.dataset.slimmingView === state.slimming.view));
  }
  for (const button of elements.slimmingMediaKindTabs.querySelectorAll(
    "[data-slimming-media-kind]"
  )) {
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.slimmingMediaKind === state.slimming.mediaKind)
    );
  }
  elements.slimmingAnalysisBody.classList.toggle("hidden", recycleView);
  elements.slimmingRecycleBody.classList.toggle("hidden", !recycleView);
  elements.newSlimmingAnalysisButton.classList.toggle("hidden", recycleView);
  const identicalGroupCount = state.slimming.clusters.filter(
    (cluster) => cluster.kind === "byteIdentical"
  ).length;
  const identicalActive = currentSlimmingIdenticalCleanupRequest();
  const analysisBlocksIdenticalCleanup = state.slimming.jobs.some(
    (job) => ["pending", "running"].includes(job.state)
  );
  elements.slimmingIdenticalCleanupButton.classList.toggle(
    "hidden",
    recycleView || identicalGroupCount === 0
  );
  elements.slimmingIdenticalCleanupButton.disabled = state.slimming.loading
    || state.slimming.identicalCleanup.preparing
    || state.slimming.identicalCleanup.submitting
    || analysisBlocksIdenticalCleanup
    || ["awaitingMac", "running"].includes(identicalActive?.phase);
  elements.slimmingIdenticalCleanupButton.textContent = identicalGroupCount
    ? `一键清理完全相同（${identicalGroupCount} 组）…`
    : "一键清理完全相同…";
  elements.slimmingIdenticalCleanupButton.setAttribute(
    "aria-label",
    identicalGroupCount
      ? `一键清理完全相同，共 ${identicalGroupCount} 组`
      : "一键清理完全相同"
  );
  elements.slimmingIdenticalCleanupButton.title = analysisBlocksIdenticalCleanup
    ? "请先等待当前分析完成或暂停"
    : "按 Mac 端规则为每个完全相同分组保留一项，并预览其余项目的清理方案";
  const loading = recycleView ? state.slimming.recycle.loading : state.slimming.loading;
  elements.refreshSlimmingButton.disabled = loading;
  elements.refreshSlimmingButton.setAttribute("aria-busy", String(loading));
  const noun = state.slimming.mediaKind === "video" ? "视频" : "照片";
  elements.slimmingNoticeText.textContent = recycleView
    ? "回收站状态来自这台 Mac；恢复、重新协调和永久删除必须在 Mac 原生窗口确认。Apple Photos 仍由系统“照片”App 管理。"
    : "分析与任务控制由这台 Mac 执行；网页只接收结果。";
  elements.slimmingSummary.textContent = recycleView
    ? (state.slimming.recycle.loading
      ? `正在读取${noun}回收站…`
      : `${state.slimming.recycle.totalCount} 个${noun}回收项目`)
    : (state.slimming.loading
      ? `正在读取${noun}分析记录…`
      : `${state.slimming.jobs.length} 条记录 · ${state.slimming.jobs.find((job) => job.id === state.slimming.selectedJobID)?.clusterCount || 0} 个候选分组`);
  if (recycleView) {
    renderSlimmingRecycle();
    return;
  }
  renderSlimmingJobs();
  renderSlimmingClusters();
  renderSlimmingMembers();
  renderSlimmingInspector();
  renderSlimmingJobStatus();
  renderSlimmingRemovalStatus();
}

function scheduleSlimmingRemovalPoll() {
  clearTimeout(state.slimming.removal.pollTimer);
  state.slimming.removal.pollTimer = null;
  const active = state.slimming.removal.requests.some(
    (request) => request.phase === "awaitingMac" || request.phase === "running"
  );
  if (!active || elements.slimmingWorkspace.classList.contains("hidden")) return;
  state.slimming.removal.pollTimer = setTimeout(
    () => loadSlimmingRemovals({ quiet: true }),
    900
  );
}

async function loadSlimmingRemovals({ quiet = false } = {}) {
  const generation = ++state.slimming.removal.requestGeneration;
  const previouslyActiveIDs = new Set(
    state.slimming.removal.requests
      .filter((request) => request.phase === "awaitingMac" || request.phase === "running")
      .map((request) => request.id)
  );
  state.slimming.removal.loading = true;
  try {
    const query = new URLSearchParams({ mediaKind: state.slimming.mediaKind });
    const snapshot = await api(`/v1/library-slimming/removals?${query}`);
    if (generation !== state.slimming.removal.requestGeneration) return;
    state.slimming.removal.requests = snapshot.requests || [];
    const terminal = state.slimming.removal.requests.find((request) =>
      previouslyActiveIDs.has(request.id)
        && ["completed", "cancelled", "failed"].includes(request.phase)
    );
    if (terminal && terminal.id !== state.slimming.removal.lastTerminalRequestID) {
      state.slimming.removal.lastTerminalRequestID = terminal.id;
      if (terminal.audit?.hiddenAssetIDs?.length) {
        const hidden = new Set(terminal.audit.hiddenAssetIDs);
        state.slimming.members = state.slimming.members.filter((member) => !hidden.has(member.id));
        state.slimming.selectedMemberIDs = new Set(
          [...state.slimming.selectedMemberIDs].filter((id) => !hidden.has(id))
        );
      }
      toast(terminal.message || "批量操作已结束");
      if (terminal.phase === "completed") {
        await loadSlimmingWorkspace({ quiet: true });
      }
    }
  } catch (error) {
    if (generation === state.slimming.removal.requestGeneration && !quiet) {
      toast(error.message || "批量操作状态载入失败");
    }
  } finally {
    if (generation === state.slimming.removal.requestGeneration) {
      state.slimming.removal.loading = false;
      renderSlimmingWorkspace();
      scheduleSlimmingRemovalPoll();
    }
  }
}

async function submitSlimmingRemoval(mode) {
  const assetIDs = [...state.slimming.selectedMemberIDs];
  if (!assetIDs.length || !state.slimming.selectedJobID || !state.slimming.selectedClusterID) {
    toast("请先在一个候选分组中选择项目");
    return;
  }
  const noun = state.slimming.mediaKind === "video" ? "段视频" : "张照片";
  const confirmed = mode === "releaseSourceSpace"
    ? window.confirm(
      `立即处理选中的 ${assetIDs.length} ${noun}？\n\n文件夹来源会在身份核验后永久删除，无法从 ImageAll 恢复；Apple Photos 项只会进入系统“最近删除”。提交后还需要在 Mac 原生窗口再次确认。`
    )
    : window.confirm(
      `将选中的 ${assetIDs.length} ${noun}移入可恢复回收站？\n\n文件夹来源会先复制并校验，保留 30 天；Apple Photos 项会进入系统“最近删除”。提交后还需要在 Mac 原生窗口再次确认。`
    );
  if (!confirmed) return;
  state.slimming.removal.submitting = true;
  renderSlimmingMemberSelection();
  try {
    const request = await api("/v1/library-slimming/removals", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        jobID: state.slimming.selectedJobID,
        clusterID: state.slimming.selectedClusterID,
        mediaKind: state.slimming.mediaKind,
        assetIDs,
        mode,
      }),
    });
    state.slimming.removal.requests = [
      request,
      ...state.slimming.removal.requests.filter((item) => item.id !== request.id),
    ];
    toast("已冻结本次选区，请回到 Mac 核对并确认");
  } catch (error) {
    toast(error.message || "批量操作提交失败");
  } finally {
    state.slimming.removal.submitting = false;
    renderSlimmingWorkspace();
    scheduleSlimmingRemovalPoll();
  }
}

function renderSlimmingIdenticalCleanupDialog() {
  const cleanup = state.slimming.identicalCleanup;
  elements.slimmingIdenticalCleanupLoading.classList.toggle("hidden", !cleanup.preparing);
  elements.slimmingIdenticalCleanupContent.classList.toggle(
    "hidden",
    cleanup.preparing || !cleanup.plan
  );
  elements.slimmingIdenticalCleanupError.textContent = cleanup.error || "";
  clearElement(elements.slimmingIdenticalCleanupMetrics);
  clearElement(elements.slimmingIdenticalCleanupSources);
  const plan = cleanup.plan;
  if (plan) {
    for (const [label, value] of [
      ["已核验媒体", plan.verifiedAssetCount],
      ["会保留", plan.retainedAssetCount],
      ["将清理", plan.removalAssetCount],
      ["处理分组", plan.groupCount],
    ]) {
      const card = document.createElement("div");
      card.className = "identical-cleanup-metric";
      const title = document.createElement("span");
      title.textContent = label;
      const count = document.createElement("strong");
      count.textContent = Number(value || 0).toLocaleString();
      card.append(title, count);
      elements.slimmingIdenticalCleanupMetrics.append(card);
    }
    for (const [label, value] of [
      ["Apple Photos", plan.photosAssetCount],
      ["文件夹来源", plan.fileAssetCount],
    ]) {
      const term = document.createElement("dt");
      term.textContent = label;
      const description = document.createElement("dd");
      description.textContent = `${Number(value || 0).toLocaleString()} 项`;
      elements.slimmingIdenticalCleanupSources.append(term, description);
    }
    const notices = [];
    if (plan.fileAssetCount > 0) {
      notices.push(`“快速清理”会永久删除 ${plan.fileAssetCount} 个文件夹原始媒体，无法从 ImageAll 恢复。`);
    }
    if (plan.photosAssetCount > 0) {
      notices.push("Apple Photos 待删项仍会由 macOS 集中显示系统确认。");
    }
    if (plan.skippedGroupCount > 0) {
      notices.push(`${plan.skippedGroupCount} 组因成员或来源状态变化已安全跳过。`);
    }
    elements.slimmingIdenticalCleanupNotice.textContent = notices.join(" ")
      || "执行前 Mac 还会再次核验冻结方案，变化的项目不会被删除。";
  }
  const disabled = cleanup.preparing || cleanup.submitting || !plan;
  elements.recoverableSlimmingIdenticalCleanupButton.disabled = disabled;
  elements.fastSlimmingIdenticalCleanupButton.disabled = disabled;
  elements.recoverableSlimmingIdenticalCleanupButton.textContent = plan
    ? `可恢复回收 ${plan.removalAssetCount} 项`
    : "可恢复回收";
  elements.fastSlimmingIdenticalCleanupButton.textContent = plan
    ? `快速清理 ${plan.removalAssetCount} 项`
    : "快速清理";
}

async function openSlimmingIdenticalCleanupDialog() {
  if (!state.slimming.selectedJobID || state.slimming.identicalCleanup.preparing) return;
  const cleanup = state.slimming.identicalCleanup;
  cleanup.plan = null;
  cleanup.error = "";
  cleanup.preparing = true;
  elements.slimmingIdenticalCleanupDialog.showModal();
  renderSlimmingIdenticalCleanupDialog();
  try {
    cleanup.plan = await api("/v1/library-slimming/identical-cleanup/plans", {
      method: "POST",
      body: JSON.stringify({
        jobID: state.slimming.selectedJobID,
        mediaKind: state.slimming.mediaKind,
      }),
    });
  } catch (error) {
    cleanup.error = error.message || "无法生成一键清理方案";
  } finally {
    cleanup.preparing = false;
    renderSlimmingIdenticalCleanupDialog();
  }
}

function closeSlimmingIdenticalCleanupDialog() {
  if (state.slimming.identicalCleanup.submitting) return;
  if (elements.slimmingIdenticalCleanupDialog.open) {
    elements.slimmingIdenticalCleanupDialog.close();
  }
  state.slimming.identicalCleanup.plan = null;
  state.slimming.identicalCleanup.error = "";
}

async function submitSlimmingIdenticalCleanup(mode) {
  const cleanup = state.slimming.identicalCleanup;
  if (!cleanup.plan || cleanup.submitting) return;
  cleanup.submitting = true;
  cleanup.error = "";
  renderSlimmingIdenticalCleanupDialog();
  try {
    const request = await api("/v1/library-slimming/identical-cleanup/requests", {
      method: "POST",
      body: JSON.stringify({
        operationID: crypto.randomUUID(),
        planID: cleanup.plan.id,
        mode,
      }),
    });
    cleanup.requests = [
      request,
      ...cleanup.requests.filter((item) => item.id !== request.id),
    ];
    elements.slimmingIdenticalCleanupDialog.close();
    cleanup.plan = null;
    toast("方案已冻结，请回到 Mac 核对并确认");
    renderSlimmingWorkspace();
    scheduleSlimmingIdenticalCleanupPoll();
  } catch (error) {
    cleanup.error = error.message || "一键清理提交失败";
  } finally {
    cleanup.submitting = false;
    renderSlimmingIdenticalCleanupDialog();
  }
}

function scheduleSlimmingIdenticalCleanupPoll() {
  const cleanup = state.slimming.identicalCleanup;
  clearTimeout(cleanup.pollTimer);
  cleanup.pollTimer = null;
  const active = cleanup.requests.some(
    (request) => request.phase === "awaitingMac" || request.phase === "running"
  );
  if (!active || elements.slimmingWorkspace.classList.contains("hidden")) return;
  cleanup.pollTimer = setTimeout(
    () => loadSlimmingIdenticalCleanupRequests({ quiet: true }),
    900
  );
}

async function loadSlimmingIdenticalCleanupRequests({ quiet = false } = {}) {
  const cleanup = state.slimming.identicalCleanup;
  const generation = ++cleanup.requestGeneration;
  const previouslyActiveIDs = new Set(cleanup.requests
    .filter((request) => request.phase === "awaitingMac" || request.phase === "running")
    .map((request) => request.id));
  try {
    const query = new URLSearchParams({ mediaKind: state.slimming.mediaKind });
    const snapshot = await api(`/v1/library-slimming/identical-cleanup/requests?${query}`);
    if (generation !== cleanup.requestGeneration) return;
    cleanup.requests = snapshot.requests || [];
    const terminal = cleanup.requests.find((request) =>
      previouslyActiveIDs.has(request.id)
        && ["completed", "cancelled", "failed"].includes(request.phase));
    if (terminal && terminal.id !== cleanup.lastTerminalRequestID) {
      cleanup.lastTerminalRequestID = terminal.id;
      toast(terminal.message || "一键清理已结束");
      if (terminal.verification && terminal.id !== cleanup.lastPresentedVerificationID) {
        cleanup.lastPresentedVerificationID = terminal.id;
        openSlimmingVerificationReport(terminal);
      }
      if (terminal.phase === "completed") {
        await loadSlimmingWorkspace({ quiet: true });
        await loadSlimmingRemovals({ quiet: true });
      }
    }
  } catch (error) {
    if (generation === cleanup.requestGeneration && !quiet) {
      toast(error.message || "一键清理状态载入失败");
    }
  } finally {
    if (generation === cleanup.requestGeneration) {
      renderSlimmingWorkspace();
      scheduleSlimmingIdenticalCleanupPoll();
    }
  }
}

async function loadSlimmingWorkspace({ jobID = null, clusterID = null, quiet = false } = {}) {
  const generation = ++state.slimming.requestGeneration;
  const previousSelectedMemberIDs = new Set(state.slimming.selectedMemberIDs);
  const previousSelectionAnchorID = state.slimming.selectionAnchorID;
  state.slimming.loading = true;
  renderSlimmingWorkspace();
  const query = new URLSearchParams({ mediaKind: state.slimming.mediaKind });
  query.set("clusterLimit", String(state.slimming.clusterLimit));
  query.set("memberLimit", String(state.slimming.memberLimit));
  if (jobID || state.slimming.selectedJobID) query.set("jobID", jobID || state.slimming.selectedJobID);
  if (clusterID || state.slimming.selectedClusterID) {
    query.set("clusterID", clusterID || state.slimming.selectedClusterID);
  }
  try {
    const snapshot = await api(`/v1/library-slimming/workspace?${query}`);
    if (generation !== state.slimming.requestGeneration) return;
    state.slimming.jobs = snapshot.jobs || [];
    state.slimming.selectedJobID = snapshot.selectedJobID || null;
    state.slimming.clusters = snapshot.clusters || [];
    state.slimming.selectedClusterID = snapshot.selectedClusterID || null;
    state.slimming.members = snapshot.members || [];
    state.slimming.pendingAnalysisCount = snapshot.pendingAnalysisCount || 0;
    state.slimming.analyzedAssetCount = snapshot.analyzedAssetCount || 0;
    state.slimming.policyVersion = snapshot.policyVersion || null;
    const memberIDs = new Set(state.slimming.members.map((member) => member.id));
    state.slimming.selectedMemberIDs = (jobID || clusterID)
      ? new Set()
      : new Set([...previousSelectedMemberIDs].filter((id) => memberIDs.has(id)));
    state.slimming.selectionAnchorID = state.slimming.selectedMemberIDs.has(
      previousSelectionAnchorID
    ) ? previousSelectionAnchorID : null;
  } catch (error) {
    if (generation === state.slimming.requestGeneration && !quiet) {
      toast(error.message || "图库瘦身结果载入失败");
    }
  } finally {
    if (generation === state.slimming.requestGeneration) {
      state.slimming.loading = false;
      renderSlimmingWorkspace();
    }
  }
}

async function openSlimmingWorkspace() {
  elements.reviewWorkspace.classList.add("hidden");
  state.reviewReturnFocus = null;
  elements.trainingWorkspace.classList.add("hidden");
  state.trainingReturnFocus = null;
  closeJobsPopover({ restoreFocus: false });
  elements.filterPopover.classList.add("hidden");
  elements.filterButton.setAttribute("aria-expanded", "false");
  if (elements.slimmingWorkspace.classList.contains("hidden")) {
    state.slimmingReturnFocus = document.activeElement;
  }
  if (matchMedia("(max-width: 720px)").matches
    && !state.slimming.inspectorCompactInitialized) {
    elements.slimmingInspector.open = false;
    state.slimming.inspectorCompactInitialized = true;
  }
  elements.appView.inert = true;
  elements.slimmingWorkspace.classList.remove("hidden");
  requestAnimationFrame(() => elements.closeSlimmingButton.focus({ preventScroll: true }));
  if (state.slimming.view === "recycle") await loadSlimmingRecycle();
  else {
    await loadSlimmingWorkspace();
    await loadSlimmingRemovals({ quiet: true });
    await loadSlimmingIdenticalCleanupRequests({ quiet: true });
  }
}

function selectSlimmingMember(memberID, event) {
  const ids = state.slimming.members.map((member) => member.id);
  if (event.shiftKey && state.slimming.selectionAnchorID) {
    const anchor = ids.indexOf(state.slimming.selectionAnchorID);
    const target = ids.indexOf(memberID);
    if (anchor >= 0 && target >= 0) {
      const range = ids.slice(Math.min(anchor, target), Math.max(anchor, target) + 1);
      state.slimming.selectedMemberIDs = (event.metaKey || event.ctrlKey)
        ? new Set([...state.slimming.selectedMemberIDs, ...range])
        : new Set(range);
    }
  } else if (event.metaKey || event.ctrlKey) {
    if (state.slimming.selectedMemberIDs.has(memberID)) {
      state.slimming.selectedMemberIDs.delete(memberID);
    } else {
      state.slimming.selectedMemberIDs.add(memberID);
    }
    state.slimming.selectionAnchorID = memberID;
  } else {
    state.slimming.selectedMemberIDs = new Set([memberID]);
    state.slimming.selectionAnchorID = memberID;
  }
  renderSlimmingMemberSelection();
}

function currentSlimmingSeedIDs() {
  if (state.mediaKind !== state.slimming.mediaKind) return [];
  if (state.selectedAssetIDs.size) return [...state.selectedAssetIDs];
  return state.selectedAssetID ? [state.selectedAssetID] : [];
}

function currentSlimmingFilterRequest() {
  const accepted = [];
  const rejected = [];
  const excluded = [];
  for (const condition of state.filters.tagConditions) {
    if (condition.decision === "accepted") {
      accepted.push({ tagID: condition.tagID, decision: "accepted" });
    } else if (condition.decision === "rejected") {
      rejected.push({ tagID: condition.tagID, decision: "rejected" });
    } else if (condition.decision === "excluded") {
      excluded.push(condition.tagID);
    }
  }
  return {
    sourceIDs: state.selectedSourceID ? [state.selectedSourceID] : [],
    searchText: state.searchText || null,
    sort: state.sort,
    limit: 200,
    cursor: null,
    tagDecisionFilters: [...accepted, ...rejected],
    excludedTagIDs: excluded,
    tagMatchMode: state.filters.tagMatchMode,
    availabilities: state.filters.availability ? [state.filters.availability] : [],
    mediaKinds: [state.slimming.mediaKind],
    mediaTypes: [...state.filters.mediaTypes],
    tagPresence: state.filters.tagPresence,
  };
}

function slimmingModeCopy(mode) {
  const noun = state.slimming.mediaKind === "video" ? "视频" : "照片";
  return {
    catalog: {
      title: "全部来源",
      detail: `扫描所选来源中的全部可用${noun}`,
    },
    currentFilter: {
      title: "当前筛选",
      detail: `冻结网页图库当前的来源、搜索和标签筛选`,
    },
    seeds: {
      title: "按种子查找",
      detail: `从图库当前选择的${noun}出发查找相似项`,
    },
  }[mode];
}

function slimmingModeAvailable(mode) {
  const setup = state.slimming.setup;
  if (mode === "catalog") return Boolean(setup.snapshot?.sources?.length);
  if (state.mediaKind !== state.slimming.mediaKind) return false;
  if (mode === "seeds") return currentSlimmingSeedIDs().length > 0;
  return true;
}

function normalizeSlimmingThresholdDraft(value) {
  if (!value) return null;
  return {
    featurePrintRecallTopK: Number(value.featurePrintRecallTopK),
    featurePrintMaxL2Distance: Number(value.featurePrintMaxL2Distance),
    dinoCosineMinSimilarity: Number(value.dinoCosineMinSimilarity),
    sceneBucketActivationAssetCount: Number(value.sceneBucketActivationAssetCount),
    featurePrintRecallMode: value.featurePrintRecallMode,
    featurePrintL2Mode: value.featurePrintL2Mode,
    dinoCosineMode: value.dinoCosineMode,
    sceneBucketingMode: value.sceneBucketingMode,
  };
}

function slimmingThresholdsValid() {
  const value = state.slimming.setup.thresholds;
  return Boolean(value)
    && Number.isInteger(value.featurePrintRecallTopK)
    && value.featurePrintRecallTopK > 0
    && value.featurePrintRecallTopK <= 128
    && Number.isFinite(value.featurePrintMaxL2Distance)
    && value.featurePrintMaxL2Distance >= 0
    && value.featurePrintMaxL2Distance <= 200
    && Number.isFinite(value.dinoCosineMinSimilarity)
    && value.dinoCosineMinSimilarity >= 0
    && value.dinoCosineMinSimilarity <= 1
    && Number.isInteger(value.sceneBucketActivationAssetCount)
    && value.sceneBucketActivationAssetCount >= 2
    && value.sceneBucketActivationAssetCount <= 10_000;
}

function canSaveSlimmingThresholds() {
  const setup = state.slimming.setup;
  return Boolean(setup.snapshot)
    && !setup.loading
    && !setup.saving
    && !setup.launching
    && slimmingThresholdsValid();
}

function canLaunchSlimmingSetup() {
  const setup = state.slimming.setup;
  if (!canSaveSlimmingThresholds() || !slimmingModeAvailable(setup.mode)) return false;
  if (setup.mode === "catalog") return setup.selectedSourceIDs.size > 0;
  if (setup.mode === "seeds") return currentSlimmingSeedIDs().length > 0;
  return state.mediaKind === state.slimming.mediaKind;
}

function appendSlimmingSetupSummary(label, value) {
  const term = document.createElement("dt");
  term.textContent = label;
  const description = document.createElement("dd");
  description.textContent = value;
  elements.slimmingLaunchSummary.append(term, description);
}

function renderSlimmingSetupModes() {
  clearElement(elements.slimmingModeOptions);
  for (const mode of ["catalog", "currentFilter", "seeds"]) {
    const copy = slimmingModeCopy(mode);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "slimming-mode-option";
    button.classList.toggle("selected", state.slimming.setup.mode === mode);
    button.dataset.slimmingMode = mode;
    button.disabled = !slimmingModeAvailable(mode) || state.slimming.setup.launching;
    button.setAttribute("role", "radio");
    button.setAttribute("aria-checked", String(state.slimming.setup.mode === mode));
    const title = document.createElement("strong");
    title.textContent = copy.title;
    const detail = document.createElement("span");
    detail.textContent = copy.detail;
    button.append(title, detail);
    elements.slimmingModeOptions.append(button);
  }
}

function renderSlimmingSourceOptions() {
  const setup = state.slimming.setup;
  clearElement(elements.slimmingSourceOptions);
  elements.slimmingSourceSection.classList.toggle("hidden", setup.mode !== "catalog");
  if (setup.mode !== "catalog") return;
  const sources = setup.snapshot?.sources || [];
  const allSelected = sources.length > 0
    && sources.every((source) => setup.selectedSourceIDs.has(source.id));
  elements.toggleAllSlimmingSourcesButton.textContent = allSelected ? "清除" : "全选";
  elements.toggleAllSlimmingSourcesButton.disabled = setup.launching;
  elements.slimmingSourceHint.textContent = allSelected
    ? "已选择全部可用来源；提交时保留 Mac 端“全部来源”语义。"
    : `已选择 ${setup.selectedSourceIDs.size} / ${sources.length} 个来源。`;
  for (const source of sources) {
    const row = document.createElement("label");
    row.className = "training-option-row";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = setup.selectedSourceIDs.has(source.id);
    input.disabled = setup.launching;
    input.dataset.slimmingSourceId = source.id;
    const name = document.createElement("strong");
    name.textContent = source.displayName;
    const kind = document.createElement("span");
    kind.textContent = source.kind === "photos" ? "照片图库" : "文件夹";
    row.append(input, name, kind);
    elements.slimmingSourceOptions.append(row);
  }
}

function syncSlimmingThresholdControls() {
  const setup = state.slimming.setup;
  const thresholds = setup.thresholds;
  if (!thresholds) return;
  elements.slimmingRecallMode.value = thresholds.featurePrintRecallMode;
  elements.slimmingRecallTopK.value = String(thresholds.featurePrintRecallTopK);
  elements.slimmingL2Mode.value = thresholds.featurePrintL2Mode;
  elements.slimmingL2Distance.value = String(thresholds.featurePrintMaxL2Distance);
  elements.slimmingDINOMode.value = thresholds.dinoCosineMode;
  elements.slimmingDINOSimilarity.value = String(thresholds.dinoCosineMinSimilarity);
  elements.slimmingBucketingMode.value = thresholds.sceneBucketingMode;
  elements.slimmingBucketActivationCount.value = String(
    thresholds.sceneBucketActivationAssetCount
  );
  const locked = setup.saving || setup.launching;
  elements.resetSlimmingThresholdsButton.disabled = locked;
  for (const control of [
    elements.slimmingRecallMode,
    elements.slimmingL2Mode,
    elements.slimmingDINOMode,
    elements.slimmingBucketingMode,
  ]) control.disabled = locked;
  elements.slimmingRecallTopK.disabled = locked
    || thresholds.featurePrintRecallMode === "allCandidates";
  elements.slimmingL2Distance.disabled = locked || thresholds.featurePrintL2Mode === "unlimited";
  elements.slimmingDINOSimilarity.disabled = locked || thresholds.dinoCosineMode === "unlimited";
  elements.slimmingBucketActivationCount.disabled = locked
    || thresholds.sceneBucketingMode !== "automatic";
  elements.slimmingExtremeWarning.classList.toggle(
    "hidden",
    thresholds.featurePrintRecallMode !== "allCandidates"
      && thresholds.featurePrintL2Mode !== "unlimited"
      && thresholds.dinoCosineMode !== "unlimited"
      && thresholds.sceneBucketingMode === "automatic"
  );
}

function renderSlimmingSetupSummary() {
  clearElement(elements.slimmingLaunchSummary);
  const setup = state.slimming.setup;
  const copy = slimmingModeCopy(setup.mode);
  appendSlimmingSetupSummary("范围", copy.title);
  if (setup.mode === "catalog") {
    const sourceCount = setup.snapshot?.sources?.length || 0;
    appendSlimmingSetupSummary(
      "来源",
      setup.selectedSourceIDs.size === sourceCount
        ? `全部 ${sourceCount} 个可用来源`
        : `${setup.selectedSourceIDs.size} 个来源`
    );
  } else if (setup.mode === "seeds") {
    appendSlimmingSetupSummary("种子", `${currentSlimmingSeedIDs().length} 项`);
  } else {
    appendSlimmingSetupSummary("筛选", state.searchText ? `包含搜索“${state.searchText}”` : "网页图库当前筛选");
  }
  appendSlimmingSetupSummary(
    "相似阈值",
    slimmingThresholdsValid() ? "使用面板中的共享设置" : "设置值无效"
  );
}

function renderSlimmingSetup() {
  const setup = state.slimming.setup;
  elements.slimmingSetupLoading.classList.toggle("hidden", !setup.loading);
  elements.slimmingSetupConfiguration.classList.toggle("hidden", setup.loading || !setup.snapshot);
  elements.slimmingSetupError.textContent = setup.error;
  elements.launchSlimmingButton.textContent = setup.launching ? "正在交给 Mac…" : "开始分析";
  elements.saveSlimmingThresholdsButton.textContent = setup.saving && !setup.launching
    ? "正在保存…"
    : "仅保存设置";
  if (setup.snapshot) {
    renderSlimmingSetupModes();
    renderSlimmingSourceOptions();
    syncSlimmingThresholdControls();
    renderSlimmingSetupSummary();
  }
  syncWriteActionControls();
}

async function openSlimmingSetupDialog() {
  const setup = state.slimming.setup;
  setup.loading = true;
  setup.saving = false;
  setup.launching = false;
  setup.snapshot = null;
  setup.error = "";
  setup.thresholdOperationID = null;
  setup.launchOperationID = null;
  const generation = ++setup.requestGeneration;
  elements.slimmingSetupDialog.showModal();
  renderSlimmingSetup();
  try {
    const query = new URLSearchParams({ mediaKind: state.slimming.mediaKind });
    const snapshot = await api(`/v1/library-slimming/setup?${query}`);
    if (generation !== setup.requestGeneration || !elements.slimmingSetupDialog.open) return;
    setup.snapshot = snapshot;
    setup.mode = slimmingModeAvailable("currentFilter") ? "currentFilter" : "catalog";
    setup.selectedSourceIDs = new Set((snapshot.sources || []).map((source) => source.id));
    setup.thresholds = normalizeSlimmingThresholdDraft(snapshot.thresholds);
  } catch (error) {
    if (generation === setup.requestGeneration) {
      setup.error = error.message || "图库瘦身设置载入失败";
    }
  } finally {
    if (generation === setup.requestGeneration) {
      setup.loading = false;
      renderSlimmingSetup();
    }
  }
}

function closeSlimmingSetupDialog() {
  state.slimming.setup.requestGeneration += 1;
  state.slimming.setup.saving = false;
  state.slimming.setup.launching = false;
  if (elements.slimmingSetupDialog.open) elements.slimmingSetupDialog.close();
  restoreOverlayFocus(elements.newSlimmingAnalysisButton);
}

function readSlimmingThresholdControls() {
  const setup = state.slimming.setup;
  setup.thresholds = {
    featurePrintRecallTopK: Number(elements.slimmingRecallTopK.value),
    featurePrintMaxL2Distance: Number(elements.slimmingL2Distance.value),
    dinoCosineMinSimilarity: Number(elements.slimmingDINOSimilarity.value),
    sceneBucketActivationAssetCount: Number(elements.slimmingBucketActivationCount.value),
    featurePrintRecallMode: elements.slimmingRecallMode.value,
    featurePrintL2Mode: elements.slimmingL2Mode.value,
    dinoCosineMode: elements.slimmingDINOMode.value,
    sceneBucketingMode: elements.slimmingBucketingMode.value,
  };
  setup.thresholdOperationID = null;
  setup.error = slimmingThresholdsValid() ? "" : "请检查相似阈值；数值必须在允许范围内。";
  renderSlimmingSetup();
}

async function saveSlimmingThresholds({ forLaunch = false } = {}) {
  const setup = state.slimming.setup;
  if (!slimmingThresholdsValid() || setup.saving) return false;
  setup.saving = true;
  setup.error = "";
  setup.thresholdOperationID ||= crypto.randomUUID();
  renderSlimmingSetup();
  try {
    const result = await api("/v1/library-slimming/thresholds", {
      method: "PUT",
      body: JSON.stringify({
        operationID: setup.thresholdOperationID,
        thresholds: setup.thresholds,
      }),
    });
    setup.thresholds = normalizeSlimmingThresholdDraft(result.thresholds);
    if (setup.snapshot) setup.snapshot.thresholds = result.thresholds;
    setup.thresholdOperationID = null;
    if (!forLaunch) toast("相似阈值已保存到 Mac");
    return true;
  } catch (error) {
    setup.error = error.message || "相似阈值保存失败";
    return false;
  } finally {
    setup.saving = false;
    renderSlimmingSetup();
  }
}

async function submitSlimmingSetup() {
  const setup = state.slimming.setup;
  if (!canLaunchSlimmingSetup()) return;
  setup.launching = true;
  setup.error = "";
  renderSlimmingSetup();
  if (!await saveSlimmingThresholds({ forLaunch: true })) {
    setup.launching = false;
    renderSlimmingSetup();
    return;
  }
  setup.launchOperationID ||= crypto.randomUUID();
  const allSourceIDs = (setup.snapshot?.sources || []).map((source) => source.id);
  const selectedSourceIDs = [...setup.selectedSourceIDs];
  const allSourcesSelected = allSourceIDs.length === selectedSourceIDs.length
    && allSourceIDs.every((id) => setup.selectedSourceIDs.has(id));
  try {
    const result = await api("/v1/library-slimming/launch", {
      method: "POST",
      body: JSON.stringify({
        operationID: setup.launchOperationID,
        mediaKind: state.slimming.mediaKind,
        mode: setup.mode,
        sourceIDs: setup.mode === "catalog"
          ? (allSourcesSelected ? null : selectedSourceIDs)
          : null,
        seedAssetIDs: setup.mode === "seeds" ? currentSlimmingSeedIDs() : [],
        filter: setup.mode === "catalog" ? null : currentSlimmingFilterRequest(),
      }),
    });
    closeSlimmingSetupDialog();
    state.slimming.selectedJobID = result.jobID;
    toast(`分析已交给 Mac · ${result.memberCount} 项`);
    await loadSlimmingWorkspace({ jobID: result.jobID, quiet: true });
  } catch (error) {
    setup.error = error.message || "图库瘦身分析创建失败";
    setup.launching = false;
    renderSlimmingSetup();
  }
}

async function applySlimmingJobAction(jobID, action) {
  if (!state.online || state.slimming.jobMutatingIDs.has(jobID)) return;
  if (action === "deleteRecord"
    && !window.confirm("永久删除这条分析任务记录和结果？不会删除任何原始媒体。")) return;
  state.slimming.jobMutatingIDs.add(jobID);
  renderSlimmingJobs();
  try {
    await api(`/v1/library-slimming/jobs/${jobID}/actions`, {
      method: "POST",
      body: JSON.stringify({ operationID: crypto.randomUUID(), action }),
    });
    toast({ pause: "分析已暂停", resume: "分析已继续", deleteRecord: "分析记录已删除" }[action]);
    if (action === "deleteRecord" && state.slimming.selectedJobID === jobID) {
      state.slimming.selectedJobID = null;
      state.slimming.selectedClusterID = null;
    }
    await loadSlimmingWorkspace({ quiet: true });
  } catch (error) {
    toast(error.message || "分析任务操作失败");
  } finally {
    state.slimming.jobMutatingIDs.delete(jobID);
    renderSlimmingJobs();
  }
}

async function applyReviewDecision(action) {
  const selectedItems = selectedReviewItems();
  const assetIDs = selectedItems.map((item) => item.assetID);
  const tagID = elements.reviewTagSelect.value;
  const generation = state.workspaceGeneration;
  if (!state.online
    || !assetIDs.length
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
        assetIDs,
        action,
      }),
    });
    if (generation !== state.workspaceGeneration) return;
    const previousIndex = state.review.selectedIndex;
    try {
      await Promise.all([
        loadReviewOverview({ throwOnError: true }),
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
      undoToast(
        result.replayed
          ? "审核操作已恢复"
          : `已为 ${mediaItemCountText(result.appliedAssetCount)}保存审核决定`,
        result.undoID,
        "review"
      );
    } catch {
      if (generation === state.workspaceGeneration) {
        void refreshWorkspace({
          quiet: true,
          kinds: ["reviewChanged", "assetsChanged"],
        });
        undoToast(
          "审核决定已保存，界面同步暂时失败，正在重试",
          result.undoID,
          "review"
        );
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
  const selectedIDs = new Set(state.review.selectedAssetIDs);
  if (state.review.loading
    || state.review.mutating
    || state.review.loadedScopeKey !== currentReviewScopeKey()
    || !selectedIDs.size
    || !state.review.items.length) return;
  const selectedIndexes = state.review.items
    .map((item, index) => selectedIDs.has(item.assetID) ? index : -1)
    .filter((index) => index >= 0);
  const lastSelectedIndex = selectedIndexes.length ? Math.max(...selectedIndexes) : -1;
  let nextIndex = state.review.items.findIndex((item, index) => (
    index > lastSelectedIndex && !selectedIDs.has(item.assetID)
  ));
  if (nextIndex < 0) {
    nextIndex = state.review.items.findIndex((item) => !selectedIDs.has(item.assetID));
  }
  if (nextIndex < 0) nextIndex = 0;
  selectReviewIndex(nextIndex);
  elements.reviewGrid.querySelector(`[data-review-index="${nextIndex}"]`)
    ?.focus({ preventScroll: true });
  toast(selectedIDs.size > 1
    ? `已跳过 ${mediaItemCountText(selectedIDs.size)}，没有修改标签决定`
    : "已跳到下一项，没有修改标签决定");
}

function lightboxItems() {
  if (state.lightboxContext === "review") {
    return state.review.items.map((item) => ({
      id: item.assetID,
      fileName: item.fileName,
      contentRevision: item.contentRevision,
    }));
  }
  if (state.lightboxContext === "slimming") {
    return state.slimming.members;
  }
  if (state.lightboxContext === "worldMap") {
    return state.worldMap.selection?.assets || [];
  }
  return state.assets;
}

function lightboxMediaKind() {
  if (state.lightboxContext === "slimming") return state.slimming.mediaKind;
  if (state.lightboxContext === "worldMap") return "image";
  return state.mediaKind;
}

function lightboxHasMoreItems() {
  if (state.lightboxContext === "library") return Boolean(state.nextCursor);
  if (state.lightboxContext === "review") return Boolean(state.review.nextCursor);
  return false;
}

function lightboxBackText() {
  return {
    library: "返回网格",
    review: "返回审核",
    slimming: "返回分析",
    worldMap: "返回地图",
  }[state.lightboxContext] || "返回";
}

async function renderLightboxMedia(item) {
  const mediaKind = lightboxMediaKind();
  if (mediaKind !== "video") {
    stopLightboxVideo();
    elements.lightboxImage.classList.remove("hidden");
    const revision = item.contentRevision == null ? "" : `?r=${item.contentRevision}`;
    setProtectedImageSource(elements.lightboxImage, `/v1/assets/${item.id}/preview${revision}`);
    return;
  }

  const requestGeneration = ++state.lightboxRequestGeneration;
  clearProtectedImageSource(elements.lightboxImage);
  elements.lightboxImage.classList.add("hidden");
  elements.lightboxVideo.pause();
  elements.lightboxVideo.removeAttribute("src");
  const poster = assetThumbnailPlaceholder(item.id);
  if (poster) elements.lightboxVideo.poster = poster;
  else elements.lightboxVideo.removeAttribute("poster");
  elements.lightboxVideo.dataset.assetId = item.id;
  elements.lightboxVideo.dataset.contentRevision = String(item.contentRevision ?? "");
  if (state.authMode === "account") {
    const workerReady = await updateMediaWorkerAuthorization(state.accountAuthorization);
    if (!workerReady
      || requestGeneration !== state.lightboxRequestGeneration
      || state.lightboxAssetID !== item.id) {
      if (requestGeneration === state.lightboxRequestGeneration
        && state.lightboxAssetID === item.id) {
        toast("当前浏览器无法建立视频播放通道");
      }
      return;
    }
  }
  if (requestGeneration !== state.lightboxRequestGeneration
    || state.lightboxAssetID !== item.id) return;
  const revision = item.contentRevision == null ? "" : `?r=${item.contentRevision}`;
  elements.lightboxVideo.src = `/v1/assets/${item.id}/media${revision}`;
  elements.lightboxVideo.classList.remove("hidden");
  elements.lightboxVideo.load();
}

function openLightbox(context, assetID) {
  if (!assetID) return;
  stopAssetHoverVideo();
  if (elements.lightbox.classList.contains("hidden")) {
    state.lightboxReturnFocus = document.activeElement;
  }
  state.lightboxContext = context;
  state.lightboxAssetID = assetID;
  if (context === "review") {
    elements.reviewWorkspace.inert = true;
  } else if (context === "slimming") {
    elements.slimmingWorkspace.inert = true;
  } else if (context === "worldMap") {
    elements.worldMapWorkspace.inert = true;
  } else {
    elements.appView.inert = true;
  }
  elements.lightbox.classList.remove("hidden");
  renderLightbox();
  requestAnimationFrame(() => {
    elements.lightboxBackButton.focus({ preventScroll: true });
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
  const noun = lightboxMediaKind() === "video" ? "视频" : "照片";
  const hasMore = lightboxHasMoreItems();
  elements.lightboxTitle.textContent = item.fileName || `未命名${noun}`;
  elements.lightboxImage.alt = item.fileName || `${noun}全屏预览`;
  void renderLightboxMedia(item);
  elements.lightboxBackLabel.textContent = lightboxBackText();
  elements.lightboxBackButton.setAttribute("aria-label", lightboxBackText());
  elements.lightboxPosition.textContent = `${index + 1} / ${items.length}${hasMore ? " · 还有更多" : ""}`;
  elements.lightboxPreviousButton.disabled = state.lightboxNavigating || index <= 0;
  elements.lightboxNextButton.disabled = state.lightboxNavigating
    || (index >= items.length - 1 && !hasMore);
  elements.lightbox.setAttribute("aria-busy", String(state.lightboxNavigating));
  elements.lightboxReviewActions.classList.toggle(
    "hidden",
    state.lightboxContext !== "review"
  );
  elements.lightbox.classList.toggle("reviewing", state.lightboxContext === "review");
  syncReviewControls();
}

function syncReviewLightboxSelection() {
  if (state.lightboxContext !== "review") return;
  const item = state.review.items[state.review.selectedIndex];
  if (!item) {
    closeLightbox();
    return;
  }
  state.lightboxAssetID = item.assetID;
  renderLightbox();
}

async function applyLightboxReviewDecision(action) {
  if (state.lightboxContext !== "review") return;
  const currentIndex = state.review.items.findIndex(
    (item) => item.assetID === state.lightboxAssetID
  );
  if (currentIndex >= 0 && currentIndex !== state.review.selectedIndex) {
    selectReviewIndex(currentIndex);
  }
  if (action === "defer") {
    deferReviewSelection();
    syncReviewLightboxSelection();
    return;
  }
  await applyReviewDecision(action);
  syncReviewLightboxSelection();
}

async function loadMoreLightboxItems() {
  if (state.lightboxContext === "library" && state.nextCursor) {
    await loadAssets({ append: true, preserveSelection: true });
    return;
  }
  if (state.lightboxContext === "review" && state.review.nextCursor) {
    await loadReviewQueue({ append: true, preserveUnchangedGrid: true });
  }
}

async function syncLibraryLightboxSelection(assetID) {
  state.selectedAssetID = assetID;
  state.selectedDetail = null;
  if (state.selectionMode) {
    state.selectedAssetIDs = new Set([assetID]);
    state.selectionAnchorID = assetID;
  }
  renderAssets();
  renderSelectionBar();
  const card = elements.assetGrid.querySelector(`[data-asset-id="${CSS.escape(assetID)}"]`);
  card?.scrollIntoView({ block: "nearest", inline: "nearest" });
  if (card) state.lightboxReturnFocus = card;
  if (state.selectionMode) {
    scheduleSelectionAggregate();
    return;
  }
  await loadInspector(assetID, { preserveExisting: false, quiet: true });
}

async function navigateLightbox(direction) {
  if (![-1, 1].includes(direction)) return;
  if (state.lightboxNavigating) {
    state.lightboxPendingDirection = direction;
    return;
  }
  const currentAssetID = state.lightboxAssetID;
  let items = lightboxItems();
  let index = items.findIndex((item) => item.id === currentAssetID);
  if (index < 0) return;
  let next = index + direction;
  state.lightboxNavigating = true;
  renderLightbox();
  try {
    if (direction > 0 && next >= items.length && lightboxHasMoreItems()) {
      await loadMoreLightboxItems();
      if (state.lightboxAssetID !== currentAssetID) return;
      items = lightboxItems();
      index = items.findIndex((item) => item.id === currentAssetID);
      next = index + direction;
    }
    if (next < 0 || next >= items.length) return;
    const nextAssetID = items[next].id;
    state.lightboxAssetID = nextAssetID;
    renderLightbox();
    if (state.lightboxContext === "review") {
      selectReviewIndex(next);
    } else if (state.lightboxContext === "library") {
      await syncLibraryLightboxSelection(nextAssetID);
    }
  } catch (error) {
    toast(error.message || "无法载入下一页");
  } finally {
    state.lightboxNavigating = false;
    const pendingDirection = state.lightboxPendingDirection;
    state.lightboxPendingDirection = 0;
    if (!elements.lightbox.classList.contains("hidden") && state.lightboxAssetID) {
      renderLightbox();
      if (pendingDirection) void navigateLightbox(pendingDirection);
    }
  }
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
  const capabilities = await api("/v1/capabilities");
  if (generation !== state.workspaceGeneration) return;
  state.capabilities = capabilities;
  const [
    sources,
    tags,
    tagGroups,
    jobs,
    sourceManagement,
    embeddingPreparation,
    sampleSuggestions,
    tagLibrarySuggestions,
  ] = await Promise.all([
    api("/v1/sources"),
    api("/v1/tags"),
    api("/v1/tag-groups"),
    api("/v1/jobs"),
    supportsSourceManagement() ? api("/v1/source-management") : Promise.resolve(null),
    api(`/v1/embedding-preparation?${new URLSearchParams({ mediaKind: state.mediaKind })}`),
    api(`/v1/sample-suggestions?${new URLSearchParams({ mediaKind: state.mediaKind })}`),
    api(`/v1/tag-library-suggestions?${new URLSearchParams({ mediaKind: state.mediaKind })}`),
  ]);
  if (generation !== state.workspaceGeneration) return;
  state.sources = sources;
  state.tags = tags;
  state.tagGroups = tagGroups;
  state.jobs = jobs;
  state.sourceManagement.snapshot = sourceManagement || {
    sources,
    canConnectPhotos: !sources.some((source) => source.kind === "photos"),
    requests: [],
  };
  state.embeddingPreparation.isAvailable = Boolean(embeddingPreparation.isAvailable);
  state.embeddingPreparation.activities = embeddingPreparation.activities || [];
  state.sampleSuggestions.isAvailable = Boolean(sampleSuggestions.isAvailable);
  state.sampleSuggestions.maximumSampleCount = sampleSuggestions.maximumSampleCount || 500;
  state.sampleSuggestions.activities = sampleSuggestions.activities || [];
  state.tagLibrarySuggestions.snapshot = tagLibrarySuggestions;
  elements.hostVersion.textContent = `Mac Host ${capabilities.hostAppVersion}`;
  elements.settingsButton.disabled = !supportsGeneralSettings();
  elements.settingsButton.title = supportsGeneralSettings()
    ? "设置（⌘,）"
    : "当前 Mac Host 不支持网页通用设置";
  if (supportsGeneralSettings()) await loadGeneralSettings({ quiet: true });
  if (generation !== state.workspaceGeneration) return;
  renderSources();
  renderTagSelects();
  renderJobs();
  renderSourcePrewarmStatus();
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
  scheduleEmbeddingPreparationPoll();
  scheduleSampleSuggestionPoll();
  scheduleTagLibrarySuggestionPoll();
  scheduleSourceManagementPoll();
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

      const [sources, tags, tagGroups, jobs] = await Promise.all([
        batch.has("sourcesChanged") ? api("/v1/sources") : null,
        batch.has("tagsChanged") ? api("/v1/tags") : null,
        batch.has("tagsChanged") ? api("/v1/tag-groups") : null,
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
      const tagGroupsChanged = Boolean(
        tagGroups
        && projectionFingerprint(tagGroups) !== projectionFingerprint(state.tagGroups)
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
        renderLibraryEmptyState();
      }
      if (tagsChanged || tagGroupsChanged) {
        if (tags) state.tags = tags;
        if (tagGroups) state.tagGroups = tagGroups;
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
        await loadReviewOverview({ throwOnError: true });
        if (state.review.mode === "queue") {
          await loadReviewQueue({
            preserveUnchangedGrid: true,
            preserveLoadedWindow: true,
            throwOnError: true,
          });
        }
      }
      if (
        !elements.trainingWorkspace.classList.contains("hidden")
        && batch.has("jobsChanged")
      ) {
        await loadTrainingWorkspace({ quiet: true });
      }
      if (
        !elements.slimmingWorkspace.classList.contains("hidden")
        && batch.has("jobsChanged")
      ) {
        await loadSlimmingWorkspace({ quiet: true });
      }
      if (
        !elements.galleryOverviewWorkspace.classList.contains("hidden")
        && (batch.has("assetsChanged") || batch.has("sourcesChanged") || batch.has("tagsChanged"))
      ) {
        await loadGalleryOverview({ quiet: true, throwOnError: true });
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
    await updateMediaWorkerAuthorization(null);
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
    await updateMediaWorkerAuthorization(state.accountAuthorization);
    elements.accountPassword.value = "";
    await loadWorkspace();
  } catch (error) {
    state.accountAuthorization = null;
    state.authMode = null;
    updateMediaWorkerAuthorization(null);
    elements.accountLoginError.textContent = error.status === 401
      ? "账号名或密码不正确，或该账号不在 Mac 白名单中。"
      : (error.message || "无法登录图库");
  } finally {
    elements.accountLoginButton.disabled = false;
    elements.accountLoginButton.textContent = "登录图库";
  }
}

function resetWorkspaceSessionState() {
  stopAssetHoverVideo();
  disconnectEvents();
  state.workspaceGeneration += 1;
  state.inspectorRequestGeneration += 1;
  state.capabilities = null;
  state.sources = [];
  state.tags = [];
  state.tagGroups = [];
  state.jobs = [];
  clearTimeout(state.sourceManagement.pollTimer);
  state.sourceManagement.pollTimer = null;
  state.sourceManagement.snapshot = null;
  state.sourceManagement.loading = false;
  state.sourceManagement.submitting = false;
  state.sourceManagement.requestGeneration += 1;
  state.sourceManagement.seenTerminalRequestIDs.clear();
  renderSourcePrewarmStatus();
  state.generalSettings.snapshot = null;
  state.generalSettings.loading = false;
  state.generalSettings.submitting = false;
  state.generalSettings.requestGeneration += 1;
  state.generalSettings.returnFocus = null;
  state.generalSettings.thresholdReturnFocus = null;
  state.generalSettings.pendingDefaultFocus = null;
  state.generalSettings.pendingThresholdFocus = null;
  state.sourceManagerReturnFocus = null;
  state.storageReturnFocus = null;
  clearTimeout(state.storageMaintenance.pollTimer);
  state.storageMaintenance.pollTimer = null;
  state.storageMaintenance.snapshot = null;
  state.storageMaintenance.loading = false;
  state.storageMaintenance.submitting = false;
  state.storageMaintenance.requestGeneration += 1;
  state.storageMaintenance.seenTerminalRequestIDs.clear();
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
  clearTimeout(state.embeddingPreparation.pollTimer);
  state.embeddingPreparation.pollTimer = null;
  state.embeddingPreparation.isAvailable = false;
  state.embeddingPreparation.activities = [];
  state.embeddingPreparation.loading = false;
  state.embeddingPreparation.submitting = false;
  state.embeddingPreparation.cancelling = false;
  state.embeddingPreparation.requestGeneration += 1;
  state.embeddingPreparation.seenTerminalOperationIDs.clear();
  clearTimeout(state.sampleSuggestions.pollTimer);
  state.sampleSuggestions.pollTimer = null;
  state.sampleSuggestions.isAvailable = false;
  state.sampleSuggestions.maximumSampleCount = 500;
  state.sampleSuggestions.activities = [];
  state.sampleSuggestions.loading = false;
  state.sampleSuggestions.submitting = false;
  state.sampleSuggestions.cancelling = false;
  state.sampleSuggestions.requestGeneration += 1;
  state.sampleSuggestions.seenTerminalOperationIDs.clear();
  clearTimeout(state.tagLibrarySuggestions.pollTimer);
  state.tagLibrarySuggestions.pollTimer = null;
  state.tagLibrarySuggestions.snapshot = null;
  state.tagLibrarySuggestions.loading = false;
  state.tagLibrarySuggestions.submitting = false;
  state.tagLibrarySuggestions.cancellingIDs.clear();
  state.tagLibrarySuggestions.requestGeneration += 1;
  state.tagLibrarySuggestions.seenTerminalOperationIDs.clear();
  state.tagLibrarySuggestions.dialog.tagID = null;
  state.tagLibrarySuggestions.dialog.method = "personalCentroid";
  state.tagLibrarySuggestions.dialog.selectedSourceIDs.clear();
  state.tagLibrarySuggestions.dialog.returnFocus = null;
  if (elements.tagSuggestionDialog.open) elements.tagSuggestionDialog.close();
  state.inspectorDismissed = false;
  state.selectionAggregates = [];
  state.aggregateGeneration += 1;
  state.tagMutating = false;
  state.tagManagementMutating = false;
  state.openingOriginal = false;
  state.undo.tag = { id: null, operationID: null, mutating: false };
  state.undo.review = { id: null, operationID: null, mutating: false };
  state.toastUndoKind = null;
  state.jobMutatingIDs.clear();
  state.review.items = [];
  state.review.mode = "overview";
  state.review.overview = [];
  state.review.overviewTotal = 0;
  state.review.overviewLoading = false;
  state.review.overviewGeneration += 1;
  state.review.nextCursor = null;
  state.review.selectedIndex = -1;
  state.review.selectedAssetIDs.clear();
  state.review.selectionAnchorIndex = -1;
  state.review.marquee = null;
  state.review.loading = false;
  state.review.mutating = false;
  state.review.requestGeneration += 1;
  state.review.loadedScopeKey = null;
  state.training.mediaKind = "image";
  state.training.method = "";
  state.training.runs = [];
  state.training.slots = [];
  state.training.activities = [];
  state.training.activityMutatingIDs.clear();
  state.training.focusedJobID = null;
  state.training.focusedTagID = null;
  state.training.selectedRunID = null;
  state.training.loading = false;
  state.training.requestGeneration += 1;
  state.training.setup.loading = false;
  state.training.setup.launching = false;
  state.training.setup.snapshot = null;
  state.training.setup.selectedTagIDs.clear();
  state.training.setup.selectedSourceIDs.clear();
  state.training.setup.error = "";
  state.training.setup.notice = "";
  state.training.setup.operationID = null;
  state.training.setup.requestGeneration += 1;
  state.reviewReturnFocus = null;
  state.trainingReturnFocus = null;
  state.galleryOverview.snapshot = null;
  state.galleryOverview.loading = false;
  state.galleryOverview.error = "";
  state.galleryOverview.refreshedAt = null;
  state.galleryOverview.requestGeneration += 1;
  state.galleryOverviewReturnFocus = null;
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
  stopInspectorVideo();
  hidePreviewPlaceholder();
  clearProtectedImageSource(elements.reviewPreviewImage);
  clearProtectedImageSource(elements.lightboxImage);
  stopLightboxVideo();
  elements.lightboxReviewActions.classList.add("hidden");
  elements.appView.inert = false;
  elements.reviewWorkspace.inert = false;
  elements.reviewWorkspace.classList.add("hidden");
  elements.trainingWorkspace.inert = false;
  elements.trainingWorkspace.classList.add("hidden");
  elements.galleryOverviewWorkspace.inert = false;
  elements.galleryOverviewWorkspace.classList.add("hidden");
  elements.lightbox.classList.add("hidden");
  elements.lightbox.classList.remove("reviewing");
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
    await loadReviewOverview();
    if (state.review.mode === "queue") await loadReviewQueue();
  }
}

function togglePopover(popover) {
  const willOpen = popover.classList.contains("hidden");
  elements.filterPopover.classList.add("hidden");
  closeJobsPopover({ restoreFocus: false });
  closePersonalModelPopover({ restoreFocus: false });
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
    {
      id: "undoTag",
      icon: "↶",
      title: "撤销最近一次标签操作",
      hint: "标签",
      disabled: !state.online || !state.undo.tag.id || state.undo.tag.mutating,
    },
    { id: "openGalleryOverview", icon: "▥", title: "打开图库总览", hint: "" },
    { id: "openWorldMap", icon: "◎", title: "打开世界地图", hint: "" },
    { id: "openReview", icon: "✦", title: "打开待审核建议", hint: "" },
    {
      id: "generateLibrarySuggestions",
      icon: "✦",
      title: `抽 ${state.sampleSuggestions.maximumSampleCount} 张生成个人建议`,
      hint: "进入审核",
      disabled: !state.online
        || state.mediaKind !== "image"
        || !state.sampleSuggestions.isAvailable
        || Boolean(activeSampleSuggestion()),
    },
    { id: "openTraining", icon: "⌁", title: "打开训练工程", hint: "" },
    {
      id: "rebuildPersonalModel",
      icon: "◎",
      title: "重建个人模型",
      hint: "Personal Centroid",
      disabled: !state.online,
    },
    {
      id: "rebuildPersonalAdamW",
      icon: "✦",
      title: "训练超级个人模型",
      hint: "Personal AdamW",
      disabled: !state.online,
    },
    { id: "openStorage", icon: "▣", title: "打开应用存储与预览缓存", hint: "" },
    {
      id: "openSettings",
      icon: "⚙",
      title: "打开通用设置",
      hint: "⌘,",
      disabled: !supportsGeneralSettings(),
    },
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
  if (state.undo.review.id) {
    commands.splice(8, 0, {
      id: "undoReview",
      icon: "↶✓",
      title: "撤销最近一次审核操作",
      hint: "审核",
      disabled: !state.online || state.undo.review.mutating,
    });
  }
  if (currentTagTargetAssetIDs().length) {
    commands.splice(5, 0,
      { id: "previewSelection", icon: "⛶", title: `预览所选${currentMediaNoun()}`, hint: "Space" },
      { id: "newTag", icon: "＋", title: `为所选${currentMediaNoun()}新增标签`, hint: "" },
      {
        id: "prepareSelectedFeatures",
        icon: "⌁",
        title: `准备所选${currentMediaNoun()}特征`,
        hint: "个人模型",
        disabled: !state.online
          || !state.embeddingPreparation.isAvailable
          || Boolean(activeEmbeddingPreparation()),
      },
      {
        id: "generateSelectedSuggestions",
        icon: "✦",
        title: `为所选${currentMediaNoun()}生成个人建议`,
        hint: "进入审核",
        disabled: !state.online
          || state.mediaKind !== "image"
          || !state.sampleSuggestions.isAvailable
          || Boolean(activeSampleSuggestion()),
      },
      {
        id: "findSimilarSelection",
        icon: "◫",
        title: `从所选${currentMediaNoun()}查找相似项`,
        hint: "图库瘦身",
        disabled: !state.online,
      });
    for (const tag of activeTags()) {
      commands.push(
        {
          id: `tagAction:accept:${tag.id}`,
          icon: "✓",
          title: `确认标签：${tag.displayName}`,
          hint: "",
          disabled: !state.online || state.tagMutating,
        },
        {
          id: `tagAction:reject:${tag.id}`,
          icon: "×",
          title: `拒绝标签：${tag.displayName}`,
          hint: "",
          disabled: !state.online || state.tagMutating,
        },
        {
          id: `tagAction:clear:${tag.id}`,
          icon: "−",
          title: `清除标签决定：${tag.displayName}`,
          hint: "",
          disabled: !state.online || state.tagMutating,
        }
      );
    }
  }
  commands.push({
    id: "connectFolder",
    icon: "▤",
    title: "连接文件夹来源…",
    hint: "在 Mac 上选择",
    disabled: !state.online,
  });
  commands.push({
    id: "installPresetTags",
    icon: "#",
    title: "添加常用标签",
    hint: "可编辑 · 不自动应用",
    disabled: !state.online || state.installingPresetTags,
  });
  commands.push(
    {
      id: "exportPortableData",
      icon: "⇧",
      title: "导出用户数据…",
      hint: "在 Mac 上选择",
      disabled: !state.online,
    },
    {
      id: "chooseExternalStorage",
      icon: "▣",
      title: "选择外置应用存储位置…",
      hint: "在 Mac 上选择",
      disabled: !state.online,
    }
  );
  const selectedSource = state.sources.find((source) => source.id === state.selectedSourceID);
  if (selectedSource) {
    const action = selectedSource.kind === "photos" ? "syncPhotos" : "rescan";
    if (sourceManagementActions(selectedSource).includes(action)) {
      commands.push({
        id: `sourceAction:${action}:${selectedSource.id}`,
        icon: "↻",
        title: `${sourceManagementActionLabel(action)}：${selectedSource.displayName}`,
        hint: "",
        disabled: !state.online,
      });
    }
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
    button.disabled = Boolean(command.disabled);
    button.setAttribute("role", "option");
    button.setAttribute("aria-selected", String(index === state.commandIndex));
    button.setAttribute("aria-disabled", String(Boolean(command.disabled)));
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
  const command = availableCommands().find((item) => item.id === commandID);
  if (command?.disabled) return;
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
  if (commandID.startsWith("tagAction:")) {
    const [, action, tagID] = commandID.split(":");
    if (state.selectionMode) await applyBatchTagDecision(action, tagID);
    else await mutateTag(tagID, action);
    return;
  }
  if (commandID.startsWith("sourceAction:")) {
    const [, action, sourceID] = commandID.split(":");
    await openSourceManager();
    await submitSourceManagementAction(action, sourceID);
    return;
  }
  switch (commandID) {
  case "showAll":
    state.filters = emptyFilters();
    state.filters.mediaKind = state.mediaKind;
    state.filterDraft = null;
    syncFilterControlsFromState();
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
  case "undoTag":
    await undoLatestDecision("tag");
    break;
  case "undoReview":
    await undoLatestDecision("review");
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
  case "prepareSelectedFeatures":
    await prepareSelectedFeatures();
    break;
  case "generateSelectedSuggestions":
    await generateSampleSuggestions({ useSelection: true });
    break;
  case "generateLibrarySuggestions":
    await generateSampleSuggestions();
    break;
  case "findSimilarSelection":
    await findSimilarFromSelection();
    break;
  case "connectFolder":
    await openSourceManager();
    await submitSourceManagementAction("connectFolder");
    break;
  case "installPresetTags":
    await installPresetTags(elements.commandButton);
    break;
  case "openReview":
    await openReviewWorkspace();
    break;
  case "openGalleryOverview":
    await openGalleryOverviewWorkspace();
    break;
  case "openWorldMap":
    await openWorldMapWorkspace();
    break;
  case "openTraining":
    await openTrainingWorkspace();
    break;
  case "rebuildPersonalModel":
    await openLibraryPersonalTraining("personalCentroid");
    break;
  case "rebuildPersonalAdamW":
    await openLibraryPersonalTraining("personalAdamW");
    break;
  case "openStorage":
    await openStorageMaintenance();
    break;
  case "openSettings":
    await openGeneralSettings();
    break;
  case "exportPortableData":
    await openStorageMaintenance();
    await submitStorageMaintenanceAction("exportPortableData");
    break;
  case "chooseExternalStorage":
    await openStorageMaintenance();
    await submitStorageMaintenanceAction("chooseExternalStorage");
    break;
  case "openJobs":
    toggleJobsPopover();
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
  elements.sourceContextMenu.classList.add("hidden");
  state.contextSourceID = null;
  elements.tagContextMenu.classList.add("hidden");
  state.contextTagID = null;
  state.contextTagGroupID = null;
}

function hideContextMenus() {
  hideContextMenu();
}

function positionContextMenu(menu, clientX, clientY) {
  const rect = menu.getBoundingClientRect();
  const left = Math.max(6, Math.min(clientX, globalThis.innerWidth - rect.width - 6));
  const top = Math.max(6, Math.min(clientY, globalThis.innerHeight - rect.height - 6));
  menu.style.left = `${left}px`;
  menu.style.top = `${top}px`;
}

function showAssetContextMenu(event, assetID) {
  hideContextMenus();
  state.contextAssetID = assetID;
  elements.assetContextMenu.classList.remove("hidden");
  positionContextMenu(elements.assetContextMenu, event.clientX, event.clientY);
}

function showSourceContextMenu(clientX, clientY, sourceID) {
  const source = state.sources.find((item) => item.id === sourceID);
  if (!source) return;
  hideContextMenus();
  state.contextSourceID = sourceID;
  elements.sourceContextMenuTitle.textContent = source.displayName;
  elements.sourceContextMenuActions.replaceChildren();
  const activeRequest = sourceManagementActiveRequest();
  const actions = [
    { action: "view", label: "在图库中查看" },
    ...sourceManagementActionsForCurrentState(source).map((action) => ({
      action,
      label: sourceManagementActionLabel(action),
      destructive: action === "delete",
    })),
    { action: "manage", label: "打开来源管理…" },
  ];
  for (const item of actions) {
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute("role", "menuitem");
    button.dataset.sourceContextAction = item.action;
    button.textContent = item.label;
    const canCancelPrewarm = item.action === "cancelPrewarm"
      && activeRequest?.sourceID === source.id
      && sourceManagementIsPrewarmAction(activeRequest.action);
    button.disabled = (!state.online && item.action !== "view")
      || (Boolean(activeRequest)
        && item.action !== "view"
        && item.action !== "manage"
        && !canCancelPrewarm);
    button.classList.toggle("danger", Boolean(item.destructive));
    elements.sourceContextMenuActions.append(button);
  }
  elements.sourceContextMenu.classList.remove("hidden");
  positionContextMenu(elements.sourceContextMenu, clientX, clientY);
  restoreOverlayFocus(elements.sourceContextMenuActions.querySelector("button:not(:disabled)"));
}

function appendTagContextAction({ action, label, destructive = false, disabled = false }) {
  const button = document.createElement("button");
  button.type = "button";
  button.setAttribute("role", "menuitem");
  button.dataset.tagContextAction = action;
  button.textContent = label;
  button.disabled = disabled;
  button.classList.toggle("danger", destructive);
  elements.tagContextMenuActions.append(button);
}

function showTagContextMenu(clientX, clientY, tagID) {
  const tag = tagByID(tagID);
  if (!tag) return;
  hideContextMenus();
  state.contextTagID = tagID;
  elements.tagContextMenu.setAttribute("aria-label", `${tag.displayName} 标签操作`);
  elements.tagContextMenuTitle.textContent = `标签 · ${tag.displayName}`;
  elements.tagContextMenuActions.replaceChildren();
  const excluded = state.filters.tagConditions.some(
    (condition) => condition.tagID === tagID && condition.decision === "excluded"
  );
  appendTagContextAction({
    action: "filterOnly",
    label: "仅筛选此标签",
    disabled: !state.online,
  });
  appendTagContextAction({
    action: "toggleExcluded",
    label: excluded ? "取消排除此标签" : "排除此标签",
    disabled: !state.online,
  });
  appendTagContextAction({ action: "renameTag", label: "重命名…" });
  appendTagContextAction({
    action: "archiveTag",
    label: "归档标签",
    destructive: true,
    disabled: !state.online || state.tagManagementMutating,
  });
  elements.tagContextMenu.classList.remove("hidden");
  positionContextMenu(elements.tagContextMenu, clientX, clientY);
  restoreOverlayFocus(elements.tagContextMenuActions.querySelector("button:not(:disabled)"));
}

function showTagGroupContextMenu(clientX, clientY, groupID) {
  const group = groupByID(groupID);
  if (!group || group.isSystem) return;
  hideContextMenus();
  state.contextTagGroupID = groupID;
  elements.tagContextMenu.setAttribute("aria-label", `${group.displayName} 标签分组操作`);
  elements.tagContextMenuTitle.textContent = `标签分组 · ${group.displayName}`;
  elements.tagContextMenuActions.replaceChildren();
  appendTagContextAction({ action: "renameGroup", label: "重命名分组…" });
  appendTagContextAction({
    action: "deleteGroup",
    label: "删除分组",
    destructive: true,
    disabled: !state.online || state.tagManagementMutating,
  });
  elements.tagContextMenu.classList.remove("hidden");
  positionContextMenu(elements.tagContextMenu, clientX, clientY);
  restoreOverlayFocus(elements.tagContextMenuActions.querySelector("button:not(:disabled)"));
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

function startReviewMarqueeSelection(event) {
  if (state.review.mode !== "queue"
    || event.button !== 0
    || event.target.closest(
      ".review-card, button, input, select, textarea, a, [role=\"button\"]"
    )) return;
  const additive = event.metaKey || event.ctrlKey;
  state.review.marquee = {
    pointerID: event.pointerId,
    startX: event.clientX,
    startY: event.clientY,
    additive,
    base: additive ? new Set(state.review.selectedAssetIDs) : new Set(),
    moved: false,
  };
  try {
    elements.reviewQueuePane.setPointerCapture(event.pointerId);
  } catch {
    // Document-level listeners remain the fallback when pointer capture is unavailable.
  }
}

function updateReviewMarqueeSelection(event) {
  const marquee = state.review.marquee;
  if (!marquee || event.pointerId !== marquee.pointerID) return;
  const dx = event.clientX - marquee.startX;
  const dy = event.clientY - marquee.startY;
  if (!marquee.moved && Math.hypot(dx, dy) < 5) return;
  if (!marquee.moved) {
    marquee.moved = true;
    elements.reviewMarqueeSelection.classList.remove("hidden");
    elements.reviewGrid.classList.add("marquee-active");
  }
  event.preventDefault();
  const left = Math.min(marquee.startX, event.clientX);
  const top = Math.min(marquee.startY, event.clientY);
  const right = Math.max(marquee.startX, event.clientX);
  const bottom = Math.max(marquee.startY, event.clientY);
  Object.assign(elements.reviewMarqueeSelection.style, {
    left: `${left}px`,
    top: `${top}px`,
    width: `${right - left}px`,
    height: `${bottom - top}px`,
  });
  const selected = new Set(marquee.base);
  let lastIntersectedIndex = -1;
  for (const card of elements.reviewGrid.querySelectorAll(":scope > .review-card")) {
    const rect = card.getBoundingClientRect();
    const intersects = rect.right >= left && rect.left <= right
      && rect.bottom >= top && rect.top <= bottom;
    card.classList.toggle("marquee-candidate", intersects);
    if (!intersects) continue;
    const index = Number(card.dataset.reviewIndex);
    const item = state.review.items[index];
    if (!item) continue;
    selected.add(item.assetID);
    lastIntersectedIndex = index;
  }
  state.review.selectedAssetIDs = selected;
  if (lastIntersectedIndex >= 0) {
    state.review.selectedIndex = lastIntersectedIndex;
    state.review.selectionAnchorIndex = lastIntersectedIndex;
  } else if (!selected.size) {
    state.review.selectedIndex = -1;
    state.review.selectionAnchorIndex = -1;
  } else if (!selected.has(state.review.items[state.review.selectedIndex]?.assetID)) {
    state.review.selectedIndex = state.review.items.findIndex((item) => selected.has(item.assetID));
  }
  renderReviewSelectionState({ renderDetail: false });
}

function finishReviewMarqueeSelection(event = null) {
  const marquee = state.review.marquee;
  if (event?.pointerId != null && event.pointerId !== marquee?.pointerID) return;
  const moved = marquee?.moved;
  const pointerID = marquee?.pointerID;
  state.review.marquee = null;
  if (pointerID != null && elements.reviewQueuePane.hasPointerCapture(pointerID)) {
    elements.reviewQueuePane.releasePointerCapture(pointerID);
  }
  elements.reviewMarqueeSelection.classList.add("hidden");
  elements.reviewGrid.classList.remove("marquee-active");
  elements.reviewGrid.querySelectorAll(".marquee-candidate").forEach((card) => {
    card.classList.remove("marquee-candidate");
  });
  if (moved) renderReviewSelectionState();
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

function setupSidebarReordering() {
  elements.sourceList.addEventListener("dragstart", (event) => {
    const row = event.target.closest("[data-source-id]");
    if (!row?.dataset.sourceId) return;
    state.sidebarDrag.sourceID = row.dataset.sourceId;
    row.classList.add("dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("application/x-imageall-source", row.dataset.sourceId);
  });
  elements.sourceList.addEventListener("dragover", (event) => {
    if (!state.sidebarDrag.sourceID) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    clearSidebarDropIndicators();
    const target = event.target.closest("[data-source-id]");
    if (!target || target.dataset.sourceId === state.sidebarDrag.sourceID) return;
    const after = event.clientY > target.getBoundingClientRect().top
      + target.getBoundingClientRect().height / 2;
    target.classList.add(after ? "drop-after" : "drop-before");
    state.sidebarDrag.dropTarget = target;
  });
  elements.sourceList.addEventListener("drop", (event) => {
    const sourceID = state.sidebarDrag.sourceID;
    if (!sourceID) return;
    event.preventDefault();
    const target = event.target.closest("[data-source-id]");
    let beforeID = null;
    if (target && target.dataset.sourceId !== sourceID) {
      if (target.classList.contains("drop-after")) {
        beforeID = target.nextElementSibling?.dataset.sourceId || null;
      } else {
        beforeID = target.dataset.sourceId;
      }
    }
    reorderSourceBefore(sourceID, beforeID);
    state.sidebarDrag.sourceID = null;
    state.sidebarDrag.suppressClickUntil = performance.now() + 250;
    clearSidebarDropIndicators();
  });
  elements.sourceList.addEventListener("dragend", (event) => {
    event.target.closest("[data-source-id]")?.classList.remove("dragging");
    state.sidebarDrag.sourceID = null;
    state.sidebarDrag.suppressClickUntil = performance.now() + 250;
    clearSidebarDropIndicators();
  });
  elements.sourceList.addEventListener("keydown", (event) => {
    const row = event.target.closest("[data-source-id]");
    if (!row?.dataset.sourceId || !event.altKey) return;
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    reorderSourceByOffset(row.dataset.sourceId, event.key === "ArrowDown" ? 1 : -1);
  });

  elements.tagNavigation.addEventListener("dragstart", (event) => {
    const chip = event.target.closest("[data-quick-tag-id]");
    if (!chip?.draggable) return;
    state.sidebarDrag.tagID = chip.dataset.quickTagId;
    state.sidebarDrag.tagSurface = "sidebar";
    chip.classList.add("dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("application/x-imageall-tag", chip.dataset.quickTagId);
  });
  elements.tagNavigation.addEventListener("dragover", (event) => {
    if (!state.sidebarDrag.tagID) return;
    const section = event.target.closest("[data-tag-drop-group-id]");
    if (!section) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    clearSidebarDropIndicators();
    const target = event.target.closest("[data-quick-tag-id]");
    if (target && target.dataset.quickTagId !== state.sidebarDrag.tagID) {
      const rect = target.getBoundingClientRect();
      const after = event.clientX > rect.left + rect.width * 0.62;
      target.classList.add(after ? "drop-after" : "drop-before");
      state.sidebarDrag.dropTarget = target;
    } else {
      section.classList.add("drag-over-group");
      state.sidebarDrag.dropTarget = section;
    }
  });
  elements.tagNavigation.addEventListener("drop", (event) => {
    const tagID = state.sidebarDrag.tagID;
    const section = event.target.closest("[data-tag-drop-group-id]");
    if (!tagID || !section) return;
    event.preventDefault();
    const target = event.target.closest("[data-quick-tag-id]");
    let beforeTagID = null;
    if (target && target.dataset.quickTagId !== tagID) {
      if (target.classList.contains("drop-after")) {
        const siblings = [...section.querySelectorAll("[data-quick-tag-id]")];
        const targetIndex = siblings.indexOf(target);
        beforeTagID = siblings[targetIndex + 1]?.dataset.quickTagId || null;
      } else {
        beforeTagID = target.dataset.quickTagId;
      }
    }
    moveSidebarTag(tagID, section.dataset.tagDropGroupId, beforeTagID);
    state.sidebarDrag.tagID = null;
    state.sidebarDrag.tagSurface = null;
    state.sidebarDrag.suppressClickUntil = performance.now() + 250;
    clearSidebarDropIndicators();
  });
  elements.tagNavigation.addEventListener("dragend", (event) => {
    event.target.closest("[data-quick-tag-id]")?.classList.remove("dragging");
    state.sidebarDrag.tagID = null;
    state.sidebarDrag.tagSurface = null;
    state.sidebarDrag.suppressClickUntil = performance.now() + 250;
    clearSidebarDropIndicators();
  });
  elements.tagNavigation.addEventListener("keydown", (event) => {
    const groupToggle = event.target.closest("[data-sidebar-tag-group-toggle]");
    if (groupToggle && (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10"))) {
      const groupID = groupToggle.dataset.sidebarTagGroupToggle;
      const group = groupByID(groupID);
      if (group && !group.isSystem) {
        event.preventDefault();
        const rect = groupToggle.getBoundingClientRect();
        showTagGroupContextMenu(rect.left + 18, rect.top + Math.min(24, rect.height), groupID);
      }
      return;
    }
    if (groupToggle && ["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) {
      const toggles = [...elements.tagNavigation.querySelectorAll(
        "[data-sidebar-tag-group-toggle]"
      )];
      const currentIndex = toggles.indexOf(groupToggle);
      const nextIndex = event.key === "Home"
        ? 0
        : event.key === "End"
          ? toggles.length - 1
          : Math.max(0, Math.min(
            toggles.length - 1,
            currentIndex + (event.key === "ArrowDown" ? 1 : -1)
          ));
      event.preventDefault();
      toggles[nextIndex]?.focus({ preventScroll: true });
      return;
    }
    const chip = event.target.closest("[data-quick-tag-id]");
    if (!chip) return;
    if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
      event.preventDefault();
      const rect = chip.getBoundingClientRect();
      showTagContextMenu(
        rect.left + Math.min(32, rect.width),
        rect.top + Math.min(24, rect.height),
        chip.dataset.quickTagId
      );
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      toggleSidebarTagFilter(chip.dataset.quickTagId, {
        matchMode: "all",
        excluded: event.altKey,
      });
      return;
    }
    if (!event.altKey) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      reorderSidebarTagByOffset(
        chip.dataset.quickTagId,
        event.key === "ArrowRight" ? 1 : -1
      );
    } else if (event.key === "ArrowUp" || event.key === "ArrowDown") {
      event.preventDefault();
      moveSidebarTagToAdjacentGroup(
        chip.dataset.quickTagId,
        event.key === "ArrowDown" ? 1 : -1
      );
    }
  });
}

function bindEvents() {
  setupSidebarReordering();
  elements.accountLoginTab.addEventListener("click", () => selectAuthMethod("account"));
  elements.pairingLoginTab.addEventListener("click", () => selectAuthMethod("pairing"));
  elements.accountLoginForm.addEventListener("submit", loginWithAccount);
  elements.pairingForm.addEventListener("submit", pair);
  elements.sourceList.addEventListener("click", (event) => {
    if (performance.now() < state.sidebarDrag.suppressClickUntil) return;
    const button = event.target.closest("[data-source-id]");
    if (button) selectSource(button.dataset.sourceId);
  });
  elements.sourceManagerButton.addEventListener("click", openSourceManager);
  elements.sourcePrewarmStatusButton.addEventListener("click", openSourceManager);
  elements.emptyConnectFolderButton.addEventListener("click", async () => {
    await openSourceManager();
    await submitSourceManagementAction("connectFolder");
  });
  elements.emptyConnectPhotosButton.addEventListener("click", async () => {
    await openSourceManager();
    await submitSourceManagementAction("connectPhotos");
  });
  elements.emptySourceRecoveryButton.addEventListener("click", async () => {
    const action = elements.emptySourceRecoveryButton.dataset.sourceAction;
    const sourceID = elements.emptySourceRecoveryButton.dataset.sourceId;
    if (!action || !sourceID) return;
    await openSourceManager();
    await submitSourceManagementAction(action, sourceID);
  });
  elements.emptyOpenSourceManagerButton.addEventListener("click", openSourceManager);
  elements.sourceList.addEventListener("contextmenu", (event) => {
    const button = event.target.closest("[data-source-id]");
    if (!button) return;
    event.preventDefault();
    showSourceContextMenu(event.clientX, event.clientY, button.dataset.sourceId);
  });
  elements.sourceList.addEventListener("keydown", (event) => {
    const button = event.target.closest("[data-source-id]");
    if (!button || !(event.key === "ContextMenu" || (event.shiftKey && event.key === "F10"))) {
      return;
    }
    event.preventDefault();
    const rect = button.getBoundingClientRect();
    showSourceContextMenu(rect.left + 18, rect.top + Math.min(28, rect.height), button.dataset.sourceId);
  });
  elements.sourceManagerCloseButton.addEventListener("click", () => closeSourceManager());
  elements.sourceManagerRefreshButton.addEventListener("click", () => loadSourceManagement());
  elements.sourceConnectFolderButton.addEventListener("click", () => {
    submitSourceManagementAction("connectFolder");
  });
  elements.sourceConnectPhotosButton.addEventListener("click", () => {
    submitSourceManagementAction("connectPhotos");
  });
  elements.sourceManagerList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-source-action][data-source-id]");
    if (button) requestSourceManagementAction(button.dataset.sourceAction, button.dataset.sourceId);
  });
  elements.sourceManagerDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeSourceManager();
  });
  elements.sourceManagerDialog.addEventListener("keydown", (event) => {
    moveDialogButtonFocus(event, elements.sourceManagerDialog);
  });
  elements.settingsButton.addEventListener("click", openGeneralSettings);
  elements.generalSettingsCloseButton.addEventListener("click", () => closeGeneralSettings());
  elements.toolbarDisplayModeControl.addEventListener("click", (event) => {
    const button = event.target.closest("[data-toolbar-display-mode]");
    if (button && button.getAttribute("aria-checked") !== "true") {
      submitGeneralSettingsPatch({ toolbarDisplayMode: button.dataset.toolbarDisplayMode });
    }
  });
  elements.generalSettingsModelToggle.addEventListener("click", () => {
    submitGeneralSettingsPatch({
      modelEnabled: elements.generalSettingsModelToggle.getAttribute("aria-checked") !== "true",
    });
  });
  elements.generalSettingsPrewarmToggle.addEventListener("click", () => {
    submitGeneralSettingsPatch({
      idleThumbnailPrewarmEnabled:
        elements.generalSettingsPrewarmToggle.getAttribute("aria-checked") !== "true",
    });
  });
  elements.generalSuggestionDefaults.addEventListener("change", (event) => {
    const input = event.target.closest("[data-suggestion-default]");
    if (input) commitSuggestionDefault(input);
  });
  elements.generalSuggestionDefaults.addEventListener("keydown", (event) => {
    const input = event.target.closest("[data-suggestion-default]");
    if (input && event.key === "Enter") {
      event.preventDefault();
      commitSuggestionDefault(input);
    }
  });
  elements.suggestionOverridesButton.addEventListener("click", openSuggestionThresholdDialog);
  elements.suggestionThresholdCloseButton.addEventListener(
    "click",
    () => closeSuggestionThresholdDialog()
  );
  elements.suggestionThresholdSearch.addEventListener("input", renderSuggestionThresholdDialog);
  elements.suggestionThresholdList.addEventListener("change", (event) => {
    const input = event.target.closest('[data-threshold-focus="input"]');
    if (input) commitSuggestionOverride(input);
  });
  elements.suggestionThresholdList.addEventListener("keydown", (event) => {
    const input = event.target.closest('[data-threshold-focus="input"]');
    if (input && event.key === "Enter") {
      event.preventDefault();
      commitSuggestionOverride(input);
    }
  });
  elements.suggestionThresholdList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-threshold-action]");
    if (!button) return;
    const mutation = {
      action: button.dataset.thresholdAction,
      method: button.dataset.thresholdMethod,
      tagID: button.dataset.thresholdTagId,
    };
    if (button.dataset.thresholdScore != null) {
      mutation.minScore = Number(button.dataset.thresholdScore);
    }
    submitGeneralSettingsPatch({ suggestionThresholdMutation: mutation });
  });
  elements.suggestionThresholdDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeSuggestionThresholdDialog();
  });
  elements.suggestionThresholdDialog.addEventListener("keydown", (event) => {
    moveDialogButtonFocus(event, elements.suggestionThresholdDialog);
  });
  elements.generalSettingsDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeGeneralSettings();
  });
  elements.generalSettingsDialog.addEventListener("keydown", (event) => {
    moveDialogButtonFocus(event, elements.generalSettingsDialog);
  });
  elements.storageButton.addEventListener("click", openStorageMaintenance);
  elements.storageCloseButton.addEventListener("click", () => closeStorageMaintenance());
  elements.storageRefreshButton.addEventListener("click", () => loadStorageMaintenance());
  elements.exportPortableDataButton.addEventListener("click", () => {
    submitStorageMaintenanceAction("exportPortableData");
  });
  elements.chooseExternalStorageButton.addEventListener("click", () => {
    submitStorageMaintenanceAction("chooseExternalStorage");
  });
  elements.clearPreviewCacheButton.addEventListener("click", () => {
    submitStorageMaintenanceAction("clearPreviewCache");
  });
  elements.clearPhotosOriginalsButton.addEventListener("click", () => {
    submitStorageMaintenanceAction("clearPhotosOriginals");
  });
  elements.storageDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeStorageMaintenance();
  });
  elements.storageDialog.addEventListener("keydown", (event) => {
    moveDialogButtonFocus(event, elements.storageDialog);
  });
  document.querySelector('[data-source-id=""]').addEventListener("click", () => selectSource(""));
  elements.untaggedNavigationButton.addEventListener("click", applyUntaggedFilter);
  elements.galleryOverviewNavigationButton.addEventListener("click", openGalleryOverviewWorkspace);
  elements.worldMapNavigationButton.addEventListener("click", openWorldMapWorkspace);
  elements.reviewNavigationButton.addEventListener("click", () => openReviewWorkspace());
  elements.trainingNavigationButton.addEventListener("click", () => openTrainingWorkspace());
  elements.slimmingNavigationButton.addEventListener("click", openSlimmingWorkspace);
  elements.tagNavigation.addEventListener("click", (event) => {
    if (performance.now() < state.sidebarDrag.suppressClickUntil) return;
    const groupToggle = event.target.closest("[data-sidebar-tag-group-toggle]");
    if (groupToggle) {
      toggleSidebarTagGroup(groupToggle.dataset.sidebarTagGroupToggle);
      return;
    }
    const button = event.target.closest("[data-quick-tag-id]");
    if (button) {
      toggleSidebarTagFilter(button.dataset.quickTagId, {
        matchMode: event.metaKey || event.ctrlKey ? "all" : "any",
        excluded: (event.metaKey || event.ctrlKey) && event.altKey,
      });
    }
  });
  elements.tagNavigation.addEventListener("contextmenu", (event) => {
    const chip = event.target.closest("[data-quick-tag-id]");
    if (chip) {
      event.preventDefault();
      showTagContextMenu(event.clientX, event.clientY, chip.dataset.quickTagId);
      return;
    }
    const groupToggle = event.target.closest("[data-sidebar-tag-group-toggle]");
    const groupID = groupToggle?.dataset.sidebarTagGroupToggle;
    const group = groupByID(groupID);
    if (!group || group.isSystem) return;
    event.preventDefault();
    showTagGroupContextMenu(event.clientX, event.clientY, groupID);
  });
  elements.tagNavigationSearch.addEventListener("input", renderTagNavigation);
  elements.closeGalleryOverviewButton.addEventListener("click", closeGalleryOverviewWorkspace);
  elements.refreshGalleryOverviewButton.addEventListener("click", () => loadGalleryOverview());
  elements.retryGalleryOverviewButton.addEventListener("click", () => loadGalleryOverview());
  elements.galleryOverviewMediaLedger.addEventListener("click", (event) => {
    const button = event.target.closest("[data-gallery-overview-media-kind]");
    if (button) drillDownFromGalleryOverview({ mediaKind: button.dataset.galleryOverviewMediaKind });
  });
  elements.galleryOverviewSources.addEventListener("click", (event) => {
    const button = event.target.closest("[data-gallery-overview-source-id]");
    if (button) drillDownFromGalleryOverview({ sourceID: button.dataset.galleryOverviewSourceId });
  });
  elements.galleryOverviewTags.addEventListener("click", (event) => {
    const button = event.target.closest("[data-gallery-overview-tag-id]");
    if (button) drillDownFromGalleryOverview({ tagID: button.dataset.galleryOverviewTagId });
  });
  elements.sidebarNewTagButton.addEventListener("click", openNewTagDialog);
  elements.sidebarInstallPresetTagsButton.addEventListener("click", () => {
    installPresetTags(elements.sidebarInstallPresetTagsButton);
  });
  elements.emptyInstallPresetTagsButton.addEventListener("click", () => {
    installPresetTags(elements.emptyInstallPresetTagsButton);
  });
  elements.tagManagerButton.addEventListener("click", openTagManager);
  elements.closeTagManagerButton.addEventListener("click", () => elements.tagManagerDialog.close());
  elements.tagManagerDialog.addEventListener("close", restoreTagManagerReturnFocus);
  elements.tagManagerTagSelect.addEventListener("change", syncManagedTagFields);
  elements.tagManagerGroupSelect.addEventListener("change", syncManagedGroupFields);
  elements.renameManagedTagButton.addEventListener("click", renameManagedTag);
  elements.moveManagedTagButton.addEventListener("click", moveManagedTag);
  elements.archiveManagedTagButton.addEventListener("click", confirmArchiveManagedTag);
  elements.createTagGroupButton.addEventListener("click", createManagedTagGroup);
  elements.installPresetTagsButton.addEventListener("click", () => {
    installPresetTags(elements.installPresetTagsButton);
  });
  elements.renameTagGroupButton.addEventListener("click", renameManagedTagGroup);
  elements.deleteTagGroupButton.addEventListener("click", confirmDeleteManagedTagGroup);
  elements.cancelConfirmButton.addEventListener("click", closeConfirmation);
  elements.confirmDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeConfirmation();
  });
  elements.confirmActionButton.addEventListener("click", async () => {
    const action = state.pendingConfirmAction;
    const returnFocus = state.confirmationReturnFocus;
    closeConfirmation({ restoreFocus: false });
    if (action) await action();
    restoreConfirmationReturnFocus(returnFocus);
  });
  elements.undoToastButton.addEventListener("click", () => {
    if (state.toastUndoKind) undoLatestDecision(state.toastUndoKind);
  });
  elements.undoTagButton.addEventListener("click", () => undoLatestDecision("tag"));
  elements.undoReviewButton.addEventListener("click", () => undoLatestDecision("review"));
  elements.reviewUndoButton.addEventListener("click", () => undoLatestDecision("review"));
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
  elements.assetGrid.addEventListener("pointerover", (event) => {
    const card = event.target.closest(".asset-card[data-asset-id]");
    if (!card || card.contains(event.relatedTarget)) return;
    if (event.pointerType && event.pointerType !== "mouse") return;
    beginAssetHoverVideo(card);
  });
  elements.assetGrid.addEventListener("pointerout", (event) => {
    const card = event.target.closest(".asset-card[data-asset-id]");
    if (!card || card.contains(event.relatedTarget)) return;
    if (activeAssetHoverCard === card) stopAssetHoverVideo(card);
  });
  elements.libraryScroll.addEventListener("scroll", () => {
    if (activeAssetHoverCard && !activeAssetHoverCard.matches(":hover")) {
      stopAssetHoverVideo();
    }
  }, { passive: true });
  elements.libraryScroll.addEventListener("pointerdown", startMarqueeSelection);
  elements.reviewQueuePane.addEventListener("pointerdown", startReviewMarqueeSelection);
  document.addEventListener("pointermove", updateMarqueeSelection);
  document.addEventListener("pointermove", updateReviewMarqueeSelection);
  document.addEventListener("pointerup", finishMarqueeSelection);
  document.addEventListener("pointerup", finishReviewMarqueeSelection);
  document.addEventListener("pointercancel", finishMarqueeSelection);
  document.addEventListener("pointercancel", finishReviewMarqueeSelection);
  globalThis.addEventListener("blur", () => {
    stopAssetHoverVideo();
    finishMarqueeSelection();
    finishReviewMarqueeSelection();
  });
  setupInspectorTagInteractions(elements.inspectorTags, "single", false);
  setupInspectorTagInteractions(elements.selectionInspectorTags, "selection", true);
  elements.inspectorSuggestions.addEventListener("click", (event) => {
    const button = event.target.closest(
      "[data-inspector-suggestion-key][data-action][data-tag-id]"
    );
    if (!button) return;
    state.pendingInspectorSuggestionFocus = {
      key: button.dataset.inspectorSuggestionKey,
      index: Number(button.dataset.inspectorSuggestionIndex) || 0,
      action: button.dataset.action,
    };
    mutateTag(button.dataset.tagId, button.dataset.action);
  });
  elements.expandInspectorSuggestionsButton.addEventListener("click", () => {
    const suggestions = state.selectedDetail?.pendingSuggestions || [];
    state.inspectorSuggestionsExpanded = true;
    if (suggestions[5]) {
      state.pendingInspectorSuggestionFocus = {
        key: inspectorSuggestionKey(suggestions[5]),
        index: 5,
        action: "accept",
      };
    }
    if (state.selectedDetail) renderInspector(state.selectedDetail);
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
    elements.openLightboxButton.classList.remove("hidden");
    hidePreviewPlaceholder();
    resetCloudPreviewRecovery();
  });
  elements.previewImage.addEventListener("imageall-protected-error", (event) => {
    if (String(event.detail?.requestID) !== elements.previewImage.dataset.protectedRequestId) {
      return;
    }
    delete elements.previewImage.dataset.protectedPath;
    elements.previewLoading.classList.add("hidden");
    const needsCloudPreview = event.detail?.status === 409
      && event.detail?.code === "conflict"
      && event.detail?.message === "cloud preview required";
    if (needsCloudPreview && state.selectedDetail?.assetID) {
      showCloudPreviewRecovery(state.selectedDetail.assetID);
      return;
    }
    if (elements.previewPlaceholderImage.hasAttribute("src")) {
      toast("已显示缩略图，大图暂不可用");
    } else {
      toast("预览暂不可用");
    }
  });
  elements.cloudPreviewButton.addEventListener("click", () => {
    downloadSelectedCloudPreview();
  });
  elements.previewVideo.addEventListener("loadeddata", () => {
    if (elements.previewVideo.dataset.assetId !== state.selectedDetail?.assetID) return;
    elements.previewLoading.classList.add("hidden");
  });
  elements.previewVideo.addEventListener("error", () => {
    if (!elements.previewVideo.hasAttribute("src")
      || elements.previewVideo.dataset.assetId !== state.selectedDetail?.assetID) return;
    elements.previewLoading.classList.add("hidden");
    toast("视频暂不可播放，请确认原片已下载到这台 Mac");
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
  elements.thumbnailAspectButton.addEventListener("click", () => {
    state.layout.aspectMode = state.layout.aspectMode === "original" ? "square" : "original";
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
  elements.openOriginalButton.addEventListener("click", openSelectedOriginalOnMac);

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
    renderActiveFilterBar();
    renderTagNavigation();
    await loadAssets();
    elements.filterPopover.classList.add("hidden");
    elements.filterButton.setAttribute("aria-expanded", "false");
  });
  elements.clearActiveFiltersButton.addEventListener("click", async () => {
    state.filters = emptyFilters();
    state.filters.mediaKind = state.mediaKind;
    state.filterDraft = null;
    syncFilterControlsFromState();
    renderTagNavigation();
    await loadAssets();
  });
  elements.activeFilterRelation.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-active-filter-match]");
    if (!button || button.disabled) return;
    const matchMode = button.dataset.activeFilterMatch;
    if (state.filters.tagMatchMode === matchMode) return;
    state.filters.tagMatchMode = matchMode;
    state.filterDraft = null;
    syncFilterControlsFromState();
    await loadAssets();
  });

  elements.selectionModeButton.addEventListener("click", () => {
    setSelectionMode(!state.selectionMode);
  });
  elements.personalModelButton.addEventListener("click", togglePersonalModelPopover);
  elements.rebuildPersonalModelButton.addEventListener("click", () => {
    openLibraryPersonalTraining("personalCentroid");
  });
  elements.rebuildPersonalAdamWButton.addEventListener("click", () => {
    openLibraryPersonalTraining("personalAdamW");
  });
  elements.personalModelPopover.addEventListener("keydown", (event) => {
    const buttons = [...elements.personalModelPopover.querySelectorAll("button:not(:disabled)")];
    if (!buttons.length) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closePersonalModelPopover();
      return;
    }
    if (!["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const current = Math.max(0, buttons.indexOf(document.activeElement));
    const next = event.key === "Home" ? 0
      : event.key === "End" ? buttons.length - 1
        : (current + (event.key === "ArrowUp" ? -1 : 1) + buttons.length) % buttons.length;
    buttons[next].focus({ preventScroll: true });
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
  elements.prepareSelectedFeaturesButton.addEventListener("click", prepareSelectedFeatures);
  elements.generateSelectedSuggestionsButton.addEventListener("click", () => {
    generateSampleSuggestions({ useSelection: true });
  });
  elements.findSimilarSelectionButton.addEventListener("click", findSimilarFromSelection);
  elements.cancelEmbeddingPreparationButton.addEventListener(
    "click",
    cancelEmbeddingPreparation
  );
  elements.selectionInspectorPrepareFeaturesButton.addEventListener(
    "click",
    prepareSelectedFeatures
  );
  elements.selectionInspectorGenerateSuggestionsButton.addEventListener("click", () => {
    generateSampleSuggestions({ useSelection: true });
  });
  elements.selectionInspectorFindSimilarButton.addEventListener(
    "click",
    findSimilarFromSelection
  );
  elements.selectionInspectorCancelPreparationButton.addEventListener(
    "click",
    cancelEmbeddingPreparation
  );
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

  elements.jobsButton.addEventListener("click", toggleJobsPopover);
  elements.closeJobsButton.addEventListener("click", () => {
    closeJobsPopover();
  });
  elements.jobsList.addEventListener("click", (event) => {
    const slimmingButton = event.target.closest("[data-open-slimming-job-id]");
    if (slimmingButton) {
      openSlimmingJobFromActivity(slimmingButton.dataset.openSlimmingJobId);
      return;
    }
    const button = event.target.closest("[data-job-id][data-action]");
    if (button) {
      applyJobAction(button.dataset.jobId, button.dataset.action);
      return;
    }
    const row = event.target.closest("[data-job-row-id]");
    if (row) selectJobRow(row.dataset.jobRowId);
  });
  elements.jobsList.addEventListener("focusin", (event) => {
    const row = event.target.closest("[data-job-row-id]");
    if (row) selectJobRow(row.dataset.jobRowId);
  });
  elements.jobsList.addEventListener("keydown", (event) => {
    if (["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) {
      event.preventDefault();
      event.stopPropagation();
      moveJobSelection(event.key);
      return;
    }
    if (event.key === "Enter" && event.target.matches("[data-job-row-id]")) {
      event.preventDefault();
      event.stopPropagation();
      const contextAction = event.target.querySelector(".job-context-action");
      if (contextAction) contextAction.click();
      else event.target.querySelector(".job-action")?.focus({ preventScroll: true });
    }
  });

  elements.reviewButton.addEventListener("click", () => openReviewWorkspace());
  elements.worldMapButton.addEventListener("click", openWorldMapWorkspace);
  elements.closeWorldMapButton.addEventListener("click", closeWorldMapWorkspace);
  elements.refreshWorldMapButton.addEventListener("click", () => {
    state.worldMap.rendererError = false;
    void loadWorldMapSnapshot({ bounds: state.worldMap.viewport });
  });
  elements.openWorldMapPlaceTagsButton.addEventListener("click", openWorldMapPlaceTags);
  elements.closeWorldMapPlaceTagButton.addEventListener("click", closeWorldMapPlaceTags);
  elements.worldMapPlaceTagDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeWorldMapPlaceTags();
  });
  elements.worldMapPlaceTagItems.addEventListener("input", (event) => {
    const input = event.target.closest("[data-place-tag-query]");
    if (!input) return;
    state.worldMap.placeTags.queryByTagID.set(input.dataset.placeTagQuery, input.value);
    updateWorldMapPlaceQueryState(input.dataset.placeTagQuery);
  });
  elements.worldMapPlaceTagItems.addEventListener("keydown", (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const input = event.target.closest("[data-place-tag-query]");
    if (input && event.key === "ArrowDown") {
      const candidates = [...elements.worldMapPlaceTagItems.querySelectorAll(
        `[data-place-tag-action="confirm"][data-tag-id="${CSS.escape(input.dataset.placeTagQuery)}"]:not(:disabled)`
      )];
      if (!candidates.length) return;
      event.preventDefault();
      candidates[0].focus({ preventScroll: true });
      candidates[0].scrollIntoView({ block: "nearest" });
      return;
    }
    const candidate = event.target.closest("[data-place-tag-action=confirm]");
    if (!candidate || !["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
    const candidates = [...elements.worldMapPlaceTagItems.querySelectorAll(
      `[data-place-tag-action="confirm"][data-tag-id="${CSS.escape(candidate.dataset.tagId)}"]:not(:disabled)`
    )];
    const currentIndex = candidates.indexOf(candidate);
    if (currentIndex < 0) return;
    event.preventDefault();
    if (event.key === "ArrowUp" && currentIndex === 0) {
      const query = elements.worldMapPlaceTagItems.querySelector(
        `[data-place-tag-query="${CSS.escape(candidate.dataset.tagId)}"]`
      );
      query?.focus({ preventScroll: true });
      query?.scrollIntoView({ block: "nearest" });
      return;
    }
    const nextIndex = event.key === "Home"
      ? 0
      : event.key === "End"
        ? candidates.length - 1
        : Math.max(0, Math.min(
          candidates.length - 1,
          currentIndex + (event.key === "ArrowDown" ? 1 : -1)
        ));
    candidates[nextIndex].focus({ preventScroll: true });
    candidates[nextIndex].scrollIntoView({ block: "nearest" });
  });
  elements.worldMapPlaceTagItems.addEventListener("submit", (event) => {
    const form = event.target.closest("[data-place-tag-form]");
    if (!form) return;
    event.preventDefault();
    void submitWorldMapPlaceTagSearch(form.dataset.placeTagForm);
  });
  elements.worldMapPlaceTagItems.addEventListener("click", (event) => {
    const button = event.target.closest("[data-place-tag-action=confirm]");
    if (!button || button.disabled) return;
    void confirmWorldMapPlaceTag(button.dataset.tagId, button.dataset.placeId);
  });
  elements.openWorldMapLocationBackfillButton.addEventListener(
    "click",
    openWorldMapLocationBackfill
  );
  elements.closeWorldMapLocationBackfillButton.addEventListener(
    "click",
    closeWorldMapLocationBackfill
  );
  elements.worldMapLocationBackfillDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeWorldMapLocationBackfill();
  });
  elements.worldMapLocationBackfillSources.addEventListener("click", (event) => {
    const button = event.target.closest("[data-location-backfill-action]");
    if (!button || button.disabled) return;
    void submitWorldMapLocationBackfill(
      button.dataset.sourceId,
      button.dataset.locationBackfillAction
    );
  });
  elements.closeWorldMapDetailButton.addEventListener("click", clearWorldMapSelection);
  elements.worldMapPhotoStrip.addEventListener("click", (event) => {
    const button = event.target.closest("[data-world-map-asset-id]");
    if (button) openLightbox("worldMap", button.dataset.worldMapAssetId);
  });
  globalThis.addEventListener("message", handleWorldMapMessage);
  const rendererStatus = worldMapRenderer()?.rendererStatus?.();
  if (rendererStatus?.ready) {
    state.worldMap.rendererReady = true;
    state.worldMap.rendererError = false;
    renderWorldMap();
  }
  elements.trainingButton.addEventListener("click", () => openTrainingWorkspace());
  elements.slimmingButton.addEventListener("click", openSlimmingWorkspace);
  elements.closeSlimmingButton.addEventListener("click", closeSlimmingWorkspace);
  elements.newSlimmingAnalysisButton.addEventListener("click", openSlimmingSetupDialog);
  elements.closeSlimmingSetupButton.addEventListener("click", closeSlimmingSetupDialog);
  elements.cancelSlimmingSetupButton.addEventListener("click", closeSlimmingSetupDialog);
  elements.slimmingSetupForm.addEventListener("submit", (event) => {
    event.preventDefault();
    submitSlimmingSetup();
  });
  elements.slimmingSetupDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeSlimmingSetupDialog();
  });
  elements.slimmingModeOptions.addEventListener("click", (event) => {
    const button = event.target.closest("[data-slimming-mode]");
    if (!button || button.disabled) return;
    state.slimming.setup.mode = button.dataset.slimmingMode;
    state.slimming.setup.launchOperationID = null;
    state.slimming.setup.error = "";
    renderSlimmingSetup();
  });
  elements.slimmingSourceOptions.addEventListener("change", (event) => {
    const input = event.target.closest("[data-slimming-source-id]");
    if (!input) return;
    if (input.checked) state.slimming.setup.selectedSourceIDs.add(input.dataset.slimmingSourceId);
    else state.slimming.setup.selectedSourceIDs.delete(input.dataset.slimmingSourceId);
    state.slimming.setup.launchOperationID = null;
    renderSlimmingSetup();
  });
  elements.toggleAllSlimmingSourcesButton.addEventListener("click", () => {
    const sources = state.slimming.setup.snapshot?.sources || [];
    const allSelected = sources.length > 0
      && sources.every((source) => state.slimming.setup.selectedSourceIDs.has(source.id));
    state.slimming.setup.selectedSourceIDs = allSelected
      ? new Set()
      : new Set(sources.map((source) => source.id));
    state.slimming.setup.launchOperationID = null;
    renderSlimmingSetup();
  });
  elements.resetSlimmingThresholdsButton.addEventListener("click", () => {
    state.slimming.setup.thresholds = normalizeSlimmingThresholdDraft(
      state.slimming.setup.snapshot?.factoryThresholds
    );
    state.slimming.setup.thresholdOperationID = null;
    state.slimming.setup.error = "";
    renderSlimmingSetup();
  });
  for (const control of [
    elements.slimmingRecallMode,
    elements.slimmingRecallTopK,
    elements.slimmingL2Mode,
    elements.slimmingL2Distance,
    elements.slimmingDINOMode,
    elements.slimmingDINOSimilarity,
    elements.slimmingBucketingMode,
    elements.slimmingBucketActivationCount,
  ]) control.addEventListener("change", readSlimmingThresholdControls);
  elements.saveSlimmingThresholdsButton.addEventListener("click", () => {
    saveSlimmingThresholds();
  });
  elements.slimmingJobActions.addEventListener("click", (event) => {
    const button = event.target.closest("[data-slimming-job-action-id][data-action]");
    if (button) applySlimmingJobAction(button.dataset.slimmingJobActionId, button.dataset.action);
  });
  elements.slimmingJobStatus.addEventListener("click", (event) => {
    const activity = event.target.closest("[data-open-job-activity-id]");
    if (activity) {
      const jobID = activity.dataset.openJobActivityId;
      closeSlimmingWorkspace();
      openAssociatedActivity(jobID);
      return;
    }
    const action = event.target.closest("[data-slimming-job-action-id][data-action]");
    if (action) {
      applySlimmingJobAction(action.dataset.slimmingJobActionId, action.dataset.action);
    }
  });
  elements.slimmingWorkspaceTabs.addEventListener("click", (event) => {
    const button = event.target.closest("[data-slimming-view]");
    if (button) setSlimmingView(button.dataset.slimmingView);
  });
  elements.refreshSlimmingButton.addEventListener("click", () => {
    if (state.slimming.view === "recycle") loadSlimmingRecycle();
    else {
      loadSlimmingWorkspace();
      loadSlimmingRemovals({ quiet: true });
      loadSlimmingIdenticalCleanupRequests({ quiet: true });
    }
  });
  elements.slimmingIdenticalCleanupButton.addEventListener(
    "click",
    openSlimmingIdenticalCleanupDialog
  );
  elements.cancelSlimmingIdenticalCleanupButton.addEventListener(
    "click",
    closeSlimmingIdenticalCleanupDialog
  );
  elements.slimmingIdenticalCleanupDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeSlimmingIdenticalCleanupDialog();
  });
  elements.recoverableSlimmingIdenticalCleanupButton.addEventListener("click", () => {
    submitSlimmingIdenticalCleanup("recoverableRecycle");
  });
  elements.fastSlimmingIdenticalCleanupButton.addEventListener("click", () => {
    submitSlimmingIdenticalCleanup("releaseSourceSpace");
  });
  elements.slimmingMoveToRecycleButton.addEventListener("click", () => {
    submitSlimmingRemoval("recoverableRecycle");
  });
  elements.slimmingReleaseSpaceButton.addEventListener("click", () => {
    submitSlimmingRemoval("releaseSourceSpace");
  });
  elements.slimmingLoadMoreClustersButton.addEventListener("click", () => {
    state.slimming.clusterLimit = Math.min(
      SLIMMING_CLUSTER_LIMIT_MAX,
      state.slimming.clusterLimit + 48
    );
    loadSlimmingWorkspace({ quiet: true });
  });
  elements.slimmingLoadMoreMembersButton.addEventListener("click", () => {
    state.slimming.memberLimit = Math.min(
      SLIMMING_MEMBER_LIMIT_MAX,
      state.slimming.memberLimit + 96
    );
    loadSlimmingWorkspace({ quiet: true });
  });
  elements.slimmingRecycleLoadMoreButton.addEventListener("click", () => {
    state.slimming.recycle.limit = Math.min(5000, state.slimming.recycle.limit + 60);
    loadSlimmingRecycle({ quiet: true });
  });
  elements.slimmingRecycleSourceSelect.addEventListener("change", () => {
    state.slimming.recycle.sourceID = elements.slimmingRecycleSourceSelect.value;
    state.slimming.recycle.limit = 60;
    loadSlimmingRecycle();
  });
  elements.slimmingRecycleSearchInput.addEventListener("input", () => {
    state.slimming.recycle.searchText = elements.slimmingRecycleSearchInput.value;
    state.slimming.recycle.limit = 60;
    clearTimeout(state.slimming.recycle.searchTimer);
    state.slimming.recycle.searchTimer = setTimeout(() => loadSlimmingRecycle({ quiet: true }), 240);
  });
  elements.slimmingRecycleList.addEventListener("click", (event) => {
    const info = event.target.closest("[data-slimming-recycle-info='photos']");
    if (info) {
      toast("请在系统“照片”App 的“最近删除”中恢复；恢复后 ImageAll 会自动对账。永久删除也由系统管理。");
      return;
    }
    const button = event.target.closest("[data-slimming-recycle-entry-id][data-action]");
    if (button) submitSlimmingRecycleAction(
      button.dataset.slimmingRecycleEntryId,
      button.dataset.action
    );
  });
  elements.slimmingMediaKindTabs.addEventListener("click", (event) => {
    const button = event.target.closest("[data-slimming-media-kind]");
    if (!button || button.dataset.slimmingMediaKind === state.slimming.mediaKind) return;
    state.slimming.mediaKind = button.dataset.slimmingMediaKind;
    state.slimming.selectedJobID = null;
    state.slimming.selectedClusterID = null;
    state.slimming.selectedMemberIDs.clear();
    state.slimming.selectionAnchorID = null;
    state.slimming.clusterLimit = 48;
    state.slimming.memberLimit = 96;
    state.slimming.recycle.limit = 60;
    state.slimming.removal.requests = [];
    state.slimming.removal.lastTerminalRequestID = null;
    clearTimeout(state.slimming.removal.pollTimer);
    state.slimming.identicalCleanup.requests = [];
    state.slimming.identicalCleanup.lastTerminalRequestID = null;
    state.slimming.identicalCleanup.lastPresentedVerificationID = null;
    clearTimeout(state.slimming.identicalCleanup.pollTimer);
    if (state.slimming.view === "recycle") loadSlimmingRecycle();
    else {
      loadSlimmingWorkspace();
      loadSlimmingRemovals({ quiet: true });
      loadSlimmingIdenticalCleanupRequests({ quiet: true });
    }
  });
  elements.slimmingJobList.addEventListener("click", async (event) => {
    const row = event.target.closest("[data-slimming-job-id]");
    if (!row || row.dataset.slimmingJobId === state.slimming.selectedJobID) return;
    state.slimming.selectedJobID = row.dataset.slimmingJobId;
    state.slimming.selectedClusterID = null;
    state.slimming.clusterLimit = 48;
    state.slimming.memberLimit = 96;
    await loadSlimmingWorkspace({ jobID: row.dataset.slimmingJobId });
    focusSelectedSlimmingJob();
  });
  elements.previousSlimmingJobButton.addEventListener("click", () => navigateSlimmingJob(-1));
  elements.nextSlimmingJobButton.addEventListener("click", () => navigateSlimmingJob(1));
  elements.slimmingJobList.addEventListener("keydown", (event) => {
    const navigation = {
      ArrowUp: -1,
      ArrowLeft: -1,
      ArrowDown: 1,
      ArrowRight: 1,
      Home: "first",
      End: "last",
    }[event.key];
    if (navigation === undefined) return;
    event.preventDefault();
    navigateSlimmingJob(navigation);
  });
  elements.slimmingClusterList.addEventListener("click", (event) => {
    const row = event.target.closest("[data-slimming-cluster-id]");
    if (!row || row.dataset.slimmingClusterId === state.slimming.selectedClusterID) return;
    state.slimming.selectedClusterID = row.dataset.slimmingClusterId;
    state.slimming.memberLimit = 96;
    loadSlimmingWorkspace({ clusterID: row.dataset.slimmingClusterId });
  });
  elements.slimmingMemberGrid.addEventListener("click", (event) => {
    const card = event.target.closest("[data-slimming-member-id]");
    if (card) selectSlimmingMember(card.dataset.slimmingMemberId, event);
  });
  elements.slimmingMemberGrid.addEventListener("dblclick", (event) => {
    const card = event.target.closest("[data-slimming-member-id]");
    if (card) openLightbox("slimming", card.dataset.slimmingMemberId);
  });
  elements.slimmingRemovalStatus.addEventListener("click", (event) => {
    const button = event.target.closest("[data-slimming-verification-request-id]");
    if (!button) return;
    const request = state.slimming.identicalCleanup.requests.find(
      (item) => item.id === button.dataset.slimmingVerificationRequestId
    );
    openSlimmingVerificationReport(request);
  });
  elements.closeSlimmingVerificationButton.addEventListener(
    "click",
    closeSlimmingVerificationReport
  );
  elements.slimmingVerificationDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeSlimmingVerificationReport();
  });
  elements.closeTrainingButton.addEventListener("click", closeTrainingWorkspace);
  elements.newTrainingButton.addEventListener("click", () => openTrainingSetupDialog());
  elements.closeTrainingSetupButton.addEventListener("click", closeTrainingSetupDialog);
  elements.cancelTrainingSetupButton.addEventListener("click", closeTrainingSetupDialog);
  elements.trainingSetupForm.addEventListener("submit", (event) => {
    event.preventDefault();
    submitTrainingSetup();
  });
  elements.trainingSetupDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeTrainingSetupDialog();
  });
  elements.trainingSetupMethods.addEventListener("click", (event) => {
    const button = event.target.closest("[data-training-setup-method]");
    if (!button || button.disabled || button.dataset.trainingSetupMethod === state.training.setup.method) {
      return;
    }
    resetTrainingSetupSelection(button.dataset.trainingSetupMethod);
    renderTrainingSetup();
  });
  elements.trainingTagSearch.addEventListener("input", () => {
    state.training.setup.tagSearchText = elements.trainingTagSearch.value;
    renderTrainingTagOptions();
  });
  elements.trainingTagOptions.addEventListener("change", (event) => {
    const input = event.target.closest("[data-training-tag-id]");
    if (!input) return;
    const tagID = input.dataset.trainingTagId;
    if (state.training.setup.method === "featureKnn") {
      state.training.setup.selectedTagIDs = new Set(input.checked ? [tagID] : []);
    } else if (input.checked) {
      state.training.setup.selectedTagIDs.add(tagID);
    } else {
      state.training.setup.selectedTagIDs.delete(tagID);
    }
    renderTrainingSetup();
  });
  elements.trainingScopeOptions.addEventListener("change", (event) => {
    const source = event.target.closest("[data-training-source-id]");
    if (source) {
      if (source.checked) state.training.setup.selectedSourceIDs.add(source.dataset.trainingSourceId);
      else state.training.setup.selectedSourceIDs.delete(source.dataset.trainingSourceId);
      renderTrainingSetup();
      return;
    }
    const scope = event.target.closest("[data-training-scope]");
    if (scope?.checked) {
      state.training.setup.scope = scope.dataset.trainingScope;
      renderTrainingSetup();
    }
  });
  elements.refreshTrainingButton.addEventListener("click", () => loadTrainingWorkspace());
  elements.toggleTrainingNavigatorButton.addEventListener("click", toggleTrainingNavigator);
  elements.trainingMediaKindTabs.addEventListener("click", (event) => {
    const button = event.target.closest("[data-training-media-kind]");
    if (!button || button.dataset.trainingMediaKind === state.training.mediaKind) return;
    state.training.mediaKind = button.dataset.trainingMediaKind;
    state.training.selectedRunID = null;
    loadTrainingWorkspace();
  });
  elements.trainingSlotStrip.addEventListener("click", (event) => {
    const slot = event.target.closest("[data-training-slot-method]");
    if (slot) void openTrainingSlot(slot.dataset.trainingSlotMethod);
  });
  elements.trainingSlotStrip.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    event.stopPropagation();
    moveTrainingSlotFocus(event.key);
  });
  elements.trainingMethodFilter.addEventListener("change", () => {
    state.training.method = elements.trainingMethodFilter.value;
    state.training.selectedRunID = null;
    loadTrainingWorkspace();
  });
  elements.trainingRecordScopeFilter.addEventListener("change", () => {
    setTrainingRunScope(elements.trainingRecordScopeFilter.value, { focus: true });
  });
  elements.trainingRunList.addEventListener("click", (event) => {
    const row = event.target.closest("[data-training-run-id]");
    if (!row) return;
    selectTrainingRun(row.dataset.trainingRunId, { focus: true });
  });
  elements.trainingRunList.addEventListener("keydown", (event) => {
    if (!["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    moveTrainingRunSelection(event.key);
  });
  elements.trainingActivityStrip.addEventListener("click", (event) => {
    const retry = event.target.closest("[data-training-batch-reconfigure-id]");
    if (retry) {
      openTrainingSetupForActivity(retry.dataset.trainingBatchReconfigureId);
      return;
    }
    const button = event.target.closest("[data-training-activity-id][data-action]");
    if (button) applyTrainingActivityAction(
      button.dataset.trainingActivityId,
      button.dataset.action
    );
  });
  elements.trainingBatchList.addEventListener("click", (event) => {
    const retry = event.target.closest("[data-training-batch-reconfigure-id]");
    if (retry) {
      openTrainingSetupForActivity(retry.dataset.trainingBatchReconfigureId);
      return;
    }
    const view = event.target.closest("[data-training-batch-view-id]");
    if (view) void openTrainingRunForBatch(view.dataset.trainingBatchViewId);
  });
  elements.trainingDetailActions.addEventListener("click", (event) => {
    const reviewButton = event.target.closest("[data-training-review-run-id]");
    if (reviewButton) {
      openReviewFromTrainingRun(reviewButton.dataset.trainingReviewRunId);
      return;
    }
    const jobButton = event.target.closest("[data-training-job-id]");
    if (jobButton) {
      openAssociatedJob(jobButton.dataset.trainingJobId);
      return;
    }
    const actionButton = event.target.closest("[data-training-run-job-id][data-action]");
    if (actionButton) {
      applyJobAction(actionButton.dataset.trainingRunJobId, actionButton.dataset.action);
      return;
    }
    const retryButton = event.target.closest("[data-training-reconfigure-run-id]");
    if (retryButton) openTrainingSetupForRun(retryButton.dataset.trainingReconfigureRunId);
  });
  elements.closeReviewButton.addEventListener("click", closeReviewWorkspace);
  elements.reviewBackButton.addEventListener("click", returnToReviewOverview);
  elements.reviewOverviewGrid.addEventListener("click", (event) => {
    const groupToggle = event.target.closest("[data-review-overview-group-toggle]");
    if (groupToggle) {
      const groupID = groupToggle.dataset.reviewOverviewGroupToggle;
      if (state.layout.collapsedReviewTagGroupIDs.has(groupID)) {
        state.layout.collapsedReviewTagGroupIDs.delete(groupID);
      } else {
        state.layout.collapsedReviewTagGroupIDs.add(groupID);
      }
      persistWorkspacePreferences();
      renderReviewOverview();
      return;
    }
    const jobAction = event.target.closest("[data-job-id][data-action]");
    if (jobAction) {
      applyJobAction(jobAction.dataset.jobId, jobAction.dataset.action);
      return;
    }
    const trainingButton = event.target.closest(
      "[data-review-training-tag-id][data-review-training-job-id]"
    );
    if (trainingButton) {
      openTrainingWorkspaceForReviewTag(
        trainingButton.dataset.reviewTrainingTagId,
        trainingButton.dataset.reviewTrainingJobId
      );
      return;
    }
    const featureButton = event.target.closest(
      "[data-review-feature-tag-id][data-review-feature-mode]"
    );
    if (featureButton && !featureButton.disabled) {
      state.training.mediaKind = state.mediaKind;
      const sourceIDs = elements.reviewCurrentSourceOnly.checked && state.selectedSourceID
        ? [state.selectedSourceID]
        : [];
      openTrainingSetupDialog({
        method: "featureKnn",
        tagIDs: [featureButton.dataset.reviewFeatureTagId],
        sourceIDs,
      });
      return;
    }
    const cancelButton = event.target.closest("[data-cancel-tag-suggestion-id]");
    if (cancelButton) {
      cancelTagLibrarySuggestions(cancelButton.dataset.cancelTagSuggestionId);
      return;
    }
    const suggestionButton = event.target.closest("[data-tag-suggestion-method][data-tag-id]");
    if (suggestionButton && !suggestionButton.disabled) {
      openTagSuggestionDialog(
        suggestionButton.dataset.tagId,
        suggestionButton.dataset.tagSuggestionMethod,
        suggestionButton
      );
      return;
    }
    const card = event.target.closest("[data-review-overview-tag-id]");
    if (card && !card.disabled) enterReviewQueue(card.dataset.reviewOverviewTagId);
  });
  elements.reviewOverviewGrid.addEventListener("keydown", (event) => {
    const groupToggle = event.target.closest("[data-review-overview-group-toggle]");
    if (!groupToggle || !["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
    const toggles = [...elements.reviewOverviewGrid.querySelectorAll(
      "[data-review-overview-group-toggle]"
    )];
    const currentIndex = toggles.indexOf(groupToggle);
    if (currentIndex < 0) return;
    event.preventDefault();
    const nextIndex = event.key === "Home"
      ? 0
      : event.key === "End"
        ? toggles.length - 1
        : Math.max(0, Math.min(
          toggles.length - 1,
          currentIndex + (event.key === "ArrowDown" ? 1 : -1)
        ));
    toggles[nextIndex].focus({ preventScroll: true });
    toggles[nextIndex].scrollIntoView({ block: "nearest" });
  });
  elements.closeTagSuggestionDialogButton.addEventListener("click", closeTagSuggestionDialog);
  elements.cancelTagSuggestionDialogButton.addEventListener("click", closeTagSuggestionDialog);
  elements.tagSuggestionDialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeTagSuggestionDialog();
  });
  elements.tagSuggestionSourceOptions.addEventListener("change", (event) => {
    const input = event.target.closest('input[type="checkbox"]');
    if (!input) return;
    if (input.checked) {
      state.tagLibrarySuggestions.dialog.selectedSourceIDs.add(input.value);
    } else {
      state.tagLibrarySuggestions.dialog.selectedSourceIDs.delete(input.value);
    }
    elements.tagSuggestionError.textContent = "";
    renderTagSuggestionDialog();
  });
  elements.selectAllTagSuggestionSourcesButton.addEventListener("click", () => {
    state.tagLibrarySuggestions.dialog.selectedSourceIDs = new Set(
      activeTagSuggestionSources().map((source) => source.id)
    );
    elements.tagSuggestionError.textContent = "";
    renderTagSuggestionDialog();
  });
  elements.clearTagSuggestionSourcesButton.addEventListener("click", () => {
    state.tagLibrarySuggestions.dialog.selectedSourceIDs.clear();
    elements.tagSuggestionError.textContent = "";
    renderTagSuggestionDialog();
  });
  elements.tagSuggestionForm.addEventListener("submit", (event) => {
    event.preventDefault();
    generateTagLibrarySuggestions();
  });
  elements.reviewTagSelect.addEventListener("change", () => {
    loadReviewQueue();
  });
  elements.reviewCurrentSourceOnly.addEventListener("change", async () => {
    await loadReviewOverview();
    if (state.review.mode === "queue") await loadReviewQueue();
  });
  elements.refreshReviewButton.addEventListener("click", async () => {
    await loadReviewOverview();
    if (state.review.mode === "queue") {
      await loadReviewQueue({ preserveLoadedWindow: true });
    }
  });
  elements.generateLibrarySuggestionsButton.addEventListener("click", () => {
    generateSampleSuggestions();
  });
  elements.cancelSampleSuggestionsButton.addEventListener("click", cancelSampleSuggestions);
  elements.loadMoreReviewButton.addEventListener("click", () => loadReviewQueue({ append: true }));
  elements.reviewGrid.addEventListener("click", (event) => {
    const card = event.target.closest("[data-review-index]");
    if (card) {
      selectReviewIndex(Number(card.dataset.reviewIndex), {
        additive: event.metaKey || event.ctrlKey,
        extendRange: event.shiftKey,
      });
    }
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
    if (item && state.review.selectedAssetIDs.size > 1) {
      selectReviewIndex(state.review.selectedIndex);
    }
    openLightbox("review", item?.assetID);
  });
  elements.reviewPreviewImage.addEventListener("dblclick", () => {
    const item = state.review.items[state.review.selectedIndex];
    if (item && state.review.selectedAssetIDs.size > 1) {
      selectReviewIndex(state.review.selectedIndex);
    }
    openLightbox("review", item?.assetID);
  });

  elements.lightboxBackButton.addEventListener("click", closeLightbox);
  elements.closeLightboxButton.addEventListener("click", closeLightbox);
  elements.lightboxPreviousButton.addEventListener("click", () => void navigateLightbox(-1));
  elements.lightboxNextButton.addEventListener("click", () => void navigateLightbox(1));
  elements.lightboxReviewActions.addEventListener("click", (event) => {
    const button = event.target.closest("[data-action]");
    if (button && !button.disabled) void applyLightboxReviewDecision(button.dataset.action);
  });
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
  elements.sourceContextMenu.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-source-context-action]");
    const sourceID = state.contextSourceID;
    if (!button || !sourceID) return;
    const action = button.dataset.sourceContextAction;
    const returnTarget = elements.sourceList.querySelector(
      `[data-source-id="${CSS.escape(sourceID)}"]`
    );
    hideContextMenus();
    if (action === "view") {
      await selectSource(sourceID);
      restoreOverlayFocus(elements.sourceList.querySelector(
        `[data-source-id="${CSS.escape(sourceID)}"]`
      ));
      return;
    }
    returnTarget?.focus({ preventScroll: true });
    await openSourceManager();
    if (action !== "manage") await submitSourceManagementAction(action, sourceID);
  });
  elements.sourceContextMenu.addEventListener("keydown", (event) => {
    const buttons = [...elements.sourceContextMenu.querySelectorAll("button:not(:disabled)")];
    if (!buttons.length) return;
    if (event.key === "Escape") {
      event.preventDefault();
      const sourceID = state.contextSourceID;
      hideContextMenus();
      restoreOverlayFocus(elements.sourceList.querySelector(
        `[data-source-id="${CSS.escape(sourceID || "")}"]`
      ));
      return;
    }
    if (!["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const current = Math.max(0, buttons.indexOf(document.activeElement));
    const next = event.key === "Home" ? 0
      : event.key === "End" ? buttons.length - 1
        : (current + (event.key === "ArrowUp" ? -1 : 1) + buttons.length) % buttons.length;
    buttons[next].focus({ preventScroll: true });
  });
  elements.tagContextMenu.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-tag-context-action]");
    if (!button) return;
    const action = button.dataset.tagContextAction;
    const tagID = state.contextTagID;
    const groupID = state.contextTagGroupID;
    const tag = tagByID(tagID);
    const group = groupByID(groupID);
    hideContextMenus();
    if (action === "filterOnly" && tagID) {
      await filterToSingleSidebarTag(tagID);
    } else if (action === "toggleExcluded" && tagID) {
      await toggleSidebarTagFilter(tagID, { excluded: true });
    } else if (action === "renameTag" && tagID) {
      openTagManagerForTag(tagID);
    } else if (action === "archiveTag" && tag) {
      confirmArchiveManagedTag(tag, { tagID, groupID: tag.groupID });
    } else if (action === "renameGroup" && groupID) {
      openTagManagerForGroup(groupID);
    } else if (action === "deleteGroup" && group) {
      confirmDeleteManagedTagGroup(group, { groupID });
    }
  });
  elements.tagContextMenu.addEventListener("keydown", (event) => {
    const buttons = [...elements.tagContextMenu.querySelectorAll("button:not(:disabled)")];
    if (!buttons.length) return;
    if (event.key === "Escape") {
      event.preventDefault();
      const tagID = state.contextTagID;
      const groupID = state.contextTagGroupID;
      hideContextMenus();
      if (tagID) focusSidebarTag(tagID);
      else if (groupID) {
        requestAnimationFrame(() => {
          elements.tagNavigation.querySelector(
            `[data-sidebar-tag-group-toggle="${CSS.escape(groupID)}"]`
          )?.focus({ preventScroll: true });
        });
      }
      return;
    }
    if (!["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const current = Math.max(0, buttons.indexOf(document.activeElement));
    const next = event.key === "Home" ? 0
      : event.key === "End" ? buttons.length - 1
        : (current + (event.key === "ArrowUp" ? -1 : 1) + buttons.length) % buttons.length;
    buttons[next].focus({ preventScroll: true });
  });

  document.addEventListener("click", (event) => {
    if (!elements.assetContextMenu.contains(event.target)
      && !elements.sourceContextMenu.contains(event.target)
      && !elements.tagContextMenu.contains(event.target)) hideContextMenus();
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
      closeJobsPopover({ restoreFocus: false });
    }
    if (!elements.personalModelPopover.classList.contains("hidden")
      && !elements.personalModelPopover.contains(event.target)
      && !elements.personalModelButton.contains(event.target)) {
      closePersonalModelPopover({ restoreFocus: false });
    }
  });
  document.addEventListener("keydown", (event) => {
    if (event.defaultPrevented) return;
    if (elements.appView.classList.contains("hidden")) return;
    const blockingDialogOpen = elements.shortcutDialog.open
      || elements.newTagDialog.open
      || elements.tagManagerDialog.open
      || elements.confirmDialog.open
      || elements.generalSettingsDialog.open
      || elements.suggestionThresholdDialog.open
      || elements.sourceManagerDialog.open
      || elements.storageDialog.open
      || elements.tagSuggestionDialog.open
      || elements.trainingSetupDialog.open
      || elements.slimmingSetupDialog.open
      || elements.worldMapPlaceTagDialog.open
      || elements.worldMapLocationBackfillDialog.open;
    const lightboxOpen = !elements.lightbox.classList.contains("hidden");
    const reviewOpen = !elements.reviewWorkspace.classList.contains("hidden");
    const trainingOpen = !elements.trainingWorkspace.classList.contains("hidden");
    const slimmingOpen = !elements.slimmingWorkspace.classList.contains("hidden");
    const worldMapOpen = !elements.worldMapWorkspace.classList.contains("hidden");
    const galleryOverviewOpen = !elements.galleryOverviewWorkspace.classList.contains("hidden");
    const jobsOpen = !elements.jobsPopover.classList.contains("hidden");
    const inspectorOverlayOpen = globalThis.matchMedia("(max-width: 980px)").matches
      && elements.inspector.classList.contains("open");
    const customOverlayOpen = lightboxOpen || reviewOpen || trainingOpen || slimmingOpen || worldMapOpen
      || galleryOverviewOpen
      || jobsOpen
      || inspectorOverlayOpen;
    if ((event.metaKey || event.ctrlKey) && event.key === ",") {
      event.preventDefault();
      if (elements.generalSettingsDialog.open) return;
      if (blockingDialogOpen || customOverlayOpen || elements.commandPalette.open) return;
      openGeneralSettings();
      return;
    }
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
      event.preventDefault();
      if (!elements.personalModelPopover.classList.contains("hidden")) {
        closePersonalModelPopover();
        return;
      }
      if (elements.suggestionThresholdDialog.open) {
        closeSuggestionThresholdDialog();
        return;
      }
      if (elements.generalSettingsDialog.open) {
        closeGeneralSettings();
        return;
      }
      if (elements.tagSuggestionDialog.open) {
        closeTagSuggestionDialog();
        return;
      }
      if (elements.storageDialog.open) {
        closeStorageMaintenance();
        return;
      }
      if (elements.sourceManagerDialog.open) {
        closeSourceManager();
        return;
      }
      if (elements.slimmingSetupDialog.open) {
        closeSlimmingSetupDialog();
        return;
      }
      if (elements.trainingSetupDialog.open) {
        closeTrainingSetupDialog();
        return;
      }
      if (elements.worldMapLocationBackfillDialog.open) {
        closeWorldMapLocationBackfill();
        return;
      }
      if (elements.worldMapPlaceTagDialog.open) {
        closeWorldMapPlaceTags();
        return;
      }
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
      if (elements.confirmDialog.open) {
        closeConfirmation();
        return;
      }
      if (elements.tagManagerDialog.open) {
        elements.tagManagerDialog.close();
        return;
      }
      if (jobsOpen) {
        closeJobsPopover();
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
      if (trainingOpen) {
        closeTrainingWorkspace();
        return;
      }
      if (slimmingOpen) {
        closeSlimmingWorkspace();
        return;
      }
      if (worldMapOpen) {
        closeWorldMapWorkspace();
        return;
      }
      if (galleryOverviewOpen) {
        closeGalleryOverviewWorkspace();
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
      closeJobsPopover({ restoreFocus: false });
      elements.sourceSidebar.classList.remove("open");
      return;
    }
    if (elements.commandPalette.open
      || elements.shortcutDialog.open
      || elements.newTagDialog.open
      || elements.tagManagerDialog.open
      || elements.confirmDialog.open
      || elements.generalSettingsDialog.open
      || elements.suggestionThresholdDialog.open
      || elements.sourceManagerDialog.open
      || elements.storageDialog.open
      || elements.tagSuggestionDialog.open
      || elements.trainingSetupDialog.open
      || elements.slimmingSetupDialog.open
      || elements.worldMapPlaceTagDialog.open
      || elements.worldMapLocationBackfillDialog.open) return;
    if (jobsOpen) {
      if (trapOverlayFocus(event, elements.jobsPopover)) return;
      return;
    }
    if (lightboxOpen) {
      if (trapOverlayFocus(event, elements.lightbox)) return;
    } else if (reviewOpen) {
      if (trapOverlayFocus(event, elements.reviewWorkspace)) return;
    } else if (trainingOpen) {
      if (trapOverlayFocus(event, elements.trainingWorkspace)) return;
    } else if (slimmingOpen) {
      if (trapOverlayFocus(event, elements.slimmingWorkspace)) return;
    } else if (worldMapOpen) {
      if (trapOverlayFocus(event, elements.worldMapWorkspace)) return;
    } else if (galleryOverviewOpen) {
      if (trapOverlayFocus(event, elements.galleryOverviewWorkspace)) return;
    } else if (inspectorOverlayOpen && trapOverlayFocus(event, elements.inspector)) {
      return;
    }
    if (isTextInputTarget(event.target)) return;
    if (lightboxOpen) {
      if (event.key === "ArrowLeft") {
        event.preventDefault();
        void navigateLightbox(-1);
      }
      if (event.key === "ArrowRight") {
        event.preventDefault();
        void navigateLightbox(1);
      }
      if (event.code === "Space") {
        event.preventDefault();
        closeLightbox();
      }
      if (state.lightboxContext === "review"
        && !event.repeat
        && !event.metaKey
        && !event.ctrlKey
        && !event.altKey) {
        const action = {
          p: "accept",
          x: "reject",
          u: "defer",
        }[event.key.toLowerCase()];
        if (action) {
          event.preventDefault();
          void applyLightboxReviewDecision(action);
        }
      }
      return;
    }
    if (worldMapOpen || galleryOverviewOpen) return;
    if (reviewOpen) {
      if (!event.repeat && !event.metaKey && !event.ctrlKey && !event.altKey
        && event.key.toLowerCase() === "j") {
        event.preventDefault();
        openJobsPopover();
        return;
      }
      if (state.review.mode !== "queue") return;
      if (event.target.closest("input, select, textarea, [contenteditable='true']")) return;
      if ((event.metaKey || event.ctrlKey) && !event.altKey
        && event.key.toLowerCase() === "a") {
        event.preventDefault();
        selectAllReviewItems();
        return;
      }
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
    if (trainingOpen) {
      if (event.metaKey || event.ctrlKey || event.altKey || event.repeat) return;
      if (event.target.closest("input, select, textarea, [contenteditable='true']")) return;
      const key = event.key.toLowerCase();
      if (key === "n") {
        event.preventDefault();
        openTrainingSetupDialog();
        return;
      }
      if (key === "r") {
        event.preventDefault();
        loadTrainingWorkspace();
        return;
      }
      if (key === "l") {
        event.preventDefault();
        toggleTrainingNavigator();
        return;
      }
      if (key === "b") {
        event.preventDefault();
        cycleTrainingRunScope();
        return;
      }
      if (key === "m") {
        event.preventDefault();
        focusTrainingSlot();
        return;
      }
      const selectedRun = state.training.runs.find(
        (run) => run.id === state.training.selectedRunID
      );
      if (key === "j") {
        event.preventDefault();
        if (selectedRun?.jobID) void openAssociatedJob(selectedRun.jobID);
        else openJobsPopover();
        return;
      }
      if (key === "v" && selectedRun?.tagID) {
        event.preventDefault();
        openReviewFromTrainingRun(selectedRun.id);
        return;
      }
      if (key === "e" && selectedRun && ["failed", "cancelled"].includes(selectedRun.state)) {
        event.preventDefault();
        openTrainingSetupForRun(selectedRun.id);
      }
      return;
    }
    if (slimmingOpen) {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") {
        event.preventDefault();
        state.slimming.selectedMemberIDs = new Set(
          state.slimming.members.map((member) => member.id)
        );
        state.slimming.selectionAnchorID = state.slimming.members[0]?.id || null;
        renderSlimmingMemberSelection();
        return;
      }
      if (event.code === "Space" && state.slimming.selectedMemberIDs.size === 1) {
        event.preventDefault();
        openLightbox("slimming", [...state.slimming.selectedMemberIDs][0]);
      }
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") {
      event.preventDefault();
      selectAllLoadedAssets();
      return;
    }
    if (!event.repeat && !event.metaKey && !event.ctrlKey && !event.altKey
      && event.key.toLowerCase() === "j") {
      event.preventDefault();
      openJobsPopover();
      return;
    }
    if (isInteractiveControlTarget(event.target)) return;
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
  ensureMediaWorker();
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
    if (state.authMode !== "account") await updateMediaWorkerAuthorization(null);
    await loadWorkspace();
  } catch (error) {
    const message = error.status && error.status !== 401
      ? "暂时无法连接 Mac Host，请稍后重试。"
      : "";
    showPairing(message);
  }
}

boot();
