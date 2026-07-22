import GRDB
import XCTest
@testable import ImageAll

final class PersonalizationPersistenceTests: XCTestCase {
    func testFreshCatalogCreatesPersonalizationTables() throws {
        let database = try CatalogDatabase.open(at: DatabaseTestSupport.makeTempDatabaseURL())

        let tables = try database.pool.read { db in
            try DatabaseTestSupport.tableNames(db)
        }

        XCTAssertTrue(tables.contains("feature"))
        XCTAssertTrue(tables.contains("tag_model_revision"))
        XCTAssertTrue(tables.contains("tag_model_sample"))
        XCTAssertTrue(tables.contains("tag_model"))
        XCTAssertTrue(tables.contains("prediction"))
    }

    func testV003CatalogFactsSurviveV004Upgrade() throws {
        let url = try DatabaseTestSupport.makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let pool = try DatabasePool(path: url.path, configuration: config)
        var migrator = DatabaseTestSupport.makeV002OnlyMigrator()
        V003AddDerivedImageCacheMigration.register(on: &migrator)
        try migrator.migrate(pool)

        let sourceID = UUID()
        let assetID = UUID()
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'v003 sentinel', ?, 0, 0, 'active', 1, 1)
                """,
                arguments: [sourceID.uuidString.lowercased(), DatabaseTestSupport.folderBookmark()]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, locator_state,
                    media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'file', 'sentinel.jpg', 'current', 'public.jpeg', 1, 'available', 1, 1, 'sentinel.jpg')
                """,
                arguments: [assetID.uuidString.lowercased(), sourceID.uuidString.lowercased()]
            )
        }
        try CatalogDatabase.closePool(pool)

        let upgraded = try CatalogDatabase.open(at: url)
        try upgraded.pool.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT display_name FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()]), "v003 sentinel")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT relative_path FROM asset WHERE id = ?", arguments: [assetID.uuidString.lowercased()]), "sentinel.jpg")
            XCTAssertTrue(try db.tableExists("feature"))
        }
    }

    func testModelPublicationAndPredictionsKeepManualDecisionAuthoritative() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let catalog = GRDBPersonalizationRepository(database: fixture.database)
        let positive = fixture.ids.assetNewest
        let negative = fixture.ids.assetOldest
        let candidate = fixture.ids.assetDuplicateTimeA

        _ = try fixture.tags.batchReject(
            tagID: fixture.ids.tagFamily,
            assetIDs: [negative],
            timestampMs: DatabaseTestSupport.timestampMs
        )

        for (assetID, cacheKey) in [
            (positive, "objects/20/positive.fprint"),
            (negative, "objects/20/negative.fprint"),
            (candidate, "objects/20/candidate.fprint"),
        ] {
            try catalog.registerFeature(
                FeatureRegistration(
                    identity: FeatureIdentity(assetID: assetID, contentRevision: 1),
                    elementCount: 4,
                    byteCount: 16,
                    vectorSHA256: Data(repeating: UInt8(cacheKey.count), count: 32),
                    cacheKey: cacheKey,
                    createdAtMs: DatabaseTestSupport.timestampMs
                )
            )
        }

        let revision = ModelRevisionRegistration(
            tagID: fixture.ids.tagFamily,
            revision: 1,
            threshold: 0,
            neighborCount: 1,
            sampleBudgetPerRole: 12,
            samples: [
                ModelSampleRegistration(identity: FeatureIdentity(assetID: positive, contentRevision: 1), role: .positive, rank: 0),
                ModelSampleRegistration(identity: FeatureIdentity(assetID: negative, contentRevision: 1), role: .negative, rank: 0),
            ],
            createdAtMs: DatabaseTestSupport.timestampMs
        )
        try catalog.publishModelRevision(revision)

        try catalog.replacePredictions(
            tagID: fixture.ids.tagFamily,
            modelRevision: 1,
            candidateAssetIDs: [candidate],
            predictions: [
                PredictionRegistration(assetID: candidate, contentRevision: 1, score: 0.4),
            ],
            createdAtMs: DatabaseTestSupport.timestampMs
        )
        XCTAssertEqual(try catalog.pendingPredictions(tagID: fixture.ids.tagFamily, limit: 10).map(\.assetID), [candidate])

        _ = try fixture.tags.batchAccept(
            tagID: fixture.ids.tagFamily,
            assetIDs: [candidate],
            timestampMs: DatabaseTestSupport.timestampMs + 1
        )
        XCTAssertEqual(try catalog.pendingPredictions(tagID: fixture.ids.tagFamily, limit: 10), [])
    }

    func testFailedModelPublicationLeavesNoPartialRevision() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let catalog = GRDBPersonalizationRepository(database: fixture.database)
        let positive = fixture.ids.assetNewest
        let negative = fixture.ids.assetOldest

        _ = try fixture.tags.batchReject(
            tagID: fixture.ids.tagFamily,
            assetIDs: [negative],
            timestampMs: DatabaseTestSupport.timestampMs
        )
        try catalog.registerFeature(
            FeatureRegistration(
                identity: FeatureIdentity(assetID: positive, contentRevision: 1),
                elementCount: 4,
                byteCount: 16,
                vectorSHA256: Data(repeating: 1, count: 32),
                cacheKey: "objects/20/positive-only.fprint",
                createdAtMs: DatabaseTestSupport.timestampMs
            )
        )

        XCTAssertThrowsError(
            try catalog.publishModelRevision(
                ModelRevisionRegistration(
                    tagID: fixture.ids.tagFamily,
                    revision: 1,
                    threshold: 0,
                    neighborCount: 1,
                    sampleBudgetPerRole: 12,
                    samples: [
                        ModelSampleRegistration(identity: FeatureIdentity(assetID: positive, contentRevision: 1), role: .positive, rank: 0),
                        ModelSampleRegistration(identity: FeatureIdentity(assetID: negative, contentRevision: 1), role: .negative, rank: 0),
                    ],
                    createdAtMs: DatabaseTestSupport.timestampMs
                )
            )
        ) { error in
            XCTAssertEqual(error as? PersonalizationCatalogError, .missingFeature)
        }

        try fixture.database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_model_revision") ?? -1, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_model_sample") ?? -1, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_model") ?? -1, 0)
        }
    }

    func testPersonalTrainingSnapshotIncludesOnlyTrainableActiveManualDecisions() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        try fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'active' WHERE id = ?",
                arguments: [fixture.ids.sourceA.uuidString.lowercased()]
            )
        }
        let accepted = [fixture.ids.assetNewest, fixture.ids.assetMiddle]
        let rejected = [fixture.ids.assetDuplicateTimeA, fixture.ids.assetDuplicateTimeB]
        _ = try fixture.tags.batchAccept(
            tagID: fixture.ids.tagFamily,
            assetIDs: accepted,
            timestampMs: DatabaseTestSupport.timestampMs + 1
        )
        _ = try fixture.tags.batchReject(
            tagID: fixture.ids.tagFamily,
            assetIDs: rejected,
            timestampMs: DatabaseTestSupport.timestampMs + 2
        )
        _ = try fixture.tags.batchAccept(
            tagID: fixture.ids.tagWork,
            assetIDs: [fixture.ids.assetNewest],
            timestampMs: DatabaseTestSupport.timestampMs + 3
        )

        let snapshot = try GRDBPersonalizationReviewRepository(
            database: fixture.database
        ).personalTrainingSnapshot()

        XCTAssertEqual(snapshot.catalogScopeID, try fixture.database.catalogScopeID())
        XCTAssertEqual(snapshot.personalTagIDs, [fixture.ids.tagFamily])
        XCTAssertEqual(
            Set(snapshot.decisions),
            Set(
                accepted.map {
                    PersonalTrainingDecision(
                        assetID: $0,
                        contentRevision: 1,
                        tagID: fixture.ids.tagFamily,
                        state: .manualAccepted
                    )
                }
            )
        )
        XCTAssertFalse(snapshot.decisions.contains { $0.state == .manualRejected })
        XCTAssertFalse(snapshot.decisions.contains { $0.tagID == fixture.ids.tagWork })
        XCTAssertFalse(snapshot.decisions.contains { $0.tagID == fixture.ids.tagArchived })

        let scoped = try GRDBPersonalizationReviewRepository(
            database: fixture.database
        ).personalTrainingSnapshot(limitingToAssetIDs: Set(accepted.prefix(2)))
        XCTAssertEqual(scoped.personalTagIDs, [fixture.ids.tagFamily])
        XCTAssertEqual(Set(scoped.decisions.map(\.assetID)), Set(accepted.prefix(2)))

        let insufficientScope = try GRDBPersonalizationReviewRepository(
            database: fixture.database
        ).personalTrainingSnapshot(limitingToAssetIDs: Set(accepted.prefix(1)))
        XCTAssertTrue(insufficientScope.personalTagIDs.isEmpty)
        XCTAssertTrue(insufficientScope.decisions.isEmpty)
    }

    func testPersonalTrainingSnapshotUsesAllAcceptedSamplesWithoutPerTagCap() throws {
        let url = try DatabaseTestSupport.makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let (_, acceptedTagID) = try CatalogQueryTestSupport.seedScaleCatalog(
            database: database,
            assetCount: 30
        )
        // Even indices are folder/file assets eligible for personal training.
        let assetIDs = (0..<15).map { CatalogQueryTestSupport.scaleAssetID($0 * 2) }
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM asset_tag_decision")
            for (index, assetID) in assetIDs.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                    VALUES (?, ?, 'accepted', ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        acceptedTagID.uuidString.lowercased(),
                        1_000 + index,
                    ]
                )
            }
        }

        let repository = GRDBPersonalizationReviewRepository(database: database)
        let scoped = try repository.personalTrainingSnapshot(limitingToAssetIDs: Set(assetIDs))
        XCTAssertEqual(scoped.personalTagIDs, [acceptedTagID])
        XCTAssertEqual(scoped.decisions.count, 15)
        XCTAssertEqual(Set(scoped.decisions.map(\.assetID)), Set(assetIDs))

        let historical = try repository.personalTrainingSnapshot()
        XCTAssertEqual(historical.personalTagIDs, [acceptedTagID])
        XCTAssertEqual(historical.decisions.count, 15)
        XCTAssertEqual(Set(historical.decisions.map(\.assetID)), Set(assetIDs))
    }

    func testPersonalTrainingSnapshotLimitingToTagIDsExcludesUnselectedTags() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        try fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'active' WHERE id = ?",
                arguments: [fixture.ids.sourceA.uuidString.lowercased()]
            )
        }
        let familyAssets = [fixture.ids.assetNewest, fixture.ids.assetMiddle]
        let workAssets = [fixture.ids.assetDuplicateTimeA, fixture.ids.assetDuplicateTimeB]
        _ = try fixture.tags.batchAccept(
            tagID: fixture.ids.tagFamily,
            assetIDs: familyAssets,
            timestampMs: DatabaseTestSupport.timestampMs + 1
        )
        _ = try fixture.tags.batchAccept(
            tagID: fixture.ids.tagWork,
            assetIDs: workAssets,
            timestampMs: DatabaseTestSupport.timestampMs + 2
        )

        let repository = GRDBPersonalizationReviewRepository(database: fixture.database)

        let emptyTags = try repository.personalTrainingSnapshot(
            limitingToTagIDs: [],
            limitingToAssetIDs: nil
        )
        XCTAssertTrue(emptyTags.personalTagIDs.isEmpty)
        XCTAssertTrue(emptyTags.decisions.isEmpty)

        let familyOnly = try repository.personalTrainingSnapshot(
            limitingToTagIDs: [fixture.ids.tagFamily],
            limitingToAssetIDs: nil
        )
        XCTAssertEqual(familyOnly.personalTagIDs, [fixture.ids.tagFamily])
        XCTAssertEqual(Set(familyOnly.decisions.map(\.assetID)), Set(familyAssets))
        XCTAssertFalse(familyOnly.decisions.contains { $0.tagID == fixture.ids.tagWork })

        let workOnOneAsset = try repository.personalTrainingSnapshot(
            limitingToTagIDs: [fixture.ids.tagWork],
            limitingToAssetIDs: [fixture.ids.assetDuplicateTimeA]
        )
        XCTAssertTrue(workOnOneAsset.personalTagIDs.isEmpty)
        XCTAssertTrue(workOnOneAsset.decisions.isEmpty)

        let workOnBothAssets = try repository.personalTrainingSnapshot(
            limitingToTagIDs: [fixture.ids.tagWork],
            limitingToAssetIDs: Set(workAssets)
        )
        XCTAssertEqual(workOnBothAssets.personalTagIDs, [fixture.ids.tagWork])
        XCTAssertEqual(Set(workOnBothAssets.decisions.map(\.assetID)), Set(workAssets))
    }
}
