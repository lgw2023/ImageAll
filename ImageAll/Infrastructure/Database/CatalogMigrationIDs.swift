import Foundation

enum CatalogMigrationID {
    static let v001CreateCatalogCore = "v001_create_catalog_core"
    static let v002AddStage1CatalogQuerySupport = "v002_add_stage_1_catalog_query_support"
    static let v003AddDerivedImageCache = "v003_add_derived_image_cache"
    static let v004AddPersonalization = "v004_add_personalization"
    static let v005AddCatalogScaleIndexes = "v005_add_catalog_scale_indexes"
    static let v006AddAssetTextSearch = "v006_add_asset_text_search"
    static let v007AddCatalogScopeIdentity = "v007_add_catalog_scope_identity"
    static let v008AddPersonalModelSuggestions = "v008_add_personal_model_suggestions"
    static let v009AddStandardOntology = "v009_add_standard_ontology"
    static let v010AddStandardPredictions = "v010_add_standard_predictions"
    static let v011AddStandardPredictionProvenance = "v011_add_standard_prediction_provenance"

    static let knownOrdered: [String] = [
        v001CreateCatalogCore,
        v002AddStage1CatalogQuerySupport,
        v003AddDerivedImageCache,
        v004AddPersonalization,
        v005AddCatalogScaleIndexes,
        v006AddAssetTextSearch,
        v007AddCatalogScopeIdentity,
        v008AddPersonalModelSuggestions,
        v009AddStandardOntology,
        v010AddStandardPredictions,
        v011AddStandardPredictionProvenance,
    ]
}
