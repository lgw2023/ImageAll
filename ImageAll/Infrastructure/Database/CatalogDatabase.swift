import Foundation
import GRDB

struct CatalogDatabase: Sendable {
    let pool: DatabasePool

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        V001CreateCatalogCoreMigration.register(on: &migrator)
        V002AddStage1CatalogQuerySupportMigration.register(on: &migrator)
        V003AddDerivedImageCacheMigration.register(on: &migrator)
        V004AddPersonalizationMigration.register(on: &migrator)
        V005AddCatalogScaleIndexesMigration.register(on: &migrator)
        V006AddAssetTextSearchMigration.register(on: &migrator)
        V007AddCatalogScopeIdentityMigration.register(on: &migrator)
        V008AddPersonalModelSuggestionsMigration.register(on: &migrator)
        V009AddStandardOntologyMigration.register(on: &migrator)
        V010AddStandardPredictionsMigration.register(on: &migrator)
        V011AddStandardPredictionProvenanceMigration.register(on: &migrator)
        V012RepairStandardTagBindingMigration.register(on: &migrator)
        V013PhotosMissingAssetRepairMigration.register(on: &migrator)
        V014AddTrainingRunsAndPersonalMultiSlotMigration.register(on: &migrator)
        V015AddSuggestionScoreThresholdsMigration.register(on: &migrator)
        V016AddTagGroupsMigration.register(on: &migrator)
        V017PerTagPersonalSuggestionModelsMigration.register(on: &migrator)
        V018AddAssetSimilarityFingerprintMigration.register(on: &migrator)
        V019AddLibrarySlimmingRecycleMigration.register(on: &migrator)
        V020HardenLibrarySlimmingRecycleMigration.register(on: &migrator)
        V021AddPhotosRecycleIdentifierMigration.register(on: &migrator)
        V022HardenLibrarySlimmingAnalysisMigration.register(on: &migrator)
        V023AddSourceSimilarityIndexMigration.register(on: &migrator)
        V024RepairSourceMutationAuthorizationMigration.register(on: &migrator)
        V025RetainPurgedAssetKnowledgeMigration.register(on: &migrator)
        V026AddMediaKindAndVideoMetadataMigration.register(on: &migrator)
        V027PartitionPersonalizationByMediaKindMigration.register(on: &migrator)
        V028PartitionSlimmingByMediaKindMigration.register(on: &migrator)
        V029AddOriginalAspectThumbnailCacheMigration.register(on: &migrator)
        V030AddSimilarityDigestProvenanceMigration.register(on: &migrator)
        V031AddAssetLocationMigration.register(on: &migrator)
        V032AddPlaceTagResolutionMigration.register(on: &migrator)
        V033AddSlimmingClusterReviewQueueMigration.register(on: &migrator)
        V034BackfillSlimmingConfirmedHistoryMigration.register(on: &migrator)
        V035AddAssetFavoriteStateMigration.register(on: &migrator)
        return migrator
    }

    static func open(at url: URL) throws -> CatalogDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: url.path, configuration: config)
        let database = CatalogDatabase(pool: pool)
        try database.migrate()
        try database.validateQuickCheck()
        return database
    }

    func migrate() throws {
        try pool.write { db in
            try Self.validateAppliedMigrations(db)
        }

        let migrator = Self.makeMigrator()
        try migrator.migrate(pool)

        try pool.write { db in
            try Self.validateAppliedMigrations(db)
        }
    }

    func validateQuickCheck() throws {
        try pool.read { db in
            let results = try String.fetchAll(db, sql: "PRAGMA quick_check")
            guard results == ["ok"] else {
                throw CatalogDatabaseError.integrityCheckFailed
            }
        }
    }

    static func validateAppliedMigrations(_ db: Database) throws {
        guard try db.tableExists("grdb_migrations") else {
            return
        }

        let applied = try String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
        )
        let known = CatalogMigrationID.knownOrdered
        let knownSet = Set(known)
        let appliedSet = Set(applied)

        let unknown = applied.filter { !knownSet.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw CatalogDatabaseError.futureSchema(applied: applied.sorted(), unknown: unknown)
        }

        let expectedPrefix = Set(known.prefix(applied.count))
        if appliedSet != expectedPrefix {
            throw CatalogDatabaseError.futureSchema(applied: applied.sorted(), unknown: unknown)
        }
    }

    func appliedMigrationIDs() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    func catalogScopeID() throws -> String {
        try pool.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: "SELECT scope_id FROM catalog_scope WHERE singleton = 1"
            ),
                let uuid = UUID(uuidString: value),
                value == uuid.uuidString.lowercased()
            else {
                throw CatalogDatabaseError.invalidCatalogScopeIdentity
            }
            return value
        }
    }

    func journalMode() throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    func foreignKeysEnabled() throws -> Bool {
        try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1
        }
    }

    /// Caller must stop scheduling and hold exclusive catalog access before calling.
    func checkpointAndCloseForReplacement() throws {
        try Self.checkpointAndClose(pool: pool, databaseURL: URL(fileURLWithPath: pool.path))
    }

    static func checkpointAndClose(pool: DatabasePool, databaseURL: URL) throws {
        try pool.barrierWriteWithoutTransaction { db in
            try performTruncateCheckpoint(db)
        }
        try closePool(pool)
        try convergeClosedDatabaseFileToDelete(at: databaseURL)
    }

    static func convergeClosedDatabaseFileToDelete(at url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
        var closed = false
        do {
            try queue.writeWithoutTransaction { db in
                try requireDeleteJournalMode(db, setDelete: true)
            }
            try queue.read { db in
                try performQuickCheck(on: db)
            }
        } catch let error as CatalogSnapshotError {
            try closeQueueOnce(queue, closed: &closed)
            throw error
        } catch {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
        try closeQueueOnce(queue, closed: &closed)
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: url)
    }

    static func performTruncateCheckpoint(_ db: Database) throws {
        do {
            let result = try db.checkpoint(.truncate)
            if result.walFrameCount < 0 {
                return
            }
            guard result.walFrameCount == result.checkpointedFrameCount else {
                throw CatalogSnapshotError.checkpointFailed
            }
            guard result.walFrameCount == 0 else {
                throw CatalogSnapshotError.checkpointFailed
            }
        } catch let error as CatalogSnapshotError {
            throw error
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
            throw CatalogSnapshotError.checkpointFailed
        } catch is DatabaseError {
            throw CatalogSnapshotError.checkpointFailed
        }
    }

    static func closePool(_ pool: DatabasePool) throws {
        do {
            try pool.close()
        } catch {
            throw CatalogSnapshotError.closeFailed
        }
    }

    static func closeQueue(_ queue: DatabaseQueue) throws {
        do {
            try queue.close()
        } catch {
            throw CatalogSnapshotError.closeFailed
        }
    }

    private static func closeQueueOnce(_ queue: DatabaseQueue, closed: inout Bool) throws {
        guard !closed else { return }
        try closeQueue(queue)
        closed = true
    }

    static func readAppliedMigrationIDs(from db: Database) throws -> [String] {
        guard try db.tableExists("grdb_migrations") else {
            return []
        }
        return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }

    static func performQuickCheck(on db: Database) throws {
        let results = try String.fetchAll(db, sql: "PRAGMA quick_check")
        guard results == ["ok"] else {
            throw CatalogSnapshotError.integrityCheckFailed
        }
    }

    static func requireDeleteJournalMode(_ db: Database, setDelete: Bool) throws {
        let mode: String
        do {
            if setDelete {
                mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") ?? ""
            } else {
                mode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
            }
        } catch is DatabaseError {
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
        guard mode.lowercased() == "delete" else {
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
    }

    static func convergeToDeleteJournalOnQueue(_ queue: DatabaseQueue, recheckQuickCheck: Bool) throws {
        try queue.writeWithoutTransaction { db in
            try performTruncateCheckpoint(db)
            try requireDeleteJournalMode(db, setDelete: true)
        }
        if recheckQuickCheck {
            try queue.read { db in
                try performQuickCheck(on: db)
            }
        }
    }

    static func withReadonlyQueue<T>(at url: URL, _ body: (Database) throws -> T) throws -> T {
        var config = Configuration()
        config.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw CatalogSnapshotError.integrityCheckFailed
        }
        var closed = false
        let value: T
        do {
            value = try queue.read { db in
                try body(db)
            }
        } catch let error as CatalogDatabaseError {
            try closeQueueOnce(queue, closed: &closed)
            if case let .futureSchema(applied, unknown) = error {
                throw CatalogSnapshotError.futureMigrationHistory(applied: applied, unknown: unknown)
            }
            throw CatalogSnapshotError.integrityCheckFailed
        } catch let error as CatalogSnapshotError {
            try closeQueueOnce(queue, closed: &closed)
            throw error
        } catch {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.integrityCheckFailed
        }
        try closeQueueOnce(queue, closed: &closed)
        return value
    }

    static func prepareWorkCopyForReplacement(
        at url: URL,
        expectedManifestMigrations: [String],
        runMigration: Bool
    ) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw CatalogSnapshotError.candidatePreparationFailed
        }
        var closed = false
        do {
            let initialMigrations = try queue.read { db -> [String] in
                try performQuickCheck(on: db)
                try validateAppliedMigrations(db)
                return try readAppliedMigrationIDs(from: db)
            }

            try CatalogSnapshotManifestValidator.validateMigrationHistoryMatchesDatabase(
                manifestMigrations: expectedManifestMigrations,
                databaseMigrations: initialMigrations
            )

            if runMigration {
                let migrator = makeMigrator()
                try migrator.migrate(queue)
            }

            try queue.read { db in
                try performQuickCheck(on: db)
                try validateAppliedMigrations(db)
                let applied = try readAppliedMigrationIDs(from: db)
                guard applied == CatalogMigrationID.knownOrdered else {
                    throw CatalogSnapshotError.invalidMigrationHistory
                }
                guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                    throw CatalogSnapshotError.integrityCheckFailed
                }
            }

            try convergeToDeleteJournalOnQueue(queue, recheckQuickCheck: true)
        } catch let error as CatalogDatabaseError {
            try closeQueueOnce(queue, closed: &closed)
            if case let .futureSchema(applied, unknown) = error {
                throw CatalogSnapshotError.futureMigrationHistory(applied: applied, unknown: unknown)
            }
            throw CatalogSnapshotError.candidatePreparationFailed
        } catch let error as CatalogSnapshotError {
            try closeQueueOnce(queue, closed: &closed)
            throw error
        } catch {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.candidatePreparationFailed
        }
        try closeQueueOnce(queue, closed: &closed)
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: url)
    }

    static func validateAndCloseReplacedDatabase(at url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw CatalogSnapshotError.postReplaceValidationFailed
        }
        var closed = false
        do {
            try queue.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                    throw CatalogSnapshotError.postReplaceValidationFailed
                }
                try performQuickCheck(on: db)
                try validateAppliedMigrations(db)
                let applied = try readAppliedMigrationIDs(from: db)
                guard applied == CatalogMigrationID.knownOrdered else {
                    throw CatalogSnapshotError.postReplaceValidationFailed
                }
            }
            try convergeToDeleteJournalOnQueue(queue, recheckQuickCheck: true)
        } catch let error as CatalogDatabaseError {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.postReplaceValidationFailed
        } catch is CatalogSnapshotError {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.postReplaceValidationFailed
        } catch {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.postReplaceValidationFailed
        }
        try closeQueueOnce(queue, closed: &closed)
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: url)
    }
}

enum V028PartitionSlimmingByMediaKindMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v028PartitionSlimmingByMediaKind) { db in
            try db.execute(sql: "ALTER TABLE source_similarity_bucket_member RENAME TO source_similarity_bucket_member_v027")
            try db.execute(sql: "ALTER TABLE source_similarity_index RENAME TO source_similarity_index_v027")

