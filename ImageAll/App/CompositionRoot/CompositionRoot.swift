import Foundation

struct CompositionRoot {
    @MainActor
    func makeStartupModel() -> CatalogStartupModel {
        CatalogStartupModel(
            dependencies: Self.makeProductionDependencies(),
            workspaceFactory: { token in
                Self.makeWorkspaceModel(runtime: token.runtime)
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
    private static func makeWorkspaceModel(runtime: CatalogRuntime) -> LibraryWorkspaceModel {
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
        if let catalogScopeID = try? runtime.database.catalogScopeID() {
            localModelSuggestions = makeLocalModelSuggestionRuntime(
                catalogScopeID: catalogScopeID
            )
        } else {
            localModelSuggestions = nil
        }
        var jobHandlers: [any JobHandler] = [handler, photosHandler, personalizationHandler]
        if let localModelSuggestions {
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
            standardLibrarySuggestionsEnabled: localModelSuggestions != nil
        )
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
            localModelSuggestions: localModelSuggestions
        )
    }

    static func makeLocalModelSuggestionRuntime(
        catalogScopeID: String
    ) -> LocalModelSuggestionRuntime? {
        guard let client = try? LoopbackModelSuggestionClient() else { return nil }
        return LocalModelSuggestionRuntime(
            client: client,
            catalogScopeID: catalogScopeID
        )
    }
}
