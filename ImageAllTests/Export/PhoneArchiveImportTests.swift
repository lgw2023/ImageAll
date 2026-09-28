import AVFoundation
import CryptoKit
import Foundation
import GRDB
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class PhoneArchiveImportTests: XCTestCase {
    func testOfflineVideoArchivePlaysAfterPhoneStageIsRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let bytes = try Data(contentsOf: sample)
        let resourceID = UUID()
        let directory = fixture.incoming.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(resourceID.uuidString.lowercased()).mp4"
        try bytes.write(to: directory.appendingPathComponent(filename))
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        let resource = ImageAllMigrationResource(
            id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.mpeg-4", required: true,
            status: .present, relativePath: "resources/\(filename)",
            byteCount: Int64(bytes.count), sha256: digest
        )
        let mediaID = UUID()
        let item = ImageAllMigrationItem(
            mediaID: mediaID, sourceLocalIdentifier: "synthetic-video",
            mediaKind: .video, createdAtMs: nil,
            favoriteTarget: nil, observedFavorite: false, factRevision: 0,
            tagDecisions: [], collections: [], resources: [resource]
        )
        let header = fixture.header(count: 1)
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let receipt = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        try FileManager.default.removeItem(at: fixture.incoming)
        XCTAssertEqual(try importer.importedItems(
            migrationID: header.migrationID, offset: 0
        ).first?.mediaKind, "video")
        let preview = try importer.verifiedPreview(
            migrationID: header.migrationID, mediaID: mediaID,
            archiveRoot: receipt.archiveURL
        )
        let copied = preview.originalURL
        XCTAssertEqual(try importer.verifiedGalleryOriginalURLs(
            migrationID: header.migrationID, archiveRoot: receipt.archiveURL
        )[mediaID], copied)
        XCTAssertNotNil(PhoneArchiveImagePreview.thumbnailData(
            at: copied, maxPixelSize: 320, isVideo: true
        ))
        XCTAssertTrue(preview.facts.tagDecisions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
        let playable = try await AVURLAsset(url: copied).load(.isPlayable)
        XCTAssertTrue(playable)
    }

    func testArchivePreviewOffersVerifiedVersionsWithoutGuessingAmbiguousEdits() throws {
        for editedCount in [1, 2] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = try fixture.resource("original", bytes: Data("original".utf8), uti: "public.jpeg")
            let paired = try fixture.resource("pairedVideo", bytes: Data("paired".utf8), uti: "public.mpeg-4")
            // A renderable UTI must not turn adjustment data into a viewable resource.
            let adjustment = try fixture.resource("adjustmentData", bytes: Data("private-format".utf8), uti: "public.jpeg")
            let edited = try (0..<editedCount).map {
                try fixture.resource("fullSizePhoto", bytes: Data("edited-\($0)".utf8), uti: "public.jpeg")
            }
            let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic-edited",
                mediaKind: .image, createdAtMs: nil, favoriteTarget: nil, observedFavorite: false,
                factRevision: 0, tagDecisions: [], collections: [], resources: [original, paired, adjustment] + edited)
            let header = fixture.header(count: 1)
            try fixture.write(header: header, items: [item])
            let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
            let receipt = try importer.importArchive(from: fixture.incoming, to: fixture.target)
            try FileManager.default.removeItem(at: fixture.incoming)
            let reopened = VerifiedPhoneArchiveImporter(database: try CatalogDatabase.open(at: fixture.databaseURL))
            let preview = try reopened.verifiedPreview(migrationID: header.migrationID,
                mediaID: item.mediaID, archiveRoot: receipt.archiveURL)
            XCTAssertEqual(preview.resources.count, editedCount + 2)
            XCTAssertEqual(preview.preferredResourceID, editedCount == 1 ? edited[0].id : original.id)
            XCTAssertEqual(try Data(contentsOf: preview.originalURL), Data("original".utf8))
            XCTAssertTrue(try XCTUnwrap(preview.resources.first { $0.id == paired.id }).isVideo)
            XCTAssertFalse(try XCTUnwrap(preview.resources.first { $0.id == edited[0].id }).isVideo)
            let editedURL = try XCTUnwrap(preview.resources.first { $0.id == edited[0].id }).url
            XCTAssertEqual(try Data(contentsOf: editedURL), Data("edited-0".utf8))
            try Data("tampered".utf8).write(to: editedURL)
            XCTAssertThrowsError(try reopened.verifiedPreview(migrationID: header.migrationID,
                mediaID: item.mediaID, archiveRoot: receipt.archiveURL))
        }
    }

    func testSealedNetworkStageImportsIntoSiblingMacArchive() async throws {
        try await checkNetworkArchiveRecovery(coverage: .selectedAssetsOnly)
    }

    func testLimitedAlbumCoverageSurvivesRecoveryButCannotComplete() async throws {
        try await checkNetworkArchiveRecovery(coverage: .unavailableLimitedAuthorization)
    }

    private func checkNetworkArchiveRecovery(coverage: ImageAllMigrationAppleAlbumCoverage) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let resource = try fixture.resource(
            "original", bytes: Data("network-stage-original".utf8), originalFilename: "../原图.heic"
        )
        let metadata = ImageAllMigrationSourceMetadata(pixelWidth: 4032, pixelHeight: 3024,
            modifiedAtMs: 900, location: .init(latitude: 0, longitude: 0, horizontalAccuracyMeters: 25))
        let item = fixture.item(resource: resource, sourceMetadata: metadata)
        let header = fixture.header(count: 1, appleAlbumCoverage: coverage)
        try fixture.write(header: header, items: [item])
        let deviceID = UUID()
        let store = try ImageAllMigrationTransferStore(root: fixture.target)
        _ = try await store.begin(
            migrationID: header.migrationID, authenticatedDeviceID: deviceID,
            sourceInstallID: header.sourceDeviceID
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
            sourceDeviceID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch,
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
            ),
            auditRecords: [.init(operationID: UUID(), sequence: 8, mediaID: item.mediaID,
                                 field: "favorite.target", value: "1", createdAtMs: 900, origin: "conflictResolution")]
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
        let restoredImporter = VerifiedPhoneArchiveImporter(database: try CatalogDatabase.open(at: recovery.recoveredCatalogURL))
        XCTAssertEqual(try restoredImporter.verifiedPreview(migrationID: header.migrationID,
            mediaID: item.mediaID, archiveRoot: recovery.restoredArchiveURL).sourceMetadata, metadata)
        let restoredPreview = try restoredImporter.verifiedPreview(migrationID: header.migrationID,
            mediaID: item.mediaID, archiveRoot: recovery.restoredArchiveURL)
        XCTAssertEqual(restoredPreview.resources.first?.originalFilename, "../原图.heic")
        XCTAssertEqual(restoredPreview.originalURL.deletingLastPathComponent().lastPathComponent, "resources")
        XCTAssertNotEqual(restoredPreview.originalURL.lastPathComponent, "原图.heic")
        XCTAssertEqual(recovery.integrity.factSnapshot?.auditRecords, facts.auditRecords)
        XCTAssertNotEqual(recovery.restoredArchiveURL, imported.archiveURL)
        XCTAssertEqual(try Data(contentsOf: recovery.restoredArchiveURL.appendingPathComponent(
            try XCTUnwrap(resource.relativePath)
        )), Data("network-stage-original".utf8))
        XCTAssertNotNil(recovery.integrity.phoneSyncCheckpoint)
        XCTAssertEqual(try restoredImporter.importedBatches().first?.appleAlbumCoverage, coverage)
        if coverage == .unavailableLimitedAuthorization {
            XCTAssertThrowsError(try importer.recordValidation(
                migrationID: header.migrationID, archiveRoot: imported.archiveURL, recovery: recovery
            )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .validationStale) }
            XCTAssertNil(try importer.latestCompletionReceipt(migrationID: header.migrationID))
            return
        }
        // A pre-V060 independent recovery must remain verifiable read-only.
        try await restoredImporter.database.pool.write { db in
            try db.execute(sql: "ALTER TABLE migration_import DROP COLUMN apple_album_unavailable_reason")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [CatalogMigrationID.v060AddPhoneAlbumUnavailableReason])
        }
        let validation = try importer.recordValidation(
            migrationID: header.migrationID, archiveRoot: imported.archiveURL,
            recovery: recovery
        )
        let recoveryWasMigrated = try await restoredImporter.database.pool.read { db in
            try db.columns(in: "migration_import").contains { $0.name == "apple_album_unavailable_reason" }
        }
        XCTAssertFalse(recoveryWasMigrated, "validation must not mutate a historical recovery catalog")
        let reopenedImporter = VerifiedPhoneArchiveImporter(
            database: try CatalogDatabase.open(at: fixture.databaseURL)
        )
        let loadedValidation = try XCTUnwrap(reopenedImporter.latestValidationRecord(
            migrationID: header.migrationID
        ))
        XCTAssertEqual(loadedValidation.id, validation.id)
        XCTAssertEqual(try reopenedImporter.auditValidationRecord(loadedValidation), integrity)
        let completion = try reopenedImporter.recordCompletionReceipt(
            validation: loadedValidation
        )
        XCTAssertEqual(completion.itemCount, 1)
        XCTAssertEqual(completion.unsupportedResourceCount, 0)
        XCTAssertEqual(completion.albumCoverage, "selectedAssetsOnly")
        XCTAssertEqual(try reopenedImporter.recordCompletionReceipt(
            validation: loadedValidation
        ), completion)
        XCTAssertEqual(try reopenedImporter.latestCompletionReceipt(
            migrationID: header.migrationID
        ), completion)
        XCTAssertEqual(try reopenedImporter.auditCompletionReceipt(completion), integrity)
        try Data("changed-recovery".utf8).write(
            to: recovery.restoredArchiveURL.appendingPathComponent(
                try XCTUnwrap(resource.relativePath)
            )
        )
        XCTAssertThrowsError(try reopenedImporter.auditValidationRecord(loadedValidation))
        XCTAssertThrowsError(try reopenedImporter.auditCompletionReceipt(completion))
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
        try fixture.database.pool.read { db in
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT source_local_identifier FROM media_item WHERE id = ?",
                arguments: [mediaID.uuidString.lowercased()]
            ), "phone-local-id")
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT storage_kind FROM media_replica WHERE media_id = ?",
                arguments: [mediaID.uuidString.lowercased()]
            ), "macArchive")
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM media_asset_binding"
            ), 0)
        }
        let sourceLink = try XCTUnwrap(importer.sourceLinks(
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch
        )[mediaID])
        XCTAssertEqual(sourceLink.migrationID, header.migrationID)
        let matchingProjection = RemoteLocalLibraryAsset(
            id: mediaID, localIdentifier: "phone-local-id", mediaKind: .image,
            createdAtMs: 1_000, observedFavorite: false, favoriteTarget: nil,
            tagDecisions: [], collections: []
        )
        XCTAssertTrue(sourceLink.matches(matchingProjection))
        XCTAssertFalse(sourceLink.matches(.init(
            id: mediaID, localIdentifier: "other-photo", mediaKind: .image,
            createdAtMs: 1_000, observedFavorite: false, favoriteTarget: nil,
            tagDecisions: [], collections: []
        )))
        XCTAssertFalse(sourceLink.matches(.init(
            id: mediaID, localIdentifier: "phone-local-id", mediaKind: .video,
            createdAtMs: 1_000, observedFavorite: false, favoriteTarget: nil,
            tagDecisions: [], collections: []
        )))
        XCTAssertTrue(try importer.sourceLinks(
            sourceInstallID: header.sourceDeviceID, sourceEpoch: UUID()
        ).isEmpty)
        XCTAssertTrue(try importer.sourceLinks(
            sourceInstallID: UUID(), sourceEpoch: header.sourceEpoch
        ).isEmpty)
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
        let offlineFacts = try importer.importedFacts(
            migrationID: header.migrationID, mediaID: mediaID
        )
        XCTAssertEqual(offlineFacts.tagDecisions.first?.tagName, "旅途")
        XCTAssertEqual(offlineFacts.collections.first?.collectionName, "相册")
        XCTAssertEqual(offlineFacts.appleAlbums.first?.albumTitle, "周末")
        XCTAssertEqual(offlineFacts.favoriteTarget, true)

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
        XCTAssertEqual(try fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_replica")
        }, 0)
        XCTAssertTrue(try importer.sourceLinks(
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch
        ).isEmpty)
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
        XCTAssertThrowsError(try importer.verifiedGalleryOriginalURLs(
            migrationID: header.migrationID, archiveRoot: receipt.archiveURL
        ))
    }

    func testAuditRejectsMissingMediaReplicaBinding() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = fixture.item(resource: try fixture.resource(
            "original", bytes: Data("replica-binding".utf8)
        ))
        let header = fixture.header(count: 1)
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let receipt = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        try fixture.database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM media_replica WHERE media_id = ?",
                arguments: [item.mediaID.uuidString.lowercased()]
            )
        }
        XCTAssertThrowsError(try importer.auditImportedArchive(
            migrationID: header.migrationID, archiveRoot: receipt.archiveURL
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .catalogDiverged) }
    }

    func testUserConfirmedAssetBindingIsVersionedAndCannotClaimAnotherMedia() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.item(resource: try fixture.resource(
            "original", bytes: Data("first-phone-image".utf8)
        ))
        let second = ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "second-phone-local-id",
            mediaKind: .image, createdAtMs: nil,
            favoriteTarget: nil, observedFavorite: false, factRevision: 0,
            tagDecisions: [], collections: [], resources: [try fixture.resource(
                "original", bytes: Data("second-phone-image".utf8)
            )]
        )
        let header = fixture.header(count: 2)
        try fixture.write(header: header, items: [first, second])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        _ = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: CatalogRepository(database: fixture.database), assetID: assetID
        )
        XCTAssertTrue(try importer.assetBindingCandidates(
            migrationID: header.migrationID, mediaID: first.mediaID, search: "x"
        ).isEmpty)
        let candidate = try XCTUnwrap(importer.assetBindingCandidates(
            migrationID: header.migrationID, mediaID: first.mediaID, search: "photo.jpg"
        ).first)
        XCTAssertEqual(candidate.id, assetID)
        try fixture.database.pool.write { db in
            try db.execute(sql: """
                UPDATE asset SET content_revision = content_revision + 1 WHERE id = ?
                """, arguments: [assetID.uuidString.lowercased()])
        }
        XCTAssertThrowsError(try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: first.mediaID, candidate: candidate
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .assetBindingCandidateChanged) }
        let refreshedCandidate = try XCTUnwrap(importer.assetBindingCandidates(
            migrationID: header.migrationID, mediaID: first.mediaID, search: "photo.jpg"
        ).first)
        let firstReceipt = try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: first.mediaID, candidate: refreshedCandidate
        )
        XCTAssertFalse(firstReceipt.replayed)
        XCTAssertTrue(try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: first.mediaID, candidate: refreshedCandidate
        ).replayed)
        XCTAssertThrowsError(try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: second.mediaID, candidate: refreshedCandidate
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .assetAlreadyBound) }
        let imported = try importer.importedItems(migrationID: header.migrationID, offset: 0)
        XCTAssertEqual(imported.first { $0.id == first.mediaID }?.assetBindingCount, 1)
        XCTAssertEqual(imported.first { $0.id == second.mediaID }?.assetBindingCount, 0)
        let bound = try importer.boundAssets(migrationID: header.migrationID, mediaID: first.mediaID)
        XCTAssertEqual(bound.map(\.id), [assetID])
        XCTAssertEqual(bound.first?.evidenceKind, "userConfirmed")
        let confirmationID = try XCTUnwrap(bound.first?.confirmationEventID)
        try fixture.database.pool.read { db in
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT evidence_kind FROM media_asset_binding WHERE asset_id = ?",
                arguments: [assetID.uuidString.lowercased()]
            ), "userConfirmed")
        }
        XCTAssertFalse(try importer.revokeAssetBinding(
            migrationID: header.migrationID, mediaID: first.mediaID,
            assetID: assetID, confirmationEventID: confirmationID
        ).replayed)
        XCTAssertTrue(try importer.revokeAssetBinding(
            migrationID: header.migrationID, mediaID: first.mediaID,
            assetID: assetID, confirmationEventID: confirmationID
        ).replayed)
        XCTAssertTrue(try importer.boundAssets(
            migrationID: header.migrationID, mediaID: first.mediaID
        ).isEmpty)
        XCTAssertFalse(try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: first.mediaID,
            candidate: refreshedCandidate
        ).replayed)
        XCTAssertThrowsError(try importer.revokeAssetBinding(
            migrationID: header.migrationID, mediaID: first.mediaID,
            assetID: assetID, confirmationEventID: confirmationID
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .assetBindingCandidateChanged) }
        try fixture.database.pool.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: """
                SELECT event_kind FROM media_asset_binding_event
                WHERE media_id = ? AND asset_id = ? ORDER BY sequence
                """, arguments: [first.mediaID.uuidString.lowercased(), assetID.uuidString.lowercased()]
            ), ["confirmed", "revoked", "confirmed"])
        }
        try fixture.database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET availability = 'missing' WHERE id = ?",
                           arguments: [assetID.uuidString.lowercased()])
        }
        XCTAssertThrowsError(try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: first.mediaID, candidate: refreshedCandidate
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .assetBindingCandidateChanged) }
        let currentConfirmation = try XCTUnwrap(importer.boundAssets(
            migrationID: header.migrationID, mediaID: first.mediaID
        ).first?.confirmationEventID)
        try fixture.database.pool.write { db in
            try db.execute(sql: "DELETE FROM media_asset_binding_event WHERE id = ?",
                           arguments: [currentConfirmation.uuidString.lowercased()])
        }
        XCTAssertThrowsError(try importer.boundAssets(
            migrationID: header.migrationID, mediaID: first.mediaID
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .catalogDiverged) }
    }

    func testBoundAssetFactComparisonKeepsTagIdentityAndSourceFactsSeparate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sharedID = UUID()
        let conflictingDecisionID = UUID()
        let missingDecisionID = UUID()
        let phoneAliasID = UUID()
        let macAliasID = UUID()
        let phoneMissingID = UUID()
        let macOnlyID = UUID()
        let item = ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "phone-comparison",
            mediaKind: .image, createdAtMs: nil,
            favoriteTarget: true, observedFavorite: false, factRevision: 1,
            tagDecisions: [
                .init(tagID: sharedID, tagName: "Trip", decision: .accepted),
                .init(tagID: conflictingDecisionID, tagName: "City", decision: .rejected),
                .init(tagID: missingDecisionID, tagName: "Walk", decision: .accepted),
                .init(tagID: phoneAliasID, tagName: "Beach", decision: .rejected),
                .init(tagID: phoneMissingID, tagName: "New", decision: .accepted),
            ],
            collections: [.init(collectionID: UUID(), collectionName: "旅途", included: true)],
            resources: [try fixture.resource("original", bytes: Data("comparison".utf8))]
        )
        let header = fixture.header(count: 1)
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        _ = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: CatalogRepository(database: fixture.database), assetID: assetID
        )
        try fixture.database.pool.write { db in
            for (id, name, normalized) in [
                (sharedID, "Trip", "trip"),
                (conflictingDecisionID, "City", "city"),
                (missingDecisionID, "Walk", "walk"),
                (macAliasID, "Beach", "beach"),
                (macOnlyID, "Mac only", "mac only"),
            ] {
                try db.execute(sql: """
                    INSERT INTO tag (id, name, normalized_name, state,
                                     created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, 'active', 1, 1)
                    """, arguments: [id.uuidString.lowercased(), name, normalized])
            }
            for (id, decision) in [(sharedID, "accepted"),
                                   (conflictingDecisionID, "accepted"),
                                   (macAliasID, "accepted"),
                                   (macOnlyID, "rejected")] {
                try db.execute(sql: """
                    INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                    VALUES (?, ?, ?, 1)
                    """, arguments: [assetID.uuidString.lowercased(), id.uuidString.lowercased(), decision])
            }
            try db.execute(sql: """
                INSERT INTO asset_favorite_state (
                    asset_id, desired_value, sync_status, intent_revision,
                    requested_at_ms, updated_at_ms
                ) VALUES (?, 0, 'localOnly', 0, 1, 1)
                """, arguments: [assetID.uuidString.lowercased()])
        }
        let candidate = try XCTUnwrap(importer.assetBindingCandidates(
            migrationID: header.migrationID, mediaID: item.mediaID, search: "photo.jpg"
        ).first)
        _ = try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: item.mediaID, candidate: candidate
        )
        let compared = try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        XCTAssertEqual(compared.sourceInstallID, fixture.sourceDeviceID)
        XCTAssertEqual(compared.sourceEpoch, fixture.sourceEpoch)
        XCTAssertEqual(compared.bindingConfirmationEventID, try XCTUnwrap(
            importer.boundAssets(migrationID: header.migrationID, mediaID: item.mediaID)
                .first?.confirmationEventID
        ))
        let exactTag = try XCTUnwrap(compared.tags.first { $0.phoneTagID == sharedID })
        XCTAssertEqual(try importer.validateBoundMacTagDecision(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: compared, expectedTag: exactTag
        ), .accepted)
        XCTAssertEqual(compared.tags.first { $0.phoneTagID == sharedID }?.state, .same)
        XCTAssertEqual(compared.tags.first { $0.phoneTagID == conflictingDecisionID }?.state, .decisionDiffers)
        XCTAssertEqual(compared.tags.first { $0.phoneTagID == missingDecisionID }?.state, .macDecisionMissing)
        XCTAssertEqual(compared.tags.first { $0.phoneTagID == phoneAliasID }?.state, .nameAliasRequired)
        XCTAssertEqual(compared.tags.first { $0.phoneTagID == phoneMissingID }?.state, .macTagMissing)
        XCTAssertEqual(compared.macOnlyTags.map(\.tagID), [macOnlyID])
        XCTAssertEqual(compared.phoneFavoriteTarget, true)
        XCTAssertEqual(compared.macFavoriteTarget, false)
        XCTAssertEqual(compared.phoneCollectionNames, ["旅途"])
        let aliasCandidate = try XCTUnwrap(compared.tags.first {
            $0.phoneTagID == phoneAliasID
        })
        let aliasRevision = try XCTUnwrap(aliasCandidate.macTagUpdatedAtMs)
        XCTAssertThrowsError(try importer.confirmTagAlias(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            phoneTagID: phoneAliasID, phoneTagName: "Beach", macTagID: sharedID,
            macTagUpdatedAtMs: 1,
            expectedFactSnapshotSequence: compared.factSnapshotSequence
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .tagAliasAlreadyMapped) }
        try fixture.database.pool.write { db in
            try db.execute(sql: "UPDATE tag SET updated_at_ms = 2 WHERE id = ?",
                           arguments: [macAliasID.uuidString.lowercased()])
        }
        XCTAssertThrowsError(try importer.confirmTagAlias(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            phoneTagID: phoneAliasID, phoneTagName: "Beach", macTagID: macAliasID,
            macTagUpdatedAtMs: aliasRevision,
            expectedFactSnapshotSequence: compared.factSnapshotSequence
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .tagAliasCandidateChanged) }
        let refreshed = try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        let refreshedAlias = try XCTUnwrap(refreshed.tags.first {
            $0.phoneTagID == phoneAliasID
        })
        let currentRevision = try XCTUnwrap(refreshedAlias.macTagUpdatedAtMs)
        XCTAssertFalse(try importer.confirmTagAlias(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            phoneTagID: phoneAliasID, phoneTagName: "Beach", macTagID: macAliasID,
            macTagUpdatedAtMs: currentRevision,
            expectedFactSnapshotSequence: refreshed.factSnapshotSequence
        ).replayed)
        XCTAssertTrue(try importer.confirmTagAlias(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            phoneTagID: phoneAliasID, phoneTagName: "Beach", macTagID: macAliasID,
            macTagUpdatedAtMs: currentRevision,
            expectedFactSnapshotSequence: refreshed.factSnapshotSequence
        ).replayed)
        let mapped = try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        let mappedAlias = try XCTUnwrap(mapped.tags.first { $0.phoneTagID == phoneAliasID })
        XCTAssertEqual(mappedAlias.state, .decisionDiffers)
        XCTAssertEqual(mappedAlias.macTagID, macAliasID)
        XCTAssertEqual(try importer.validateBoundMacTagDecision(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: mapped, expectedTag: mappedAlias
        ), .accepted)
        let outboundOperationID = UUID()
        let sharedBeforeOutbound = RemoteLocalLibrarySyncStore.SharedTagFact(
            assetID: item.mediaID, tagID: phoneAliasID, tagName: "Beach",
            decision: .rejected, revision: 1
        )
        let prepared = try importer.prepareOutboundMacTagDecision(
            operationID: outboundOperationID,
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: mapped, expectedTag: mappedAlias,
            phoneDeviceID: UUID(), phoneScopeRevision: 1,
            sharedFact: sharedBeforeOutbound, timestampMs: 5
        )
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertThrowsError(try importer.prepareOutboundMacTagDecision(
            operationID: UUID(),
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: mapped, expectedTag: mappedAlias,
            phoneDeviceID: prepared.phoneDeviceID, phoneScopeRevision: 1,
            sharedFact: sharedBeforeOutbound, timestampMs: 5
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .tagSyncPending) }
        let reopenedCatalog = try CatalogDatabase.open(at: fixture.databaseURL)
        let reopenedImporter = VerifiedPhoneArchiveImporter(database: reopenedCatalog)
        XCTAssertEqual(try reopenedImporter.outboundTagIntents(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        ).map(\.id), [outboundOperationID])
        let outboundReceipt = RemoteLocalLibrarySyncStore.MacTagOperationReceipt(
            operationID: outboundOperationID, deviceID: prepared.phoneDeviceID,
            installID: fixture.sourceDeviceID, sourceEpoch: fixture.sourceEpoch,
            scopeRevision: 1, assetID: item.mediaID, tagID: phoneAliasID,
            createdTagName: nil, decision: .accepted, expectedRevision: 1,
            resultingRevision: 2, changeSequence: 1
        )
        let committed = try reopenedImporter.finalizeOutboundMacTagDecision(
            operationID: outboundOperationID, receipt: outboundReceipt,
            timestampMs: 6
        )
        XCTAssertEqual(committed.state, .committed)
        XCTAssertEqual(committed.phoneResultingRevision, 2)
        XCTAssertEqual(try importer.outboundTagIntents(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        ).count, 0)
        let phoneDeviceID = UUID()
        let applyOperationID = UUID()
        let sharedRejection = RemoteLocalLibrarySyncStore.SharedTagFact(
            assetID: item.mediaID, tagID: phoneAliasID, tagName: "Beach",
            decision: .rejected, revision: 2
        )
        let applied = try importer.applySharedPhoneTagDecisionToBoundAsset(
            operationID: applyOperationID,
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: mapped, expectedTag: mappedAlias,
            phoneDeviceID: phoneDeviceID, phoneScopeRevision: 1,
            sharedFact: sharedRejection, timestampMs: 2
        )
        XCTAssertFalse(applied.replayed)
        XCTAssertEqual(applied.decision, .rejected)
        XCTAssertEqual(applied.macDecisionRevision, 2)
        XCTAssertTrue(try importer.applySharedPhoneTagDecisionToBoundAsset(
            operationID: applyOperationID,
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: mapped, expectedTag: mappedAlias,
            phoneDeviceID: phoneDeviceID, phoneScopeRevision: 1,
            sharedFact: sharedRejection, timestampMs: 2
        ).replayed)
        XCTAssertThrowsError(try importer.applySharedPhoneTagDecisionToBoundAsset(
            operationID: applyOperationID,
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: mapped, expectedTag: mappedAlias,
            phoneDeviceID: phoneDeviceID, phoneScopeRevision: 1,
            sharedFact: .init(
                assetID: item.mediaID, tagID: phoneAliasID, tagName: "Beach",
                decision: .accepted, revision: 2
            ), timestampMs: 2
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .tagSyncCandidateChanged) }
        XCTAssertThrowsError(try importer.applySharedPhoneTagDecisionToBoundAsset(
            operationID: UUID(),
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: mapped, expectedTag: mappedAlias,
            phoneDeviceID: phoneDeviceID, phoneScopeRevision: 1,
            sharedFact: sharedRejection, timestampMs: 3
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .tagSyncCandidateChanged) }
        let afterRejection = try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        let clearCandidate = try XCTUnwrap(afterRejection.tags.first {
            $0.phoneTagID == phoneAliasID
        })
        let cleared = try importer.applySharedPhoneTagDecisionToBoundAsset(
            operationID: UUID(),
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: afterRejection, expectedTag: clearCandidate,
            phoneDeviceID: phoneDeviceID, phoneScopeRevision: 1,
            sharedFact: .init(
                assetID: item.mediaID, tagID: phoneAliasID, tagName: "Beach",
                decision: .cleared, revision: 3
            ), timestampMs: 3
        )
        XCTAssertEqual(cleared.macDecisionRevision, 3)
        try fixture.database.pool.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: """
                SELECT decision FROM asset_tag_decision
                WHERE asset_id = ? AND tag_id = ?
                """, arguments: [assetID.uuidString.lowercased(),
                                 macAliasID.uuidString.lowercased()]))
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM phone_tag_mac_application_event
                WHERE asset_id = ? AND mac_tag_id = ?
                """, arguments: [assetID.uuidString.lowercased(),
                                 macAliasID.uuidString.lowercased()]), 2)
        }
        let afterClear = try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        let missingDecision = try XCTUnwrap(afterClear.tags.first {
            $0.phoneTagID == phoneAliasID
        })
        XCTAssertEqual(missingDecision.state, .macDecisionMissing)
        let accepted = try importer.applySharedPhoneTagDecisionToBoundAsset(
            operationID: UUID(),
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: afterClear, expectedTag: missingDecision,
            phoneDeviceID: phoneDeviceID, phoneScopeRevision: 1,
            sharedFact: .init(
                assetID: item.mediaID, tagID: phoneAliasID, tagName: "Beach",
                decision: .accepted, revision: 4
            ), timestampMs: 4
        )
        XCTAssertEqual(accepted.macDecisionRevision, 4)
        XCTAssertThrowsError(try importer.validateBoundMacTagDecision(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: mapped, expectedTag: mappedAlias
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .tagSyncCandidateChanged) }
        let aliasConfirmation = try XCTUnwrap(mappedAlias.aliasConfirmationEventID)
        try fixture.database.pool.write { db in
            try db.execute(sql: """
                UPDATE tag SET name = 'Coast', normalized_name = 'coast', updated_at_ms = 3
                WHERE id = ?
                """, arguments: [macAliasID.uuidString.lowercased()])
        }
        XCTAssertEqual(try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        ).tags.first { $0.phoneTagID == phoneAliasID }?.state, .nameDiffers)
        try fixture.database.pool.write { db in
            try db.execute(sql: """
                UPDATE tag SET name = 'Beach', normalized_name = 'beach', updated_at_ms = 4
                WHERE id = ?
                """, arguments: [macAliasID.uuidString.lowercased()])
        }
        XCTAssertFalse(try importer.revokeTagAlias(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            phoneTagID: phoneAliasID, macTagID: macAliasID,
            confirmationEventID: aliasConfirmation
        ).replayed)
        XCTAssertTrue(try importer.revokeTagAlias(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            phoneTagID: phoneAliasID, macTagID: macAliasID,
            confirmationEventID: aliasConfirmation
        ).replayed)
        XCTAssertEqual(try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        ).tags.first { $0.phoneTagID == phoneAliasID }?.state, .nameAliasRequired)
        XCTAssertFalse(try importer.confirmTagAlias(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            phoneTagID: phoneAliasID, phoneTagName: "Beach", macTagID: macAliasID,
            macTagUpdatedAtMs: 4,
            expectedFactSnapshotSequence: refreshed.factSnapshotSequence
        ).replayed)
        XCTAssertThrowsError(try importer.revokeTagAlias(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            phoneTagID: phoneAliasID, macTagID: macAliasID,
            confirmationEventID: aliasConfirmation
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .tagAliasCandidateChanged) }
        try fixture.database.pool.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: """
                SELECT event_kind FROM phone_tag_alias_event
                WHERE phone_tag_id = ? ORDER BY sequence
                """, arguments: [phoneAliasID.uuidString.lowercased()]),
                ["confirmed", "revoked", "confirmed"])
        }
        let confirmationID = try XCTUnwrap(importer.boundAssets(
            migrationID: header.migrationID, mediaID: item.mediaID
        ).first?.confirmationEventID)
        let beforeRebinding = try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        _ = try importer.revokeAssetBinding(
            migrationID: header.migrationID, mediaID: item.mediaID,
            assetID: assetID, confirmationEventID: confirmationID
        )
        XCTAssertThrowsError(try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .assetBindingCandidateChanged) }
        let reboundCandidate = try XCTUnwrap(importer.assetBindingCandidates(
            migrationID: header.migrationID, mediaID: item.mediaID, search: "photo.jpg"
        ).first)
        _ = try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: item.mediaID,
            candidate: reboundCandidate
        )
        XCTAssertThrowsError(try importer.validateBoundMacTagDecision(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: beforeRebinding,
            expectedTag: try XCTUnwrap(beforeRebinding.tags.first {
                $0.phoneTagID == sharedID
            })
        )) { XCTAssertEqual($0 as? PhoneArchiveImportError, .tagSyncCandidateChanged) }
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

    func testDifferentPhoneInstallCannotClaimExistingGlobalMediaID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = fixture.item(resource: try fixture.resource(
            "original", bytes: Data("same-bytes-do-not-merge-identity".utf8)
        ))
        let firstHeader = fixture.header(count: 1)
        try fixture.write(header: firstHeader, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        _ = try importer.importArchive(from: fixture.incoming, to: fixture.target)

        let second = fixture.root.appendingPathComponent("other-install", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.incoming, to: second)
        try FileManager.default.removeItem(
            at: second.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        )
        let otherHeader = ImageAllMigrationHeader(
            migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(),
            scopeRevision: firstHeader.scopeRevision,
            inventoryWatermark: firstHeader.inventoryWatermark,
            declaredItemCount: 1
        )
        try ImageAllMigrationArchive.write(header: otherHeader, items: [item], to: second)
        XCTAssertThrowsError(try importer.importArchive(from: second, to: fixture.target)) {
            XCTAssertEqual($0 as? PhoneArchiveImportError, .migrationIdentityConflict)
        }
        try fixture.database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_item"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_replica"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 1)
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT state FROM migration_import WHERE id = ?",
                arguments: [otherHeader.migrationID.uuidString.lowercased()]
            ), "prepared")
        }
    }

    func testByteIdenticalPhoneItemsKeepSeparateMediaIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data("identical-bytes-distinct-user-items".utf8)
        let first = fixture.item(resource: try fixture.resource("original", bytes: bytes))
        let second = ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "phone-second",
            mediaKind: .image, createdAtMs: nil,
            favoriteTarget: nil, observedFavorite: false, factRevision: 0,
            tagDecisions: [], collections: [],
            resources: [try fixture.resource("original", bytes: bytes)]
        )
        let header = fixture.header(count: 2)
        try fixture.write(header: header, items: [first, second])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let receipt = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        XCTAssertEqual(receipt.itemCount, 2)
        try fixture.database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_item"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_replica"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset_binding"), 0)
        }
        XCTAssertEqual(try importer.auditImportedArchive(
            migrationID: header.migrationID, archiveRoot: receipt.archiveURL
        ).itemCount, 2)
    }

    func testMacTagOutboundIntentFinalizesFromDurableLedgerAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tagID = UUID()
        let item = ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "recoverable-tag",
            mediaKind: .image, createdAtMs: nil,
            favoriteTarget: nil, observedFavorite: false, factRevision: 1,
            tagDecisions: [.init(tagID: tagID, tagName: "Trip", decision: .accepted)],
            collections: [],
            resources: [try fixture.resource("original", bytes: Data("recover-tag".utf8))]
        )
        let header = fixture.header(count: 1)
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        _ = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: CatalogRepository(database: fixture.database), assetID: assetID
        )
        try await fixture.database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO tag (id, name, normalized_name, state,
                                 created_at_ms, updated_at_ms)
                VALUES (?, 'Trip', 'trip', 'active', 1, 1)
                """, arguments: [tagID.uuidString.lowercased()])
            try db.execute(sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'rejected', 1)
                """, arguments: [assetID.uuidString.lowercased(),
                                 tagID.uuidString.lowercased()])
        }
        let candidate = try XCTUnwrap(importer.assetBindingCandidates(
            migrationID: header.migrationID, mediaID: item.mediaID, search: "photo.jpg"
        ).first)
        _ = try importer.confirmAssetBinding(
            migrationID: header.migrationID, mediaID: item.mediaID, candidate: candidate
        )
        let comparison = try importer.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        let comparedTag = try XCTUnwrap(comparison.tags.first)
        let hostID = UUID()
        let deviceID = UUID()
        let ledgerURL = fixture.root.appendingPathComponent("shared-ledger.json")
        let store = try RemoteLocalLibrarySyncStore(hostID: hostID, storageURL: ledgerURL)
        let phoneAsset = RemoteLocalLibraryAsset(
            id: item.mediaID, localIdentifier: item.sourceLocalIdentifier,
            mediaKind: .image, createdAtMs: nil,
            observedFavorite: false, favoriteTarget: nil,
            tagDecisions: [.init(tagID: tagID, tagName: "Trip", decision: .accepted)],
            collections: []
        )
        _ = try await store.submit(.init(
            hostID: hostID, installID: fixture.sourceDeviceID,
            sourceEpoch: fixture.sourceEpoch, scopeRevision: 1,
            snapshotSequence: 1, selectedAssetIDs: [item.mediaID],
            assets: [phoneAsset]
        ), authenticatedDeviceID: deviceID)
        let projected = await store.projection(deviceID: deviceID)
        let fact = try XCTUnwrap(projected?.sharedTagFacts.first)
        let operationID = UUID()
        let intent = try importer.prepareOutboundMacTagDecision(
            operationID: operationID,
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: comparison, expectedTag: comparedTag,
            phoneDeviceID: deviceID, phoneScopeRevision: 1,
            sharedFact: fact, timestampMs: 10
        )
        XCTAssertEqual(intent.state, .prepared)
        let beforeCommit = try await importer.recoverPreparedOutboundMacTagDecisions {
            deviceID, operationID in
            await store.macTagOperation(deviceID: deviceID, operationID: operationID)
        }
        XCTAssertEqual(beforeCommit, .init(
            prepared: 1, committed: 0, stillPending: 1, failedVerification: 0
        ))
        _ = try await store.setTagDecisionFromMac(
            deviceID: deviceID, assetID: item.mediaID, tagID: tagID,
            decision: .rejected, expectedRevision: 1,
            expectedInstallID: fixture.sourceDeviceID,
            expectedSourceEpoch: fixture.sourceEpoch,
            expectedScopeRevision: 1, operationID: operationID
        )
        // Simulate termination before SQLite records the JSON commit.
        let recoveredCatalog = try CatalogDatabase.open(at: fixture.databaseURL)
        let recoveredImporter = VerifiedPhoneArchiveImporter(database: recoveredCatalog)
        let recoveredStore = try RemoteLocalLibrarySyncStore(
            hostID: hostID, storageURL: ledgerURL
        )
        XCTAssertEqual(try recoveredImporter.outboundTagIntents(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        ).map(\.id), [operationID])
        let recoveredValue = await recoveredStore.macTagOperation(
            deviceID: deviceID, operationID: operationID
        )
        let receipt = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(receipt.resultingRevision, 2)
        let wrongReceipt = RemoteLocalLibrarySyncStore.MacTagOperationReceipt(
            operationID: UUID(), deviceID: receipt.deviceID,
            installID: receipt.installID, sourceEpoch: receipt.sourceEpoch,
            scopeRevision: receipt.scopeRevision, assetID: receipt.assetID,
            tagID: receipt.tagID, createdTagName: receipt.createdTagName,
            decision: receipt.decision,
            expectedRevision: receipt.expectedRevision,
            resultingRevision: receipt.resultingRevision,
            changeSequence: receipt.changeSequence
        )
        let rejectedProof = try await recoveredImporter.recoverPreparedOutboundMacTagDecisions {
            _, _ in wrongReceipt
        }
        XCTAssertEqual(rejectedProof, .init(
            prepared: 1, committed: 0, stillPending: 1, failedVerification: 1
        ))
        let recovered = try await recoveredImporter.recoverPreparedOutboundMacTagDecisions {
            deviceID, operationID in
            await recoveredStore.macTagOperation(deviceID: deviceID, operationID: operationID)
        }
        XCTAssertEqual(recovered, .init(
            prepared: 1, committed: 1, stillPending: 0, failedVerification: 0
        ))
        XCTAssertTrue(try recoveredImporter.outboundTagIntents(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        ).isEmpty)
        XCTAssertEqual(try recoveredImporter.finalizeOutboundMacTagDecision(
            operationID: operationID, receipt: receipt, timestampMs: 12
        ).state, .committed)
        let replayRecovery = try await recoveredImporter.recoverPreparedOutboundMacTagDecisions {
            deviceID, operationID in
            await recoveredStore.macTagOperation(deviceID: deviceID, operationID: operationID)
        }
        XCTAssertEqual(replayRecovery, .init(
            prepared: 0, committed: 0, stillPending: 0, failedVerification: 0
        ))

        // A cleared Mac decision is a versioned change, not a missing tag field.
        try await recoveredCatalog.pool.write { db in
            try db.execute(sql: """
                DELETE FROM asset_tag_decision WHERE asset_id = ? AND tag_id = ?
                """, arguments: [assetID.uuidString.lowercased(),
                                 tagID.uuidString.lowercased()])
        }
        let clearedComparison = try recoveredImporter.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        let clearedTag = try XCTUnwrap(clearedComparison.tags.first)
        XCTAssertEqual(clearedTag.state, .macDecisionMissing)
        XCTAssertEqual(try recoveredImporter.validateBoundMacTagDecision(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: clearedComparison, expectedTag: clearedTag
        ), .cleared)
        let currentProjection = await recoveredStore.projection(deviceID: deviceID)
        let currentFact = try XCTUnwrap(currentProjection?.sharedTagFacts.first)
        let clearOperationID = UUID()
        let clearIntent = try recoveredImporter.prepareOutboundMacTagDecision(
            operationID: clearOperationID,
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: clearedComparison, expectedTag: clearedTag,
            phoneDeviceID: deviceID, phoneScopeRevision: 1,
            sharedFact: currentFact, timestampMs: 13
        )
        XCTAssertEqual(clearIntent.desiredDecision, .cleared)
        _ = try await recoveredStore.setTagDecisionFromMac(
            deviceID: deviceID, assetID: item.mediaID, tagID: tagID,
            decision: .cleared, expectedRevision: currentFact.revision,
            expectedInstallID: fixture.sourceDeviceID,
            expectedSourceEpoch: fixture.sourceEpoch,
            expectedScopeRevision: 1, operationID: clearOperationID
        )
        let clearReceiptValue = await recoveredStore.macTagOperation(
            deviceID: deviceID, operationID: clearOperationID
        )
        let clearReceipt = try XCTUnwrap(clearReceiptValue)
        XCTAssertEqual(try recoveredImporter.finalizeOutboundMacTagDecision(
            operationID: clearOperationID, receipt: clearReceipt, timestampMs: 14
        ).state, .committed)
        let clearedProjection = await recoveredStore.projection(deviceID: deviceID)
        XCTAssertEqual(clearedProjection?.sharedTagFacts.first?.decision, .cleared)

        let newMacTagID = UUID()
        try await recoveredCatalog.pool.write { db in
            try db.execute(sql: """
                INSERT INTO tag (id, name, normalized_name, state,
                                 created_at_ms, updated_at_ms)
                VALUES (?, 'New Journey', 'new journey', 'active', 15, 15)
                """, arguments: [newMacTagID.uuidString.lowercased()])
            try db.execute(sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', 15)
                """, arguments: [assetID.uuidString.lowercased(),
                                 newMacTagID.uuidString.lowercased()])
        }
        let newComparison = try recoveredImporter.compareBoundAssetFacts(
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID
        )
        let newTag = try XCTUnwrap(newComparison.macOnlyTags.first {
            $0.tagID == newMacTagID
        })
        let newOperationID = UUID()
        let newIntent = try recoveredImporter.prepareOutboundMacOnlyTagDecision(
            operationID: newOperationID,
            migrationID: header.migrationID, mediaID: item.mediaID, assetID: assetID,
            expectedComparison: newComparison, expectedTag: newTag,
            phoneDeviceID: deviceID, phoneScopeRevision: 1, timestampMs: 16
        )
        XCTAssertEqual(newIntent.phoneExpectedRevision, 0)
        XCTAssertNil(newIntent.phoneExpectedDecision)
        _ = try await recoveredStore.setTagDecisionFromMac(
            deviceID: deviceID, assetID: item.mediaID, tagID: newMacTagID,
            decision: .accepted, expectedRevision: 0,
            expectedInstallID: fixture.sourceDeviceID,
            expectedSourceEpoch: fixture.sourceEpoch,
            expectedScopeRevision: 1, operationID: newOperationID,
            tagNameForCreate: "New Journey"
        )
        let secondRestart = try RemoteLocalLibrarySyncStore(
            hostID: hostID, storageURL: ledgerURL
        )
        let newRecovery = try await recoveredImporter.recoverPreparedOutboundMacTagDecisions {
            deviceID, operationID in
            await secondRestart.macTagOperation(deviceID: deviceID, operationID: operationID)
        }
        XCTAssertEqual(newRecovery, .init(
            prepared: 1, committed: 1, stillPending: 0, failedVerification: 0
        ))
        let newProjection = await secondRestart.projection(deviceID: deviceID)
        XCTAssertEqual(newProjection?.sharedTagFacts.first(where: {
            $0.tagID == newMacTagID
        })?.revision, 1)
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

        func resource(_ role: String, bytes: Data, uti: String = "public.data", originalFilename: String? = nil) throws -> ImageAllMigrationResource {
            let id = UUID()
            let directory = incoming.appendingPathComponent("resources", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(id.uuidString.lowercased()).bin"
            try bytes.write(to: directory.appendingPathComponent(name))
            let hash = Data(SHA256.hash(data: bytes))
                .map { String(format: "%02x", $0) }.joined()
            return .init(id: id, role: role, version: 1,
                         uniformTypeIdentifier: uti, required: true,
                         status: .present, relativePath: "resources/\(name)",
                         byteCount: Int64(bytes.count), sha256: hash, originalFilename: originalFilename)
        }

        func item(resource: ImageAllMigrationResource, sourceMetadata: ImageAllMigrationSourceMetadata? = nil) -> ImageAllMigrationItem {
            .init(mediaID: UUID(), sourceLocalIdentifier: "phone-local-id",
                  mediaKind: .image, createdAtMs: nil,
                  favoriteTarget: nil, observedFavorite: false, factRevision: 0,
                  tagDecisions: [], collections: [], resources: [resource], sourceMetadata: sourceMetadata)
        }

        func write(header: ImageAllMigrationHeader, items: [ImageAllMigrationItem]) throws {
            try ImageAllMigrationArchive.write(header: header, items: items, to: incoming)
        }
    }
}