            try db.execute(
                sql: """
                CREATE TABLE source_similarity_index (
                    source_id TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    media_kind TEXT NOT NULL CHECK(media_kind IN ('image', 'video')),
                    state TEXT NOT NULL CHECK(state IN ('building','ready','stale','failed')),
                    policy_version TEXT NOT NULL,
                    feature_print_provider TEXT NOT NULL,
                    feature_print_request_revision INTEGER NOT NULL,
                    feature_print_preprocessing_revision INTEGER NOT NULL,
                    feature_print_max_l2 REAL NOT NULL,
                    lsh_bit_count INTEGER NOT NULL CHECK(lsh_bit_count BETWEEN 8 AND 64),
                    lsh_planes_json BLOB NOT NULL,
                    asset_count INTEGER NOT NULL CHECK(asset_count >= 0),
                    indexed_count INTEGER NOT NULL CHECK(indexed_count >= 0),
                    cluster_count INTEGER NOT NULL CHECK(cluster_count >= 0),
                    pending_count INTEGER NOT NULL CHECK(pending_count >= 0),
                    job_id TEXT REFERENCES job(id) ON DELETE SET NULL,
                    built_at_ms INTEGER,
                    updated_at_ms INTEGER NOT NULL,
                    last_error TEXT,
                    PRIMARY KEY(source_id, media_kind)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                INSERT INTO source_similarity_index (
                    source_id, media_kind, state, policy_version, feature_print_provider,
                    feature_print_request_revision, feature_print_preprocessing_revision,
                    feature_print_max_l2, lsh_bit_count, lsh_planes_json,
                    asset_count, indexed_count, cluster_count, pending_count,
                    job_id, built_at_ms, updated_at_ms, last_error
                )
                SELECT
                    source_id, 'image', state, policy_version, feature_print_provider,
                    feature_print_request_revision, feature_print_preprocessing_revision,
                    feature_print_max_l2, lsh_bit_count, lsh_planes_json,
                    asset_count, indexed_count, cluster_count, pending_count,
                    job_id, built_at_ms, updated_at_ms, last_error
                FROM source_similarity_index_v027
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE source_similarity_bucket_member (
                    source_id TEXT NOT NULL,
                    media_kind TEXT NOT NULL CHECK(media_kind IN ('image', 'video')),
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    content_revision INTEGER NOT NULL CHECK(content_revision >= 1),
                    bucket_key INTEGER NOT NULL,
                    cluster_id TEXT,
                    PRIMARY KEY(source_id, media_kind, asset_id),
                    FOREIGN KEY(source_id, media_kind)
                        REFERENCES source_similarity_index(source_id, media_kind)
                        ON DELETE CASCADE
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                INSERT INTO source_similarity_bucket_member (
                    source_id, media_kind, asset_id, content_revision, bucket_key, cluster_id
                )
                SELECT source_id, 'image', asset_id, content_revision, bucket_key, cluster_id
                FROM source_similarity_bucket_member_v027
                """
            )
            try db.execute(sql: "DROP TABLE source_similarity_bucket_member_v027")
            try db.execute(sql: "DROP TABLE source_similarity_index_v027")
            try db.execute(
                sql: """
                CREATE INDEX source_similarity_bucket_lookup_idx
                ON source_similarity_bucket_member(
                    source_id, media_kind, bucket_key, asset_id
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX source_similarity_cluster_lookup_idx
                ON source_similarity_bucket_member(
                    source_id, media_kind, cluster_id, asset_id
                )
                """
            )
        }
    }
}

