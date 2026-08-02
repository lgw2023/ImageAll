import Foundation

struct CompositionRoot {
    @MainActor
    func makeStartupModel(
        modelActivationCoordinator: AppModelActivationCoordinator? = nil,
        dependencies: CatalogBootstrapDependencies = Self.makeProductionDependencies()
    ) -> CatalogStartupModel {
        CatalogStartupModel(
            dependencies: dependencies,
            workspaceFactory: { token in
                Self.makeWorkspaceModel(
                    runtime: token.runtime,
                    modelActivationCoordinator: modelActivationCoordinator
                )
            }
        )
    }

    static func makeProductionDependencies(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CatalogBootstrapDependencies {
        let pathsResolver: any AppPathsResolving
#if DEBUG
        if let developmentRoot = environment["IMAGEALL_DEVELOPMENT_ROOT"] {
            let trimmedRoot = developmentRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRoot.isEmpty,
               NSString(string: trimmedRoot).isAbsolutePath,
               URL(fileURLWithPath: trimmedRoot, isDirectory: true).standardizedFileURL.path != "/"
            {
                pathsResolver = TemporaryAppPathsResolver(
                    rootURL: URL(fileURLWithPath: trimmedRoot, isDirectory: true)
                )
            } else {
                pathsResolver = RejectedDevelopmentAppPathsResolver()
            }
        } else {
            pathsResolver = FoundationAppPathsResolver()
        }
#else
        pathsResolver = FoundationAppPathsResolver()
#endif
        return CatalogBootstrapDependencies(
            pathsResolver: pathsResolver,
            appVersionProvider: { BundleAppVersionProvider().currentVersion() }
        )
    }

    @MainActor
    private static func makeWorkspaceModel(
        runtime: CatalogRuntime,
        modelActivationCoordinator: AppModelActivationCoordinator?
    ) -> LibraryWorkspaceModel {
        let clock = SystemJobClock()
        let sourceRepository = GRDBFolderSourceAuthorizationRepository(database: runtime.database)
        let bookmark = FoundationSecurityScopedBookmarkAdapter()
        let rootValidator = FolderRootValidator()
        let authorization = FolderAuthorizationCoordinator(
            dependencies: FolderAuthorizationDependencies(
                repository: sourceRepository,
                picker: AppKitFolderDirectoryPicker(
                    panelFactory: {
                        AppKitFolderDirectoryPicker.makeSourceImportPanel()
                    }
                ),
                bookmarkPort: bookmark,
                rootValidator: rootValidator,
                relationshipChecker: FoundationFolderRootRelationshipChecker(),
                clock: clock,
                idGenerator: { UUID() }
            )
        )
        let sourceAccess = FolderReconcileSourceAccessService(
            repository: sourceRepository,
            bookmarkPort: bookmark,
            rootValidator: rootValidator,
            clock: clock
        )
        let quarantineRootURL = QuarantinePathLayout.rootURL(
            applicationSupportDirectory: runtime.paths.applicationSupportDirectory
        )
        let photosOriginalCache = PhotosOriginalCacheService(
            database: runtime.database,
            rootURL: runtime.paths.applicationSupportDirectory
                .appendingPathComponent("Photos Originals/v1", isDirectory: true),
            clock: clock
        )
        let photosAccess = PhotoKitPhotosLibraryAdapter()
        let photosMutation = PhotoKitPhotosLibraryMutationAdapter()
        let interactiveIOGate = InteractiveIOPriorityGate()
        let appOwnedAssetPixelCachePurger = AppOwnedAssetPixelCachePurger(
            database: runtime.database,
            derivedCachesDirectory: runtime.paths.cachesDirectory,
            photosOriginalCache: photosOriginalCache
        )
        let librarySlimmingRecycle = LibrarySlimmingRecycleService(
            database: runtime.database,
            mutationAccess: FolderMutationAccessService(
                database: runtime.database,
                bookmarkPort: bookmark
            ),
            quarantineRootURL: quarantineRootURL,
            clock: clock,
            jobQueue: runtime.jobQueue,
            photosMutation: photosMutation,
            pixelCachePurger: appOwnedAssetPixelCachePurger,
            interactiveIOGate: interactiveIOGate
        )
        let librarySlimmingMutationAuthorization = FolderMutationAuthorizationCoordinator(
            database: runtime.database,
            picker: AppKitFolderDirectoryPicker(
                panelFactory: {
                    AppKitFolderDirectoryPicker.makeMutationAuthorizationPanel()
                }
            ),
            bookmarkPort: bookmark,
            rootValidator: rootValidator,
            relationshipChecker: FoundationFolderRootRelationshipChecker(),
            clock: clock
        )
        let folderSourceMonitor = FolderSourceMonitoringCoordinator(
            repository: sourceRepository,
            bookmarkPort: bookmark,
            rootValidator: rootValidator,
            dirtyTrigger: FolderSourceDirtyTrigger(
                database: runtime.database,
                clock: clock
            ),
            streamFactory: FoundationFolderFileSystemEventStreamFactory(),
            clock: clock
        )
        let handler = FolderReconcileHandler(
            rootAccess: sourceAccess,
            interactiveIOGate: interactiveIOGate
        )
        let photosConnection = PhotosLibraryConnectionService(
            database: runtime.database,
            access: photosAccess,
            clock: clock
        )
        let photosObserver = PhotosLibraryChangeObserverCoordinator(
            observer: photosAccess,
            availabilityObserver: photosAccess,
            database: runtime.database,
            clock: clock
        )
        let photosHandler = PhotosReconcileHandler(
            database: runtime.database,
            queue: runtime.jobQueue,
            access: photosAccess,
            changeHistory: photosAccess,
            clock: clock
        )
        let derivedImages = DerivedImageCacheService(
            database: runtime.database,
            cachesDirectory: runtime.paths.cachesDirectory,
            sourceAccess: sourceAccess,
            clock: clock
        )
        let featureInputImages = PrioritizedDownloadedPreviewCache(
            primary: photosOriginalCache,
            fallback: derivedImages
        )
        let appStorageLocationController = AppStorageLocationController(
            picker: AppKitFolderDirectoryPicker(),
            store: UserDefaultsAppStorageLocationStore(
                bookmarks: FoundationAppStorageBookmarkAdapter()
            ),
            activeStatus: runtime.paths.storageLocationStatus
        )
        let featurePrintService = FeaturePrintCacheService(
            database: runtime.database,
            cachesDirectory: runtime.paths.cachesDirectory,
            sourceAccess: sourceAccess,
            photosImages: photosAccess,
            downloadedPreviews: featureInputImages,
            clock: clock
        )
        let suggestionThresholds = GRDBSuggestionThresholdRepository(database: runtime.database)
        let pendingSuggestionCountPreferences = UserDefaultsPendingSuggestionCountPreferenceStore()
        let personalizationHandler = FullLibrarySuggestionsHandler(
            dependencies: FullLibrarySuggestionsHandlerDependencies(
                database: runtime.database,
                queue: runtime.jobQueue,
                featureLoader: featurePrintService,
                clock: clock,
                minimumScoreForTag: { tagID in
                    try suggestionThresholds.effectiveMinScore(tagID: tagID, method: .featureKnn)
                },
                maxPendingSuggestionsPerTag: {
                    pendingSuggestionCountPreferences.maxPendingSuggestionsPerTag
                }
            )
        )
        let assetImages = LibraryAssetImageLoader(
            database: runtime.database,
            fileImages: derivedImages,
            photosImages: photosAccess,
            cloudPreviews: photosAccess,
            downloadedPreviews: derivedImages,
            photoThumbnails: derivedImages,
            limits: .default
        )
        let localModelSuggestions: LocalModelSuggestionRuntime?
        localModelSuggestions = makeLocalModelSuggestionRuntime()
        var jobHandlers: [any JobHandler] = [
            handler,
            photosHandler,
            personalizationHandler,
            LibrarySlimmingPurgeExpiredHandler(
                recycle: librarySlimmingRecycle,
                clock: clock
            ),
        ]
        if let localModelSuggestions {
            jobHandlers.append(
                PersonalModelRebuildJobHandler(
                    dependencies: PersonalModelRebuildJobHandlerDependencies(
                        database: runtime.database,
                        client: localModelSuggestions.client,
                        catalogScopeID: localModelSuggestions.catalogScopeID,
                        clock: clock
                    )
                )
            )
            jobHandlers.append(
                PersonalLibrarySuggestionsHandler(
                    dependencies: PersonalLibrarySuggestionsHandlerDependencies(
                        database: runtime.database,
                        queue: runtime.jobQueue,
                        images: assetImages,
                        client: localModelSuggestions.client,
                        catalogScopeID: localModelSuggestions.catalogScopeID,
                        clock: clock
                    )
                )
            )
            jobHandlers.append(
                StandardLibrarySuggestionsHandler(
                    dependencies: StandardLibrarySuggestionsHandlerDependencies(
                        database: runtime.database,
                        queue: runtime.jobQueue,
                        images: assetImages,
                        client: localModelSuggestions.client,
                        clock: clock
                    )
                )
            )
        }
        let executionCoordinator = JobExecutionCoordinator(
            queue: runtime.jobQueue,
            registry: MultiJobHandlerRegistry(handlers: jobHandlers),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: runtime.jobQueue)
        )
        let personalizationReview = PersonalizationReviewService(
            database: runtime.database,
            queue: runtime.jobQueue,
            executionCoordinator: executionCoordinator,
            tags: GRDBTagCatalogRepository(database: runtime.database),
            clock: clock,
            personalLibrarySuggestionsEnabled: localModelSuggestions != nil,
            standardLibrarySuggestionsEnabled: localModelSuggestions != nil,
            personalModelRebuildEnabled: localModelSuggestions != nil
        )
        let catalogScopeID = try? runtime.database.catalogScopeID()
        let appPersonalModelRebuilder: AppPersonalModelRebuildRuntime?
        let appPersonalAdamWModelRebuilder: AppPersonalModelRebuildRuntime?
        let appPersonalSampleSuggester: AppPersonalSampleSuggestionRuntime?
        let appPersonalTagLibrarySuggester: AppPersonalTagLibrarySuggestionRuntime?
        let appPersonalAdamWTagLibrarySuggester: AppPersonalTagLibrarySuggestionRuntime?
        if let modelActivationCoordinator, let catalogScopeID {
            appPersonalModelRebuilder = AppPersonalModelRebuildRuntime(
                expectedCatalogScopeID: catalogScopeID,
                activationCoordinator: modelActivationCoordinator,
                cachesDirectory: runtime.paths.cachesDirectory,
                applicationSupportDirectory: runtime.paths.applicationSupportDirectory,
                family: .centroid,
                database: runtime.database,
                clock: clock
            )
            appPersonalAdamWModelRebuilder = AppPersonalModelRebuildRuntime(
                expectedCatalogScopeID: catalogScopeID,
                activationCoordinator: modelActivationCoordinator,
                cachesDirectory: runtime.paths.cachesDirectory,
                applicationSupportDirectory: runtime.paths.applicationSupportDirectory,
                family: .adamW,
                database: runtime.database,
                clock: clock
            )
            appPersonalSampleSuggester = AppPersonalSampleSuggestionRuntime(
                expectedCatalogScopeID: catalogScopeID,
                activationCoordinator: modelActivationCoordinator,
                applicationSupportDirectory: runtime.paths.applicationSupportDirectory,
                database: runtime.database
            )
            appPersonalTagLibrarySuggester = AppPersonalTagLibrarySuggestionRuntime(
                expectedCatalogScopeID: catalogScopeID,
                activationCoordinator: modelActivationCoordinator,
                applicationSupportDirectory: runtime.paths.applicationSupportDirectory,
                family: .centroid,
                database: runtime.database
            )
            appPersonalAdamWTagLibrarySuggester = AppPersonalTagLibrarySuggestionRuntime(
                expectedCatalogScopeID: catalogScopeID,
                activationCoordinator: modelActivationCoordinator,
                applicationSupportDirectory: runtime.paths.applicationSupportDirectory,
                family: .adamW,
                database: runtime.database
            )
        } else {
            appPersonalModelRebuilder = nil
            appPersonalAdamWModelRebuilder = nil
            appPersonalSampleSuggester = nil
            appPersonalTagLibrarySuggester = nil
            appPersonalAdamWTagLibrarySuggester = nil
        }
        let selectedAssetEmbeddingCache: AppSelectedAssetEmbeddingCacheRuntime?
        if let modelActivationCoordinator,
           let catalogScopeID,
           let catalogScopeUUID = UUID(uuidString: catalogScopeID)
        {
            selectedAssetEmbeddingCache = AppSelectedAssetEmbeddingCacheRuntime(
                catalogScopeID: catalogScopeUUID,
                activationCoordinator: modelActivationCoordinator,
                cachesDirectory: runtime.paths.cachesDirectory
            )
        } else {
            selectedAssetEmbeddingCache = nil
        }
        let service = ProductionLibraryWorkspaceService(
            sourceRepository: sourceRepository,
            folderSourceMonitor: folderSourceMonitor,
            photosSourceMonitor: photosObserver,
            authorization: authorization,
            photosConnection: photosConnection,
            queue: runtime.jobQueue,
            executionCoordinator: executionCoordinator,
            query: GRDBAssetCatalogQueryRepository(database: runtime.database),
            tags: GRDBTagCatalogRepository(database: runtime.database),
            assetImages: assetImages,
            personalizationReview: personalizationReview,
            derivedImageCache: derivedImages,
            photosOriginalCache: photosOriginalCache,
            sourceDeletion: LibrarySourceDeletionService(
                database: runtime.database,
                cachePurger: appOwnedAssetPixelCachePurger
            ),
            appStorageLocationController: appStorageLocationController,
            portableExportDestinationPicker: AppKitPortableExportDestinationPicker(),
            portableExportSourceIsolation: PortableExportSourceIsolationValidator(
                sourceRepository: sourceRepository,
                bookmarkPort: bookmark,
                relationshipChecker: FoundationFolderRootRelationshipChecker()
            ),
            portableExporter: PortableCatalogExporter(database: runtime.database),
            appVersion: BundleAppVersionProvider().currentVersion(),
            clock: clock
        )
        RemoteHostProcessHolder.attach(
            catalog: service,
            review: personalizationReview,
            hostAppVersion: BundleAppVersionProvider().currentVersion()
        )
        let fingerprintCompletion = FingerprintCompletionService(
            database: runtime.database,
            sourceAccess: sourceAccess,
            photosOriginals: photosAccess,
            photosOriginalCache: photosOriginalCache,
            photosFeatureImages: photosAccess,
            downloadedPreviews: featureInputImages,
            clock: clock
        )
        let featurePrintInputLoader = LibraryFeaturePrintInputLoader(
            database: runtime.database,
            sourceAccess: sourceAccess,
            photosImages: photosAccess,
            downloadedPreviews: featureInputImages
        )
        let slimmingEmbeddingService = makeAppCoreMLEmbeddingService(isEnabled: true)
        let slimmingEmbeddingLoader: CatalogSlimmingEmbeddingLoader?
        if let catalogScopeID,
           let catalogScopeUUID = UUID(uuidString: catalogScopeID)
        {
            slimmingEmbeddingLoader = CatalogSlimmingEmbeddingLoader(
                catalogScopeID: catalogScopeUUID,
                cachesDirectory: runtime.paths.cachesDirectory,
                inputLoader: featurePrintInputLoader,
                serviceProvider: { slimmingEmbeddingService }
            )
        } else {
            slimmingEmbeddingLoader = nil
        }
        let slimmingThresholdStore = UserDefaultsNearDuplicateSceneThresholdStore()
        let slimmingFeatureLoader = BudgetedFeaturePrintSlimmingLoader(service: featurePrintService)
        let optionalSlimmingEmbeddingLoader = OptionalSlimmingEmbeddingLoader(
            base: slimmingEmbeddingLoader
        )
        let sourceSimilarityIndex = SourceSimilarityIndexService(
            database: runtime.database,
            queue: runtime.jobQueue,
            featureLoader: slimmingFeatureLoader,
            thresholdReader: slimmingThresholdStore,
            clock: clock
        )
        let librarySlimming = LibrarySlimmingScanService(
            database: runtime.database,
            identicalScan: IdenticalDuplicateClusterService(database: runtime.database),
            fingerprintCompletion: fingerprintCompletion,
            featureLoader: slimmingFeatureLoader,
            embeddingLoader: optionalSlimmingEmbeddingLoader,
            thresholdReader: slimmingThresholdStore,
            sourceIndex: sourceSimilarityIndex
        )
        let librarySlimmingAnalysis = LibrarySlimmingAnalysisService(
            database: runtime.database,
            queue: runtime.jobQueue,
            fingerprintCompletion: fingerprintCompletion,
            featureLoader: slimmingFeatureLoader,
            embeddingLoader: optionalSlimmingEmbeddingLoader,
            scanner: librarySlimming,
            clock: clock
        )
        return LibraryWorkspaceModel(
            service: service,
            review: personalizationReview,
            trainingWorkspace: GRDBTrainingWorkspaceRepository(
                database: runtime.database
            ),
            librarySlimming: librarySlimming,
            librarySlimmingAnalysis: librarySlimmingAnalysis,
            librarySlimmingSourceIndex: sourceSimilarityIndex,
            librarySlimmingRecycle: librarySlimmingRecycle,
            librarySlimmingMutationAuthorization: librarySlimmingMutationAuthorization,
            photosLibraryMutation: photosMutation,
            librarySlimmingThresholds: slimmingThresholdStore,
            localModelSuggestions: localModelSuggestions,
            appPersonalModelRebuilder: appPersonalModelRebuilder,
            appPersonalAdamWModelRebuilder: appPersonalAdamWModelRebuilder,
            selectedAssetEmbeddingCache: selectedAssetEmbeddingCache,
            idleFeaturePrintCache: featurePrintService,
            appPersonalSampleSuggester: appPersonalSampleSuggester,
            appPersonalTagLibrarySuggester: appPersonalTagLibrarySuggester,
            appPersonalAdamWTagLibrarySuggester: appPersonalAdamWTagLibrarySuggester,
            suggestionThresholds: suggestionThresholds,
            pendingSuggestionCountPreferences: pendingSuggestionCountPreferences,
            originalAssetOpener: AppKitLibraryOriginalAssetOpener(
                database: runtime.database,
                folderAuthorization: authorization,
                photosLibrary: photosAccess
            ),
            videoPlaybackProvider: AppKitLibraryVideoPlaybackProvider(
                database: runtime.database,
                folderAuthorization: authorization,
                photosLibrary: photosAccess
            ),
            clock: clock
        )
    }

