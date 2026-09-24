import CryptoKit
import Foundation
import GRDB
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class PhoneArchiveImportTests: XCTestCase {
    func testSealedNetworkStageImportsIntoSiblingMacArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let resource = try fixture.resource(
            "original", bytes: Data("network-stage-original".utf8)
        )
        let item = fixture.item(resource: resource)
        let header = fixture.header(count: 1)
        try fixture.write(header: header, items: [item])
        let deviceID = header.sourceDeviceID
        let store = try ImageAllMigrationTransferStore(root: fixture.target)
        _ = try await store.begin(
            migrationID: header.migrationID, authenticatedDeviceID: deviceID
        )
        let paths = [ImageAllMigrationArchive.manifestFilename, resource.relativePath!]
        for path in paths {
            let bytes = try Data(contentsOf: fixture.incoming.appendingPathComponent(path))
            let digest = Data(SHA256.hash(data: bytes))
                .map { String(format: "%02x", $0) }.joined()
            _ = try await store.append(
                migrationID: header.migrationID, authenticatedDeviceID: deviceID,
                relativePath: path, offset: 0, bytes: bytes, sha256: digest
            )
        }
        let (stage, verification) = try await store.sealVerifiedArchive(
            migrationID: header.migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertTrue(verification.isComplete)
        let staged = try await store.sealedArchives()
        XCTAssertEqual(staged.map(\.id), [header.migrationID])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let imported = try importer.importArchive(from: stage, to: fixture.target)
        XCTAssertNotEqual(imported.archiveURL, stage)
        XCTAssertEqual(imported.manifestSHA256, verification.manifestSHA256)
        XCTAssertEqual(try Data(contentsOf: importer.verifiedOriginalURL(
            migrationID: header.migrationID, mediaID: item.mediaID,
            archiveRoot: imported.archiveURL
        )), Data("network-stage-original".utf8))

        let facts = ImageAllMigrationFactSnapshot(
            sourceDeviceID: deviceID, sourceEpoch: header.sourceEpoch,
            scopeRevision: header.scopeRevision, snapshotSequence: 8,
            factWatermark: 8,
            items: [.init(
                mediaID: item.mediaID, observedFavorite: true, favoriteTarget: true,
                tagDecisions: [.init(
                    tagID: UUID(), tagName: "传输后标签", decision: .accepted
                )], collections: []
            )], syncCheckpoint: .init(
                hostID: UUID(), deviceID: UUID(),
                acknowledgedScopeRevision: header.scopeRevision,
                acknowledgedSnapshotSequence: header.inventoryWatermark,
                tagChangeCursor: 0, collectionChangeCursor: 0,
                favoriteChangeCursor: 0,
                archiveManifestSHA256: verification.manifestSHA256,
                sourceVerifiedAtMs: 1_000
            )
        )
        let factsFile = fixture.root.appendingPathComponent("latest.imageallfacts")
        try ImageAllMigrationFacts.write(facts, to: factsFile)
        let attached = try ImageAllMigrationFacts.publish(
            from: factsFile, into: fixture.incoming
        )
        let relativeFacts = "facts/\(attached.lastPathComponent)"
        let factsBytes = try Data(contentsOf: attached)
        let factsDigest = Data(SHA256.hash(data: factsBytes))
            .map { String(format: "%02x", $0) }.joined()
        _ = try await store.append(
            migrationID: header.migrationID, authenticatedDeviceID: deviceID,
            relativePath: relativeFacts, offset: 0,
            bytes: factsBytes, sha256: factsDigest
        )
        let (_, updated) = try await store.sealVerifiedArchive(
            migrationID: header.migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertNotNil(updated.factsSHA256)
        let replay = try importer.importArchive(from: stage, to: fixture.target)
        XCTAssertTrue(replay.replayed)
        let batch = try XCTUnwrap(importer.importedBatches().first)
        XCTAssertEqual(batch.factSnapshotSequence, 8)
        let tagName = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT tag_name FROM migration_import_tag_decision"
            )
        }
        XCTAssertEqual(tagName, "传输后标签")
        XCTAssertNotNil(try ImageAllMigrationArchive.verify(
            at: imported.archiveURL
        ).factsSHA256)
        let integrity = try importer.auditImportedArchive(
            migrationID: header.migrationID, archiveRoot: imported.archiveURL
        )
        XCTAssertEqual(integrity.factSnapshotSequence, 8)
        XCTAssertNotNil(integrity.phoneSyncCheckpoint)
        let recoveryDirectory = fixture.root.appendingPathComponent(
            "independent-recovery", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: recoveryDirectory, withIntermediateDirectories: false
        )
        let recovery = try importer.verifyIndependentRecovery(
            migrationID: header.migrationID, archiveRoot: imported.archiveURL,
            into: recoveryDirectory
        )
        XCTAssertEqual(recovery.integrity, integrity)
        XCTAssertNotEqual(recovery.restoredArchiveURL, imported.archiveURL)
        XCTAssertEqual(try Data(contentsOf: recovery.restoredArchiveURL.appendingPathComponent(
            try XCTUnwrap(resource.relativePath)
        )), Data("network-stage-original".utf8))
        XCTAssertNotNil(recovery.integrity.phoneSyncCheckpoint)
        let wrongBinding = ImageAllMigrationFactSnapshot(
            sourceDeviceID: deviceID, sourceEpoch: header.sourceEpoch,
            scopeRevision: header.scopeRevision, snapshotSequence: 9,
            factWatermark: 9, items: facts.items,
            syncCheckpoint: .init(
                hostID: UUID(), deviceID: UUID(),
                acknowledgedScopeRevision: header.scopeRevision,
                acknowledgedSnapshotSequence: header.inventoryWatermark,
                tagChangeCursor: 0, collectionChangeCursor: 0,
                favoriteChangeCursor: 0,
                archiveManifestSHA256: String(repeating: "a", count: 64),
                sourceVerifiedAtMs: 1_001
            )
        )
        let wrongBindingURL = fixture.root.appendingPathComponent("wrong-binding.imageallfacts")
        try ImageAllMigrationFacts.write(wrongBinding, to: wrongBindingURL)
        XCTAssertThrowsError(try importer.reconcileFacts(
            from: wrongBindingURL, migrationID: header.migrationID,
            archiveRoot: imported.archiveURL
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .factScopeMismatch) }
        XCTAssertThrowsError(try importer.verifyIndependentRecovery(
            migrationID: header.migrationID, archiveRoot: imported.archiveURL,
            into: recoveryDirectory
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .recoveryDestinationNotEmpty) }
        try await fixture.database.pool.write { db in
            try db.execute(sql: """
                UPDATE migration_import_tag_decision SET tag_name = '被改动'
                WHERE media_id = ?
                """, arguments: [item.mediaID.uuidString.lowercased()])
        }
        XCTAssertThrowsError(try importer.auditImportedArchive(
            migrationID: header.migrationID, archiveRoot: imported.archiveURL
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .catalogDiverged) }
    }

    func testImportPreservesMediaResourcesAndFactsAcrossRestartAndReplay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mediaID = UUID()
        let original = try fixture.resource("original", bytes: Data("original-photo".utf8))
        let pair = try fixture.resource("pairedVideo", bytes: Data("paired-video".utf8))
        let tagID = UUID()
        let collectionID = UUID()
        let header = fixture.header(count: 1, appleAlbumCoverage: .selectedAssetsOnly)
        let item = ImageAllMigrationItem(
            mediaID: mediaID, sourceLocalIdentifier: "phone-local-id",
            mediaKind: .image, createdAtMs: 1_000,
            favoriteTarget: true, observedFavorite: false, factRevision: 7,
            tagDecisions: [.init(tagID: tagID, tagName: "旅途", decision: .rejected)],
            collections: [.init(collectionID: collectionID, collectionName: "相册", included: true)],
            resources: [original, pair],
            appleAlbums: [.init(
                albumLocalIdentifier: "photos-album-1", albumTitle: "周末",
                folderPath: [.init(localIdentifier: "photos-folder-1", title: "出游")],
                sourceOrdinal: 4
            )]
        )
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let receipt = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        XCTAssertFalse(receipt.replayed)
        XCTAssertEqual(receipt.itemCount, 1)
        XCTAssertEqual(receipt.resourceCount, 2)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: receipt.archiveURL).isComplete, true)
        XCTAssertEqual(try importer.auditImportedArchive(
            migrationID: header.migrationID, archiveRoot: receipt.archiveURL
        ).resourceCount, 2)
        let batch = try XCTUnwrap(importer.importedBatches().first)
        XCTAssertEqual(batch.id, header.migrationID)
        XCTAssertEqual(batch.itemCount, 1)
        XCTAssertEqual(batch.appleAlbumCoverage, .selectedAssetsOnly)
        let listed = try XCTUnwrap(importer.importedItems(migrationID: batch.id, offset: 0).first)
        XCTAssertEqual(listed.id, mediaID)
        XCTAssertEqual(listed.resourceCount, 2)
        XCTAssertEqual(listed.tagCount, 1)
        XCTAssertEqual(listed.collectionCount, 1)
        XCTAssertEqual(listed.appleAlbumCount, 1)
        let opened = try importer.verifiedOriginalURL(
            migrationID: batch.id, mediaID: listed.id, archiveRoot: receipt.archiveURL
        )
        XCTAssertEqual(try Data(contentsOf: opened), Data("original-photo".utf8))

        try fixture.database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM migration_import_item"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM migration_import_resource"), 2)
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT decision FROM migration_import_tag_decision"
            ), "rejected")
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT collection_name FROM migration_import_collection"
            ), "相册")
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT album_title FROM migration_import_apple_album_member"
            ), "周末")
            XCTAssertEqual(try Int64.fetchOne(
                db, sql: "SELECT source_ordinal FROM migration_import_apple_album_member"
            ), 4)
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT favorite_target FROM migration_import_item"
            ), 1)
        }
        let reopened = try CatalogDatabase.open(at: fixture.databaseURL)
        let replay = try VerifiedPhoneArchiveImporter(database: reopened).importArchive(
            from: fixture.incoming, to: fixture.target
        )
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.archiveURL, receipt.archiveURL)
        XCTAssertEqual(try Data(contentsOf: fixture.incoming.appendingPathComponent(original.relativePath!)),
                       Data("original-photo".utf8))
        try FileManager.default.removeItem(at: fixture.incoming)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: receipt.archiveURL).verifiedBytes,
                       Int64("original-photo".utf8.count + "paired-video".utf8.count))

        let recoveryTarget = fixture.root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryTarget, withIntermediateDirectories: true)
        let cleanCatalog = try CatalogDatabase.open(
            at: fixture.root.appendingPathComponent("recovered-catalog.sqlite")
        )
        let restored = try VerifiedPhoneArchiveImporter(database: cleanCatalog).importArchive(
            from: receipt.archiveURL, to: recoveryTarget
        )
        XCTAssertEqual(restored.manifestSHA256, receipt.manifestSHA256)
        XCTAssertEqual(try cleanCatalog.pool.read { db in
            try String.fetchOne(db, sql: "SELECT decision FROM migration_import_tag_decision")
        }, "rejected")
        XCTAssertEqual(try cleanCatalog.pool.read { db in
            try String.fetchOne(db, sql: "SELECT folder_path_json FROM migration_import_apple_album_member")
        }, "[{\"localIdentifier\":\"photos-folder-1\",\"title\":\"出游\"}]")
        XCTAssertEqual(try cleanCatalog.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT source_ordinal FROM migration_import_apple_album_member")
        }, 4)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: restored.archiveURL).resourceCount, 2)
    }

    func testInterruptedAfterPublicationResumesWithoutReCopying() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let header = fixture.header(count: 1)
        let item = fixture.item(resource: try fixture.resource(
            "original", bytes: Data("recoverable-original".utf8)
        ))
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        enum Injected: Error { case stop }
        XCTAssertThrowsError(try importer.importArchive(
            from: fixture.incoming, to: fixture.target,
            afterPublication: { throw Injected.stop }
        ))
        XCTAssertEqual(try fixture.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM migration_import")
        }, "prepared")
        let receipt = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        XCTAssertFalse(receipt.replayed)
        XCTAssertEqual(try fixture.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM migration_import")
        }, "catalogCommitted")
    }

    func testOriginalCannotOpenAfterPublishedResourceChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let resource = try fixture.resource("original", bytes: Data("verified-original".utf8))
        let item = fixture.item(resource: resource)
        let header = fixture.header(count: 1)
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let receipt = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        try Data("changed-original".utf8).write(
            to: receipt.archiveURL.appendingPathComponent(try XCTUnwrap(resource.relativePath))
        )
        XCTAssertThrowsError(try importer.verifiedOriginalURL(
            migrationID: header.migrationID, mediaID: item.mediaID, archiveRoot: receipt.archiveURL
        ))
    }

    func testFactSnapshotReconcilesExactBatchAndRejectsStaleOrChangedReplay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = fixture.item(resource: try fixture.resource(
            "original", bytes: Data("facts-original".utf8)
        ))
        let header = fixture.header(count: 1)
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let published = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        let factsURL = fixture.root.appendingPathComponent("facts.imageallfacts")
        let tag = ImageAllMigrationTagDecision(
            tagID: UUID(), tagName: "旅行", decision: .rejected
        )
        let collection = ImageAllMigrationCollectionMembership(
            collectionID: UUID(), collectionName: "夏天", included: true
        )
        func snapshot(
            sequence: Int64, mediaID: UUID = item.mediaID,
            tags: [ImageAllMigrationTagDecision] = [tag],
            collections: [ImageAllMigrationCollectionMembership] = [collection]
        ) -> ImageAllMigrationFactSnapshot {
            ImageAllMigrationFactSnapshot(
                sourceDeviceID: fixture.sourceDeviceID, sourceEpoch: fixture.sourceEpoch,
                scopeRevision: 1, snapshotSequence: sequence, factWatermark: sequence + 2,
                items: [.init(
                    mediaID: mediaID, observedFavorite: true, favoriteTarget: true,
                    tagDecisions: tags, collections: collections
                )]
            )
        }
        try ImageAllMigrationFacts.write(snapshot(sequence: 8), to: factsURL)
        let applied = try importer.reconcileFacts(from: factsURL, migrationID: header.migrationID)
        XCTAssertFalse(applied.replayed)
        XCTAssertEqual(applied.itemCount, 1)
        XCTAssertTrue(try importer.reconcileFacts(
            from: factsURL, migrationID: header.migrationID
        ).replayed)
        XCTAssertEqual(try fixture.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT decision FROM migration_import_tag_decision")
        }, "rejected")
        XCTAssertEqual(try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT favorite_target FROM migration_import_item")
        }, 1)

        try ImageAllMigrationFacts.write(snapshot(sequence: 7), to: factsURL)
        XCTAssertThrowsError(try importer.reconcileFacts(
            from: factsURL, migrationID: header.migrationID
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .staleFactSnapshot) }
        try ImageAllMigrationFacts.write(snapshot(sequence: 8, tags: []), to: factsURL)
        XCTAssertThrowsError(try importer.reconcileFacts(
            from: factsURL, migrationID: header.migrationID
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .factSnapshotConflict) }
        try ImageAllMigrationFacts.write(snapshot(sequence: 9, mediaID: UUID()), to: factsURL)
        XCTAssertThrowsError(try importer.reconcileFacts(
            from: factsURL, migrationID: header.migrationID
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .factScopeMismatch) }

        let latestTag = ImageAllMigrationTagDecision(
            tagID: UUID(), tagName: "最新", decision: .accepted
        )
        try ImageAllMigrationFacts.write(
            snapshot(sequence: 9, tags: [latestTag], collections: []), to: factsURL
        )
        _ = try importer.reconcileFacts(from: factsURL, migrationID: header.migrationID)
        try fixture.database.pool.read { db in
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT tag_name FROM migration_import_tag_decision"
            ), "最新")
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT count(*) FROM migration_import_collection"
            ), 0)
            XCTAssertEqual(try Int64.fetchOne(
                db, sql: "SELECT fact_snapshot_sequence FROM migration_import"
            ), 9)
        }
        XCTAssertNotNil(try ImageAllMigrationArchive.verify(
            at: published.archiveURL
        ).factsSHA256)
        try FileManager.default.removeItem(at: fixture.incoming)
        let recovery = fixture.root.appendingPathComponent("fact-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let clean = try CatalogDatabase.open(at: fixture.root.appendingPathComponent("clean-facts.sqlite"))
        let restored = try VerifiedPhoneArchiveImporter(database: clean).importArchive(
            from: published.archiveURL, to: recovery
        )
        XCTAssertEqual(restored.resourceCount, 1)
        let recoveredOriginal = try VerifiedPhoneArchiveImporter(database: clean)
            .verifiedOriginalURL(
                migrationID: header.migrationID, mediaID: item.mediaID,
                archiveRoot: restored.archiveURL
            )
        XCTAssertEqual(try Data(contentsOf: recoveredOriginal), Data("facts-original".utf8))
        try clean.pool.read { db in
            XCTAssertEqual(try Int64.fetchOne(
                db, sql: "SELECT fact_snapshot_sequence FROM migration_import"
            ), 9)
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT tag_name FROM migration_import_tag_decision"
            ), "最新")
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT decision FROM migration_import_tag_decision"
            ), "accepted")
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT favorite_target FROM migration_import_item"
            ), 1)
        }
        let sidecar = try XCTUnwrap(ImageAllMigrationFacts.latestPublishedURL(
            in: published.archiveURL
        ))
        try Data("changed".utf8).write(to: sidecar)
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: published.archiveURL))
    }

    func testFactScopeMismatchDoesNotPublishOrMutateCatalog() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.item(resource: try fixture.resource(
            "original", bytes: Data("first".utf8)
        ))
        let second = ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "phone-second", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false,
            factRevision: 0, tagDecisions: [], collections: [],
            resources: [try fixture.resource("original", bytes: Data("second".utf8))]
        )
        let header = fixture.header(count: 2)
        try fixture.write(header: header, items: [first, second])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let published = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        let changed = ImageAllMigrationFactItem(
            mediaID: first.mediaID, observedFavorite: true, favoriteTarget: true,
            tagDecisions: [.init(tagID: UUID(), tagName: "新增", decision: .accepted)],
            collections: []
        )
        let unknown = ImageAllMigrationFactItem(
            mediaID: UUID(), observedFavorite: false, favoriteTarget: nil,
            tagDecisions: [], collections: []
        )
        let snapshot = ImageAllMigrationFactSnapshot(
            sourceDeviceID: fixture.sourceDeviceID, sourceEpoch: fixture.sourceEpoch,
            scopeRevision: 1, snapshotSequence: 8, factWatermark: 9,
            items: [changed, unknown]
        )
        let factsURL = fixture.root.appendingPathComponent("wrong-facts.imageallfacts")
        try ImageAllMigrationFacts.write(snapshot, to: factsURL)
        XCTAssertThrowsError(try importer.reconcileFacts(
            from: factsURL, migrationID: header.migrationID
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .factScopeMismatch) }
        try fixture.database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT count(*) FROM migration_import_tag_decision"
            ), 0)
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT count(*) FROM migration_import_item WHERE favorite_target IS NOT NULL"
            ), 0)
            XCTAssertEqual(try Int64.fetchOne(
                db, sql: "SELECT fact_snapshot_sequence FROM migration_import"
            ), 0)
        }
        XCTAssertNil(try ImageAllMigrationArchive.verify(
            at: published.archiveURL
        ).factsSHA256)
    }

    func testFactSidecarPublishedBeforeCatalogCommitRecoversOnArchiveReplay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = fixture.item(resource: try fixture.resource(
            "original", bytes: Data("recover-facts".utf8)
        ))
        let header = fixture.header(count: 1)
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let published = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        let facts = ImageAllMigrationFactSnapshot(
            sourceDeviceID: fixture.sourceDeviceID, sourceEpoch: fixture.sourceEpoch,
            scopeRevision: 1, snapshotSequence: 8, factWatermark: 9,
            items: [.init(
                mediaID: item.mediaID, observedFavorite: true, favoriteTarget: true,
                tagDecisions: [], collections: []
            )]
        )
        let url = fixture.root.appendingPathComponent("interrupted.imageallfacts")
        try ImageAllMigrationFacts.write(facts, to: url)
        enum Injected: Error { case stop }
        XCTAssertThrowsError(try importer.reconcileFacts(
            from: url, migrationID: header.migrationID,
            afterFactPublication: { throw Injected.stop }
        ))
        XCTAssertEqual(try fixture.database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT fact_snapshot_sequence FROM migration_import")
        }, 0)
        XCTAssertNotNil(try ImageAllMigrationArchive.verify(
            at: published.archiveURL
        ).factsSHA256)
        XCTAssertTrue(try importer.importArchive(
            from: fixture.incoming, to: fixture.target
        ).replayed)
        XCTAssertEqual(try fixture.database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT fact_snapshot_sequence FROM migration_import")
        }, 8)
        XCTAssertEqual(try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT favorite_target FROM migration_import_item")
        }, 1)
    }

    func testMissingOriginalCannotPublishOrCreateImportJournal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = fixture.item(resource: .init(
            id: UUID(), role: "original", version: 1,
            uniformTypeIdentifier: "public.jpeg", required: true,
            status: .notLocal, relativePath: nil, byteCount: nil, sha256: nil
        ))
        try fixture.write(header: fixture.header(count: 1), items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        XCTAssertThrowsError(try importer.importArchive(from: fixture.incoming, to: fixture.target)) {
            XCTAssertEqual($0 as? PhoneArchiveImportError, .incompleteArchive)
        }
        XCTAssertEqual(try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM migration_import")
        }, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).isEmpty)
    }

    func testSecondMigrationForSamePhoneMediaIdentityRequiresReconciliation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = fixture.item(resource: try fixture.resource(
            "original", bytes: Data("same-source-media".utf8)
        ))
        try fixture.write(header: fixture.header(count: 1), items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        _ = try importer.importArchive(from: fixture.incoming, to: fixture.target)

        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.incoming, to: second)
        try FileManager.default.removeItem(
            at: second.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        )
        try ImageAllMigrationArchive.write(
            header: fixture.header(count: 1), items: [item], to: second
        )
        XCTAssertThrowsError(try importer.importArchive(from: second, to: fixture.target)) {
            XCTAssertEqual($0 as? PhoneArchiveImportError, .migrationIdentityConflict)
        }
        XCTAssertEqual(try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM migration_import_item")
        }, 1)
    }

    private final class Fixture {
        let root: URL
        let incoming: URL
        let target: URL
        let databaseURL: URL
        let database: CatalogDatabase
        let sourceDeviceID = UUID()
        let sourceEpoch = UUID()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ImageAll-PhoneArchiveImport-\(UUID().uuidString)", isDirectory: true
            )
            incoming = root.appendingPathComponent("incoming", isDirectory: true)
            target = root.appendingPathComponent("target", isDirectory: true)
            databaseURL = root.appendingPathComponent("catalog.sqlite")
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            database = try CatalogDatabase.open(at: databaseURL)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func header(
            count: Int, appleAlbumCoverage: ImageAllMigrationAppleAlbumCoverage? = nil
        ) -> ImageAllMigrationHeader {
            .init(migrationID: UUID(), sourceDeviceID: sourceDeviceID,
                  sourceEpoch: sourceEpoch, scopeRevision: 1,
                  inventoryWatermark: 7, declaredItemCount: count,
                  appleAlbumCoverage: appleAlbumCoverage)
        }

        func resource(_ role: String, bytes: Data) throws -> ImageAllMigrationResource {
            let id = UUID()
            let directory = incoming.appendingPathComponent("resources", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(id.uuidString.lowercased()).bin"
            try bytes.write(to: directory.appendingPathComponent(name))
            let hash = Data(SHA256.hash(data: bytes))
                .map { String(format: "%02x", $0) }.joined()
            return .init(id: id, role: role, version: 1,
                         uniformTypeIdentifier: "public.data", required: true,
                         status: .present, relativePath: "resources/\(name)",
                         byteCount: Int64(bytes.count), sha256: hash)
        }

        func item(resource: ImageAllMigrationResource) -> ImageAllMigrationItem {
            .init(mediaID: UUID(), sourceLocalIdentifier: "phone-local-id",
                  mediaKind: .image, createdAtMs: nil,
                  favoriteTarget: nil, observedFavorite: false, factRevision: 0,
                  tagDecisions: [], collections: [], resources: [resource])
        }

        func write(header: ImageAllMigrationHeader, items: [ImageAllMigrationItem]) throws {
            try ImageAllMigrationArchive.write(header: header, items: items, to: incoming)
        }
    }
}
