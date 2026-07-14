import Foundation

struct CompositionRoot {
    @MainActor
    func makeStartupModel() -> CatalogStartupModel {
        CatalogStartupModel(dependencies: Self.makeProductionDependencies())
    }

    static func makeProductionDependencies() -> CatalogBootstrapDependencies {
        CatalogBootstrapDependencies(
            pathsResolver: FoundationAppPathsResolver(),
            appVersionProvider: { BundleAppVersionProvider().currentVersion() }
        )
    }
}
