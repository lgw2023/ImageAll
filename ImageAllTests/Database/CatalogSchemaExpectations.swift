import Foundation

enum CatalogSchemaExpectations {
    struct ColumnExpectation: Equatable {
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?
        let primaryKeyOrder: Int
    }

    struct ForeignKeyExpectation: Equatable {
        let from: String
        let toTable: String
        let to: String
        let onDelete: String
    }

    struct IndexKeyColumnExpectation: Equatable {
        let name: String
        let descending: Bool
        let collation: String
    }

    struct IndexKeyEntryExpectation: Equatable {
        let name: String?
        let descending: Bool
        let collation: String?
    }

    struct IndexExpectation: Equatable {
        let name: String
        let keyColumns: [IndexKeyColumnExpectation]
        let unique: Bool
        let partialPredicateSQL: String
        let orderedKeyEntries: [IndexKeyEntryExpectation]?
        let keyListSQL: String?

        init(
            name: String,
            keyColumns: [IndexKeyColumnExpectation],
            unique: Bool,
            partialPredicateSQL: String = "",
            orderedKeyEntries: [IndexKeyEntryExpectation]? = nil,
            keyListSQL: String? = nil
        ) {
            self.name = name
            self.keyColumns = keyColumns
            self.unique = unique
            self.partialPredicateSQL = partialPredicateSQL
            self.orderedKeyEntries = orderedKeyEntries
            self.keyListSQL = keyListSQL
        }
    }

    static let assetCurrentTimeEmptyMarkerExpression = """
        (CASE WHEN media_created_at_ms IS NOT NULL OR media_modified_at_ms IS NOT NULL THEN 0 ELSE 1 END)
        """

    static let assetCoalescedMediaTimeExpression = "coalesce(media_created_at_ms, media_modified_at_ms)"

    static let infrastructureTables = [
        "asset_search",
        "asset_search_config",
        "asset_search_data",
        "asset_search_docsize",
        "asset_search_idx",
        "grdb_migrations",
    ]

    static let infrastructureTriggers = [
        "asset_search_after_delete",
        "asset_search_after_insert",
        "asset_search_after_update",
        "personal_suggestion_tag_before_insert",
        "personal_tag_model_before_insert",
    ]

    static let allowedSchemaObjectTypes = ["index", "table", "trigger"]

    static let businessTables = [
        "asset",
        "asset_tag_decision",
        "catalog_scope",
        "derived_image_cache_entry",
        "feature",
        "file_fingerprint",
        "job",
        "ontology_concept",
        "ontology_edge",
        "ontology_pack",
        "personal_prediction",
        "personal_suggestion_model",
        "personal_suggestion_tag",
        "prediction",
        "source",
        "standard_model_revision",
        "standard_tag_binding",
        "tag",
        "tag_model",
        "tag_model_revision",
        "tag_model_sample",
    ]

    static let businessIndexes = [
        "asset_current_file_locator_uq",
        "asset_current_file_name_idx",
        "asset_current_file_name_all_idx",
        "asset_current_photos_locator_uq",
        "asset_current_source_media_time_desc_idx",
        "asset_current_source_time_idx",
        "asset_current_time_desc_idx",
        "asset_current_time_idx",
        "asset_generation_missing_idx",
        "asset_source_availability_idx",
        "decision_tag_idx",
        "derived_image_cache_key_uq",
        "derived_image_cache_lru_idx",
        "feature_cache_key_uq",
        "file_fingerprint_resource_id_idx",
        "file_fingerprint_sha256_idx",
        "job_active_coalescing_uq",
        "job_queue_idx",
        "personal_prediction_review_rank_idx",
        "prediction_review_rank_idx",
        "tag_model_sample_feature_idx",
        "tag_normalized_name_uq",
    ]

