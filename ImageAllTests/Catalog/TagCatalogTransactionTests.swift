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
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        XCTAssertThrowsError(
            try fixture.tags.createTag(rawName: "FAMILY", timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .duplicateTag)
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

    func testCreateAndApplyRollsBackWhenDecisionPhaseFails() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let tags = GRDBTagCatalogRepository(database: database)
        let assetID = UUID()
        try repository.createSourceWithAsset(
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

        let failing = FailingAfterTagInsertRepository(base: tags)
        XCTAssertThrowsError(
            try failing.createTagAndApply(
                rawName: "RollbackMe",
                assetIDs: [assetID],
                decision: .accepted,
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )

        let count = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name = 'RollbackMe'") ?? 0
        }
        XCTAssertEqual(count, 0)
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
}

private struct FailingAfterTagInsertRepository: TagDecisionCommandPort {
    let base: GRDBTagCatalogRepository

    func createTag(rawName: String, timestampMs: Int64) throws -> Tag {
        try base.createTag(rawName: rawName, timestampMs: timestampMs)
    }

    func batchAccept(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult {
        try base.batchAccept(tagID: tagID, assetIDs: assetIDs, timestampMs: timestampMs)
    }

    func batchReject(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult {
        try base.batchReject(tagID: tagID, assetIDs: assetIDs, timestampMs: timestampMs)
    }

    func batchClear(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult {
        try base.batchClear(tagID: tagID, assetIDs: assetIDs, timestampMs: timestampMs)
    }

    func createTagAndApply(
        rawName: String,
        assetIDs: [UUID],
        decision: PersistableTagDecision,
        timestampMs: Int64
    ) throws -> TagMutationResult {
        try base.database.pool.write { db in
            let existing = try Row.fetchAll(db, sql: "SELECT id, name, normalized_name, state FROM tag").map { row in
                let normalizedName: String = row["normalized_name"]
                return Tag(
                    id: UUID(uuidString: row["id"])!,
                    displayName: row["name"],
                    normalizedName: normalizedName,
                    normalizedNameKey: Data(normalizedName.utf8),
                    state: TagState(rawValue: row["state"]) ?? .active
                )
            }
            let tag: Tag
            switch TagCatalogRules.createTag(rawName: rawName, existingTags: existing) {
            case let .success(created):
                tag = created
            case let .failure(error):
                throw map(error)
            }
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, 'active', ?, ?)
                """,
                arguments: [
                    tag.id.uuidString.lowercased(),
                    tag.displayName,
                    tag.normalizedName,
                    timestampMs,
                    timestampMs,
                ]
            )
            throw CatalogQueryError.persistenceFailure
        }
    }

    func restorePriorStates(_ snapshot: TagMutationPriorStateSnapshot, timestampMs: Int64) throws {
        try base.restorePriorStates(snapshot, timestampMs: timestampMs)
    }

    private func map(_ error: DomainError) -> CatalogQueryError {
        switch error {
        case .invalidName: .invalidTagName
        case .duplicateTag: .duplicateTag
        default: .persistenceFailure
        }
    }
}
