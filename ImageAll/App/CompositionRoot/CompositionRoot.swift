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
        let handler = FolderReconcileHandler(rootAccess: sourceAccess)
        let photosAccess = PhotoKitPhotosLibraryAdapter()
        let photosConnection = PhotosLibraryConnectionService(
            database: runtime.database,
            access: photosAccess,
            clock: clock
        )
        let photosObserver = PhotosLibraryChangeObserverCoordinator(
            observer: photosAccess,
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
        let executionCoordinator = JobExecutionCoordinator(
            queue: runtime.jobQueue,
            registry: MultiJobHandlerRegistry(handlers: [handler, photosHandler, personalizationHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: runtime.jobQueue)
        )
        let assetImages = LibraryAssetImageLoader(
            database: runtime.database,
            fileImages: derivedImages,
            photosImages: photosAccess,
            cloudPreviews: photosAccess,
            downloadedPreviews: derivedImages
        )
        let personalizationReview = PersonalizationReviewService(
            database: runtime.database,
            queue: runtime.jobQueue,
            executionCoordinator: executionCoordinator,
            tags: GRDBTagCatalogRepository(database: runtime.database),
            clock: clock
        )
        let service = ProductionLibraryWorkspaceService(
            sourceRepository: sourceRepository,
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
            portableExporter: PortableCatalogExporter(database: runtime.database),
            appVersion: BundleAppVersionProvider().currentVersion(),
            clock: clock
        )
        photosObserver.start()
        return LibraryWorkspaceModel(service: service, review: personalizationReview)
    }
}
