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

    static func makeProductionDependencies() -> CatalogBootstrapDependencies {
        CatalogBootstrapDependencies(
            pathsResolver: FoundationAppPathsResolver(),
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
                picker: AppKitFolderDirectoryPicker(),
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
        let handler = FolderReconcileHandler(rootAccess: sourceAccess)
        let photosAccess = PhotoKitPhotosLibraryAdapter()
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
        let featurePrintService = FeaturePrintCacheService(
            database: runtime.database,
            cachesDirectory: runtime.paths.cachesDirectory,
            sourceAccess: sourceAccess,
            photosImages: photosAccess,
            downloadedPreviews: derivedImages,
            clock: clock
        )
        let personalizationHandler = FullLibrarySuggestionsHandler(
            dependencies: FullLibrarySuggestionsHandlerDependencies(
                database: runtime.database,
                queue: runtime.jobQueue,
                featureLoader: featurePrintService,
                clock: clock
            )
        )
        let assetImages = LibraryAssetImageLoader(
            database: runtime.database,
            fileImages: derivedImages,
            photosImages: photosAccess,
            cloudPreviews: photosAccess,
            downloadedPreviews: derivedImages,
            photoThumbnails: derivedImages
        )
        let localModelSuggestions: LocalModelSuggestionRuntime?
        localModelSuggestions = makeLocalModelSuggestionRuntime()
        var jobHandlers: [any JobHandler] = [handler, photosHandler, personalizationHandler]
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
        let appPersonalSampleSuggester: AppPersonalSampleSuggestionRuntime?
        let appPersonalTagLibrarySuggester: AppPersonalTagLibrarySuggestionRuntime?
        if let modelActivationCoordinator, let catalogScopeID {
            appPersonalModelRebuilder = AppPersonalModelRebuildRuntime(
                expectedCatalogScopeID: catalogScopeID,
                activationCoordinator: modelActivationCoordinator,
                cachesDirectory: runtime.paths.cachesDirectory,
                applicationSupportDirectory: runtime.paths.applicationSupportDirectory
            )
            appPersonalSampleSuggester = AppPersonalSampleSuggestionRuntime(
                expectedCatalogScopeID: catalogScopeID,
                activationCoordinator: modelActivationCoordinator,
                applicationSupportDirectory: runtime.paths.applicationSupportDirectory
            )
            appPersonalTagLibrarySuggester = AppPersonalTagLibrarySuggestionRuntime(
                expectedCatalogScopeID: catalogScopeID,
                activationCoordinator: modelActivationCoordinator,
                applicationSupportDirectory: runtime.paths.applicationSupportDirectory
            )
        } else {
            appPersonalModelRebuilder = nil
            appPersonalSampleSuggester = nil
            appPersonalTagLibrarySuggester = nil
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
        return LibraryWorkspaceModel(
            service: service,
            review: personalizationReview,
            localModelSuggestions: localModelSuggestions,
            appPersonalModelRebuilder: appPersonalModelRebuilder,
            selectedAssetEmbeddingCache: selectedAssetEmbeddingCache,
            appPersonalSampleSuggester: appPersonalSampleSuggester,
            appPersonalTagLibrarySuggester: appPersonalTagLibrarySuggester
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