enum V029AddOriginalAspectThumbnailCacheMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v029AddOriginalAspectThumbnailCache) { db in
            try db.execute(
                sql: "ALTER TABLE derived_image_cache_entry RENAME TO derived_image_cache_entry_v028"
            )
            try db.execute(
                sql: """
                CREATE TABLE derived_image_cache_entry (
                    id TEXT NOT NULL PRIMARY KEY,
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    content_revision INTEGER NOT NULL CHECK(content_revision >= 1),
                    representation_version INTEGER NOT NULL CHECK(representation_version >= 1),
                    variant TEXT NOT NULL CHECK(
                        variant IN ('gridSmall', 'gridRegular', 'gridOriginal', 'preview')
                    ),
                    storage_format TEXT NOT NULL CHECK(storage_format IN ('jpeg', 'png')),
                    pixel_width INTEGER NOT NULL CHECK(pixel_width > 0),
                    pixel_height INTEGER NOT NULL CHECK(pixel_height > 0),
                    byte_size INTEGER NOT NULL CHECK(byte_size > 0),
                    encoded_sha256 BLOB NOT NULL CHECK(length(encoded_sha256) = 32),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    last_accessed_at_ms INTEGER NOT NULL CHECK(last_accessed_at_ms >= 0),
                    CHECK(\(V001CreateCatalogCoreMigration.uuidCheck)),
                    CHECK(
                        (variant = 'gridSmall' AND pixel_width = 256 AND pixel_height = 256)
                        OR (variant = 'gridRegular' AND pixel_width = 512 AND pixel_height = 512)
                        OR (
                            variant = 'gridOriginal'
                            AND max(pixel_width, pixel_height) <= 512
                        )
                        OR (
                            variant = 'preview'
                            AND max(pixel_width, pixel_height) <= 2048
                        )
                    )
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                INSERT INTO derived_image_cache_entry (
                    id, asset_id, content_revision, representation_version, variant,
                    storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                    created_at_ms, last_accessed_at_ms
                )
                SELECT
                    id, asset_id, content_revision, representation_version, variant,
                    storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                    created_at_ms, last_accessed_at_ms
                FROM derived_image_cache_entry_v028
                """
            )
            try db.execute(sql: "DROP TABLE derived_image_cache_entry_v028")
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX derived_image_cache_key_uq ON derived_image_cache_entry (
                    asset_id,
                    content_revision,
                    representation_version,
                    variant
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX derived_image_cache_lru_idx ON derived_image_cache_entry (
                    last_accessed_at_ms,
                    id
                )
                """
            )
        }
    }
}

enum V030AddSimilarityDigestProvenanceMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v030AddSimilarityDigestProvenance) { db in
            try db.execute(
                sql: """
                ALTER TABLE asset_similarity_fingerprint
                ADD COLUMN content_digest_origin TEXT NOT NULL DEFAULT 'unverifiedLegacy'
                CHECK(
                    content_digest_origin IN (
                        'verifiedOriginalBytes',
                        'visualDerivative',
                        'unverifiedLegacy'
                    )
                )
                """
            )

            // Folder still-image digests were always computed from the opened
            // encoded source file, so their legacy provenance is recoverable.
            try db.execute(
                sql: """
                UPDATE asset_similarity_fingerprint
                SET content_digest_origin = 'verifiedOriginalBytes'
                WHERE content_sha256 IS NOT NULL
                  AND asset_id IN (
                    SELECT a.id
                    FROM asset a
                    JOIN source s ON s.id = a.source_id
                    WHERE a.locator_kind = 'file'
                      AND a.media_kind = 'image'
                      AND s.kind = 'folder'
                  )
                """
            )

            // A legacy Photos digest is deletion-grade only when the durable
            // original cache independently records the same encoded bytes.
            try db.execute(
                sql: """
                UPDATE asset_similarity_fingerprint
                SET content_digest_origin = 'verifiedOriginalBytes'
                WHERE content_sha256 IS NOT NULL
                  AND EXISTS (
                    SELECT 1
                    FROM asset a
                    JOIN photos_original_cache_entry c ON c.asset_id = a.id
                    WHERE a.id = asset_similarity_fingerprint.asset_id
                      AND a.locator_kind = 'photos'
                      AND a.media_kind = 'image'
                      AND c.content_revision = asset_similarity_fingerprint.content_revision
                      AND c.photos_local_identifier = a.photos_local_identifier
                      AND c.encoded_sha256 = asset_similarity_fingerprint.content_sha256
                  )
                """
            )

            // Everything else is conservatively retained for perceptual use
            // but cannot establish exact byte identity.
            try db.execute(
                sql: """
                UPDATE asset_similarity_fingerprint
                SET content_digest_origin = 'visualDerivative'
                WHERE content_digest_origin = 'unverifiedLegacy'
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX asset_similarity_fingerprint_exact_idx
                ON asset_similarity_fingerprint (
                    content_digest_origin, content_sha256, asset_id
                )
                """
            )
        }
    }
}

enum V031AddAssetLocationMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v031AddAssetLocation) { db in
            try db.execute(
                sql: """
                CREATE TABLE asset_location (
                    asset_id TEXT NOT NULL PRIMARY KEY
                        REFERENCES asset(id) ON DELETE CASCADE,
                    latitude REAL,
                    longitude REAL,
                    altitude_m REAL,
                    source_kind TEXT NOT NULL CHECK(
                        source_kind IN ('none', 'embeddedGPS', 'photosGPS', 'placeTag')
                    ),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
                    CHECK(
                        (
                            source_kind = 'none'
                            AND latitude IS NULL
                            AND longitude IS NULL
                            AND altitude_m IS NULL
                        )
                        OR (
                            source_kind != 'none'
                            AND latitude IS NOT NULL
                            AND longitude IS NOT NULL
                            AND latitude BETWEEN -90.0 AND 90.0
                            AND longitude BETWEEN -180.0 AND 180.0
                        )
                    )
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX asset_location_coordinate_idx
                ON asset_location(latitude, longitude, asset_id)
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                """
            )
        }
    }
}

enum V032AddPlaceTagResolutionMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v032AddPlaceTagResolution) { db in
            try db.execute(
                sql: """
                CREATE TABLE place (
                    id TEXT NOT NULL PRIMARY KEY CHECK(length(id) > 0),
                    canonical_name TEXT NOT NULL CHECK(length(canonical_name) > 0),
                    subtitle TEXT,
                    latitude REAL NOT NULL CHECK(latitude BETWEEN -90.0 AND 90.0),
                    longitude REAL NOT NULL CHECK(longitude BETWEEN -180.0 AND 180.0),
                    kind TEXT NOT NULL CHECK(kind IN ('poi', 'city', 'region', 'country')),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
                ) STRICT
                """
            )
            try db.execute(sql: "DROP INDEX asset_location_coordinate_idx")
            try db.execute(sql: "ALTER TABLE asset_location RENAME TO asset_location_pre_v032")
            try db.execute(
                sql: """
                CREATE TABLE asset_location (
                    asset_id TEXT NOT NULL PRIMARY KEY
                        REFERENCES asset(id) ON DELETE CASCADE,
                    latitude REAL,
                    longitude REAL,
                    altitude_m REAL,
                    source_kind TEXT NOT NULL CHECK(
                        source_kind IN ('none', 'embeddedGPS', 'photosGPS', 'placeTag')
                    ),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
                    place_id TEXT REFERENCES place(id) ON DELETE RESTRICT,
                    CHECK(
                        (
                            source_kind = 'none'
                            AND latitude IS NULL
                            AND longitude IS NULL
                            AND altitude_m IS NULL
                            AND place_id IS NULL
                        )
                        OR (
                            source_kind IN ('embeddedGPS', 'photosGPS')
                            AND latitude IS NOT NULL
                            AND longitude IS NOT NULL
                            AND latitude BETWEEN -90.0 AND 90.0
                            AND longitude BETWEEN -180.0 AND 180.0
                            AND place_id IS NULL
                        )
                        OR (
                            source_kind = 'placeTag'
                            AND latitude IS NOT NULL
                            AND longitude IS NOT NULL
                            AND latitude BETWEEN -90.0 AND 90.0
                            AND longitude BETWEEN -180.0 AND 180.0
                            AND place_id IS NOT NULL
                        )
                    )
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                INSERT INTO asset_location (
                    asset_id, latitude, longitude, altitude_m, source_kind,
                    updated_at_ms, place_id
                )
                SELECT
                    asset_id, latitude, longitude, altitude_m, source_kind,
                    updated_at_ms, NULL
                FROM asset_location_pre_v032
                """
            )
            try db.execute(sql: "DROP TABLE asset_location_pre_v032")
            try db.execute(
                sql: """
                CREATE INDEX asset_location_coordinate_idx
                ON asset_location(latitude, longitude, asset_id)
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE tag_place_binding (
                    tag_id TEXT NOT NULL PRIMARY KEY
                        REFERENCES tag(id) ON DELETE CASCADE,
                    place_id TEXT REFERENCES place(id) ON DELETE RESTRICT,
                    status TEXT NOT NULL CHECK(
                        status IN ('resolved', 'ambiguous', 'ignored', 'failed')
                    ),
                    resolver_version INTEGER NOT NULL CHECK(resolver_version >= 1),
                    resolved_at_ms INTEGER CHECK(resolved_at_ms IS NULL OR resolved_at_ms >= 0),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
                    CHECK(
                        (status = 'resolved' AND place_id IS NOT NULL AND resolved_at_ms IS NOT NULL)
                        OR (status != 'resolved' AND place_id IS NULL AND resolved_at_ms IS NULL)
                    )
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE tag_place_candidate (
                    tag_id TEXT NOT NULL
                        REFERENCES tag_place_binding(tag_id) ON DELETE CASCADE,
                    place_id TEXT NOT NULL REFERENCES place(id) ON DELETE RESTRICT,
                    rank INTEGER NOT NULL CHECK(rank >= 0),
                    PRIMARY KEY (tag_id, place_id),
                    UNIQUE (tag_id, rank)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX tag_place_binding_status_idx
                ON tag_place_binding(status, tag_id)
                """
            )
        }
    }
}

enum V033AddSlimmingClusterReviewQueueMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v033AddSlimmingClusterReviewQueue) { db in
            try db.execute(
                sql: """
                CREATE TABLE library_slimming_cluster_review (
                    job_id TEXT NOT NULL REFERENCES job(id) ON DELETE CASCADE,
                    cluster_id TEXT NOT NULL,
                    disposition TEXT NOT NULL CHECK(
                        disposition IN ('confirmed', 'ignored')
                    ),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
                    PRIMARY KEY (job_id, cluster_id)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX library_slimming_cluster_review_queue_idx
                ON library_slimming_cluster_review(disposition, updated_at_ms DESC, job_id, cluster_id)
                """
            )
        }
    }
}

/// Projects pre-review-queue user handling into the new confirmed queue.
///
/// A cluster is backfilled only when one of its persisted members has a
/// non-failed recycle lifecycle created after that analysis result was saved
/// and fewer than two members remain viewable. Existing explicit review state
/// always wins via `INSERT OR IGNORE`.
enum V034BackfillSlimmingConfirmedHistoryMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v034BackfillSlimmingConfirmedHistory) { db in
            let resultRows = try Row.fetchAll(
                db,
                sql: """
                SELECT result.job_id, result.result_json, result.updated_at_ms
                FROM library_slimming_scan_result AS result
                JOIN job ON job.id = result.job_id
                WHERE job.kind = ?
                ORDER BY result.job_id
                """,
                arguments: [LibrarySlimmingAnalysisJobFactory.kind]
            )
            let decoder = JSONDecoder()
            let handledRows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_id, created_at_ms, updated_at_ms
                FROM recycle_entry
                WHERE asset_id IS NOT NULL
                  AND state IN (
                      'pending', 'recycled', 'restoring', 'purging',
                      'restored', 'purged'
                  )
                ORDER BY asset_id, created_at_ms
                """
            )
            var handledLifecyclesByAssetID:
                [UUID: [(createdAtMs: Int64, updatedAtMs: Int64)]] = [:]
            for handledRow in handledRows {
                let rawAssetID: String = handledRow["asset_id"]
                guard let assetID = UUID(uuidString: rawAssetID) else { continue }
                handledLifecyclesByAssetID[assetID, default: []].append(
                    (
                        createdAtMs: handledRow["created_at_ms"],
                        updatedAtMs: handledRow["updated_at_ms"]
                    )
                )
            }

            for resultRow in resultRows {
                let rawJobID: String = resultRow["job_id"]
                let resultData: Data = resultRow["result_json"]
                let resultUpdatedAtMs: Int64 = resultRow["updated_at_ms"]
                // Scan results are derived data. A malformed legacy blob must
                // not prevent the catalog from opening; it simply cannot prove
                // a historical review decision.
                guard let result = try? decoder.decode(
                    LibrarySlimmingScanResult.self,
                    from: resultData
                ) else { continue }

                var handledAtByAssetID: [UUID: Int64] = [:]
                let resultMemberIDs = Set(result.clusters.flatMap(\.memberAssetIDs))
                for assetID in resultMemberIDs {
                    let handledAtMs = handledLifecyclesByAssetID[assetID]?.lazy
                        .filter { $0.createdAtMs >= resultUpdatedAtMs }
                        .map { $0.updatedAtMs }
                        .max()
                    if let handledAtMs {
                        handledAtByAssetID[assetID] = handledAtMs
                    }
                }
                guard !handledAtByAssetID.isEmpty else { continue }

                let viewableRows = try String.fetchAll(
                    db,
                    sql: """
                    SELECT member.asset_id
                    FROM library_slimming_scan_member AS member
                    JOIN asset ON asset.id = member.asset_id
                    WHERE member.job_id = ?
                      AND asset.availability != 'recycled'
                      AND NOT EXISTS (
                          SELECT 1
                          FROM recycle_entry AS active_recycle
                          WHERE active_recycle.asset_id = member.asset_id
                            AND active_recycle.state IN ('pending', 'recycled')
                      )
                    """,
                    arguments: [rawJobID]
                )
                let viewableAssetIDs = Set(viewableRows.compactMap(UUID.init(uuidString:)))

                for cluster in result.clusters {
                    let handledAtMs = cluster.memberAssetIDs.compactMap {
                        handledAtByAssetID[$0]
                    }.max()
                    guard let handledAtMs else { continue }
                    let currentViewableCount = cluster.memberAssetIDs.lazy.filter {
                        viewableAssetIDs.contains($0)
                    }.count
                    // Partial cleanup that still leaves a duplicate group is
                    // still actionable and must remain pending. The backfill is
                    // for groups the old UI already considered handled and hid.
                    guard currentViewableCount < 2 else { continue }
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO library_slimming_cluster_review (
                            job_id, cluster_id, disposition, updated_at_ms
                        ) VALUES (?, ?, 'confirmed', ?)
                        """,
                        arguments: [
                            rawJobID,
                            cluster.id.uuidString.lowercased(),
                            handledAtMs,
                        ]
                    )
                }
            }
        }
    }
}

enum V035AddAssetFavoriteStateMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v035AddAssetFavoriteState) { db in
            try db.execute(
                sql: """
                CREATE TABLE asset_favorite_state (
                    asset_id TEXT NOT NULL PRIMARY KEY
                        REFERENCES asset(id) ON DELETE CASCADE,
                    desired_value INTEGER NOT NULL
                        CHECK(desired_value IN (0, 1)),
                    photos_observed_value INTEGER
                        CHECK(photos_observed_value IS NULL OR photos_observed_value IN (0, 1)),
                    sync_status TEXT NOT NULL
                        CHECK(sync_status IN ('localOnly', 'synced', 'pending', 'failed')),
                    intent_revision INTEGER NOT NULL DEFAULT 0
                        CHECK(intent_revision >= 0),
                    requested_at_ms INTEGER NOT NULL
                        CHECK(requested_at_ms >= 0),
                    photos_observed_modified_at_ms INTEGER
                        CHECK(
                            photos_observed_modified_at_ms IS NULL
                            OR photos_observed_modified_at_ms >= 0
                        ),
                    photos_write_modified_at_ms INTEGER
                        CHECK(
                            photos_write_modified_at_ms IS NULL
                            OR photos_write_modified_at_ms >= 0
                        ),
                    last_error_code TEXT
                        CHECK(last_error_code IS NULL OR length(last_error_code) > 0),
                    updated_at_ms INTEGER NOT NULL
                        CHECK(updated_at_ms >= 0)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX asset_favorite_state_favorite_idx
                ON asset_favorite_state(asset_id)
                WHERE desired_value = 1 OR photos_observed_value = 1
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX asset_favorite_state_pending_idx
                ON asset_favorite_state(sync_status, requested_at_ms, asset_id)
                WHERE sync_status IN ('pending', 'failed')
                """
            )
        }
    }
}

enum V005AddCatalogScaleIndexesMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v005AddCatalogScaleIndexes) { db in
            for statement in indexStatements {
                try db.execute(sql: statement)
            }
        }
    }

    private static let timeEmptyMarkerExpression =
        V002AddStage1CatalogQuerySupportMigration.timeEmptyMarkerExpression
    private static let coalescedMediaTimeExpression =
        V002AddStage1CatalogQuerySupportMigration.coalescedMediaTimeExpression

    private static let indexStatements = [
        """
        CREATE INDEX asset_current_time_desc_idx ON asset (
            \(timeEmptyMarkerExpression),
            \(coalescedMediaTimeExpression) DESC,
            id DESC
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_source_media_time_desc_idx ON asset (
            source_id,
            media_type,
            \(timeEmptyMarkerExpression),
            \(coalescedMediaTimeExpression) DESC,
            id DESC
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_file_name_all_idx ON asset (
            (CASE WHEN file_name IS NOT NULL THEN 0 ELSE 1 END),
            file_name COLLATE NOCASE,
            id
        ) WHERE locator_state = 'current'
        """,
    ]
}

enum V006AddAssetTextSearchMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v006AddAssetTextSearch) { db in
            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE asset_search USING fts5(
                    file_name,
                    relative_path,
                    content = 'asset',
                    content_rowid = 'rowid',
                    tokenize = 'trigram'
                )
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER asset_search_after_insert
                AFTER INSERT ON asset
                BEGIN
                    INSERT INTO asset_search(rowid, file_name, relative_path)
                    VALUES (new.rowid, new.file_name, new.relative_path);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER asset_search_after_delete
                AFTER DELETE ON asset
                BEGIN
                    INSERT INTO asset_search(asset_search, rowid, file_name, relative_path)
                    VALUES ('delete', old.rowid, old.file_name, old.relative_path);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER asset_search_after_update
                AFTER UPDATE OF file_name, relative_path ON asset
                BEGIN
                    INSERT INTO asset_search(asset_search, rowid, file_name, relative_path)
                    VALUES ('delete', old.rowid, old.file_name, old.relative_path);
                    INSERT INTO asset_search(rowid, file_name, relative_path)
                    VALUES (new.rowid, new.file_name, new.relative_path);
                END
                """
            )
            try db.execute(sql: "INSERT INTO asset_search(asset_search) VALUES ('rebuild')")
        }
    }
}

enum V007AddCatalogScopeIdentityMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v007AddCatalogScopeIdentity) { db in
            try db.execute(
                sql: """
                CREATE TABLE catalog_scope (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    scope_id TEXT NOT NULL UNIQUE
                ) STRICT
                """
            )
            try db.execute(
                sql: "INSERT INTO catalog_scope (singleton, scope_id) VALUES (1, ?)",
                arguments: [UUID().uuidString.lowercased()]
            )
        }
    }
}

enum V008AddPersonalModelSuggestionsMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v008AddPersonalModelSuggestions) { db in
            try db.execute(
                sql: """
                CREATE TABLE personal_suggestion_model (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    catalog_scope_id TEXT NOT NULL REFERENCES catalog_scope(scope_id) ON DELETE CASCADE,
                    bundle_id TEXT NOT NULL CHECK(length(bundle_id) BETWEEN 1 AND 200),
                    bundle_revision TEXT NOT NULL CHECK(length(bundle_revision) BETWEEN 1 AND 200),
                    provider TEXT NOT NULL CHECK(length(provider) BETWEEN 1 AND 200),
                    model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 300),
                    model_revision TEXT NOT NULL CHECK(length(model_revision) BETWEEN 1 AND 200),
                    preprocessing_revision TEXT NOT NULL CHECK(length(preprocessing_revision) BETWEEN 1 AND 200),
                    element_count INTEGER NOT NULL CHECK(element_count > 0),
                    label_vocabulary_revision TEXT NOT NULL CHECK(
                        length(label_vocabulary_revision) = 64
                        AND label_vocabulary_revision NOT GLOB '*[^0-9a-f]*'
                    ),
                    weights_sha256 TEXT NOT NULL CHECK(
                        length(weights_sha256) = 64
                        AND weights_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    policy_revision TEXT NOT NULL CHECK(length(policy_revision) BETWEEN 1 AND 200),
                    activated_at_ms INTEGER NOT NULL CHECK(activated_at_ms >= 0)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE personal_suggestion_tag (
                    tag_id TEXT PRIMARY KEY REFERENCES tag(id) ON DELETE CASCADE,
                    model_singleton INTEGER NOT NULL DEFAULT 1 CHECK(model_singleton = 1)
                        REFERENCES personal_suggestion_model(singleton) ON DELETE CASCADE
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE personal_prediction (
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES personal_suggestion_tag(tag_id) ON DELETE CASCADE,
                    content_revision INTEGER NOT NULL CHECK(content_revision > 0),
                    score REAL NOT NULL CHECK(
                        typeof(score) IN ('real', 'integer')
                        AND score = score
                        AND score BETWEEN -1.0e308 AND 1.0e308
                    ),
                    state TEXT NOT NULL CHECK(state = 'pendingReview'),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    PRIMARY KEY(asset_id, tag_id, content_revision)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX personal_prediction_review_rank_idx ON personal_prediction (
                    tag_id,
                    state,
                    score DESC,
                    asset_id
                )
                """
            )
        }
    }
}

enum V009AddStandardOntologyMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v009AddStandardOntology) { db in
            try db.execute(
                sql: """
                CREATE TABLE ontology_pack (
                    standard_pack_id TEXT NOT NULL CHECK(length(standard_pack_id) BETWEEN 1 AND 200),
                    standard_pack_revision TEXT NOT NULL CHECK(length(standard_pack_revision) BETWEEN 1 AND 200),
                    ontology_id TEXT NOT NULL CHECK(length(ontology_id) BETWEEN 1 AND 200),
                    ontology_revision TEXT NOT NULL CHECK(length(ontology_revision) BETWEEN 1 AND 200),
                    locale_revision TEXT NOT NULL CHECK(length(locale_revision) BETWEEN 1 AND 200),
                    manifest_sha256 TEXT NOT NULL CHECK(
                        length(manifest_sha256) = 64
                        AND manifest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    state TEXT NOT NULL DEFAULT 'active' CHECK(state = 'active'),
                    installed_at_ms INTEGER NOT NULL CHECK(installed_at_ms >= 0),
                    PRIMARY KEY(standard_pack_id, standard_pack_revision),
                    UNIQUE(ontology_id, ontology_revision)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE ontology_concept (
                    ontology_id TEXT NOT NULL,
                    ontology_revision TEXT NOT NULL,
                    concept_id TEXT NOT NULL CHECK(length(concept_id) BETWEEN 1 AND 300),
                    canonical_name TEXT NOT NULL CHECK(length(canonical_name) BETWEEN 1 AND 200),
                    normalized_name TEXT NOT NULL CHECK(length(normalized_name) BETWEEN 1 AND 200),
                    PRIMARY KEY(ontology_id, ontology_revision, concept_id),
                    FOREIGN KEY(ontology_id, ontology_revision)
                        REFERENCES ontology_pack(ontology_id, ontology_revision) ON DELETE RESTRICT
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE ontology_edge (
                    ontology_id TEXT NOT NULL,
                    ontology_revision TEXT NOT NULL,
                    parent_concept_id TEXT NOT NULL,
                    child_concept_id TEXT NOT NULL,
                    CHECK(parent_concept_id <> child_concept_id),
                    PRIMARY KEY(ontology_id, ontology_revision, parent_concept_id, child_concept_id),
                    FOREIGN KEY(ontology_id, ontology_revision, parent_concept_id)
                        REFERENCES ontology_concept(ontology_id, ontology_revision, concept_id) ON DELETE RESTRICT,
                    FOREIGN KEY(ontology_id, ontology_revision, child_concept_id)
                        REFERENCES ontology_concept(ontology_id, ontology_revision, concept_id) ON DELETE RESTRICT
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE standard_model_revision (
                    standard_pack_id TEXT NOT NULL,
                    standard_pack_revision TEXT NOT NULL,
                    provider TEXT NOT NULL CHECK(length(provider) BETWEEN 1 AND 200),
                    model_revision TEXT NOT NULL CHECK(length(model_revision) BETWEEN 1 AND 200),
                    preprocessing_revision TEXT NOT NULL CHECK(length(preprocessing_revision) BETWEEN 1 AND 200),
                    mapping_revision TEXT NOT NULL CHECK(length(mapping_revision) BETWEEN 1 AND 200),
                    policy_revision TEXT NOT NULL CHECK(length(policy_revision) BETWEEN 1 AND 200),
                    weights_sha256 TEXT NOT NULL CHECK(
                        length(weights_sha256) = 64
                        AND weights_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    PRIMARY KEY(standard_pack_id, standard_pack_revision),
                    FOREIGN KEY(standard_pack_id, standard_pack_revision)
                        REFERENCES ontology_pack(standard_pack_id, standard_pack_revision) ON DELETE RESTRICT
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE standard_tag_binding (
                    tag_id TEXT NOT NULL PRIMARY KEY
                        REFERENCES tag(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
                    ontology_id TEXT NOT NULL,
                    ontology_revision TEXT NOT NULL,
                    concept_id TEXT NOT NULL,
                    UNIQUE(ontology_id, concept_id),
                    FOREIGN KEY(ontology_id, ontology_revision, concept_id)
                        REFERENCES ontology_concept(ontology_id, ontology_revision, concept_id) ON DELETE RESTRICT
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER personal_tag_model_before_insert
                BEFORE INSERT ON tag_model_revision
                WHEN EXISTS (SELECT 1 FROM standard_tag_binding WHERE tag_id = NEW.tag_id)
                BEGIN
                    SELECT RAISE(ABORT, 'personal model requires personal tag');
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER personal_suggestion_tag_before_insert
                BEFORE INSERT ON personal_suggestion_tag
                WHEN EXISTS (SELECT 1 FROM standard_tag_binding WHERE tag_id = NEW.tag_id)
                BEGIN
                    SELECT RAISE(ABORT, 'personal suggestion requires personal tag');
                END
                """
            )
        }
    }
}

