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
