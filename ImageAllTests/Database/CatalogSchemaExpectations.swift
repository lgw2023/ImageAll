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

    struct IndexExpectation: Equatable {
        let name: String
        let keyColumns: [IndexKeyColumnExpectation]
        let unique: Bool
        let partialPredicateFragments: [String]
        let ddlKeyFragments: [String]

        init(
            name: String,
            keyColumns: [IndexKeyColumnExpectation],
            unique: Bool,
            partialPredicateFragments: [String],
            ddlKeyFragments: [String] = []
        ) {
            self.name = name
            self.keyColumns = keyColumns
            self.unique = unique
            self.partialPredicateFragments = partialPredicateFragments
            self.ddlKeyFragments = ddlKeyFragments
        }
    }

    static let infrastructureTables = ["grdb_migrations"]

    static let allowedSchemaObjectTypes = ["index", "table"]

    static let businessTables = [
        "asset",
        "asset_tag_decision",
        "file_fingerprint",
        "job",
        "source",
        "tag",
    ]

    static let businessIndexes = [
        "asset_current_file_locator_uq",
        "asset_current_file_name_idx",
        "asset_current_photos_locator_uq",
        "asset_current_source_time_idx",
        "asset_current_time_idx",
        "asset_generation_missing_idx",
        "asset_source_availability_idx",
        "decision_tag_idx",
        "file_fingerprint_resource_id_idx",
        "file_fingerprint_sha256_idx",
        "job_active_coalescing_uq",
        "job_queue_idx",
        "tag_normalized_name_uq",
    ]

    static let columnsByTable: [String: [ColumnExpectation]] = [
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
    ]

    static let foreignKeysByTable: [String: [ForeignKeyExpectation]] = [
        "source": [],
        "asset": [
            .init(from: "source_id", toTable: "source", to: "id", onDelete: "RESTRICT"),
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
    ]

    static let indexTableByName: [String: String] = [
        "asset_current_file_locator_uq": "asset",
        "asset_current_file_name_idx": "asset",
        "asset_current_photos_locator_uq": "asset",
        "asset_current_source_time_idx": "asset",
        "asset_current_time_idx": "asset",
        "asset_generation_missing_idx": "asset",
        "asset_source_availability_idx": "asset",
        "tag_normalized_name_uq": "tag",
        "decision_tag_idx": "asset_tag_decision",
        "file_fingerprint_resource_id_idx": "file_fingerprint",
        "file_fingerprint_sha256_idx": "file_fingerprint",
        "job_queue_idx": "job",
        "job_active_coalescing_uq": "job",
    ]

    static let indexes: [IndexExpectation] = [
        .init(
            name: "asset_current_file_locator_uq",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "relative_path", descending: false, collation: "BINARY"),
            ],
            unique: true,
            partialPredicateFragments: ["locator_kind = 'file'", "locator_state = 'current'"]
        ),
        .init(
            name: "asset_current_photos_locator_uq",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "photos_local_identifier", descending: false, collation: "BINARY"),
            ],
            unique: true,
            partialPredicateFragments: ["locator_kind = 'photos'", "locator_state = 'current'"]
        ),
        .init(
            name: "asset_source_availability_idx",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "availability", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: []
        ),
        .init(
            name: "tag_normalized_name_uq",
            keyColumns: [
                .init(name: "normalized_name", descending: false, collation: "BINARY"),
            ],
            unique: true,
            partialPredicateFragments: []
        ),
        .init(
            name: "decision_tag_idx",
            keyColumns: [
                .init(name: "tag_id", descending: false, collation: "BINARY"),
                .init(name: "decision", descending: false, collation: "BINARY"),
                .init(name: "asset_id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: []
        ),
        .init(
            name: "job_queue_idx",
            keyColumns: [
                .init(name: "state", descending: false, collation: "BINARY"),
                .init(name: "priority", descending: true, collation: "BINARY"),
                .init(name: "not_before_ms", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: []
        ),
        .init(
            name: "job_active_coalescing_uq",
            keyColumns: [
                .init(name: "coalescing_key", descending: false, collation: "BINARY"),
            ],
            unique: true,
            partialPredicateFragments: [
                "coalescing_key IS NOT NULL",
                "'pending'",
                "'running'",
                "'paused'",
                "'retryableFailed'",
            ]
        ),
        .init(
            name: "asset_current_time_idx",
            keyColumns: [
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: ["locator_state = 'current'"],
            ddlKeyFragments: [
                "CASE WHEN media_created_at_ms IS NOT NULL OR media_modified_at_ms IS NOT NULL THEN 0 ELSE 1 END",
                "coalesce(media_created_at_ms, media_modified_at_ms)",
            ]
        ),
        .init(
            name: "asset_current_source_time_idx",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: ["locator_state = 'current'"],
            ddlKeyFragments: [
                "CASE WHEN media_created_at_ms IS NOT NULL OR media_modified_at_ms IS NOT NULL THEN 0 ELSE 1 END",
                "coalesce(media_created_at_ms, media_modified_at_ms)",
            ]
        ),
        .init(
            name: "asset_current_file_name_idx",
            keyColumns: [
                .init(name: "file_name", descending: false, collation: "NOCASE"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: [
                "locator_kind = 'file'",
                "locator_state = 'current'",
                "file_name IS NOT NULL",
            ]
        ),
        .init(
            name: "asset_generation_missing_idx",
            keyColumns: [
                .init(name: "source_id", descending: false, collation: "BINARY"),
                .init(name: "last_seen_generation", descending: false, collation: "BINARY"),
                .init(name: "id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: [
                "locator_kind = 'file'",
                "locator_state = 'current'",
            ]
        ),
        .init(
            name: "file_fingerprint_resource_id_idx",
            keyColumns: [
                .init(name: "resource_id", descending: false, collation: "BINARY"),
                .init(name: "asset_id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: ["resource_id IS NOT NULL"]
        ),
        .init(
            name: "file_fingerprint_sha256_idx",
            keyColumns: [
                .init(name: "sha256", descending: false, collation: "BINARY"),
                .init(name: "asset_id", descending: false, collation: "BINARY"),
            ],
            unique: false,
            partialPredicateFragments: ["sha256 IS NOT NULL"]
        ),
    ]
}