    static func makeAppCoreMLEmbeddingService(
        isEnabled: Bool,
        bundle: Bundle = .main
    ) -> AppCoreMLEmbeddingService {
        let artifactDirectory = bundle.resourceURL?
            .appendingPathComponent("DINOv2Small", isDirectory: true)
            ?? URL(fileURLWithPath: "/__ImageAllMissingBundleResource__")
        return AppCoreMLEmbeddingService(
            isEnabled: isEnabled,
            artifactDirectory: artifactDirectory
        )
    }

    static func makeAppCoreMLEmbeddingCache(
        isEnabled: Bool,
        cachesDirectory: URL,
        bundle: Bundle = .main
    ) -> AppCoreMLEmbeddingCache {
        AppCoreMLEmbeddingCache(
            cachesDirectory: cachesDirectory,
            service: makeAppCoreMLEmbeddingService(
                isEnabled: isEnabled,
                bundle: bundle
            )
        )
    }

    @MainActor
    static func makeAppModelSettingsModel(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> AppModelSettingsModel {
        AppModelSettingsModel(
            coordinator: makeAppModelActivationCoordinator(
                defaults: defaults,
                bundle: bundle
            )
        )
    }

    static func makeAppModelActivationCoordinator(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> AppModelActivationCoordinator {
        let preferenceStore = UserDefaultsModelEnablementPreferenceStore(
            defaults: defaults
        )
        return AppModelActivationCoordinator(
            preferenceStore: preferenceStore,
            serviceFactory: {
                makeAppCoreMLEmbeddingService(
                    isEnabled: true,
                    bundle: bundle
                )
            }
        )
    }

    @MainActor
    static func makeAppModelSettingsModel(
        coordinator: AppModelActivationCoordinator
    ) -> AppModelSettingsModel {
        AppModelSettingsModel(coordinator: coordinator)
    }

    static func makeLocalModelSuggestionRuntime() -> LocalModelSuggestionRuntime? {
        nil
    }
}

#if DEBUG
private struct RejectedDevelopmentAppPathsResolver: AppPathsResolving {
    func resolve() throws -> AppPaths {
        throw AppPathsError.resolutionFailed
    }

    func ensureRequiredDirectories(for _: AppPaths) throws {
        throw AppPathsError.resolutionFailed
    }
}
#endif
