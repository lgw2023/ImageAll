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

    func testCreateMissingTagsAddsOnlyNewTagsWithoutChangingDecisions() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let decisionsBefore = try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision")
        }

        let created = try fixture.tags.createMissingTags(
            rawNames: ["Family", "人像", "风景", "人像"],
            timestampMs: DatabaseTestSupport.timestampMs
        )

        XCTAssertEqual(created.map(\.displayName), ["人像", "风景"])
        XCTAssertEqual(
            try fixture.tags.listTags(includeArchived: false).map(\.displayName),
            ["Family", "Work", "人像", "风景"]
        )
        XCTAssertTrue(
            try fixture.tags.createMissingTags(
                rawNames: ["family", " 人像 ", "风景"],
                timestampMs: DatabaseTestSupport.timestampMs + 1
            ).isEmpty
        )
        let decisionsAfter = try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision")
        }
        XCTAssertEqual(decisionsAfter, decisionsBefore)
    }

    func testDuplicateNormalizedTagIsRejected() throws {
        try testRepositoryDuplicateTagReturnsStructuredError()
    }

    func testInstallStandardOntologyIsAtomicIdempotentAndKeepsPersonalSameName() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let personalBeach = try fixture.tags.createTag(
            rawName: "Beach",
            timestampMs: DatabaseTestSupport.timestampMs
        )
        let package = makeStandardOntologyPackage()

        let first = try fixture.tags.installStandardOntologyPackage(
            package,
            timestampMs: DatabaseTestSupport.timestampMs + 1
        )
        let second = try fixture.tags.installStandardOntologyPackage(
            package,
            timestampMs: DatabaseTestSupport.timestampMs + 2
        )

        XCTAssertFalse(first.wasAlreadyInstalled)
        XCTAssertTrue(second.wasAlreadyInstalled)
        XCTAssertEqual(first.installedTags, second.installedTags)
        XCTAssertEqual(first.installedTags.map(\.displayName), ["Beach", "Scenes"])
        XCTAssertEqual(
            try fixture.tags.listTags(includeArchived: false).filter { $0.displayName == "Beach" }.count,
            2
        )

        try fixture.database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_pack"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_concept"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_edge"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standard_model_revision"), 1)

            let personal = try Row.fetchOne(
                db,
                sql: """
                SELECT tag.id, binding.ontology_id, binding.concept_id, binding.ontology_revision
                FROM tag
                LEFT JOIN standard_tag_binding binding ON binding.tag_id = tag.id
                WHERE tag.id = ?
                """,
                arguments: [personalBeach.id.uuidString.lowercased()]
            )
            XCTAssertNil(personal?["ontology_id"] as String?)
            XCTAssertNil(personal?["concept_id"] as String?)
            XCTAssertNil(personal?["ontology_revision"] as String?)

            let standardBeach = try Row.fetchOne(
                db,
                sql: """
                SELECT tag.id, binding.ontology_id, binding.concept_id, binding.ontology_revision
                FROM standard_tag_binding binding
                JOIN tag ON tag.id = binding.tag_id
                WHERE binding.concept_id = 'scene.beach'
                """
            )
            XCTAssertNotEqual(standardBeach?["id"] as String?, personalBeach.id.uuidString.lowercased())
            XCTAssertEqual(standardBeach?["ontology_id"] as String?, package.ontologyID)
            XCTAssertEqual(standardBeach?["concept_id"] as String?, "scene.beach")
            XCTAssertEqual(standardBeach?["ontology_revision"] as String?, package.ontologyRevision)
        }
    }

    func testInstallStandardOntologyRejectsCycleWithoutPartialWrites() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let package = makeStandardOntologyPackage(
            edges: [
                StandardOntologyEdgeInput(parentConceptID: "scene.root", childConceptID: "scene.beach"),
                StandardOntologyEdgeInput(parentConceptID: "scene.beach", childConceptID: "scene.root"),
            ]
        )

        XCTAssertThrowsError(
            try fixture.tags.installStandardOntologyPackage(
                package,
                timestampMs: DatabaseTestSupport.timestampMs
            )
        ) { error in
            XCTAssertEqual(error as? StandardOntologyCatalogError, .invalidPackage)
        }

        try fixture.database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_pack"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_concept"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_edge"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standard_model_revision"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standard_tag_binding"), 0)
        }
    }

    func testConflictingStandardPackRevisionPreservesInstalledFacts() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let installed = try fixture.tags.installStandardOntologyPackage(
            makeStandardOntologyPackage(),
            timestampMs: DatabaseTestSupport.timestampMs
        )
        let conflicting = makeStandardOntologyPackage(
            standardPackRevision: "standard-pack-v2",
            manifestSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertThrowsError(
            try fixture.tags.installStandardOntologyPackage(
                conflicting,
                timestampMs: DatabaseTestSupport.timestampMs + 1
            )
        ) { error in
            XCTAssertEqual(error as? StandardOntologyCatalogError, .conflictingPackage)
        }

        let preserved = try fixture.database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_pack") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_concept") ?? 0,
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT tag.id
                    FROM standard_tag_binding binding
                    JOIN tag ON tag.id = binding.tag_id
                    ORDER BY tag.id
                    """
                )
            )
        }
        XCTAssertEqual(preserved.0, 1)
        XCTAssertEqual(preserved.1, 2)
        XCTAssertEqual(preserved.2, installed.installedTags.map { $0.id.uuidString.lowercased() }.sorted())
    }

    func testConflictingStandardOntologyIdentityPreservesInstalledFacts() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        _ = try fixture.tags.installStandardOntologyPackage(
            makeStandardOntologyPackage(),
            timestampMs: DatabaseTestSupport.timestampMs
        )
        let conflicting = makeStandardOntologyPackage(
            standardPackID: "imageall.standard.other",
            standardPackRevision: "other-v1",
            manifestSHA256: String(repeating: "d", count: 64)
        )

        XCTAssertThrowsError(
            try fixture.tags.installStandardOntologyPackage(
                conflicting,
                timestampMs: DatabaseTestSupport.timestampMs + 1
            )
        ) { error in
            XCTAssertEqual(error as? StandardOntologyCatalogError, .conflictingPackage)
        }

        try fixture.database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_pack"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ontology_concept"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standard_tag_binding"), 2)
        }
    }

    func testV009MigratesExistingTagsAsPersonalWithoutChangingIdentity() throws {
        let url = try makeTempDatabaseURL()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        V001CreateCatalogCoreMigration.register(on: &migrator)
        V002AddStage1CatalogQuerySupportMigration.register(on: &migrator)
        V003AddDerivedImageCacheMigration.register(on: &migrator)
        V004AddPersonalizationMigration.register(on: &migrator)
        V005AddCatalogScaleIndexesMigration.register(on: &migrator)
        V006AddAssetTextSearchMigration.register(on: &migrator)
        V007AddCatalogScopeIdentityMigration.register(on: &migrator)
        V008AddPersonalModelSuggestionsMigration.register(on: &migrator)
        try migrator.migrate(pool)

        let tagID = UUID().uuidString.lowercased()
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Existing', 'existing', 'active', ?, ?)
                """,
                arguments: [tagID, DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
        }

        try CatalogDatabase(pool: pool).migrate()

        try pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT tag.id, binding.tag_id AS standard_tag_id
                FROM tag
                LEFT JOIN standard_tag_binding binding ON binding.tag_id = tag.id
                WHERE tag.id = ?
                """,
                arguments: [tagID]
            )
            XCTAssertEqual(row?["id"] as String?, tagID)
            XCTAssertNil(row?["standard_tag_id"] as String?)
        }
    }

    func testRenameTagUsesDomainNormalizationAndKeepsIdentity() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()

        let renamed = try fixture.tags.renameTag(
            tagID: fixture.ids.tagFamily,
            rawName: "  Caf\u{65}\u{301}  ",
            timestampMs: DatabaseTestSupport.timestampMs + 1
        )

        XCTAssertEqual(renamed.id, fixture.ids.tagFamily)
        XCTAssertEqual(Array(renamed.displayName.unicodeScalars), Array("Cafe\u{301}".unicodeScalars))
        XCTAssertEqual(renamed.normalizedName, "café")
        XCTAssertEqual(renamed.state, .active)
    }

    func testRenameTagRejectsAnotherTagsNormalizedName() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()

        XCTAssertThrowsError(
            try fixture.tags.renameTag(
                tagID: fixture.ids.tagWork,
                rawName: "FAMILY",
                timestampMs: DatabaseTestSupport.timestampMs + 1
            )
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .duplicateTag)
        }

        let active = try fixture.tags.listTags(includeArchived: false)
        XCTAssertEqual(active.map(\.displayName), ["Family", "Work"])
    }

    func testArchiveTagHidesItFromActiveCatalogAndPreservesDecisionHistory() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let before = try fixture.query.fetchInspectorDetail(assetID: fixture.ids.assetNewest)
        let priorDecision = before.tags.first { $0.tagID == fixture.ids.tagFamily }?.decision

        try fixture.tags.archiveTag(
            tagID: fixture.ids.tagFamily,
            timestampMs: DatabaseTestSupport.timestampMs + 1
        )

        let active = try fixture.tags.listTags(includeArchived: false)
        XCTAssertFalse(active.contains { $0.id == fixture.ids.tagFamily })

        let archived = try XCTUnwrap(
            fixture.tags.listTags(includeArchived: true).first { $0.id == fixture.ids.tagFamily }
        )
        XCTAssertEqual(archived.state, .archived)

        let after = try fixture.query.fetchInspectorDetail(assetID: fixture.ids.assetNewest)
        let preserved = try XCTUnwrap(after.tags.first { $0.tagID == fixture.ids.tagFamily })
        XCTAssertEqual(preserved.decision, priorDecision)
        XCTAssertEqual(preserved.tagState, .archived)
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
        try assertConcurrentNormalizedNameUniqueRaceOnce()
    }

    private func assertConcurrentNormalizedNameUniqueRaceOnce() throws {
        let url = try DatabaseTestSupport.makeTempDatabaseURL()
        let catalogDatabase = try CatalogDatabase.open(at: url)
        try catalogDatabase.pool.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try CatalogDatabase.closePool(catalogDatabase.pool)

        let group = DispatchGroup()
        let lock = NSLock()
        var outcomes: [Result<Void, Error>] = []

        for index in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    var config = Configuration()
                    config.busyMode = .timeout(10.0)
                    config.prepareDatabase { db in
                        try db.execute(sql: "PRAGMA foreign_keys = ON")
                        try db.execute(sql: "PRAGMA journal_mode = WAL")
                    }
                    let queue = try DatabaseQueue(path: url.path, configuration: config)
                    defer { try? queue.close() }
                    let tagID = UUID()
                    try queue.inTransaction(.immediate) { db in
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
                        return .commit
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

        let successCount = outcomes.filter { if case .success = $0 { return true }; return false }.count
        let failures = outcomes.compactMap { result -> Error? in
            if case let .failure(error) = result { return error }
            return nil
        }

        XCTAssertEqual(successCount, 1, "Expected exactly one successful insert")
        XCTAssertEqual(failures.count, 1, "Expected exactly one failed insert")
        guard let failure = failures.first else { return }

        guard let dbError = failure as? DatabaseError else {
            XCTFail("Expected DatabaseError, got \(failure)")
            return
        }
        XCTAssertEqual(dbError.extendedResultCode, .SQLITE_CONSTRAINT_UNIQUE)

        let database = try CatalogDatabase.open(at: url)
        let rowCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE normalized_name = 'racetag'") ?? 0
        }
        XCTAssertEqual(rowCount, 1)
    }

    func testConcurrentDuplicateNormalizedTagIsRejectedByDatabase() throws {
        try assertConcurrentNormalizedNameUniqueRaceOnce()
    }

    func testCreateTagMapsUnrelatedUniqueConstraintToPersistenceFailure() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try database.pool.write { db in
            try CatalogQueryTestFaultSupport.installUnrelatedTagUniqueIndex(on: db)
        }
        let tags = GRDBTagCatalogRepository(database: database)
        let fixedTimestamp = DatabaseTestSupport.timestampMs
        _ = try tags.createTag(rawName: "First", timestampMs: fixedTimestamp)
        XCTAssertThrowsError(
            try tags.createTag(rawName: "Second", timestampMs: fixedTimestamp)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
            XCTAssertNotEqual(error as? CatalogQueryError, .duplicateTag)
        }
    }

    func testCreateAndApplyMapsUnrelatedUniqueConstraintToPersistenceFailureWithoutPartialWrites() throws {
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
                relativePath: "unique-fail.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )
        try fault.database.pool.write { db in
            try CatalogQueryTestFaultSupport.installUnrelatedTagUniqueIndex(on: db)
        }
        let fixedTimestamp = DatabaseTestSupport.timestampMs + 1
        _ = try fault.tags.createTag(rawName: "Existing", timestampMs: fixedTimestamp)

        XCTAssertThrowsError(
            try fault.tags.createTagAndApply(
                rawName: "Collision",
                assetIDs: [assetID],
                decision: .accepted,
                timestampMs: fixedTimestamp
            )
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
            XCTAssertNotEqual(error as? CatalogQueryError, .duplicateTag)
        }

        try fault.database.pool.read { db in
            let tagCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name = 'Collision'") ?? 0
            let decisionCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM asset_tag_decision
                WHERE asset_id = ? AND tag_id IN (SELECT id FROM tag WHERE name = 'Collision')
                """,
                arguments: [assetID.uuidString.lowercased()]
            ) ?? 0
            XCTAssertEqual(tagCount, 0)
            XCTAssertEqual(decisionCount, 0)
        }
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
        let recorder = RestoreDecisionWriteRecorder()

        let assets = [fixtureIDs.assetA, fixtureIDs.assetB, fixtureIDs.assetC, fixtureIDs.assetD]
        let beforeRestore = try CatalogQueryTestSupport.decisionStates(
            database: fault.database,
            tagID: fixtureIDs.tagID,
            assetIDs: assets
        )
        XCTAssertEqual(beforeRestore[fixtureIDs.assetA], .accepted)
        XCTAssertEqual(beforeRestore[fixtureIDs.assetB], .unknown)
        XCTAssertEqual(beforeRestore[fixtureIDs.assetC], .accepted)
        XCTAssertEqual(beforeRestore[fixtureIDs.assetD], .rejected)

        try fault.database.pool.write { db in
            db.add(transactionObserver: recorder, extent: .databaseLifetime)
            try CatalogQueryTestFaultSupport.setFaultMode(.failRestoreAfterThreeWrites, on: db)
        }

        let snapshot = TagMutationPriorStateSnapshot(
            tagID: fixtureIDs.tagID,
            priorStates: [
                TagMutationPriorState(assetID: fixtureIDs.assetA, priorState: .unknown),
                TagMutationPriorState(assetID: fixtureIDs.assetB, priorState: .accepted),
                TagMutationPriorState(assetID: fixtureIDs.assetC, priorState: .rejected),
                TagMutationPriorState(assetID: fixtureIDs.assetD, priorState: .accepted),
            ]
        )

        XCTAssertThrowsError(
            try fault.tags.restorePriorStates(snapshot, timestampMs: DatabaseTestSupport.timestampMs)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
        }

        XCTAssertEqual(recorder.deletes, 1)
        XCTAssertEqual(recorder.inserts, 1)
        XCTAssertEqual(recorder.updates, 1)

        let afterFailedRestore = try CatalogQueryTestSupport.decisionStates(
            database: fault.database,
            tagID: fixtureIDs.tagID,
            assetIDs: assets
        )
        XCTAssertEqual(afterFailedRestore[fixtureIDs.assetA], beforeRestore[fixtureIDs.assetA])
        XCTAssertEqual(afterFailedRestore[fixtureIDs.assetB], beforeRestore[fixtureIDs.assetB])
        XCTAssertEqual(afterFailedRestore[fixtureIDs.assetC], beforeRestore[fixtureIDs.assetC])
        XCTAssertEqual(afterFailedRestore[fixtureIDs.assetD], beforeRestore[fixtureIDs.assetD])
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
        let assetD: UUID
    }

    private func makeStandardOntologyPackage(
        standardPackID: String = "imageall.standard.synthetic",
        standardPackRevision: String = "standard-pack-v1",
        manifestSHA256: String = String(repeating: "a", count: 64),
        edges: [StandardOntologyEdgeInput] = [
            StandardOntologyEdgeInput(parentConceptID: "scene.root", childConceptID: "scene.beach"),
        ]
    ) -> StandardOntologyPackageInput {
        StandardOntologyPackageInput(
            standardPackID: standardPackID,
            standardPackRevision: standardPackRevision,
            ontologyID: "imageall.synthetic.scene",
            ontologyRevision: "ontology-v1",
            localeRevision: "locale-en-v1",
            manifestSHA256: manifestSHA256,
            provider: "synthetic",
            modelID: "synthetic/model",
            modelRevision: "model-v1",
            preprocessingRevision: "preprocessing-v1",
            mappingRevision: "mapping-v1",
            policyRevision: "policy-v1",
            weightsSHA256: String(repeating: "c", count: 64),
            concepts: [
                StandardOntologyConceptInput(conceptID: "scene.root", canonicalName: "Scenes"),
                StandardOntologyConceptInput(conceptID: "scene.beach", canonicalName: "Beach"),
            ],
            edges: edges
        )
    }

    private func seedMinimalRestoreFixture(
        database: CatalogDatabase,
        repository: CatalogRepository
    ) throws -> MinimalRestoreFixtureIDs {
        let sourceID = UUID()
        let assetA = UUID()
        let assetB = UUID()
        let assetC = UUID()
        let assetD = UUID()
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
            for (assetID, path) in [(assetB, "b.jpg"), (assetC, "c.jpg"), (assetD, "d.jpg")] {
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
                arguments: [assetA.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [assetC.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'rejected', ?)
                """,
                arguments: [assetD.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
        }
        return MinimalRestoreFixtureIDs(
            tagID: tagID,
            assetA: assetA,
            assetB: assetB,
            assetC: assetC,
            assetD: assetD
        )
    }
}
