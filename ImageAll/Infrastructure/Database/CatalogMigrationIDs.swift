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
    static let v012RepairStandardTagBinding = "v012_repair_standard_tag_binding"
    static let v013PhotosMissingAssetRepair = "v013_photos_missing_asset_repair"
    static let v014AddTrainingRunsAndPersonalMultiSlot =
        "v014_add_training_runs_and_personal_multi_slot"
    static let v015AddSuggestionScoreThresholds =
        "v015_add_suggestion_score_thresholds"
    static let v016AddTagGroups = "v016_add_tag_groups"
    static let v017PerTagPersonalSuggestionModels =
        "v017_per_tag_personal_suggestion_models"
    static let v018AddAssetSimilarityFingerprint =
        "v018_add_asset_similarity_fingerprint"
    static let v019AddLibrarySlimmingRecycle =
        "v019_add_library_slimming_recycle"
    static let v020HardenLibrarySlimmingRecycle =
        "v020_harden_library_slimming_recycle"
    static let v021AddPhotosRecycleIdentifier =
        "v021_add_photos_recycle_identifier"
    static let v022HardenLibrarySlimmingAnalysis =
        "v022_harden_library_slimming_analysis"
    static let v023AddSourceSimilarityIndex =
        "v023_add_source_similarity_index"
    static let v024RepairSourceMutationAuthorization =
        "v024_repair_source_mutation_authorization"
    static let v025RetainPurgedAssetKnowledge =
        "v025_retain_purged_asset_knowledge"
    static let v026AddMediaKindAndVideoMetadata =
        "v026_add_media_kind_and_video_metadata"
    static let v027PartitionPersonalizationByMediaKind =
        "v027_partition_personalization_by_media_kind"
    static let v028PartitionSlimmingByMediaKind =
        "v028_partition_slimming_by_media_kind"
    static let v029AddOriginalAspectThumbnailCache =
        "v029_add_original_aspect_thumbnail_cache"
    static let v030AddSimilarityDigestProvenance =
        "v030_add_similarity_digest_provenance"

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
        v012RepairStandardTagBinding,
        v013PhotosMissingAssetRepair,
        v014AddTrainingRunsAndPersonalMultiSlot,
        v015AddSuggestionScoreThresholds,
        v016AddTagGroups,
        v017PerTagPersonalSuggestionModels,
        v018AddAssetSimilarityFingerprint,
        v019AddLibrarySlimmingRecycle,
        v020HardenLibrarySlimmingRecycle,
        v021AddPhotosRecycleIdentifier,
        v022HardenLibrarySlimmingAnalysis,
        v023AddSourceSimilarityIndex,
        v024RepairSourceMutationAuthorization,
        v025RetainPurgedAssetKnowledge,
        v026AddMediaKindAndVideoMetadata,
        v027PartitionPersonalizationByMediaKind,
        v028PartitionSlimmingByMediaKind,
        v029AddOriginalAspectThumbnailCache,
        v030AddSimilarityDigestProvenance,
    ]
}