enum V010AddStandardPredictionsMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v010AddStandardPredictions) { db in
            try db.execute(
                sql: """
                CREATE TABLE standard_prediction (
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES standard_tag_binding(tag_id) ON DELETE CASCADE,
                    content_revision INTEGER NOT NULL CHECK(content_revision > 0),
                    standard_pack_id TEXT NOT NULL,
                    standard_pack_revision TEXT NOT NULL,
                    score REAL NOT NULL CHECK(
                        typeof(score) IN ('real', 'integer')
                        AND score = score
                        AND score BETWEEN -1.0e308 AND 1.0e308
                    ),
                    recommended_state TEXT NOT NULL
                        CHECK(recommended_state IN ('suggested', 'autoAssigned')),
                    state TEXT NOT NULL CHECK(state = 'pendingReview'),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    PRIMARY KEY(asset_id, tag_id, content_revision),
                    FOREIGN KEY(standard_pack_id, standard_pack_revision)
                        REFERENCES standard_model_revision(
                            standard_pack_id, standard_pack_revision
                        ) ON DELETE CASCADE
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX standard_prediction_review_rank_idx ON standard_prediction (
                    tag_id,
                    state,
                    score DESC,
                    asset_id
                )
                """
            )
        }
    }
}

enum V011AddStandardPredictionProvenanceMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v011AddStandardPredictionProvenance) { db in
            try db.execute(
                sql: """
                ALTER TABLE standard_prediction
                ADD COLUMN derived_from_concept_id TEXT
                    CHECK(
                        derived_from_concept_id IS NULL
                        OR length(derived_from_concept_id) > 0
                    )
                """
            )
        }
    }
}

enum V012RepairStandardTagBindingMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v012RepairStandardTagBinding) { db in
            // Some production catalogs recorded v009–v011 without creating
            // `standard_tag_binding`. Tag list/create JOINs require the table.
            guard try !db.tableExists("standard_tag_binding") else { return }
            try db.execute(
                sql: """
                CREATE TABLE standard_tag_binding (
                    tag_id TEXT NOT NULL PRIMARY KEY
                        REFERENCES tag(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
                    ontology_id TEXT NOT NULL,
                    ontology_revision TEXT NOT NULL,
                    concept_id TEXT NOT NULL,
                    UNIQUE(ontology_id, concept_id),
                    FOREIGN KEY(ontology_id, ontology_revision, concept_id)
                        REFERENCES ontology_concept(ontology_id, ontology_revision, concept_id) ON DELETE RESTRICT
                ) STRICT
                """
            )
        }
    }
}

enum V013PhotosMissingAssetRepairMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v013PhotosMissingAssetRepair) { db in
            // One-time upgrade repair: restore assets previously marked missing by
            // incremental false-deletes. The next Photos reconcile job performs full
            // generation because sync_cursor is cleared.
            try db.execute(
                sql: """
                UPDATE source
                SET sync_cursor = NULL
                WHERE kind = 'photos' AND state = 'active'
                """
            )
        }
    }
}

