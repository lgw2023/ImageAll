import CryptoKit
import Foundation
import GRDB
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class PhoneArchiveImportTests: XCTestCase {
    func testImportPreservesMediaResourcesAndFactsAcrossRestartAndReplay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mediaID = UUID()
        let original = try fixture.resource("original", bytes: Data("original-photo".utf8))
        let pair = try fixture.resource("pairedVideo", bytes: Data("paired-video".utf8))
        let tagID = UUID()
        let collectionID = UUID()
        let header = fixture.header(count: 1)
        let item = ImageAllMigrationItem(
            mediaID: mediaID, sourceLocalIdentifier: "phone-local-id",
            mediaKind: .image, createdAtMs: 1_000,
            favoriteTarget: true, observedFavorite: false, factRevision: 7,
            tagDecisions: [.init(tagID: tagID, tagName: "旅途", decision: .rejected)],
            collections: [.init(collectionID: collectionID, collectionName: "相册", included: true)],
            resources: [original, pair]
        )
        try fixture.write(header: header, items: [item])
        let importer = VerifiedPhoneArchiveImporter(database: fixture.database)
        let receipt = try importer.importArchive(from: fixture.incoming, to: fixture.target)
        XCTAssertFalse(receipt.replayed)
        XCTAssertEqual(receipt.itemCount, 1)
        XCTAssertEqual(receipt.resourceCount, 2)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: receipt.archiveURL).isComplete, true)
        let batch = try XCTUnwrap(importer.importedBatches().first)
        XCTAssertEqual(batch.id, header.migrationID)
        XCTAssertEqual(batch.itemCount, 1)
        let listed = try XCTUnwrap(importer.importedItems(migrationID: batch.id, offset: 0).first)
        XCTAssertEqual(listed.id, mediaID)
        XCTAssertEqual(listed.resourceCount, 2)
        XCTAssertEqual(listed.tagCount, 1)
        XCTAssertEqual(listed.collectionCount, 1)
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

        func header(count: Int) -> ImageAllMigrationHeader {
            .init(migrationID: UUID(), sourceDeviceID: sourceDeviceID,
                  sourceEpoch: sourceEpoch, scopeRevision: 1,
                  inventoryWatermark: 7, declaredItemCount: count)
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
