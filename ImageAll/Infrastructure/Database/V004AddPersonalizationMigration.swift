import Foundation
import GRDB

enum V004AddPersonalizationMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v004AddPersonalization) { db in
            try db.execute(sql: featureDDL)
            try db.execute(sql: tagModelRevisionDDL)
            try db.execute(sql: tagModelSampleDDL)
            try db.execute(sql: tagModelDDL)
            try db.execute(sql: predictionDDL)
            for statement in indexStatements {
                try db.execute(sql: statement)
            }
        }
    }

    private static let featureDDL = """
        CREATE TABLE feature (
            asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
            provider TEXT NOT NULL CHECK(provider = 'vision-feature-print'),
            request_revision INTEGER NOT NULL CHECK(request_revision > 0),
            preprocessing_revision INTEGER NOT NULL CHECK(preprocessing_revision > 0),
            content_revision INTEGER NOT NULL CHECK(content_revision > 0),
            element_type TEXT NOT NULL CHECK(element_type = 'float32'),
            element_count INTEGER NOT NULL CHECK(element_count > 0),
            byte_count INTEGER NOT NULL CHECK(byte_count = element_count * 4),
            vector_sha256 BLOB NOT NULL CHECK(length(vector_sha256) = 32),
            cache_key TEXT NOT NULL CHECK(
                length(cache_key) BETWEEN 1 AND 200
                AND instr(cache_key, char(0)) = 0
                AND instr(cache_key, '..') = 0
                AND instr(cache_key, '\\') = 0
                AND cache_key GLOB 'objects/[0-9a-f][0-9a-f]/*.fprint'
            ),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            PRIMARY KEY (
                asset_id,
                provider,
                request_revision,
                preprocessing_revision,
                content_revision
            )
        ) STRICT
        """

    private static let tagModelRevisionDDL = """
        CREATE TABLE tag_model_revision (
            tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
            revision INTEGER NOT NULL CHECK(revision > 0),
            provider TEXT NOT NULL CHECK(provider = 'vision-feature-print'),
            request_revision INTEGER NOT NULL CHECK(request_revision > 0),
            preprocessing_revision INTEGER NOT NULL CHECK(preprocessing_revision > 0),
            threshold REAL NOT NULL CHECK(
                typeof(threshold) IN ('real', 'integer')
                AND threshold = threshold
                AND threshold BETWEEN -1.0e308 AND 1.0e308
            ),
            positive_count INTEGER NOT NULL CHECK(positive_count > 0),
            negative_count INTEGER NOT NULL CHECK(negative_count > 0),
            neighbor_count INTEGER NOT NULL CHECK(
                neighbor_count > 0
                AND neighbor_count <= positive_count
                AND neighbor_count <= negative_count
            ),
            sample_budget_per_role INTEGER NOT NULL CHECK(
                sample_budget_per_role >= positive_count
                AND sample_budget_per_role >= negative_count
            ),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            PRIMARY KEY (tag_id, revision)
        ) STRICT
        """

    private static let tagModelSampleDDL = """
        CREATE TABLE tag_model_sample (
            tag_id TEXT NOT NULL,
            model_revision INTEGER NOT NULL,
            asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
            content_revision INTEGER NOT NULL CHECK(content_revision > 0),
            role TEXT NOT NULL CHECK(role IN ('positive', 'negative')),
            rank INTEGER NOT NULL CHECK(rank >= 0),
            provider TEXT NOT NULL CHECK(provider = 'vision-feature-print'),
            request_revision INTEGER NOT NULL CHECK(request_revision > 0),
            preprocessing_revision INTEGER NOT NULL CHECK(preprocessing_revision > 0),
            PRIMARY KEY (tag_id, model_revision, asset_id),
            UNIQUE (tag_id, model_revision, role, rank),
            FOREIGN KEY (tag_id, model_revision)
                REFERENCES tag_model_revision(tag_id, revision) ON DELETE CASCADE,
            FOREIGN KEY (
                asset_id,
                provider,
                request_revision,
                preprocessing_revision,
                content_revision
            ) REFERENCES feature(
                asset_id,
                provider,
                request_revision,
                preprocessing_revision,
                content_revision
            ) ON DELETE CASCADE
        ) STRICT
        """

    private static let tagModelDDL = """
        CREATE TABLE tag_model (
            tag_id TEXT NOT NULL PRIMARY KEY REFERENCES tag(id) ON DELETE CASCADE,
            current_revision INTEGER NOT NULL CHECK(current_revision > 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
            FOREIGN KEY (tag_id, current_revision)
                REFERENCES tag_model_revision(tag_id, revision) ON DELETE RESTRICT
        ) STRICT
        """

    private static let predictionDDL = """
        CREATE TABLE prediction (
            asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
            tag_id TEXT NOT NULL,
            content_revision INTEGER NOT NULL CHECK(content_revision > 0),
            model_revision INTEGER NOT NULL CHECK(model_revision > 0),
            score REAL NOT NULL CHECK(
                typeof(score) IN ('real', 'integer')
                AND score = score
                AND score BETWEEN -1.0e308 AND 1.0e308
            ),
            state TEXT NOT NULL CHECK(state = 'pendingReview'),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            PRIMARY KEY (asset_id, tag_id, content_revision, model_revision),
            FOREIGN KEY (tag_id, model_revision)
                REFERENCES tag_model_revision(tag_id, revision) ON DELETE CASCADE
        ) STRICT
        """

    private static let indexStatements = [
        "CREATE UNIQUE INDEX feature_cache_key_uq ON feature(cache_key)",
        """
        CREATE INDEX tag_model_sample_feature_idx ON tag_model_sample (
            asset_id,
            provider,
            request_revision,
            preprocessing_revision,
            content_revision
        )
        """,
        """
        CREATE INDEX prediction_review_rank_idx ON prediction (
            tag_id,
            state,
            score DESC,
            asset_id
        )
        """,
    ]
}