enum V014AddTrainingRunsAndPersonalMultiSlotMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v014AddTrainingRunsAndPersonalMultiSlot) { db in
            // Idempotent for repair-style replay of earlier migrations that must
            // clear this id while the multi-slot schema is already present.
            let modelColumns = try db.columns(in: "personal_suggestion_model").map(\.name)
            if modelColumns.contains("method"), try db.tableExists("training_run") {
                return
            }
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: """
                CREATE TABLE training_run (
                    id TEXT PRIMARY KEY CHECK(
                        length(id) = 36 AND id GLOB '*-*-*-*-*'
                    ),
                    method TEXT NOT NULL CHECK(
                        method IN ('featureKnn', 'personalCentroid', 'personalAdamW')
                    ),
                    state TEXT NOT NULL CHECK(
                        state IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')
                    ),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    started_at_ms INTEGER CHECK(started_at_ms IS NULL OR started_at_ms >= 0),
                    finished_at_ms INTEGER CHECK(finished_at_ms IS NULL OR finished_at_ms >= 0),
                    catalog_scope_id TEXT NOT NULL
                        REFERENCES catalog_scope(scope_id) ON DELETE CASCADE,
                    job_id TEXT REFERENCES job(id) ON DELETE SET NULL,
                    sample_summary_json TEXT NOT NULL DEFAULT '{}' CHECK(
                        length(sample_summary_json) BETWEEN 2 AND 100000
                    ),
                    sample_manifest_sha256 TEXT CHECK(
                        sample_manifest_sha256 IS NULL
                        OR (
                            length(sample_manifest_sha256) = 64
                            AND sample_manifest_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    config_json TEXT NOT NULL DEFAULT '{}' CHECK(
                        length(config_json) BETWEEN 2 AND 100000
                    ),
                    metrics_json TEXT NOT NULL DEFAULT '{}' CHECK(
                        length(metrics_json) BETWEEN 2 AND 5000000
                    ),
                    artifact_kind TEXT CHECK(
                        artifact_kind IS NULL OR length(artifact_kind) BETWEEN 1 AND 200
                    ),
                    artifact_ref TEXT CHECK(
                        artifact_ref IS NULL OR length(artifact_ref) BETWEEN 1 AND 1000
                    ),
                    artifact_sha256 TEXT CHECK(
                        artifact_sha256 IS NULL
                        OR (
                            length(artifact_sha256) = 64
                            AND artifact_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    result_summary_json TEXT NOT NULL DEFAULT '{}' CHECK(
                        length(result_summary_json) BETWEEN 2 AND 100000
                    ),
                    error_code TEXT CHECK(
                        error_code IS NULL OR length(error_code) BETWEEN 1 AND 200
                    ),
                    CHECK(
                        (state IN ('queued', 'running') AND finished_at_ms IS NULL)
                        OR (state IN ('succeeded', 'failed', 'cancelled')
                            AND finished_at_ms IS NOT NULL)
                    )
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX training_run_method_created_idx ON training_run (
                    method,
                    created_at_ms DESC
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX training_run_state_created_idx ON training_run (
                    state,
                    created_at_ms DESC
                )
                """
            )

            try db.execute(
                sql: "ALTER TABLE personal_suggestion_model RENAME TO personal_suggestion_model_v008"
            )
            try db.execute(
                sql: "ALTER TABLE personal_suggestion_tag RENAME TO personal_suggestion_tag_v008"
            )
            try db.execute(
                sql: "ALTER TABLE personal_prediction RENAME TO personal_prediction_v008"
            )
            try db.execute(sql: "DROP TRIGGER IF EXISTS personal_suggestion_tag_before_insert")

            try db.execute(
                sql: """
                CREATE TABLE personal_suggestion_model (
                    method TEXT PRIMARY KEY CHECK(
                        method IN ('personalCentroid', 'personalAdamW')
                    ),
                    catalog_scope_id TEXT NOT NULL
                        REFERENCES catalog_scope(scope_id) ON DELETE CASCADE,
                    bundle_id TEXT NOT NULL CHECK(length(bundle_id) BETWEEN 1 AND 200),
                    bundle_revision TEXT NOT NULL CHECK(length(bundle_revision) BETWEEN 1 AND 200),
                    provider TEXT NOT NULL CHECK(length(provider) BETWEEN 1 AND 200),
                    model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 300),
                    model_revision TEXT NOT NULL CHECK(length(model_revision) BETWEEN 1 AND 200),
                    preprocessing_revision TEXT NOT NULL
                        CHECK(length(preprocessing_revision) BETWEEN 1 AND 200),
                    element_count INTEGER NOT NULL CHECK(element_count > 0),
                    label_vocabulary_revision TEXT NOT NULL CHECK(
                        length(label_vocabulary_revision) = 64
                        AND label_vocabulary_revision NOT GLOB '*[^0-9a-f]*'
                    ),
                    weights_sha256 TEXT NOT NULL CHECK(
                        length(weights_sha256) = 64
                        AND weights_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    policy_revision TEXT NOT NULL CHECK(length(policy_revision) BETWEEN 1 AND 200),
                    activated_at_ms INTEGER NOT NULL CHECK(activated_at_ms >= 0),
                    published_run_id TEXT REFERENCES training_run(id) ON DELETE SET NULL
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE personal_suggestion_tag (
                    method TEXT NOT NULL REFERENCES personal_suggestion_model(method)
                        ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    PRIMARY KEY(method, tag_id)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE personal_prediction (
                    method TEXT NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL,
                    content_revision INTEGER NOT NULL CHECK(content_revision > 0),
                    score REAL NOT NULL CHECK(
                        typeof(score) IN ('real', 'integer')
                        AND score = score
                        AND score BETWEEN -1.0e308 AND 1.0e308
                    ),
                    state TEXT NOT NULL CHECK(state = 'pendingReview'),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    PRIMARY KEY(method, asset_id, tag_id, content_revision),
                    FOREIGN KEY(method, tag_id)
                        REFERENCES personal_suggestion_tag(method, tag_id) ON DELETE CASCADE
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_model (
                    method, catalog_scope_id, bundle_id, bundle_revision, provider, model_id,
                    model_revision, preprocessing_revision, element_count,
                    label_vocabulary_revision, weights_sha256, policy_revision,
                    activated_at_ms, published_run_id
                )
                SELECT
                    CASE
                        WHEN bundle_id = 'app.personal.adamw-head.v1' THEN 'personalAdamW'
                        ELSE 'personalCentroid'
                    END,
                    catalog_scope_id, bundle_id, bundle_revision, provider, model_id,
                    model_revision, preprocessing_revision, element_count,
                    label_vocabulary_revision, weights_sha256, policy_revision,
                    activated_at_ms, NULL
                FROM personal_suggestion_model_v008
                """
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_tag (method, tag_id)
                SELECT m.method, t.tag_id
                FROM personal_suggestion_tag_v008 t
                JOIN personal_suggestion_model m ON 1 = 1
                """
            )
            try db.execute(
                sql: """
                INSERT INTO personal_prediction (
                    method, asset_id, tag_id, content_revision, score, state, created_at_ms
                )
                SELECT m.method, p.asset_id, p.tag_id, p.content_revision, p.score, p.state,
                    p.created_at_ms
                FROM personal_prediction_v008 p
                JOIN personal_suggestion_model m ON 1 = 1
                """
            )
            try db.execute(sql: "DROP TABLE personal_prediction_v008")
            try db.execute(sql: "DROP TABLE personal_suggestion_tag_v008")
            try db.execute(sql: "DROP TABLE personal_suggestion_model_v008")
            try db.execute(
                sql: """
                CREATE INDEX personal_prediction_review_rank_idx ON personal_prediction (
                    method,
                    tag_id,
                    state,
                    score DESC,
                    asset_id
                )
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER personal_suggestion_tag_before_insert
                BEFORE INSERT ON personal_suggestion_tag
                WHEN EXISTS (SELECT 1 FROM standard_tag_binding WHERE tag_id = NEW.tag_id)
                BEGIN
                    SELECT RAISE(ABORT, 'personal suggestion requires personal tag');
                END
                """
            )
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }
}

enum V015AddSuggestionScoreThresholdsMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v015AddSuggestionScoreThresholds) { db in
            try db.execute(
                sql: """
                CREATE TABLE suggestion_score_threshold_default (
                    method TEXT PRIMARY KEY CHECK(
                        method IN ('featureKnn', 'personalCentroid', 'personalAdamW')
                    ),
                    min_score REAL NOT NULL,
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE suggestion_score_threshold_override (
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    method TEXT NOT NULL CHECK(
                        method IN ('featureKnn', 'personalCentroid', 'personalAdamW')
                    ),
                    min_score REAL NOT NULL,
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
                    PRIMARY KEY (tag_id, method)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                INSERT INTO suggestion_score_threshold_default (
                    method, min_score, updated_at_ms
                ) VALUES
                    ('featureKnn', 0, 0),
                    ('personalCentroid', 0, 0),
                    ('personalAdamW', 0, 0)
                """
            )
        }
    }
}

enum V017PerTagPersonalSuggestionModelsMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v017PerTagPersonalSuggestionModels) { db in
            let modelColumns = try db.columns(in: "personal_suggestion_model").map(\.name)
            if modelColumns.contains("tag_id") {
                return
            }

            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: "ALTER TABLE personal_suggestion_model RENAME TO personal_suggestion_model_v014"
            )
            try db.execute(
                sql: "ALTER TABLE personal_suggestion_tag RENAME TO personal_suggestion_tag_v014"
            )
            try db.execute(
                sql: "ALTER TABLE personal_prediction RENAME TO personal_prediction_v014"
            )
            try db.execute(sql: "DROP TRIGGER IF EXISTS personal_suggestion_tag_before_insert")
            try db.execute(sql: "DROP INDEX IF EXISTS personal_prediction_review_rank_idx")

            try db.execute(
                sql: """
                CREATE TABLE personal_suggestion_model (
                    method TEXT NOT NULL CHECK(
                        method IN ('personalCentroid', 'personalAdamW')
                    ),
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    catalog_scope_id TEXT NOT NULL
                        REFERENCES catalog_scope(scope_id) ON DELETE CASCADE,
                    bundle_id TEXT NOT NULL CHECK(length(bundle_id) BETWEEN 1 AND 200),
                    bundle_revision TEXT NOT NULL CHECK(length(bundle_revision) BETWEEN 1 AND 200),
                    provider TEXT NOT NULL CHECK(length(provider) BETWEEN 1 AND 200),
                    model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 300),
                    model_revision TEXT NOT NULL CHECK(length(model_revision) BETWEEN 1 AND 200),
                    preprocessing_revision TEXT NOT NULL
                        CHECK(length(preprocessing_revision) BETWEEN 1 AND 200),
                    element_count INTEGER NOT NULL CHECK(element_count > 0),
                    label_vocabulary_revision TEXT NOT NULL CHECK(
                        length(label_vocabulary_revision) = 64
                        AND label_vocabulary_revision NOT GLOB '*[^0-9a-f]*'
                    ),
                    weights_sha256 TEXT NOT NULL CHECK(
                        length(weights_sha256) = 64
                        AND weights_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    policy_revision TEXT NOT NULL CHECK(length(policy_revision) BETWEEN 1 AND 200),
                    activated_at_ms INTEGER NOT NULL CHECK(activated_at_ms >= 0),
                    published_run_id TEXT REFERENCES training_run(id) ON DELETE SET NULL,
                    PRIMARY KEY(method, tag_id)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE personal_suggestion_tag (
                    method TEXT NOT NULL,
                    tag_id TEXT NOT NULL,
                    PRIMARY KEY(method, tag_id),
                    FOREIGN KEY(method, tag_id)
                        REFERENCES personal_suggestion_model(method, tag_id) ON DELETE CASCADE
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE personal_prediction (
                    method TEXT NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL,
                    content_revision INTEGER NOT NULL CHECK(content_revision > 0),
                    score REAL NOT NULL CHECK(
                        typeof(score) IN ('real', 'integer')
                        AND score = score
                        AND score BETWEEN -1.0e308 AND 1.0e308
                    ),
                    state TEXT NOT NULL CHECK(state = 'pendingReview'),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    PRIMARY KEY(method, asset_id, tag_id, content_revision),
                    FOREIGN KEY(method, tag_id)
                        REFERENCES personal_suggestion_tag(method, tag_id) ON DELETE CASCADE
                ) STRICT
                """
            )

            let chestnutID = try String.fetchOne(
                db,
                sql: """
                SELECT id FROM tag
                WHERE name = '板栗' OR normalized_name = '板栗'
                ORDER BY id
                LIMIT 1
                """
            )
            let oldMethods = try Row.fetchAll(
                db,
                sql: "SELECT * FROM personal_suggestion_model_v014"
            )
            for model in oldMethods {
                let method: String = model["method"]
                let tagRows = try String.fetchAll(
                    db,
                    sql: """
                    SELECT tag_id FROM personal_suggestion_tag_v014
                    WHERE method = ?
                    ORDER BY tag_id
                    """,
                    arguments: [method]
                )
                let preservedTagIDs: [String]
                if tagRows.count == 1 {
                    preservedTagIDs = tagRows
                } else if let chestnutID, tagRows.contains(chestnutID) {
                    // Multi-tag shared heads are unstable; keep only 板栗 and
                    // drop published_run_id so a single-tag artifact must be
                    // republished before suggestions resume.
                    preservedTagIDs = [chestnutID]
                } else {
                    preservedTagIDs = []
                }
                for tagID in preservedTagIDs {
                    let keepPublishedRun = tagRows.count == 1
                    try db.execute(
                        sql: """
                        INSERT INTO personal_suggestion_model (
                            method, tag_id, catalog_scope_id, bundle_id, bundle_revision,
                            provider, model_id, model_revision, preprocessing_revision,
                            element_count, label_vocabulary_revision, weights_sha256,
                            policy_revision, activated_at_ms, published_run_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            method,
                            tagID,
                            model["catalog_scope_id"] as String,
                            model["bundle_id"] as String,
                            model["bundle_revision"] as String,
                            model["provider"] as String,
                            model["model_id"] as String,
                            model["model_revision"] as String,
                            model["preprocessing_revision"] as String,
                            model["element_count"] as Int64,
                            model["label_vocabulary_revision"] as String,
                            model["weights_sha256"] as String,
                            model["policy_revision"] as String,
                            model["activated_at_ms"] as Int64,
                            keepPublishedRun ? model["published_run_id"] as String? : nil,
                        ]
                    )
                    try db.execute(
                        sql: """
                        INSERT INTO personal_suggestion_tag (method, tag_id)
                        VALUES (?, ?)
                        """,
                        arguments: [method, tagID]
                    )
                    try db.execute(
                        sql: """
                        INSERT INTO personal_prediction (
                            method, asset_id, tag_id, content_revision, score, state, created_at_ms
                        )
                        SELECT method, asset_id, tag_id, content_revision, score, state, created_at_ms
                        FROM personal_prediction_v014
                        WHERE method = ? AND tag_id = ?
                        """,
                        arguments: [method, tagID]
                    )
                }
            }

            try db.execute(sql: "DROP TABLE personal_prediction_v014")
            try db.execute(sql: "DROP TABLE personal_suggestion_tag_v014")
            try db.execute(sql: "DROP TABLE personal_suggestion_model_v014")
            try db.execute(
                sql: """
                CREATE INDEX personal_prediction_review_rank_idx ON personal_prediction (
                    method,
                    tag_id,
                    state,
                    score DESC,
                    asset_id
                )
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER personal_suggestion_tag_before_insert
                BEFORE INSERT ON personal_suggestion_tag
                WHEN EXISTS (SELECT 1 FROM standard_tag_binding WHERE tag_id = NEW.tag_id)
                BEGIN
                    SELECT RAISE(ABORT, 'personal suggestion requires personal tag');
                END
                """
            )
            if try !db.columns(in: "training_run").map(\.name).contains("tag_id") {
                try db.execute(
                    sql: """
                    ALTER TABLE training_run ADD COLUMN tag_id TEXT
                        REFERENCES tag(id) ON DELETE SET NULL
                    """
                )
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }
}

enum V016AddTagGroupsMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v016AddTagGroups) { db in
            try db.execute(
                sql: """
                CREATE TABLE tag_group (
                    id TEXT NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL CHECK(length(name) > 0),
                    sort_order INTEGER NOT NULL CHECK(sort_order >= 0),
                    is_system INTEGER NOT NULL CHECK(is_system IN (0, 1)),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
                    CHECK(
                        length(id) = 36
                        AND id = lower(id)
                        AND id GLOB '????????-????-????-????-????????????'
                    )
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX tag_group_name_uq
                ON tag_group(name COLLATE NOCASE)
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX tag_group_sort_idx
                ON tag_group(sort_order, id)
                """
            )

            let seedTimestampMs: Int64 = 0
            for seed in TagGroupSeed.allCases {
                try db.execute(
                    sql: """
                    INSERT INTO tag_group (
                        id, name, sort_order, is_system, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, 1, ?, ?)
                    """,
                    arguments: [
                        seed.id.uuidString.lowercased(),
                        seed.displayName,
                        seed.sortOrder,
                        seedTimestampMs,
                        seedTimestampMs,
                    ]
                )
            }

            try db.execute(
                sql: """
                ALTER TABLE tag ADD COLUMN group_id TEXT
                    REFERENCES tag_group(id) ON DELETE RESTRICT
                """
            )

            let existingTags = try Row.fetchAll(db, sql: "SELECT id, name FROM tag")
            for row in existingTags {
                let tagID: String = row["id"]
                let name: String = row["name"]
                let groupID = TagGroupSeed.classify(displayName: name).id.uuidString.lowercased()
                try db.execute(
                    sql: "UPDATE tag SET group_id = ? WHERE id = ?",
                    arguments: [groupID, tagID]
                )
            }

