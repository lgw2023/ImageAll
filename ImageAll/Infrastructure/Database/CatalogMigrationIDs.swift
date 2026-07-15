import Foundation

enum CatalogMigrationID {
    static let v001CreateCatalogCore = "v001_create_catalog_core"
    static let v002AddStage1CatalogQuerySupport = "v002_add_stage_1_catalog_query_support"
    static let v003AddDerivedImageCache = "v003_add_derived_image_cache"

    static let knownOrdered: [String] = [
        v001CreateCatalogCore,
        v002AddStage1CatalogQuerySupport,
        v003AddDerivedImageCache,
    ]
}
