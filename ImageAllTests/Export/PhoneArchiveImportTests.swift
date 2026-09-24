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

    func testSealedNetworkStageImportsIntoSiblingMacArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let resource = try fixture.resource(
            "original", bytes: Data("network-stage-original".utf8)
        )
        let item = fixture.item(resource: resource)
        let header = fixture.header(count: 1, appleAlbumCoverage: .selectedAssetsOnly)
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
        let validation = try importer.recordValidation(
            migrationID: header.migrationID, archiveRoot: imported.archiveURL,
            recovery: recovery
        )
        let reopenedImporter = VerifiedPhoneArchiveImporter(
            database: try CatalogDatabase.open(at: fixture.databaseURL)
        )
        let loadedValidation = try XCTUnwrap(reopenedImporter.latestValidationRecord(
            migrationID: header.migrationID
        ))
        XCTAssertEqual(loadedValidation.id, validation.id)
        XCTAssertEqual(try reopenedImporter.auditValidationRecord(loadedValidation), integrity)
        try Data("changed-recovery".utf8).write(
            to: recovery.restoredArchiveURL.appendingPathComponent(
                try XCTUnwrap(resource.relativePath)
            )
        )
        XCTAssertThrowsError(try reopenedImporter.auditValidationRecord(loadedValidation))
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