            try db.execute(
                sql: """
                UPDATE tag
                SET group_id = ?
                WHERE group_id IS NULL
                """,
                arguments: [TagGroupSeed.other.id.uuidString.lowercased()]
            )

            try db.execute(
                sql: """
                CREATE INDEX tag_group_id_idx
                ON tag(group_id, id)
                """
            )
        }
    }
}

enum V018AddAssetSimilarityFingerprintMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v018AddAssetSimilarityFingerprint) { db in
            try db.execute(
                sql: """
                CREATE TABLE asset_similarity_fingerprint (
                    asset_id TEXT NOT NULL PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
                    content_revision INTEGER NOT NULL CHECK(content_revision >= 1),
                    algo_version TEXT NOT NULL CHECK(length(algo_version) > 0),
                    perceptual_hash BLOB NOT NULL CHECK(length(perceptual_hash) = 8),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
                    CHECK(
                        length(asset_id) = 36
                        AND asset_id = lower(asset_id)
                        AND asset_id GLOB '????????-????-????-????-????????????'
                    )
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX asset_similarity_fingerprint_hash_idx
                ON asset_similarity_fingerprint (algo_version, perceptual_hash, asset_id)
                """
            )
        }
    }
}

enum V019AddLibrarySlimmingRecycleMigration {
    private static let uuidAllowedCharsStripped: String = {
        var expression = "id"
        for character in Array("0123456789abcdef-") {
            expression = "replace(\(expression), '\(character)', '')"
        }
        return expression
    }()

    private static let uuidCheck = """
        length(id) = 36
        AND id = lower(id)
        AND id GLOB '????????-????-????-????-????????????'
        AND \(uuidAllowedCharsStripped) = ''
        """

    /// Full canonical `asset` DDL with `file_name` folded in and `availability`
    /// expanded to include `recycled`. SQLite cannot ALTER a CHECK constraint,
    /// so the table must be rebuilt.
    private static let rebuiltAssetDDL = """
        CREATE TABLE asset (
            id TEXT NOT NULL PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES source(id) ON DELETE RESTRICT,
            locator_kind TEXT NOT NULL CHECK(locator_kind IN ('file', 'photos')),
            relative_path TEXT,
            photos_local_identifier TEXT,
            locator_state TEXT NOT NULL DEFAULT 'current'
                CHECK(locator_state IN ('current', 'historical')),
            media_type TEXT NOT NULL CHECK(length(media_type) > 0),
            width INTEGER CHECK(width IS NULL OR width > 0),
            height INTEGER CHECK(height IS NULL OR height > 0),
            media_created_at_ms INTEGER,
            media_modified_at_ms INTEGER,
            content_revision INTEGER NOT NULL DEFAULT 1 CHECK(content_revision >= 1),
            last_seen_generation INTEGER CHECK(last_seen_generation IS NULL OR last_seen_generation >= 0),
            availability TEXT NOT NULL DEFAULT 'available'
                CHECK(availability IN ('available', 'missing', 'unreadable', 'unsupported', 'recycled')),
            record_created_at_ms INTEGER NOT NULL,
            record_updated_at_ms INTEGER NOT NULL,
            file_name TEXT CHECK(
                file_name IS NULL
                OR (
                    length(file_name) > 0
                    AND file_name NOT IN ('.', '..')
                    AND instr(file_name, '/') = 0
                    AND instr(file_name, char(0)) = 0
                )
            ),
            CHECK(
                (locator_kind = 'file'
                    AND relative_path IS NOT NULL AND length(relative_path) > 0
                    AND photos_local_identifier IS NULL)
                OR (locator_kind = 'photos'
                    AND photos_local_identifier IS NOT NULL AND length(photos_local_identifier) > 0
                    AND relative_path IS NULL)
            ),
            CHECK(\(uuidCheck))
        ) STRICT
        """

    private static let assetIndexStatements = [
        """
        CREATE UNIQUE INDEX asset_current_file_locator_uq
        ON asset(source_id, relative_path)
        WHERE locator_kind = 'file' AND locator_state = 'current'
        """,
        """
        CREATE UNIQUE INDEX asset_current_photos_locator_uq
        ON asset(source_id, photos_local_identifier)
        WHERE locator_kind = 'photos' AND locator_state = 'current'
        """,
        """
        CREATE INDEX asset_source_availability_idx
        ON asset(source_id, availability, id)
        """,
        """
        CREATE INDEX asset_current_time_idx ON asset (
            \(V002AddStage1CatalogQuerySupportMigration.timeEmptyMarkerExpression),
            \(V002AddStage1CatalogQuerySupportMigration.coalescedMediaTimeExpression),
            id
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_source_time_idx ON asset (
            source_id,
            \(V002AddStage1CatalogQuerySupportMigration.timeEmptyMarkerExpression),
            \(V002AddStage1CatalogQuerySupportMigration.coalescedMediaTimeExpression),
            id
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_file_name_idx ON asset (
            file_name COLLATE NOCASE,
            id
        ) WHERE locator_kind = 'file'
            AND locator_state = 'current'
            AND file_name IS NOT NULL
        """,
        """
        CREATE INDEX asset_generation_missing_idx ON asset (
            source_id,
            last_seen_generation,
            id
        ) WHERE locator_kind = 'file' AND locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_time_desc_idx ON asset (
            \(V002AddStage1CatalogQuerySupportMigration.timeEmptyMarkerExpression),
            \(V002AddStage1CatalogQuerySupportMigration.coalescedMediaTimeExpression) DESC,
            id DESC
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_source_media_time_desc_idx ON asset (
            source_id,
            media_type,
            \(V002AddStage1CatalogQuerySupportMigration.timeEmptyMarkerExpression),
            \(V002AddStage1CatalogQuerySupportMigration.coalescedMediaTimeExpression) DESC,
            id DESC
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_file_name_all_idx ON asset (
            (CASE WHEN file_name IS NOT NULL THEN 0 ELSE 1 END),
            file_name COLLATE NOCASE,
            id
        ) WHERE locator_state = 'current'
        """,
    ]

    private static let assetSearchTriggerStatements = [
        """
        CREATE TRIGGER asset_search_after_insert
        AFTER INSERT ON asset
        BEGIN
            INSERT INTO asset_search(rowid, file_name, relative_path)
            VALUES (new.rowid, new.file_name, new.relative_path);
        END
        """,
        """
        CREATE TRIGGER asset_search_after_delete
        AFTER DELETE ON asset
        BEGIN
            INSERT INTO asset_search(asset_search, rowid, file_name, relative_path)
            VALUES ('delete', old.rowid, old.file_name, old.relative_path);
        END
        """,
        """
        CREATE TRIGGER asset_search_after_update
        AFTER UPDATE OF file_name, relative_path ON asset
        BEGIN
            INSERT INTO asset_search(asset_search, rowid, file_name, relative_path)
            VALUES ('delete', old.rowid, old.file_name, old.relative_path);
            INSERT INTO asset_search(rowid, file_name, relative_path)
            VALUES (new.rowid, new.file_name, new.relative_path);
        END
        """,
    ]

    private static let recycleEntryDDL = """
        CREATE TABLE recycle_entry (
            id TEXT NOT NULL PRIMARY KEY,
            asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
            source_kind TEXT NOT NULL CHECK(source_kind IN ('file', 'photos')),
            trashed_at_ms INTEGER NOT NULL CHECK(trashed_at_ms >= 0),
            purge_after_ms INTEGER NOT NULL CHECK(purge_after_ms >= trashed_at_ms),
            state TEXT NOT NULL CHECK(
                state IN ('pending', 'recycled', 'restored', 'purged', 'failed')
            ),
            quarantine_relative_path TEXT CHECK(
                quarantine_relative_path IS NULL OR length(quarantine_relative_path) > 0
            ),
            original_relative_path TEXT NOT NULL CHECK(length(original_relative_path) > 0),
            error_code TEXT CHECK(error_code IS NULL OR length(error_code) > 0),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
            CHECK(\(uuidCheck))
        ) STRICT
        """

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v019AddLibrarySlimmingRecycle) { db in
            try addSourceMutationBookmarkColumn(db)
            try rebuildAssetAvailabilityCheck(db)
            try createRecycleEntryTable(db)
        }
    }

    private static func addSourceMutationBookmarkColumn(_ db: Database) throws {
        guard try !db.columns(in: "source").map(\.name).contains("mutation_bookmark") else {
            return
        }
        try db.execute(sql: "ALTER TABLE source ADD COLUMN mutation_bookmark BLOB")
    }

    private static func rebuildAssetAvailabilityCheck(_ db: Database) throws {
        let existingSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'asset'"
        )
        guard let existingSQL, !existingSQL.contains("'recycled'") else {
            return
        }

        try db.execute(sql: "PRAGMA foreign_keys = OFF")

        try db.execute(sql: "DROP INDEX IF EXISTS asset_current_file_locator_uq")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_current_photos_locator_uq")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_source_availability_idx")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_current_time_idx")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_current_source_time_idx")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_current_file_name_idx")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_generation_missing_idx")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_current_time_desc_idx")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_current_source_media_time_desc_idx")
        try db.execute(sql: "DROP INDEX IF EXISTS asset_current_file_name_all_idx")
        try db.execute(sql: "DROP TRIGGER IF EXISTS asset_search_after_insert")
        try db.execute(sql: "DROP TRIGGER IF EXISTS asset_search_after_delete")
        try db.execute(sql: "DROP TRIGGER IF EXISTS asset_search_after_update")

        try db.execute(sql: "ALTER TABLE asset RENAME TO asset_v018")
        try db.execute(sql: rebuiltAssetDDL)
        try db.execute(
            sql: """
            INSERT INTO asset (
                rowid, id, source_id, locator_kind, relative_path, photos_local_identifier,
                locator_state, media_type, width, height, media_created_at_ms,
                media_modified_at_ms, content_revision, last_seen_generation, availability,
                record_created_at_ms, record_updated_at_ms, file_name
            )
            SELECT
                rowid, id, source_id, locator_kind, relative_path, photos_local_identifier,
                locator_state, media_type, width, height, media_created_at_ms,
                media_modified_at_ms, content_revision, last_seen_generation, availability,
                record_created_at_ms, record_updated_at_ms, file_name
            FROM asset_v018
            """
        )
        try db.execute(sql: "DROP TABLE asset_v018")

        for statement in assetIndexStatements {
            try db.execute(sql: statement)
        }
        for statement in assetSearchTriggerStatements {
            try db.execute(sql: statement)
        }
        try db.execute(sql: "INSERT INTO asset_search(asset_search) VALUES ('rebuild')")

        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }

    private static func createRecycleEntryTable(_ db: Database) throws {
        guard try !db.tableExists("recycle_entry") else {
            return
        }
        try db.execute(sql: recycleEntryDDL)
        try db.execute(
            sql: """
            CREATE UNIQUE INDEX recycle_entry_active_asset_uq
            ON recycle_entry(asset_id)
            WHERE state IN ('pending', 'recycled', 'failed')
            """
        )
        try db.execute(
            sql: """
            CREATE INDEX recycle_entry_purge_due_idx
            ON recycle_entry(purge_after_ms, id)
            WHERE state = 'recycled'
            """
        )
    }
}

enum V020HardenLibrarySlimmingRecycleMigration {
    private static let sourceMutationAuthorizationDDL = """
        CREATE TABLE source_mutation_authorization (
            source_id TEXT NOT NULL PRIMARY KEY REFERENCES source(id) ON DELETE CASCADE,
            bookmark BLOB NOT NULL CHECK(length(bookmark) > 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
        ) STRICT
        """

