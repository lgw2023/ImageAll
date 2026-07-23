import GRDB
import XCTest
@testable import ImageAll

final class TrainingWorkspaceSchemaTests: XCTestCase {
    func testUnknownPersonalBundleIDDoesNotDefaultToCentroid() {
        XCTAssertNil(PersonalSuggestionMethod(bundleID: "app.personal.unknown.v1"))
    }

    func testFreshDatabaseIncludesTrainingRunAndMultiSlotPersonalTables() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try database.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
        try database.pool.read { db in
            XCTAssertTrue(try db.tableExists("training_run"))
            let modelColumns = try db.columns(in: "personal_suggestion_model").map(\.name)
            XCTAssertEqual(modelColumns.first, "method")
            XCTAssertTrue(modelColumns.contains("published_run_id"))
            XCTAssertFalse(modelColumns.contains("singleton"))
            let predictionColumns = try db.columns(in: "personal_prediction").map(\.name)
            XCTAssertEqual(predictionColumns.first, "method")
        }
    }

    func testV014MigratesSingletonPersonalModelIntoCentroidSlot() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        var migrator = DatabaseMigrator()
        for register in [
            V001CreateCatalogCoreMigration.register,
            V002AddStage1CatalogQuerySupportMigration.register,
            V003AddDerivedImageCacheMigration.register,
            V004AddPersonalizationMigration.register,
            V005AddCatalogScaleIndexesMigration.register,
            V006AddAssetTextSearchMigration.register,
            V007AddCatalogScopeIdentityMigration.register,
            V008AddPersonalModelSuggestionsMigration.register,
            V009AddStandardOntologyMigration.register,
            V010AddStandardPredictionsMigration.register,
            V011AddStandardPredictionProvenanceMigration.register,
            V012RepairStandardTagBindingMigration.register,
            V013PhotosMissingAssetRepairMigration.register,
        ] as [(inout DatabaseMigrator) -> Void] {
            register(&migrator)
        }
        try migrator.migrate(pool)

        let scopeID = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT scope_id FROM catalog_scope WHERE singleton = 1")
        }!
        let tagID = UUID()
        let assetID = UUID()
        let sourceID = UUID()
        let sha = String(repeating: "a", count: 64)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, sync_cursor, state,
                    created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Folder', ?, NULL, 'active', ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.folderBookmark(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, locator_state, media_type,
                    content_revision, availability, record_created_at_ms, record_updated_at_ms,
                    file_name
                ) VALUES (?, ?, 'file', 'a.jpg', 'current', 'public.jpeg', 1, 'available', ?, ?, 'a.jpg')
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO tag (
                    id, name, normalized_name, state, created_at_ms, updated_at_ms
                ) VALUES (?, 'wife', 'wife', 'active', ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_model (
                    singleton, catalog_scope_id, bundle_id, bundle_revision, provider, model_id,
                    model_revision, preprocessing_revision, element_count,
                    label_vocabulary_revision, weights_sha256, policy_revision, activated_at_ms
                ) VALUES (1, ?, 'app.personal.linear-head.v1', 'rev-1', 'coreml', 'model',
                    'mrev', 'prev', 768, ?, ?, 'policy', ?)
                """,
                arguments: [scopeID, sha, sha, DatabaseTestSupport.timestampMs]
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_tag (tag_id, model_singleton)
                VALUES (?, 1)
                """,
                arguments: [tagID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO personal_prediction (
                    asset_id, tag_id, content_revision, score, state, created_at_ms
                ) VALUES (?, ?, 1, 0.9, 'pendingReview', ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }

        V014AddTrainingRunsAndPersonalMultiSlotMigration.register(on: &migrator)
        try migrator.migrate(pool)

        try pool.read { db in
            let methods = try String.fetchAll(
                db,
                sql: "SELECT method FROM personal_suggestion_model ORDER BY method"
            )
            XCTAssertEqual(methods, ["personalCentroid"])
            let tagMethod = try String.fetchOne(
                db,
                sql: "SELECT method FROM personal_suggestion_tag WHERE tag_id = ?",
                arguments: [tagID.uuidString.lowercased()]
            )
            XCTAssertEqual(tagMethod, "personalCentroid")
            let predictionMethod = try String.fetchOne(
                db,
                sql: "SELECT method FROM personal_prediction WHERE asset_id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
            XCTAssertEqual(predictionMethod, "personalCentroid")
            XCTAssertTrue(try db.tableExists("training_run"))
        }
    }

    func testActivatingAdamWDoesNotDeleteCentroidSlotOrPredictions() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let sourceID = UUID()
        let assetID = UUID()
        let tagID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: CatalogRepository(database: database),
            sourceID: sourceID,
            assetID: assetID
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (
                    id, name, normalized_name, state, created_at_ms, updated_at_ms
                ) VALUES (?, 'wife', 'wife', 'active', ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }
        let scopeID = try database.catalogScopeID()
        let review = GRDBPersonalizationReviewRepository(database: database)
        let centroidSHA = String(repeating: "b", count: 64)
        let adamSHA = String(repeating: "c", count: 64)
        let centroid = PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: scopeID,
                bundleID: PersonalSuggestionMethod.linearHeadBundleID,
                bundleRevision: "centroid-rev",
                provider: "coreml",
                modelID: "dino",
                modelRevision: "1",
                preprocessingRevision: "p1",
                elementCount: 768,
                labelVocabularyRevision: centroidSHA,
                weightsSHA256: centroidSHA,
                policyRevision: "centroid-policy"
            ),
            tagIDs: [tagID]
        )
        let adamW = PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: scopeID,
                bundleID: PersonalSuggestionMethod.adamWHeadBundleID,
                bundleRevision: "adamw-rev",
                provider: "coreml",
                modelID: "dino",
                modelRevision: "1",
                preprocessingRevision: "p1",
                elementCount: 768,
                labelVocabularyRevision: adamSHA,
                weightsSHA256: adamSHA,
                policyRevision: "adamw-policy"
            ),
            tagIDs: [tagID]
        )
        try review.activatePersonalSuggestionBundle(centroid, activatedAtMs: 10)
        _ = try review.replacePersonalSuggestions(
            candidate: PersonalSuggestionCandidate(assetID: assetID, contentRevision: 1),
            predictions: [PersonalSuggestionPrediction(tagID: tagID, score: 0.8)],
            expectedCapability: centroid,
            createdAtMs: 11
        )
        try review.activatePersonalSuggestionBundle(adamW, activatedAtMs: 12)
        _ = try review.replacePersonalSuggestions(
            candidate: PersonalSuggestionCandidate(assetID: assetID, contentRevision: 1),
            predictions: [PersonalSuggestionPrediction(tagID: tagID, score: 0.7)],
            expectedCapability: adamW,
            createdAtMs: 13
        )

        try database.pool.read { db in
            let methods = try String.fetchAll(
                db,
                sql: "SELECT method FROM personal_suggestion_model ORDER BY method"
            )
            XCTAssertEqual(methods, ["personalAdamW", "personalCentroid"])
            let predictionMethods = try String.fetchAll(
                db,
                sql: """
                SELECT method FROM personal_prediction
                WHERE asset_id = ? AND tag_id = ?
                ORDER BY method
                """,
                arguments: [assetID.uuidString.lowercased(), tagID.uuidString.lowercased()]
            )
            XCTAssertEqual(predictionMethods, ["personalAdamW", "personalCentroid"])
            let centroidWeights = try String.fetchOne(
                db,
                sql: """
                SELECT weights_sha256 FROM personal_suggestion_model
                WHERE method = 'personalCentroid'
                """
            )
            XCTAssertEqual(centroidWeights, centroidSHA)
        }
    }

    func testRetrainingCentroidKeepsAdamWSlotAndPredictionUnchanged() throws {
        let fixture = try makePublishedPersonalSlotsFixture()
        let before = try personalMethodState(
            fixture,
            method: .personalAdamW
        )
        let centroidV2 = personalCapability(
            method: .personalCentroid,
            scopeID: try fixture.database.catalogScopeID(),
            tagID: fixture.tagID,
            revision: "centroid-v2",
            sha: String(repeating: "d", count: 64)
        )

        try fixture.review.activatePersonalSuggestionBundle(
            centroidV2,
            activatedAtMs: 20
        )

        XCTAssertEqual(
            try personalMethodState(fixture, method: .personalAdamW),
            before
        )
    }

    func testRetrainingAdamWKeepsCentroidSlotAndPredictionUnchanged() throws {
        let fixture = try makePublishedPersonalSlotsFixture()
        let before = try personalMethodState(
            fixture,
            method: .personalCentroid
        )
        let adamWV2 = personalCapability(
            method: .personalAdamW,
            scopeID: try fixture.database.catalogScopeID(),
            tagID: fixture.tagID,
            revision: "adamw-v2",
            sha: String(repeating: "e", count: 64)
        )

        try fixture.review.activatePersonalSuggestionBundle(
            adamWV2,
            activatedAtMs: 21
        )

        XCTAssertEqual(
            try personalMethodState(fixture, method: .personalCentroid),
            before
        )
    }

    func testTrainingRunRoundTripPersistsMetricsJSON() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let runs = GRDBTrainingRunRepository(database: database)
        let runID = UUID()
        let metrics = #"{"epochs":[{"epoch":1,"val_loss":0.42},{"epoch":2,"val_loss":0.31}]}"#
        try runs.insert(
            TrainingRunRecord(
                id: runID,
                method: .personalAdamW,
                state: .queued,
                createdAtMs: 100,
                startedAtMs: nil,
                finishedAtMs: nil,
                catalogScopeID: try database.catalogScopeID(),
                jobID: nil,
                sampleSummaryJSON: #"{"tagCount":1}"#,
                sampleManifestSHA256: nil,
                configJSON: #"{"epochs":2}"#,
                metricsJSON: "{}",
                artifactKind: nil,
                artifactRef: nil,
                artifactSHA256: nil,
                resultSummaryJSON: "{}",
                errorCode: nil
            )
        )
        try runs.update(
            id: runID,
            state: .succeeded,
            startedAtMs: 110,
            finishedAtMs: 120,
            metricsJSON: metrics,
            artifactKind: "adamWHead",
            artifactRef: "PersonalModels/AdamWHead/v1",
            artifactSHA256: String(repeating: "d", count: 64),
            resultSummaryJSON: #"{"published":true}"#
        )
        let fetched = try XCTUnwrap(runs.fetch(id: runID))
        XCTAssertEqual(fetched.state, .succeeded)
        XCTAssertEqual(fetched.metricsJSON, metrics)
        XCTAssertEqual(try runs.list(method: .personalAdamW).map(\.id), [runID])
        XCTAssertTrue(try runs.list(method: .featureKnn).isEmpty)
    }

    private func makePublishedPersonalSlotsFixture() throws -> PersonalSlotsFixture {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let sourceID = UUID()
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: CatalogRepository(database: database),
            sourceID: sourceID,
            assetID: assetID
        )
        let tag = try GRDBTagCatalogRepository(database: database).createTag(
            rawName: "Retrain Isolation",
            timestampMs: DatabaseTestSupport.timestampMs
        )
        let fixture = PersonalSlotsFixture(
            database: database,
            review: GRDBPersonalizationReviewRepository(database: database),
            assetID: assetID,
            tagID: tag.id
        )
        let scopeID = try database.catalogScopeID()
        let centroid = personalCapability(
            method: .personalCentroid,
            scopeID: scopeID,
            tagID: tag.id,
            revision: "centroid-v1",
            sha: String(repeating: "b", count: 64)
        )
        let adamW = personalCapability(
            method: .personalAdamW,
            scopeID: scopeID,
            tagID: tag.id,
            revision: "adamw-v1",
            sha: String(repeating: "c", count: 64)
        )
        try fixture.review.activatePersonalSuggestionBundle(centroid, activatedAtMs: 10)
        _ = try fixture.review.replacePersonalSuggestions(
            candidate: PersonalSuggestionCandidate(assetID: assetID, contentRevision: 1),
            predictions: [PersonalSuggestionPrediction(tagID: tag.id, score: 0.8)],
            expectedCapability: centroid,
            createdAtMs: 11
        )
        try fixture.review.activatePersonalSuggestionBundle(adamW, activatedAtMs: 12)
        _ = try fixture.review.replacePersonalSuggestions(
            candidate: PersonalSuggestionCandidate(assetID: assetID, contentRevision: 1),
            predictions: [PersonalSuggestionPrediction(tagID: tag.id, score: 0.7)],
            expectedCapability: adamW,
            createdAtMs: 13
        )
        return fixture
    }

    private func personalCapability(
        method: PersonalSuggestionMethod,
        scopeID: String,
        tagID: UUID,
        revision: String,
        sha: String
    ) -> PersonalModelSuggestionCapability {
        PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: scopeID,
                bundleID: method == .personalCentroid
                    ? PersonalSuggestionMethod.linearHeadBundleID
                    : PersonalSuggestionMethod.adamWHeadBundleID,
                bundleRevision: revision,
                provider: "coreml",
                modelID: "dino",
                modelRevision: "1",
                preprocessingRevision: "p1",
                elementCount: 768,
                labelVocabularyRevision: sha,
                weightsSHA256: sha,
                policyRevision: "\(revision)-policy"
            ),
            tagIDs: [tagID]
        )
    }

    private func personalMethodState(
        _ fixture: PersonalSlotsFixture,
        method: PersonalSuggestionMethod
    ) throws -> PersonalMethodState {
        try fixture.database.pool.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                    SELECT bundle_revision, weights_sha256, activated_at_ms, published_run_id
                    FROM personal_suggestion_model
                    WHERE method = ?
                    """,
                    arguments: [method.rawValue]
                )
            )
            let tagCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM personal_suggestion_tag WHERE method = ?",
                arguments: [method.rawValue]
            ) ?? 0
            let predictionCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM personal_prediction WHERE method = ?",
                arguments: [method.rawValue]
            ) ?? 0
            let predictionScore = try Double.fetchOne(
                db,
                sql: """
                SELECT score FROM personal_prediction
                WHERE method = ? AND asset_id = ? AND tag_id = ?
                """,
                arguments: [
                    method.rawValue,
                    fixture.assetID.uuidString.lowercased(),
                    fixture.tagID.uuidString.lowercased(),
                ]
            )
            return PersonalMethodState(
                bundleRevision: row["bundle_revision"],
                weightsSHA256: row["weights_sha256"],
                activatedAtMs: row["activated_at_ms"],
                publishedRunID: row["published_run_id"],
                tagCount: tagCount,
                predictionCount: predictionCount,
                predictionScore: predictionScore
            )
        }
    }
}

private struct PersonalSlotsFixture {
    let database: CatalogDatabase
    let review: GRDBPersonalizationReviewRepository
    let assetID: UUID
    let tagID: UUID
}

private struct PersonalMethodState: Equatable {
    let bundleRevision: String
    let weightsSHA256: String
    let activatedAtMs: Int64
    let publishedRunID: String?
    let tagCount: Int
    let predictionCount: Int
    let predictionScore: Double?
}
