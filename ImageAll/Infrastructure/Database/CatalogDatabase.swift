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
