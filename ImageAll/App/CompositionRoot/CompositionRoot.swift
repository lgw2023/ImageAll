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
        let executionCoordinator = JobExecutionCoordinator(
            queue: runtime.jobQueue,
            registry: SingleJobHandlerRegistry(registeredHandler: handler),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: runtime.jobQueue)
        )
        let derivedImages = DerivedImageCacheService(
            database: runtime.database,
            cachesDirectory: runtime.paths.cachesDirectory,
            sourceAccess: sourceAccess,
            clock: clock
        )
        let service = ProductionLibraryWorkspaceService(
            sourceRepository: sourceRepository,
            authorization: authorization,
            queue: runtime.jobQueue,
            executionCoordinator: executionCoordinator,
            query: GRDBAssetCatalogQueryRepository(database: runtime.database),
            derivedImages: derivedImages,
            clock: clock
        )
        return LibraryWorkspaceModel(service: service)
    }
}
