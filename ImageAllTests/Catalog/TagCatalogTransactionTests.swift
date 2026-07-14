import GRDB
import XCTest
@testable import ImageAll

final class TagCatalogTransactionTests: XCTestCase {
    func testListTagsStableOrderAndArchivedFilter() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let active = try fixture.tags.listTags(includeArchived: false)
        XCTAssertEqual(active.map(\.displayName), ["Family", "Work"])

        let all = try fixture.tags.listTags(includeArchived: true)
        XCTAssertEqual(all.map(\.displayName), ["Family", "Legacy", "Work"])
    }

    func testSelectionAggregateCountsSumToSelectionSize() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let selection = [fixture.ids.assetNewest, fixture.ids.assetMiddle, fixture.ids.assetOldest]
        let aggregates = try fixture.tags.selectionAggregate(
            tagIDs: [fixture.ids.tagFamily, fixture.ids.tagWork],
            assetIDs: selection
        )
        XCTAssertEqual(aggregates.count, 2)
        for aggregate in aggregates {
            XCTAssertEqual(
                aggregate.acceptedCount + aggregate.rejectedCount + aggregate.unknownCount,
                selection.count
            )
        }
    }

    func testMissingAssetFailsWholeAggregate() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        XCTAssertThrowsError(
            try fixture.tags.selectionAggregate(
                tagIDs: [fixture.ids.tagFamily],
                assetIDs: [fixture.ids.assetNewest, UUID()]
            )
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .notFound)
        }
    }

    func testCreateTagUsesDomainNormalization() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let tag = try fixture.tags.createTag(rawName: "  Café  ", timestampMs: DatabaseTestSupport.timestampMs)
        XCTAssertEqual(tag.displayName, "Café")
        XCTAssertEqual(tag.normalizedName, "café")
    }

    func testDuplicateNormalizedTagIsRejected() throws {
        try testRepositoryDuplicateTagReturnsStructuredError()
    }

    func testRepositoryDuplicateTagReturnsStructuredError() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        XCTAssertThrowsError(
            try fixture.tags.createTag(rawName: "FAMILY", timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .duplicateTag)
        }
    }

    func testConcurrentDatabaseNormalizedNameUniqueConstraintAllowsExactlyOneInsert() throws {
        let url = try DatabaseTestSupport.makeTempDatabaseURL()
        _ = try CatalogDatabase.open(at: url)

        let group = DispatchGroup()
        let lock = NSLock()
        var outcomes: [Result<Void, Error>] = []

        for index in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    var config = Configuration()
                    config.prepareDatabase { db in
                        try db.execute(sql: "PRAGMA foreign_keys = ON")
                    }
                    let queue = try DatabaseQueue(path: url.path, configuration: config)
                    defer { try? queue.close() }
                    let tagID = UUID()
                    try queue.write { db in
                        try db.execute(
                            sql: """
                            INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                            VALUES (?, ?, ?, 'active', ?, ?)
                            """,
                            arguments: [
                                tagID.uuidString.lowercased(),
                                "Race \(index)",
                                "racetag",
                                DatabaseTestSupport.timestampMs,
                                DatabaseTestSupport.timestampMs,
                            ]
                        )
                    }
                    lock.lock()
                    outcomes.append(.success(()))
                    lock.unlock()
                } catch {
                    lock.lock()
                    outcomes.append(.failure(error))
                    lock.unlock()
                }
            }
        }
        group.wait()

        XCTAssertEqual(outcomes.filter { if case .success = $0 { return true }; return false }.count, 1)
        let failures = outcomes.compactMap { result -> Error? in
            if case let .failure(error) = result { return error }
            return nil
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0] is DatabaseError)

        let database = try CatalogDatabase.open(at: url)
        let rowCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE normalized_name = 'racetag'") ?? 0
        }
        XCTAssertEqual(rowCount, 1)
    }

    func testConcurrentDuplicateNormalizedTagIsRejectedByDatabase() throws {
        try testConcurrentDatabaseNormalizedNameUniqueConstraintAllowsExactlyOneInsert()
    }

    func testCreateTagMapsNonDuplicateCheckConstraintToPersistenceFailure() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_tag_insert_check_fail
                BEFORE INSERT ON tag
                WHEN NEW.normalized_name = 'triggerfailtag'
                BEGIN
                    SELECT RAISE(ABORT, 'CHECK constraint failed: state');
                END
                """)
        }
        let tags = GRDBTagCatalogRepository(database: database)
        XCTAssertThrowsError(
            try tags.createTag(rawName: "TriggerFailTag", timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
            XCTAssertNotEqual(error as? CatalogQueryError, .duplicateTag)
            XCTAssertFalse(String(describing: error).contains("TriggerFailTag"))
        }
    }

    func testBatchAcceptRejectAndClearReturnPriorStates() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let selection = [fixture.ids.assetOldest, fixture.ids.assetNoTime]

        let accepted = try fixture.tags.batchAccept(
            tagID: fixture.ids.tagWork,
            assetIDs: selection,
            timestampMs: DatabaseTestSupport.timestampMs
        )
        XCTAssertEqual(accepted.priorStates.count, 2)
        XCTAssertTrue(accepted.priorStates.allSatisfy { $0.priorState == .unknown })

        let rejected = try fixture.tags.batchReject(
            tagID: fixture.ids.tagWork,
            assetIDs: [fixture.ids.assetOldest],
            timestampMs: DatabaseTestSupport.timestampMs
        )
        XCTAssertEqual(rejected.priorStates.first?.priorState, .accepted)

        let cleared = try fixture.tags.batchClear(
            tagID: fixture.ids.tagWork,
            assetIDs: selection,
            timestampMs: DatabaseTestSupport.timestampMs
        )
        XCTAssertTrue(cleared.priorStates.contains { $0.priorState == .accepted || $0.priorState == .rejected })
    }

    func testBatchMissingAssetFailsWholeOperationWithoutWrites() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let missing = UUID()
        let selection = [fixture.ids.assetNewest, missing]

        let decisionCountBefore = try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? 0
        }

        for operation: (String, () throws -> Void) in [
            ("batchAccept", {
                _ = try fixture.tags.batchAccept(
                    tagID: fixture.ids.tagWork,
                    assetIDs: selection,
                    timestampMs: DatabaseTestSupport.timestampMs
                )
            }),
            ("batchReject", {
                _ = try fixture.tags.batchReject(
                    tagID: fixture.ids.tagWork,
                    assetIDs: selection,
                    timestampMs: DatabaseTestSupport.timestampMs
                )
            }),
            ("batchClear", {
                _ = try fixture.tags.batchClear(
                    tagID: fixture.ids.tagWork,
                    assetIDs: selection,
                    timestampMs: DatabaseTestSupport.timestampMs
                )
            }),
        ] {
            XCTAssertThrowsError(try operation.1(), operation.0) { error in
                XCTAssertEqual(error as? CatalogQueryError, .notFound)
            }
        }

        let decisionCountAfter = try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? 0
        }
        XCTAssertEqual(decisionCountBefore, decisionCountAfter)
    }

    func testArchivedTagRejectsMutations() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        XCTAssertThrowsError(
            try fixture.tags.batchAccept(
                tagID: fixture.ids.tagArchived,
                assetIDs: [fixture.ids.assetNewest],
                timestampMs: DatabaseTestSupport.timestampMs
            )
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .archivedTag)
        }
    }

    func testEmptyAndTooLargeSelectionAreRejected() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        XCTAssertThrowsError(
            try fixture.tags.batchAccept(tagID: fixture.ids.tagFamily, assetIDs: [], timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .emptySelection)
        }

        let tooMany = (0..<10_001).map { _ in UUID() }
        XCTAssertThrowsError(
            try fixture.tags.batchAccept(tagID: fixture.ids.tagFamily, assetIDs: tooMany, timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .selectionTooLarge)
        }
    }

    func testCreateAndApplyReturnsTagIdentityAndPriorStates() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let result = try fixture.tags.createTagAndApply(
            rawName: "Applied",
            assetIDs: [fixture.ids.assetOldest, fixture.ids.assetNoTime],
            decision: .accepted,
            timestampMs: DatabaseTestSupport.timestampMs
        )
        XCTAssertEqual(result.displayName, "Applied")
        XCTAssertEqual(result.normalizedName, "applied")
        XCTAssertEqual(result.priorStates.count, 2)
        XCTAssertTrue(result.priorStates.allSatisfy { $0.priorState == .unknown })

        let listed = try fixture.tags.listTags(includeArchived: false)
        XCTAssertTrue(listed.contains { $0.id == result.tagID && $0.displayName == "Applied" })
    }

    func testCreateAndApplyUndoUsesReturnedSnapshot() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let result = try fixture.tags.createTagAndApply(
            rawName: "UndoMe",
            assetIDs: [fixture.ids.assetMiddle],
            decision: .accepted,
            timestampMs: DatabaseTestSupport.timestampMs
        )
        try fixture.tags.restorePriorStates(result.restoreSnapshot(), timestampMs: DatabaseTestSupport.timestampMs)

        let detail = try fixture.query.fetchInspectorDetail(assetID: fixture.ids.assetMiddle)
        let tag = detail.tags.first { $0.tagID == result.tagID }
        XCTAssertEqual(tag?.decision, .unknown)
    }

    func testCreateAndApplyRollsBackWhenDecisionPhaseFails() throws {
        let fault = try CatalogQueryTestSupport.openFaultDatabase()
        let assetID = UUID()
        try fault.repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: UUID(),
                sourceKind: .folder,
                displayName: "Folder",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: assetID,
                locatorKind: .file,
                relativePath: "photo.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )
        try fault.database.pool.write { db in
            try CatalogQueryTestFaultSupport.setFaultMode(.failDecisionWrites, on: db)
        }

        XCTAssertThrowsError(
            try fault.tags.createTagAndApply(
                rawName: "RollbackMe",
                assetIDs: [assetID],
                decision: .accepted,
                timestampMs: DatabaseTestSupport.timestampMs
            )
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
            XCTAssertFalse(String(describing: error).contains("INSERT"))
        }

        try fault.database.pool.read { db in
            let tagCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name = 'RollbackMe'") ?? 0
            let decisionCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? 0
            XCTAssertEqual(tagCount, 0)
            XCTAssertEqual(decisionCount, 0)
        }
    }

    func testBatchOver500RollsBackWhenLaterWriteFails() throws {
        let fault = try CatalogQueryTestSupport.openFaultDatabase()
        let sourceID = UUID()
        let firstAsset = UUID()
        try fault.repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: sourceID,
                sourceKind: .folder,
                displayName: "Folder",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: firstAsset,
                locatorKind: .file,
                relativePath: "first.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )

        var assetIDs = [firstAsset]
        try fault.database.pool.write { db in
            for index in 1..<1_200 {
                let assetID = UUID()
                assetIDs.append(assetID)
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms
                    ) VALUES (?, ?, 'file', ?, NULL, 'current', 'public.jpeg', 1, 'available', ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        sourceID.uuidString.lowercased(),
                        "bulk/\(index).jpg",
                        DatabaseTestSupport.timestampMs,
                        DatabaseTestSupport.timestampMs,
                    ]
                )
            }
            try CatalogQueryTestFaultSupport.setFaultMode(.failAfter500DecisionWrites, on: db)
        }

        let tag = try fault.tags.createTag(rawName: "Bulk", timestampMs: DatabaseTestSupport.timestampMs)
        XCTAssertThrowsError(
            try fault.tags.batchAccept(tagID: tag.id, assetIDs: assetIDs, timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
        }

        let decisionCount = try fault.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset_tag_decision WHERE tag_id = ?",
                arguments: [tag.id.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(decisionCount, 0)
    }

    func testChunkedBatchRemainsSingleTransaction() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let tags = GRDBTagCatalogRepository(database: database)
        let sourceID = UUID()
        let firstAsset = UUID()
        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: sourceID,
                sourceKind: .folder,
                displayName: "Folder",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: firstAsset,
                locatorKind: .file,
                relativePath: "first.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )

        var assetIDs = [firstAsset]
        try database.pool.write { db in
            for index in 1..<1_200 {
                let assetID = UUID()
                assetIDs.append(assetID)
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms
                    ) VALUES (?, ?, 'file', ?, NULL, 'current', 'public.jpeg', 1, 'available', ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        sourceID.uuidString.lowercased(),
                        "bulk/\(index).jpg",
                        DatabaseTestSupport.timestampMs,
                        DatabaseTestSupport.timestampMs,
                    ]
                )
            }
        }

        let tag = try tags.createTag(rawName: "Bulk", timestampMs: DatabaseTestSupport.timestampMs)
        _ = try tags.batchAccept(tagID: tag.id, assetIDs: assetIDs, timestampMs: DatabaseTestSupport.timestampMs)

        let decisionCount = try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset_tag_decision WHERE tag_id = ?",
                arguments: [tag.id.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(decisionCount, assetIDs.count)
    }

    func testRestorePriorStatesRestoresMixedUnknownAcceptedRejected() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let selection = [fixture.ids.assetOldest, fixture.ids.assetNoTime, fixture.ids.assetMiddle]
        let snapshot = TagMutationPriorStateSnapshot(
            tagID: fixture.ids.tagWork,
            priorStates: [
                TagMutationPriorState(assetID: fixture.ids.assetOldest, priorState: .unknown),
                TagMutationPriorState(assetID: fixture.ids.assetNoTime, priorState: .accepted),
                TagMutationPriorState(assetID: fixture.ids.assetMiddle, priorState: .rejected),
            ]
        )

        _ = try fixture.tags.batchAccept(
            tagID: fixture.ids.tagWork,
            assetIDs: selection,
            timestampMs: DatabaseTestSupport.timestampMs
        )
        try fixture.tags.restorePriorStates(snapshot, timestampMs: DatabaseTestSupport.timestampMs)

        let detailOldest = try fixture.query.fetchInspectorDetail(assetID: fixture.ids.assetOldest)
        let workOldest = detailOldest.tags.first { $0.tagID == fixture.ids.tagWork }
        XCTAssertEqual(workOldest?.decision, .unknown)

        let detailNoTime = try fixture.query.fetchInspectorDetail(assetID: fixture.ids.assetNoTime)
        let workNoTime = detailNoTime.tags.first { $0.tagID == fixture.ids.tagWork }
        XCTAssertEqual(workNoTime?.decision, .accepted)

        let detailMiddle = try fixture.query.fetchInspectorDetail(assetID: fixture.ids.assetMiddle)
        let workMiddle = detailMiddle.tags.first { $0.tagID == fixture.ids.tagWork }
        XCTAssertEqual(workMiddle?.decision, .rejected)
    }

    func testRestoreMixedPriorStatesRollsBackWhenLaterWriteFails() throws {
        let fault = try CatalogQueryTestSupport.openFaultDatabase()
        let fixtureIDs = try seedMinimalRestoreFixture(database: fault.database, repository: fault.repository)
        _ = try fault.tags.batchAccept(
            tagID: fixtureIDs.tagID,
            assetIDs: [fixtureIDs.assetA, fixtureIDs.assetB, fixtureIDs.assetC],
            timestampMs: DatabaseTestSupport.timestampMs
        )

        let assets = [fixtureIDs.assetA, fixtureIDs.assetB, fixtureIDs.assetC]
        let beforeRestore = try CatalogQueryTestSupport.decisionStates(
            database: fault.database,
            tagID: fixtureIDs.tagID,
            assetIDs: assets
        )
        XCTAssertEqual(beforeRestore[fixtureIDs.assetA], .accepted)
        XCTAssertEqual(beforeRestore[fixtureIDs.assetB], .accepted)
        XCTAssertEqual(beforeRestore[fixtureIDs.assetC], .accepted)

        try fault.database.pool.write { db in
            try CatalogQueryTestFaultSupport.setFaultMode(.failRestoreAfterFirstWrite, on: db)
        }

        let snapshot = TagMutationPriorStateSnapshot(
            tagID: fixtureIDs.tagID,
            priorStates: [
                TagMutationPriorState(assetID: fixtureIDs.assetA, priorState: .unknown),
                TagMutationPriorState(assetID: fixtureIDs.assetB, priorState: .accepted),
                TagMutationPriorState(assetID: fixtureIDs.assetC, priorState: .rejected),
            ]
        )

        XCTAssertThrowsError(
            try fault.tags.restorePriorStates(snapshot, timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
        }

        let afterFailedRestore = try CatalogQueryTestSupport.decisionStates(
            database: fault.database,
            tagID: fixtureIDs.tagID,
            assetIDs: assets
        )
        XCTAssertEqual(afterFailedRestore, beforeRestore)
    }

    func testClosedPoolTagOperationsSurfacePersistenceFailure() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let tags = GRDBTagCatalogRepository(database: database)
        try CatalogDatabase.closePool(database.pool)

        XCTAssertThrowsError(
            try tags.createTag(rawName: "Closed", timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
            let description = String(describing: error)
            XCTAssertFalse(description.contains("INSERT"))
            XCTAssertFalse(description.contains("Closed"))
        }
    }

    func testClosedPoolRestoreSurfacesPersistenceFailure() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let tags = GRDBTagCatalogRepository(database: database)
        let tag = try tags.createTag(rawName: "RestoreClosed", timestampMs: DatabaseTestSupport.timestampMs)
        let assetID = UUID()
        try CatalogRepository(database: database).createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: UUID(),
                sourceKind: .folder,
                displayName: "Folder",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: assetID,
                locatorKind: .file,
                relativePath: "closed.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )
        let snapshot = TagMutationPriorStateSnapshot(
            tagID: tag.id,
            priorStates: [TagMutationPriorState(assetID: assetID, priorState: .unknown)]
        )
        try CatalogDatabase.closePool(database.pool)

        XCTAssertThrowsError(
            try tags.restorePriorStates(snapshot, timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
            let description = String(describing: error)
            XCTAssertFalse(description.contains("DELETE"))
            XCTAssertFalse(description.contains("closed.jpg"))
        }
    }

    private struct MinimalRestoreFixtureIDs {
        let tagID: UUID
        let assetA: UUID
        let assetB: UUID
        let assetC: UUID
    }

    private func seedMinimalRestoreFixture(
        database: CatalogDatabase,
        repository: CatalogRepository
    ) throws -> MinimalRestoreFixtureIDs {
        let sourceID = UUID()
        let assetA = UUID()
        let assetB = UUID()
        let assetC = UUID()
        let tagID = UUID()
        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: sourceID,
                sourceKind: .folder,
                displayName: "Folder",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: assetA,
                locatorKind: .file,
                relativePath: "a.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )
        try database.pool.write { db in
            for (assetID, path) in [(assetB, "b.jpg"), (assetC, "c.jpg")] {
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms
                    ) VALUES (?, ?, 'file', ?, NULL, 'current', 'public.jpeg', 1, 'available', ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        sourceID.uuidString.lowercased(),
                        path,
                        DatabaseTestSupport.timestampMs,
                        DatabaseTestSupport.timestampMs,
                    ]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Restore', 'restore', 'active', ?, ?)
                """,
                arguments: [tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [assetB.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'rejected', ?)
                """,
                arguments: [assetC.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
        }
        return MinimalRestoreFixtureIDs(tagID: tagID, assetA: assetA, assetB: assetB, assetC: assetC)
    }
}