    static let columnsByTable: [String: [ColumnExpectation]] = [
        "catalog_scope": [
            .init(name: "singleton", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "scope_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "ontology_pack": [
            .init(name: "standard_pack_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "standard_pack_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "ontology_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "ontology_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "locale_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "manifest_sha256", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "state", type: "TEXT", notNull: true, defaultValue: "'active'", primaryKeyOrder: 0),
            .init(name: "installed_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "ontology_concept": [
            .init(name: "ontology_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "ontology_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "concept_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 3),
            .init(name: "canonical_name", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "normalized_name", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "ontology_edge": [
            .init(name: "ontology_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "ontology_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "parent_concept_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 3),
            .init(name: "child_concept_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 4),
        ],
        "standard_model_revision": [
            .init(name: "standard_pack_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "standard_pack_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "provider", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "model_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "preprocessing_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "mapping_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "policy_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "weights_sha256", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "standard_tag_binding": [
            .init(name: "tag_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "ontology_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "ontology_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "concept_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "personal_suggestion_model": [
            .init(name: "singleton", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "catalog_scope_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "bundle_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "bundle_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "provider", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "model_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "model_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "preprocessing_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "element_count", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "label_vocabulary_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "weights_sha256", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "policy_revision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "activated_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "personal_suggestion_tag": [
            .init(name: "tag_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "model_singleton", type: "INTEGER", notNull: true, defaultValue: "1", primaryKeyOrder: 0),
        ],
        "personal_prediction": [
            .init(name: "asset_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "tag_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "content_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 3),
            .init(name: "score", type: "REAL", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "state", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "source": [
            .init(name: "id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "kind", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "display_name", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "bookmark", type: "BLOB", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "sync_cursor", type: "BLOB", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "scan_generation", type: "INTEGER", notNull: true, defaultValue: "0", primaryKeyOrder: 0),
            .init(name: "dirty_epoch", type: "INTEGER", notNull: true, defaultValue: "0", primaryKeyOrder: 0),
            .init(name: "state", type: "TEXT", notNull: true, defaultValue: "'active'", primaryKeyOrder: 0),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "updated_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "asset": [
            .init(name: "id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "source_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "locator_kind", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "relative_path", type: "TEXT", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "photos_local_identifier", type: "TEXT", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "locator_state", type: "TEXT", notNull: true, defaultValue: "'current'", primaryKeyOrder: 0),
            .init(name: "media_type", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "width", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "height", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "media_created_at_ms", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "media_modified_at_ms", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "content_revision", type: "INTEGER", notNull: true, defaultValue: "1", primaryKeyOrder: 0),
            .init(name: "last_seen_generation", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "availability", type: "TEXT", notNull: true, defaultValue: "'available'", primaryKeyOrder: 0),
            .init(name: "record_created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "record_updated_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "file_name", type: "TEXT", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "file_fingerprint": [
            .init(name: "asset_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "size_bytes", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "modified_at_ns", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "resource_id", type: "BLOB", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "sha256", type: "BLOB", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "tag": [
            .init(name: "id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "name", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "normalized_name", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "state", type: "TEXT", notNull: true, defaultValue: "'active'", primaryKeyOrder: 0),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "updated_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "asset_tag_decision": [
            .init(name: "asset_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "tag_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "decision", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "updated_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "job": [
            .init(name: "id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "kind", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "payload_version", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "payload", type: "BLOB", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "source_id", type: "TEXT", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "coalescing_key", type: "TEXT", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "checkpoint_version", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "checkpoint", type: "BLOB", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "scan_generation", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "started_dirty_epoch", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "state", type: "TEXT", notNull: true, defaultValue: "'pending'", primaryKeyOrder: 0),
            .init(name: "control_request", type: "TEXT", notNull: true, defaultValue: "'none'", primaryKeyOrder: 0),
            .init(name: "priority", type: "INTEGER", notNull: true, defaultValue: "0", primaryKeyOrder: 0),
            .init(name: "attempts", type: "INTEGER", notNull: true, defaultValue: "0", primaryKeyOrder: 0),
            .init(name: "max_attempts", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "not_before_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "lease_owner", type: "TEXT", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "lease_expires_at_ms", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "progress_completed", type: "INTEGER", notNull: true, defaultValue: "0", primaryKeyOrder: 0),
            .init(name: "progress_total", type: "INTEGER", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "last_error_code", type: "TEXT", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "last_error_message", type: "TEXT", notNull: false, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "updated_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "derived_image_cache_entry": [
            .init(name: "id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "asset_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "content_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "representation_version", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "variant", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "storage_format", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "pixel_width", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "pixel_height", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "byte_size", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "encoded_sha256", type: "BLOB", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "last_accessed_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "feature": [
            .init(name: "asset_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "provider", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "request_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 3),
            .init(name: "preprocessing_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 4),
            .init(name: "content_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 5),
            .init(name: "element_type", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "element_count", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "byte_count", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "vector_sha256", type: "BLOB", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "cache_key", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "tag_model_revision": [
            .init(name: "tag_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "provider", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "request_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "preprocessing_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "threshold", type: "REAL", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "positive_count", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "negative_count", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "neighbor_count", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "sample_budget_per_role", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "tag_model_sample": [
            .init(name: "tag_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "model_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "asset_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 3),
            .init(name: "content_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "role", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "rank", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "provider", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "request_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "preprocessing_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "tag_model": [
            .init(name: "tag_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "current_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "updated_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
        "prediction": [
            .init(name: "asset_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 1),
            .init(name: "tag_id", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 2),
            .init(name: "content_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 3),
            .init(name: "model_revision", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 4),
            .init(name: "score", type: "REAL", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "state", type: "TEXT", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, defaultValue: nil, primaryKeyOrder: 0),
        ],
    ]

    static let foreignKeysByTable: [String: [ForeignKeyExpectation]] = [
        "source": [],
        "ontology_pack": [],
        "ontology_concept": [
            .init(from: "ontology_id", toTable: "ontology_pack", to: "ontology_id", onDelete: "RESTRICT"),
            .init(from: "ontology_revision", toTable: "ontology_pack", to: "ontology_revision", onDelete: "RESTRICT"),
        ],
        "ontology_edge": [
            .init(from: "ontology_id", toTable: "ontology_concept", to: "ontology_id", onDelete: "RESTRICT"),
            .init(from: "ontology_revision", toTable: "ontology_concept", to: "ontology_revision", onDelete: "RESTRICT"),
            .init(from: "parent_concept_id", toTable: "ontology_concept", to: "concept_id", onDelete: "RESTRICT"),
            .init(from: "ontology_id", toTable: "ontology_concept", to: "ontology_id", onDelete: "RESTRICT"),
            .init(from: "ontology_revision", toTable: "ontology_concept", to: "ontology_revision", onDelete: "RESTRICT"),
            .init(from: "child_concept_id", toTable: "ontology_concept", to: "concept_id", onDelete: "RESTRICT"),
        ],
        "standard_model_revision": [
            .init(from: "standard_pack_id", toTable: "ontology_pack", to: "standard_pack_id", onDelete: "RESTRICT"),
            .init(from: "standard_pack_revision", toTable: "ontology_pack", to: "standard_pack_revision", onDelete: "RESTRICT"),
        ],
        "standard_tag_binding": [
            .init(from: "tag_id", toTable: "tag", to: "id", onDelete: "RESTRICT"),
            .init(from: "ontology_id", toTable: "ontology_concept", to: "ontology_id", onDelete: "RESTRICT"),
            .init(from: "ontology_revision", toTable: "ontology_concept", to: "ontology_revision", onDelete: "RESTRICT"),
            .init(from: "concept_id", toTable: "ontology_concept", to: "concept_id", onDelete: "RESTRICT"),
        ],
        "personal_suggestion_model": [
            .init(from: "catalog_scope_id", toTable: "catalog_scope", to: "scope_id", onDelete: "CASCADE"),
        ],
        "personal_suggestion_tag": [
            .init(from: "tag_id", toTable: "tag", to: "id", onDelete: "CASCADE"),
            .init(from: "model_singleton", toTable: "personal_suggestion_model", to: "singleton", onDelete: "CASCADE"),
        ],
        "personal_prediction": [
            .init(from: "asset_id", toTable: "asset", to: "id", onDelete: "CASCADE"),
            .init(from: "tag_id", toTable: "personal_suggestion_tag", to: "tag_id", onDelete: "CASCADE"),
        ],
        "asset": [
            .init(from: "source_id", toTable: "source", to: "id", onDelete: "RESTRICT"),
        ],
        "derived_image_cache_entry": [
            .init(from: "asset_id", toTable: "asset", to: "id", onDelete: "CASCADE"),
        ],
        "feature": [
            .init(from: "asset_id", toTable: "asset", to: "id", onDelete: "CASCADE"),
        ],
        "file_fingerprint": [
            .init(from: "asset_id", toTable: "asset", to: "id", onDelete: "CASCADE"),
        ],
        "tag": [],
        "asset_tag_decision": [
            .init(from: "asset_id", toTable: "asset", to: "id", onDelete: "RESTRICT"),
            .init(from: "tag_id", toTable: "tag", to: "id", onDelete: "RESTRICT"),
        ],
        "job": [
            .init(from: "source_id", toTable: "source", to: "id", onDelete: "SET NULL"),
        ],
        "tag_model_revision": [
            .init(from: "tag_id", toTable: "tag", to: "id", onDelete: "CASCADE"),
        ],
        "tag_model_sample": [
            .init(from: "tag_id", toTable: "tag_model_revision", to: "tag_id", onDelete: "CASCADE"),
            .init(from: "model_revision", toTable: "tag_model_revision", to: "revision", onDelete: "CASCADE"),
            .init(from: "asset_id", toTable: "asset", to: "id", onDelete: "CASCADE"),
            .init(from: "asset_id", toTable: "feature", to: "asset_id", onDelete: "CASCADE"),
            .init(from: "provider", toTable: "feature", to: "provider", onDelete: "CASCADE"),
            .init(from: "request_revision", toTable: "feature", to: "request_revision", onDelete: "CASCADE"),
            .init(from: "preprocessing_revision", toTable: "feature", to: "preprocessing_revision", onDelete: "CASCADE"),
            .init(from: "content_revision", toTable: "feature", to: "content_revision", onDelete: "CASCADE"),
        ],
        "tag_model": [
            .init(from: "tag_id", toTable: "tag", to: "id", onDelete: "CASCADE"),
            .init(from: "tag_id", toTable: "tag_model_revision", to: "tag_id", onDelete: "RESTRICT"),
            .init(from: "current_revision", toTable: "tag_model_revision", to: "revision", onDelete: "RESTRICT"),
        ],
        "prediction": [
            .init(from: "asset_id", toTable: "asset", to: "id", onDelete: "CASCADE"),
            .init(from: "tag_id", toTable: "tag_model_revision", to: "tag_id", onDelete: "CASCADE"),
            .init(from: "model_revision", toTable: "tag_model_revision", to: "revision", onDelete: "CASCADE"),
        ],
    ]

    static let indexTableByName: [String: String] = [
        "asset_current_file_locator_uq": "asset",
        "asset_current_file_name_idx": "asset",
        "asset_current_file_name_all_idx": "asset",
        "asset_current_photos_locator_uq": "asset",
        "asset_current_source_media_time_desc_idx": "asset",
        "asset_current_source_time_idx": "asset",
        "asset_current_time_desc_idx": "asset",
        "asset_current_time_idx": "asset",
        "asset_generation_missing_idx": "asset",
        "asset_source_availability_idx": "asset",
        "tag_normalized_name_uq": "tag",
        "decision_tag_idx": "asset_tag_decision",
        "derived_image_cache_key_uq": "derived_image_cache_entry",
        "derived_image_cache_lru_idx": "derived_image_cache_entry",
        "feature_cache_key_uq": "feature",
        "file_fingerprint_resource_id_idx": "file_fingerprint",
        "file_fingerprint_sha256_idx": "file_fingerprint",
        "job_queue_idx": "job",
        "job_active_coalescing_uq": "job",
        "personal_prediction_review_rank_idx": "personal_prediction",
        "prediction_review_rank_idx": "prediction",
        "tag_model_sample_feature_idx": "tag_model_sample",
    ]

    static let indexes: [IndexExpectation] = [
        .init(
            name: "asset_current_file_locator_uq",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "relative_path", descending: false, collation: "BINARY"),
            ],
            unique: true,
            partialPredicateSQL: "locator_kind = 'file' AND locator_state = 'current'"
        ),
        .init(
            name: "asset_current_photos_locator_uq",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "photos_local_identifier", descending: false, collation: "BINARY"),
            ],
            unique: true,
            partialPredicateSQL: "locator_kind = 'photos' AND locator_state = 'current'"
        ),
        .init(
            name: "asset_source_availability_idx",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "availability", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false
        ),
        .init(
            name: "tag_normalized_name_uq",
            keyColumns: [
                .init(name: "normalized_name", descending: false, collation: "BINARY"),
            ],
            unique: true
        ),
        .init(
            name: "decision_tag_idx",
            keyColumns: [
                .init(name: "tag_id", descending: false, collation: "BINARY"),
                .init(name: "decision", descending: false, collation: "BINARY"),
                .init(name: "asset_id", descending: false, collation: "BINARY"),
            ],
            unique: false
        ),
        .init(
            name: "job_queue_idx",
            keyColumns: [
                .init(name: "state", descending: false, collation: "BINARY"),
                .init(name: "priority", descending: true, collation: "BINARY"),
                .init(name: "not_before_ms", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false
        ),
        .init(
            name: "job_active_coalescing_uq",
            keyColumns: [
                .init(name: "coalescing_key", descending: false, collation: "BINARY"),
            ],
            unique: true,
            partialPredicateSQL: """
                coalescing_key IS NOT NULL AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                """
        ),
        .init(
            name: "asset_current_time_idx",
            keyColumns: [
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: "locator_state = 'current'",
            orderedKeyEntries: [
                .init(name: nil, descending: false, collation: "BINARY"),
                .init(name: nil, descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            keyListSQL: """
                \(assetCurrentTimeEmptyMarkerExpression), \(assetCoalescedMediaTimeExpression), id
                """
        ),
        .init(
            name: "asset_current_time_desc_idx",
            keyColumns: [
                .init(name: "id", descending: true, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: "locator_state = 'current'",
            orderedKeyEntries: [
                .init(name: nil, descending: false, collation: "BINARY"),
                .init(name: nil, descending: true, collation: "BINARY"),
                .init(name: "id", descending: true, collation: "BINARY"),
            ],
            keyListSQL: """
                \(assetCurrentTimeEmptyMarkerExpression), \(assetCoalescedMediaTimeExpression) DESC, id DESC
                """
        ),
        .init(
            name: "asset_current_source_media_time_desc_idx",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "media_type", descending: false, collation: "BINARY"),
                .init(name: "id", descending: true, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: "locator_state = 'current'",
            orderedKeyEntries: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "media_type", descending: false, collation: "BINARY"),
                .init(name: nil, descending: false, collation: "BINARY"),
                .init(name: nil, descending: true, collation: "BINARY"),
                .init(name: "id", descending: true, collation: "BINARY"),
            ],
            keyListSQL: """
                source_id, media_type, \(assetCurrentTimeEmptyMarkerExpression),
                \(assetCoalescedMediaTimeExpression) DESC, id DESC
                """
        ),
        .init(
            name: "asset_current_source_time_idx",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: "locator_state = 'current'",
            orderedKeyEntries: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: nil, descending: false, collation: "BINARY"),
                .init(name: nil, descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            keyListSQL: """
                source_id, \(assetCurrentTimeEmptyMarkerExpression), \(assetCoalescedMediaTimeExpression), id
                """
        ),
        .init(
            name: "asset_current_file_name_idx",
            keyColumns: [
                .init(name: "file_name", descending: false, collation: "NOCASE"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: """
                locator_kind = 'file' AND locator_state = 'current' AND file_name IS NOT NULL
                """
        ),
        .init(
            name: "asset_current_file_name_all_idx",
            keyColumns: [
                .init(name: "file_name", descending: false, collation: "NOCASE"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: "locator_state = 'current'",
            orderedKeyEntries: [
                .init(name: nil, descending: false, collation: "BINARY"),
                .init(name: "file_name", descending: false, collation: "NOCASE"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            keyListSQL: """
                (CASE WHEN file_name IS NOT NULL THEN 0 ELSE 1 END), file_name COLLATE NOCASE, id
                """
        ),
        .init(
            name: "asset_generation_missing_idx",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "last_seen_generation", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: "locator_kind = 'file' AND locator_state = 'current'"
        ),
        .init(
            name: "file_fingerprint_resource_id_idx",
            keyColumns: [
                .init(name: "resource_id", descending: false, collation: "BINARY"),
                .init(name: "asset_id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: "resource_id IS NOT NULL"
        ),
        .init(
            name: "file_fingerprint_sha256_idx",
            keyColumns: [
                .init(name: "sha256", descending: false, collation: "BINARY"),
                .init(name: "asset_id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateSQL: "sha256 IS NOT NULL"
        ),
        .init(
            name: "derived_image_cache_key_uq",
            keyColumns: [
                .init(name: "asset_id", descending: false, collation: "BINARY"),
                .init(name: "content_revision", descending: false, collation: "BINARY"),
                .init(name: "representation_version", descending: false, collation: "BINARY"),
                .init(name: "variant", descending: false, collation: "BINARY"),
            ],
            unique: true
        ),
        .init(
            name: "derived_image_cache_lru_idx",
            keyColumns: [
                .init(name: "last_accessed_at_ms", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false
        ),
        .init(
            name: "feature_cache_key_uq",
            keyColumns: [
                .init(name: "cache_key", descending: false, collation: "BINARY"),
            ],
            unique: true
        ),
        .init(
            name: "tag_model_sample_feature_idx",
            keyColumns: [
                .init(name: "asset_id", descending: false, collation: "BINARY"),
                .init(name: "provider", descending: false, collation: "BINARY"),
                .init(name: "request_revision", descending: false, collation: "BINARY"),
                .init(name: "preprocessing_revision", descending: false, collation: "BINARY"),
                .init(name: "content_revision", descending: false, collation: "BINARY"),
            ],
            unique: false
        ),
        .init(
            name: "personal_prediction_review_rank_idx",
            keyColumns: [
                .init(name: "tag_id", descending: false, collation: "BINARY"),
                .init(name: "state", descending: false, collation: "BINARY"),
                .init(name: "score", descending: true, collation: "BINARY"),
                .init(name: "asset_id", descending: false, collation: "BINARY"),
            ],
            unique: false
        ),
        .init(
            name: "prediction_review_rank_idx",
            keyColumns: [
                .init(name: "tag_id", descending: false, collation: "BINARY"),
                .init(name: "state", descending: false, collation: "BINARY"),
                .init(name: "score", descending: true, collation: "BINARY"),
                .init(name: "asset_id", descending: false, collation: "BINARY"),
            ],
            unique: false
        ),
    ]
}