    private static let recycleEntryDDL = """
        CREATE TABLE recycle_entry (
            id TEXT NOT NULL PRIMARY KEY,
            asset_id TEXT REFERENCES asset(id) ON DELETE SET NULL,
            source_kind TEXT NOT NULL CHECK(source_kind IN ('file', 'photos')),
            trashed_at_ms INTEGER NOT NULL CHECK(trashed_at_ms >= 0),
            purge_after_ms INTEGER NOT NULL CHECK(purge_after_ms >= trashed_at_ms),
            state TEXT NOT NULL CHECK(
                state IN (
                    'pending', 'recycled', 'restoring', 'purging',
                    'restored', 'purged', 'failed'
                )
            ),
            quarantine_relative_path TEXT CHECK(
                quarantine_relative_path IS NULL OR length(quarantine_relative_path) > 0
            ),
            original_relative_path TEXT CHECK(
                original_relative_path IS NULL OR length(original_relative_path) > 0
            ),
            error_code TEXT CHECK(error_code IS NULL OR length(error_code) > 0),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
            CHECK(\(V001CreateCatalogCoreMigration.uuidCheck)),
            CHECK(
                state != 'purged'
                OR (
                    asset_id IS NULL
                    AND quarantine_relative_path IS NULL
                    AND original_relative_path IS NULL
                )
            )
        ) STRICT
        """

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v020HardenLibrarySlimmingRecycle) { db in
            try db.execute(sql: sourceMutationAuthorizationDDL)
            try db.execute(
                sql: """
                INSERT INTO source_mutation_authorization (
                    source_id, bookmark, updated_at_ms
                )
                SELECT id, mutation_bookmark, updated_at_ms
                FROM source
                WHERE mutation_bookmark IS NOT NULL AND length(mutation_bookmark) > 0
                """
            )
            try db.execute(sql: "ALTER TABLE source DROP COLUMN mutation_bookmark")

            try db.execute(sql: "DROP INDEX IF EXISTS recycle_entry_active_asset_uq")
            try db.execute(sql: "DROP INDEX IF EXISTS recycle_entry_purge_due_idx")
            try db.execute(sql: "ALTER TABLE recycle_entry RENAME TO recycle_entry_v019")
            try db.execute(sql: recycleEntryDDL)
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, error_code,
                    created_at_ms, updated_at_ms
                )
                SELECT
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, error_code,
                    created_at_ms, updated_at_ms
                FROM recycle_entry_v019
                """
            )
            try db.execute(sql: "DROP TABLE recycle_entry_v019")
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX recycle_entry_active_asset_uq
                ON recycle_entry(asset_id)
                WHERE state IN ('pending', 'recycled', 'restoring', 'purging')
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX recycle_entry_purge_due_idx
                ON recycle_entry(purge_after_ms, id)
                WHERE state = 'recycled'
                """
            )
        }
    }
}

enum V021AddPhotosRecycleIdentifierMigration {
    private static let recycleEntryDDL = """
        CREATE TABLE recycle_entry (
            id TEXT NOT NULL PRIMARY KEY,
            asset_id TEXT REFERENCES asset(id) ON DELETE SET NULL,
            source_kind TEXT NOT NULL CHECK(source_kind IN ('file', 'photos')),
            trashed_at_ms INTEGER NOT NULL CHECK(trashed_at_ms >= 0),
            purge_after_ms INTEGER NOT NULL CHECK(purge_after_ms >= trashed_at_ms),
            state TEXT NOT NULL CHECK(
                state IN (
                    'pending', 'recycled', 'restoring', 'purging',
                    'restored', 'purged', 'failed'
                )
            ),
            quarantine_relative_path TEXT CHECK(
                quarantine_relative_path IS NULL OR length(quarantine_relative_path) > 0
            ),
            original_relative_path TEXT CHECK(
                original_relative_path IS NULL OR length(original_relative_path) > 0
            ),
            photos_local_identifier TEXT CHECK(
                photos_local_identifier IS NULL OR length(photos_local_identifier) > 0
            ),
            error_code TEXT CHECK(error_code IS NULL OR length(error_code) > 0),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
            CHECK(\(V001CreateCatalogCoreMigration.uuidCheck)),
            CHECK(
                source_kind != 'file' OR photos_local_identifier IS NULL
            ),
            CHECK(
                source_kind != 'photos' OR quarantine_relative_path IS NULL
            ),
            CHECK(
                source_kind != 'photos'
                OR photos_local_identifier IS NOT NULL
                OR state IN ('purging', 'purged')
            ),
            CHECK(
                state != 'purged'
                OR (
                    asset_id IS NULL
                    AND quarantine_relative_path IS NULL
                    AND original_relative_path IS NULL
                    AND photos_local_identifier IS NULL
                )
            )
        ) STRICT
        """

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v021AddPhotosRecycleIdentifier) { db in
            try db.execute(sql: "DROP INDEX IF EXISTS recycle_entry_active_asset_uq")
            try db.execute(sql: "DROP INDEX IF EXISTS recycle_entry_purge_due_idx")
            try db.execute(sql: "ALTER TABLE recycle_entry RENAME TO recycle_entry_v020")
            try db.execute(sql: recycleEntryDDL)
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                )
                SELECT
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, NULL,
                    error_code, created_at_ms, updated_at_ms
                FROM recycle_entry_v020
                """
            )
            try db.execute(sql: "DROP TABLE recycle_entry_v020")
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX recycle_entry_active_asset_uq
                ON recycle_entry(asset_id)
                WHERE state IN ('pending', 'recycled', 'restoring', 'purging')
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX recycle_entry_purge_due_idx
                ON recycle_entry(purge_after_ms, id)
                WHERE state = 'recycled'
                """
            )
        }
    }
}

enum V022HardenLibrarySlimmingAnalysisMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v022HardenLibrarySlimmingAnalysis) { db in
            try db.execute(
                sql: """
                ALTER TABLE asset_similarity_fingerprint
                ADD COLUMN content_sha256 BLOB
                CHECK(content_sha256 IS NULL OR length(content_sha256) = 32)
                """
            )
            try db.execute(
                sql: """
                ALTER TABLE asset_similarity_fingerprint
                ADD COLUMN verification_signature BLOB
                CHECK(verification_signature IS NULL OR length(verification_signature) = 768)
                """
            )
            try db.execute(
                sql: """
                ALTER TABLE asset_similarity_fingerprint
                ADD COLUMN pixel_width INTEGER
                CHECK(pixel_width IS NULL OR pixel_width > 0)
                """
            )
            try db.execute(
                sql: """
                ALTER TABLE asset_similarity_fingerprint
                ADD COLUMN pixel_height INTEGER
                CHECK(pixel_height IS NULL OR pixel_height > 0)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE photos_original_cache_entry (
                    asset_id TEXT NOT NULL PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
                    content_revision INTEGER NOT NULL CHECK(content_revision >= 1),
                    photos_local_identifier TEXT NOT NULL
                        CHECK(length(photos_local_identifier) > 0),
                    object_name TEXT NOT NULL UNIQUE CHECK(length(object_name) = 36),
                    media_type TEXT NOT NULL CHECK(length(media_type) > 0),
                    byte_size INTEGER NOT NULL CHECK(byte_size > 0),
                    encoded_sha256 BLOB NOT NULL CHECK(length(encoded_sha256) = 32),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE library_slimming_scan_member (
                    job_id TEXT NOT NULL REFERENCES job(id) ON DELETE CASCADE,
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                    is_seed INTEGER NOT NULL DEFAULT 0 CHECK(is_seed IN (0, 1)),
                    PRIMARY KEY(job_id, asset_id),
                    UNIQUE(job_id, ordinal)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE library_slimming_scan_result (
                    job_id TEXT NOT NULL PRIMARY KEY REFERENCES job(id) ON DELETE CASCADE,
                    result_json BLOB NOT NULL CHECK(length(result_json) > 0),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
                ) STRICT
                """
            )
        }
    }
}

enum V023AddSourceSimilarityIndexMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v023AddSourceSimilarityIndex) { db in
            try db.execute(
                sql: """
                CREATE TABLE source_similarity_index (
                    source_id TEXT NOT NULL PRIMARY KEY REFERENCES source(id) ON DELETE CASCADE,
                    state TEXT NOT NULL CHECK(state IN ('building','ready','stale','failed')),
                    policy_version TEXT NOT NULL,
                    feature_print_provider TEXT NOT NULL,
                    feature_print_request_revision INTEGER NOT NULL,
                    feature_print_preprocessing_revision INTEGER NOT NULL,
                    feature_print_max_l2 REAL NOT NULL,
                    lsh_bit_count INTEGER NOT NULL CHECK(lsh_bit_count BETWEEN 8 AND 64),
                    lsh_planes_json BLOB NOT NULL,
                    asset_count INTEGER NOT NULL CHECK(asset_count >= 0),
                    indexed_count INTEGER NOT NULL CHECK(indexed_count >= 0),
                    cluster_count INTEGER NOT NULL CHECK(cluster_count >= 0),
                    pending_count INTEGER NOT NULL CHECK(pending_count >= 0),
                    job_id TEXT REFERENCES job(id) ON DELETE SET NULL,
                    built_at_ms INTEGER,
                    updated_at_ms INTEGER NOT NULL,
                    last_error TEXT
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE source_similarity_bucket_member (
                    source_id TEXT NOT NULL REFERENCES source_similarity_index(source_id) ON DELETE CASCADE,
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    content_revision INTEGER NOT NULL CHECK(content_revision >= 1),
                    bucket_key INTEGER NOT NULL,
                    cluster_id TEXT,
                    PRIMARY KEY(source_id, asset_id)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX source_similarity_bucket_lookup_idx
                ON source_similarity_bucket_member(source_id, bucket_key, asset_id)
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX source_similarity_cluster_lookup_idx
                ON source_similarity_bucket_member(source_id, cluster_id, asset_id)
                """
            )
        }
    }
}

/// Repairs catalogs where v020–v023 are recorded but `source_mutation_authorization`
/// is missing and legacy `source.mutation_bookmark` remains (observed after partial
/// restore / schema drift). Fully idempotent for healthy databases.
enum V024RepairSourceMutationAuthorizationMigration {
    private static let sourceMutationAuthorizationDDL = """
        CREATE TABLE source_mutation_authorization (
            source_id TEXT NOT NULL PRIMARY KEY REFERENCES source(id) ON DELETE CASCADE,
            bookmark BLOB NOT NULL CHECK(length(bookmark) > 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
        ) STRICT
        """

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v024RepairSourceMutationAuthorization) { db in
            if try !db.tableExists("source_mutation_authorization") {
                try db.execute(sql: sourceMutationAuthorizationDDL)
            }

            let hasLegacyColumn = try db.columns(in: "source")
                .contains { $0.name == "mutation_bookmark" }
            guard hasLegacyColumn else { return }

            try db.execute(
                sql: """
                INSERT INTO source_mutation_authorization (
                    source_id, bookmark, updated_at_ms
                )
                SELECT id, mutation_bookmark, updated_at_ms
                FROM source
                WHERE mutation_bookmark IS NOT NULL AND length(mutation_bookmark) > 0
                ON CONFLICT(source_id) DO UPDATE SET
                    bookmark = excluded.bookmark,
                    updated_at_ms = excluded.updated_at_ms
                WHERE excluded.updated_at_ms >= source_mutation_authorization.updated_at_ms
                """
            )
            try db.execute(sql: "ALTER TABLE source DROP COLUMN mutation_bookmark")
        }
    }
}

/// Keeps a purged file asset as a non-browseable knowledge tombstone so manual
/// decisions, fingerprints/features, training samples, and model provenance do
/// not disappear when the quarantine bytes are permanently deleted.
enum V025RetainPurgedAssetKnowledgeMigration {
    private static let recycleEntryDDL = """
        CREATE TABLE recycle_entry (
            id TEXT NOT NULL PRIMARY KEY,
            asset_id TEXT REFERENCES asset(id) ON DELETE SET NULL,
            source_kind TEXT NOT NULL CHECK(source_kind IN ('file', 'photos')),
            trashed_at_ms INTEGER NOT NULL CHECK(trashed_at_ms >= 0),
            purge_after_ms INTEGER NOT NULL CHECK(purge_after_ms >= trashed_at_ms),
            state TEXT NOT NULL CHECK(
                state IN (
                    'pending', 'recycled', 'restoring', 'purging',
                    'restored', 'purged', 'failed'
                )
            ),
            quarantine_relative_path TEXT CHECK(
                quarantine_relative_path IS NULL OR length(quarantine_relative_path) > 0
            ),
            original_relative_path TEXT CHECK(
                original_relative_path IS NULL OR length(original_relative_path) > 0
            ),
            photos_local_identifier TEXT CHECK(
                photos_local_identifier IS NULL OR length(photos_local_identifier) > 0
            ),
            error_code TEXT CHECK(error_code IS NULL OR length(error_code) > 0),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
            CHECK(\(V001CreateCatalogCoreMigration.uuidCheck)),
            CHECK(source_kind != 'file' OR photos_local_identifier IS NULL),
            CHECK(source_kind != 'photos' OR quarantine_relative_path IS NULL),
            CHECK(
                source_kind != 'photos'
                OR photos_local_identifier IS NOT NULL
                OR state IN ('purging', 'purged')
            ),
            CHECK(
                state != 'purged'
                OR (
                    quarantine_relative_path IS NULL
                    AND original_relative_path IS NULL
                    AND photos_local_identifier IS NULL
                )
            )
        ) STRICT
        """

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v025RetainPurgedAssetKnowledge) { db in
            try db.execute(sql: "DROP INDEX IF EXISTS recycle_entry_active_asset_uq")
            try db.execute(sql: "DROP INDEX IF EXISTS recycle_entry_purge_due_idx")
            try db.execute(sql: "ALTER TABLE recycle_entry RENAME TO recycle_entry_v024")
            try db.execute(sql: recycleEntryDDL)
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                )
                SELECT
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                FROM recycle_entry_v024
                """
            )
            try db.execute(sql: "DROP TABLE recycle_entry_v024")
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX recycle_entry_active_asset_uq
                ON recycle_entry(asset_id)
                WHERE state IN ('pending', 'recycled', 'restoring', 'purging')
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX recycle_entry_purge_due_idx
                ON recycle_entry(purge_after_ms, id)
                WHERE state = 'recycled'
                """
            )
        }
    }
}

