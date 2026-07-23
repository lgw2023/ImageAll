import XCTest
@testable import ImageAll

final class SuggestionThresholdTests: XCTestCase {
    func testV015SeedsThreeDefaultThresholdsAtZero() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try database.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
        let thresholds = GRDBSuggestionThresholdRepository(database: database)
        let defaults = try thresholds.defaults()
        XCTAssertEqual(defaults.featureKnn, 0)
        XCTAssertEqual(defaults.personalCentroid, 0)
        XCTAssertEqual(defaults.personalAdamW, 0)
    }

    func testOverrideTakesPrecedenceOverDefaultAndClearRestoresDefault() throws {
        let fixture = try makeTagFixture()
        let thresholds = GRDBSuggestionThresholdRepository(database: fixture.database)
        try thresholds.setDefault(method: .personalAdamW, minScore: 0.1, updatedAtMs: 1)
        XCTAssertEqual(
            try thresholds.effectiveMinScore(tagID: fixture.tagID, method: .personalAdamW),
            0.1
        )
        try thresholds.setOverride(
            tagID: fixture.tagID,
            method: .personalAdamW,
            minScore: 0.4,
            updatedAtMs: 2
        )
        XCTAssertEqual(
            try thresholds.effectiveMinScore(tagID: fixture.tagID, method: .personalAdamW),
            0.4
        )
        try thresholds.clearOverride(tagID: fixture.tagID, method: .personalAdamW)
        XCTAssertEqual(
            try thresholds.effectiveMinScore(tagID: fixture.tagID, method: .personalAdamW),
            0.1
        )
    }

    func testMethodsDoNotShareDefaults() throws {
        let fixture = try makeTagFixture()
        let thresholds = GRDBSuggestionThresholdRepository(database: fixture.database)
        try thresholds.setDefault(method: .featureKnn, minScore: 0.2, updatedAtMs: 1)
        try thresholds.setDefault(method: .personalCentroid, minScore: 0.3, updatedAtMs: 1)
        let defaults = try thresholds.defaults()
        XCTAssertEqual(defaults.featureKnn, 0.2)
        XCTAssertEqual(defaults.personalCentroid, 0.3)
        XCTAssertEqual(defaults.personalAdamW, 0)
        XCTAssertEqual(
            try thresholds.effectiveMinScore(tagID: fixture.tagID, method: .personalAdamW),
            0
        )
    }

    func testTagOverrideListIncludesActiveTagsBeforeTheyHaveOverrides() throws {
        let fixture = try makeTagFixture()
        let thresholds = GRDBSuggestionThresholdRepository(database: fixture.database)

        XCTAssertEqual(
            try thresholds.listTagOverrides(),
            [
                SuggestionTagThresholdOverrideRow(
                    tagID: fixture.tagID,
                    displayName: "板栗",
                    overrides: [:]
                ),
            ]
        )
    }

    func testPrunePendingBelowThresholdOnlyRemovesMatchingMethodRows() throws {
        let fixture = try makeTagFixture()
        let thresholds = GRDBSuggestionThresholdRepository(database: fixture.database)
        let tagID = fixture.tagID
        let assetLow = fixture.assetIDs[0]
        let assetHigh = fixture.assetIDs[1]
        try fixture.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag_model_revision (
                    tag_id, revision, provider, request_revision, preprocessing_revision,
                    threshold, positive_count, negative_count, neighbor_count,
                    sample_budget_per_role, created_at_ms
                ) VALUES (?, 1, 'vision-feature-print', 1, 1, 0, 2, 2, 2, 12, ?)
                """,
                arguments: [tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
            try db.execute(
                sql: """
                INSERT INTO tag_model (tag_id, current_revision, updated_at_ms)
                VALUES (?, 1, ?)
                """,
                arguments: [tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
            for (assetID, score) in [(assetLow, 0.05), (assetHigh, 0.5)] {
                try db.execute(
                    sql: """
                    INSERT INTO prediction (
                        asset_id, tag_id, content_revision, model_revision,
                        score, state, created_at_ms
                    ) VALUES (?, ?, 1, 1, ?, 'pendingReview', ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        tagID.uuidString.lowercased(),
                        score,
                        DatabaseTestSupport.timestampMs,
                    ]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_model (
                    method, catalog_scope_id, bundle_id, bundle_revision, provider, model_id,
                    model_revision, preprocessing_revision, element_count,
                    label_vocabulary_revision, weights_sha256, policy_revision, activated_at_ms
                ) VALUES (
                    'personalCentroid', ?, 'app.personal.linear-head.v1', '1', 'app', 'head',
                    '1', '1', 4, ?, ?, 'policy', ?
                )
                """,
                arguments: [
                    fixture.scopeID,
                    String(repeating: "b", count: 64),
                    String(repeating: "c", count: 64),
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_tag (method, tag_id) VALUES ('personalCentroid', ?)
                """,
                arguments: [tagID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO personal_prediction (
                    method, asset_id, tag_id, content_revision, score, state, created_at_ms
                ) VALUES ('personalCentroid', ?, ?, 1, 0.05, 'pendingReview', ?)
                """,
                arguments: [
                    assetLow.uuidString.lowercased(),
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }

        let deletedFeature = try thresholds.prunePendingBelowThreshold(
            tagID: tagID,
            method: .featureKnn,
            minScore: 0.1
        )
        XCTAssertEqual(deletedFeature, 1)

        let remainingFeature = try fixture.database.pool.read { db in
            try Double.fetchAll(
                db,
                sql: """
                SELECT score FROM prediction
                WHERE tag_id = ? AND state = 'pendingReview'
                ORDER BY score ASC
                """,
                arguments: [tagID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(remainingFeature, [0.5])

        let personalStillThere = try fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM personal_prediction
                WHERE tag_id = ? AND method = 'personalCentroid' AND state = 'pendingReview'
                """,
                arguments: [tagID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(personalStillThere, 1)
    }

    func testRejectsNonFiniteScores() throws {
        let fixture = try makeTagFixture()
        let thresholds = GRDBSuggestionThresholdRepository(database: fixture.database)
        XCTAssertThrowsError(
            try thresholds.setDefault(method: .featureKnn, minScore: .nan, updatedAtMs: 1)
        ) { error in
            XCTAssertEqual(error as? SuggestionThresholdError, .invalidScore)
        }
    }

    func testReferenceSuggestionUsesLatestTwentyRejectedScoresWithoutCrossingMethods() throws {
        let fixture = try makeTagFixture(assetCount: 25)
        let thresholds = GRDBSuggestionThresholdRepository(database: fixture.database)
        try fixture.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag_model_revision (
                    tag_id, revision, provider, request_revision, preprocessing_revision,
                    threshold, positive_count, negative_count, neighbor_count,
                    sample_budget_per_role, created_at_ms
                ) VALUES (?, 1, 'vision-feature-print', 1, 1, 0, 2, 2, 2, 12, 1)
                """,
                arguments: [fixture.tagID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_model (
                    method, catalog_scope_id, bundle_id, bundle_revision, provider, model_id,
                    model_revision, preprocessing_revision, element_count,
                    label_vocabulary_revision, weights_sha256, policy_revision, activated_at_ms
                ) VALUES (
                    'personalCentroid', ?, 'app.personal.linear-head.v1', '1', 'app', 'head',
                    '1', '1', 4, ?, ?, 'policy', 1
                )
                """,
                arguments: [
                    fixture.scopeID,
                    String(repeating: "b", count: 64),
                    String(repeating: "c", count: 64),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO personal_suggestion_tag (method, tag_id)
                VALUES ('personalCentroid', ?)
                """,
                arguments: [fixture.tagID.uuidString.lowercased()]
            )
            for (index, assetID) in fixture.assetIDs.enumerated() {
                let decidedAt = Int64(100 + index)
                try db.execute(
                    sql: """
                    INSERT INTO prediction (
                        asset_id, tag_id, content_revision, model_revision,
                        score, state, created_at_ms
                    ) VALUES (?, ?, 1, 1, ?, 'pendingReview', ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        fixture.tagID.uuidString.lowercased(),
                        Double(index + 1) / 10,
                        decidedAt - 1,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO personal_prediction (
                        method, asset_id, tag_id, content_revision,
                        score, state, created_at_ms
                    ) VALUES ('personalCentroid', ?, ?, 1, ?, 'pendingReview', ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        fixture.tagID.uuidString.lowercased(),
                        Double(index + 1),
                        decidedAt - 1,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO asset_tag_decision (
                        asset_id, tag_id, decision, updated_at_ms
                    ) VALUES (?, ?, 'rejected', ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        fixture.tagID.uuidString.lowercased(),
                        decidedAt,
                    ]
                )
            }
        }

        XCTAssertEqual(
            try thresholds.referenceSuggestion(
                tagID: fixture.tagID,
                method: .featureKnn
            ),
            SuggestionThresholdReference(
                minScore: Double(23) / 10,
                rejectedSampleCount: 20
            )
        )
        XCTAssertEqual(
            try thresholds.referenceSuggestion(
                tagID: fixture.tagID,
                method: .personalCentroid
            ),
            SuggestionThresholdReference(minScore: 23, rejectedSampleCount: 20)
        )
        XCTAssertNil(
            try thresholds.referenceSuggestion(
                tagID: fixture.tagID,
                method: .personalAdamW
            )
        )
    }

    func testReferenceSuggestionRequiresFiveTraceableRejectedScores() throws {
        let fixture = try makeTagFixture(assetCount: 4)
        let thresholds = GRDBSuggestionThresholdRepository(database: fixture.database)
        try fixture.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag_model_revision (
                    tag_id, revision, provider, request_revision, preprocessing_revision,
                    threshold, positive_count, negative_count, neighbor_count,
                    sample_budget_per_role, created_at_ms
                ) VALUES (?, 1, 'vision-feature-print', 1, 1, 0, 2, 2, 2, 12, 1)
                """,
                arguments: [fixture.tagID.uuidString.lowercased()]
            )
            for (index, assetID) in fixture.assetIDs.enumerated() {
                let decidedAt = Int64(100 + index)
                try db.execute(
                    sql: """
                    INSERT INTO prediction (
                        asset_id, tag_id, content_revision, model_revision,
                        score, state, created_at_ms
                    ) VALUES (?, ?, 1, 1, ?, 'pendingReview', ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        fixture.tagID.uuidString.lowercased(),
                        Double(index + 1) / 10,
                        decidedAt - 1,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO asset_tag_decision (
                        asset_id, tag_id, decision, updated_at_ms
                    ) VALUES (?, ?, 'rejected', ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        fixture.tagID.uuidString.lowercased(),
                        decidedAt,
                    ]
                )
            }
        }

        XCTAssertNil(
            try thresholds.referenceSuggestion(
                tagID: fixture.tagID,
                method: .featureKnn
            )
        )
    }

    private struct TagFixture {
        let database: CatalogDatabase
        let scopeID: String
        let tagID: UUID
        let assetIDs: [UUID]
    }

    private func makeTagFixture(assetCount: Int = 2) throws -> TagFixture {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let scopeID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT scope_id FROM catalog_scope WHERE singleton = 1")!
        }
        let tagID = UUID()
        let sourceID = UUID()
        let assetIDs = (0 ..< assetCount).map { _ in UUID() }
        try database.pool.write { db in
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
            for (index, assetID) in assetIDs.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, locator_state, media_type,
                        content_revision, availability, record_created_at_ms, record_updated_at_ms,
                        file_name
                    ) VALUES (?, ?, 'file', ?, 'current', 'public.jpeg', 1, 'available', ?, ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        sourceID.uuidString.lowercased(),
                        "a\(index).jpg",
                        DatabaseTestSupport.timestampMs,
                        DatabaseTestSupport.timestampMs,
                        "a\(index).jpg",
                    ]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO tag (
                    id, name, normalized_name, state, created_at_ms, updated_at_ms
                ) VALUES (?, '板栗', '板栗', 'active', ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }
        return TagFixture(
            database: database,
            scopeID: scopeID,
            tagID: tagID,
            assetIDs: assetIDs
        )
    }
}