/// Introduces a first-class image/video domain without rewriting the existing
/// catalog or training history. Existing rows are image assets by contract.
enum V026AddMediaKindAndVideoMetadataMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v026AddMediaKindAndVideoMetadata) { db in
            let assetColumns = try Set(db.columns(in: "asset").map(\.name))
            if !assetColumns.contains("media_kind") {
                try db.execute(
                    sql: """
                    ALTER TABLE asset
                    ADD COLUMN media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video'))
                    """
                )
            }
            if !assetColumns.contains("duration_ms") {
                try db.execute(
                    sql: """
                    ALTER TABLE asset
                    ADD COLUMN duration_ms INTEGER
                        CHECK(duration_ms IS NULL OR duration_ms > 0)
                    """
                )
            }
            let trainingRunColumns = try Set(db.columns(in: "training_run").map(\.name))
            if !trainingRunColumns.contains("media_kind") {
                try db.execute(
                    sql: """
                    ALTER TABLE training_run
                    ADD COLUMN media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video'))
                    """
                )
            }
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS asset_current_media_kind_idx
                ON asset(media_kind, locator_state, availability, id)
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS training_run_media_kind_method_created_idx
                ON training_run(media_kind, method, created_at_ms DESC, id)
                """
            )
        }
    }
}

/// Gives image and video independent Feature KNN and app-personal model slots.
/// Existing model history predates video support and is therefore copied into
/// the image partition without changing its revisions or artifact identity.
enum V027PartitionPersonalizationByMediaKindMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v027PartitionPersonalizationByMediaKind) { db in
            let featureModelColumns = try Set(db.columns(in: "tag_model_revision").map(\.name))
            let personalModelColumns = try Set(db.columns(in: "personal_suggestion_model").map(\.name))
            if featureModelColumns.contains("media_kind"),
               personalModelColumns.contains("media_kind")
            {
                return
            }

            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP INDEX IF EXISTS tag_model_sample_feature_idx")
            try db.execute(sql: "DROP INDEX IF EXISTS prediction_review_rank_idx")
            try db.execute(sql: "DROP INDEX IF EXISTS personal_prediction_review_rank_idx")
            try db.execute(sql: "DROP TRIGGER IF EXISTS personal_suggestion_tag_before_insert")

            for table in [
                "prediction",
                "tag_model_sample",
                "tag_model",
                "tag_model_revision",
                "personal_prediction",
                "personal_suggestion_tag",
                "personal_suggestion_model",
            ] {
                try db.execute(sql: "ALTER TABLE \(table) RENAME TO \(table)_v026")
            }

            try db.execute(
                sql: """
                CREATE TABLE tag_model_revision (
                    media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video')),
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
                    PRIMARY KEY (media_kind, tag_id, revision)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE tag_model_sample (
                    media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video')),
                    tag_id TEXT NOT NULL,
                    model_revision INTEGER NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    content_revision INTEGER NOT NULL CHECK(content_revision > 0),
                    role TEXT NOT NULL CHECK(role IN ('positive', 'negative')),
                    rank INTEGER NOT NULL CHECK(rank >= 0),
                    provider TEXT NOT NULL CHECK(provider = 'vision-feature-print'),
                    request_revision INTEGER NOT NULL CHECK(request_revision > 0),
                    preprocessing_revision INTEGER NOT NULL CHECK(preprocessing_revision > 0),
                    PRIMARY KEY (media_kind, tag_id, model_revision, asset_id),
                    UNIQUE (media_kind, tag_id, model_revision, role, rank),
                    FOREIGN KEY (media_kind, tag_id, model_revision)
                        REFERENCES tag_model_revision(media_kind, tag_id, revision)
                        ON DELETE CASCADE,
                    FOREIGN KEY (
                        asset_id, provider, request_revision,
                        preprocessing_revision, content_revision
                    ) REFERENCES feature(
                        asset_id, provider, request_revision,
                        preprocessing_revision, content_revision
                    ) ON DELETE CASCADE
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE tag_model (
                    media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video')),
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    current_revision INTEGER NOT NULL CHECK(current_revision > 0),
                    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
                    PRIMARY KEY (media_kind, tag_id),
                    FOREIGN KEY (media_kind, tag_id, current_revision)
                        REFERENCES tag_model_revision(media_kind, tag_id, revision)
                        ON DELETE RESTRICT
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE prediction (
                    media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video')),
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
                    PRIMARY KEY (
                        media_kind, asset_id, tag_id, content_revision, model_revision
                    ),
                    FOREIGN KEY (media_kind, tag_id, model_revision)
                        REFERENCES tag_model_revision(media_kind, tag_id, revision)
                        ON DELETE CASCADE
                ) STRICT
                """
            )

            try db.execute(
                sql: """
                CREATE TABLE personal_suggestion_model (
                    media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video')),
                    method TEXT NOT NULL CHECK(
                        method IN ('personalCentroid', 'personalAdamW')
                    ),
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    catalog_scope_id TEXT NOT NULL
                        REFERENCES catalog_scope(scope_id) ON DELETE CASCADE,
                    bundle_id TEXT NOT NULL CHECK(length(bundle_id) BETWEEN 1 AND 200),
                    bundle_revision TEXT NOT NULL CHECK(length(bundle_revision) BETWEEN 1 AND 200),
                    provider TEXT NOT NULL CHECK(length(provider) BETWEEN 1 AND 200),
                    model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 300),
                    model_revision TEXT NOT NULL CHECK(length(model_revision) BETWEEN 1 AND 200),
                    preprocessing_revision TEXT NOT NULL
                        CHECK(length(preprocessing_revision) BETWEEN 1 AND 200),
                    element_count INTEGER NOT NULL CHECK(element_count > 0),
                    label_vocabulary_revision TEXT NOT NULL CHECK(
                        length(label_vocabulary_revision) = 64
                        AND label_vocabulary_revision NOT GLOB '*[^0-9a-f]*'
                    ),
                    weights_sha256 TEXT NOT NULL CHECK(
                        length(weights_sha256) = 64
                        AND weights_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    policy_revision TEXT NOT NULL CHECK(length(policy_revision) BETWEEN 1 AND 200),
                    activated_at_ms INTEGER NOT NULL CHECK(activated_at_ms >= 0),
                    published_run_id TEXT REFERENCES training_run(id) ON DELETE SET NULL,
                    PRIMARY KEY(media_kind, method, tag_id)
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE personal_suggestion_tag (
                    media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video')),
                    method TEXT NOT NULL,
                    tag_id TEXT NOT NULL,
                    PRIMARY KEY(media_kind, method, tag_id),
                    FOREIGN KEY(media_kind, method, tag_id)
                        REFERENCES personal_suggestion_model(media_kind, method, tag_id)
                        ON DELETE CASCADE
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE personal_prediction (
                    media_kind TEXT NOT NULL DEFAULT 'image'
                        CHECK(media_kind IN ('image', 'video')),
                    method TEXT NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL,
                    content_revision INTEGER NOT NULL CHECK(content_revision > 0),
                    score REAL NOT NULL CHECK(
                        typeof(score) IN ('real', 'integer')
                        AND score = score
                        AND score BETWEEN -1.0e308 AND 1.0e308
                    ),
                    state TEXT NOT NULL CHECK(state = 'pendingReview'),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    PRIMARY KEY(media_kind, method, asset_id, tag_id, content_revision),
                    FOREIGN KEY(media_kind, method, tag_id)
                        REFERENCES personal_suggestion_tag(media_kind, method, tag_id)
                        ON DELETE CASCADE
                ) STRICT
                """
            )

            try db.execute(
                sql: """
                INSERT INTO tag_model_revision (
                    media_kind, tag_id, revision, provider, request_revision,
                    preprocessing_revision, threshold, positive_count, negative_count,
                    neighbor_count, sample_budget_per_role, created_at_ms
                )
                SELECT
                    'image', tag_id, revision, provider, request_revision,
                    preprocessing_revision, threshold, positive_count, negative_count,
                    neighbor_count, sample_budget_per_role, created_at_ms
                FROM tag_model_revision_v026
                """
            )
            try db.execute(
                sql: """
                INSERT INTO tag_model_sample (
                    media_kind, tag_id, model_revision, asset_id, content_revision,
                    role, rank, provider, request_revision, preprocessing_revision
                )
                SELECT
                    'image', tag_id, model_revision, asset_id, content_revision,
                    role, rank, provider, request_revision, preprocessing_revision
                FROM tag_model_sample_v026
                """
            )
            try db.execute(
                sql: """
                INSERT INTO tag_model (
                    media_kind, tag_id, current_revision, updated_at_ms
                )
                SELECT 'image', tag_id, current_revision, updated_at_ms
                FROM tag_model_v026
                """
            )
            try db.execute(
                sql: """
                INSERT INTO prediction (
                    media_kind, asset_id, tag_id, content_revision, model_revision,
                    score, state, created_at_ms
                )
                SELECT
                    'image', asset_id, tag_id, content_revision, model_revision,
                    score, state, created_at_ms
                FROM prediction_v026
                """
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_model (
                    media_kind, method, tag_id, catalog_scope_id, bundle_id,
                    bundle_revision, provider, model_id, model_revision,
                    preprocessing_revision, element_count, label_vocabulary_revision,
                    weights_sha256, policy_revision, activated_at_ms, published_run_id
                )
                SELECT
                    'image', method, tag_id, catalog_scope_id, bundle_id,
                    bundle_revision, provider, model_id, model_revision,
                    preprocessing_revision, element_count, label_vocabulary_revision,
                    weights_sha256, policy_revision, activated_at_ms, published_run_id
                FROM personal_suggestion_model_v026
                """
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_tag (media_kind, method, tag_id)
                SELECT 'image', method, tag_id
                FROM personal_suggestion_tag_v026
                """
            )
            try db.execute(
                sql: """
                INSERT INTO personal_prediction (
                    media_kind, method, asset_id, tag_id, content_revision,
                    score, state, created_at_ms
                )
                SELECT
                    'image', method, asset_id, tag_id, content_revision,
                    score, state, created_at_ms
                FROM personal_prediction_v026
                """
            )

            for table in [
                "prediction_v026",
                "tag_model_sample_v026",
                "tag_model_v026",
                "tag_model_revision_v026",
                "personal_prediction_v026",
                "personal_suggestion_tag_v026",
                "personal_suggestion_model_v026",
            ] {
                try db.execute(sql: "DROP TABLE \(table)")
            }

            try db.execute(
                sql: """
                CREATE INDEX tag_model_sample_feature_idx ON tag_model_sample (
                    asset_id, provider, request_revision,
                    preprocessing_revision, content_revision
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX prediction_review_rank_idx ON prediction (
                    media_kind, tag_id, state, score DESC, asset_id
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX personal_prediction_review_rank_idx ON personal_prediction (
                    media_kind, method, tag_id, state, score DESC, asset_id
                )
                """
            )
            try db.execute(
                sql: "DROP TRIGGER IF EXISTS personal_tag_model_before_insert"
            )
            try db.execute(
                sql: """
                CREATE TRIGGER personal_tag_model_before_insert
                BEFORE INSERT ON tag_model_revision
                WHEN EXISTS (SELECT 1 FROM standard_tag_binding WHERE tag_id = NEW.tag_id)
                BEGIN
                    SELECT RAISE(ABORT, 'personal model requires personal tag');
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER personal_suggestion_tag_before_insert
                BEFORE INSERT ON personal_suggestion_tag
                WHEN EXISTS (SELECT 1 FROM standard_tag_binding WHERE tag_id = NEW.tag_id)
                BEGIN
                    SELECT RAISE(ABORT, 'personal suggestion requires personal tag');
                END
                """
            )
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }
}
