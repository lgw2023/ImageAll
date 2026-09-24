import CryptoKit
import Foundation
import ImageAllRemoteProtocol
import XCTest

final class ImageAllMigrationArchiveTests: XCTestCase {
    func testIndependentVerifierChecksOriginalBytesAndHumanFacts() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceID = UUID()
        let bytes = Data("synthetic-original-image".utf8)
        let item = try makeItem(root: root, resourceID: resourceID, bytes: bytes)
        let migrationID = UUID()
        try ImageAllMigrationArchive.write(
            header: header(migrationID: migrationID, count: 1),
            items: [item], to: root
        )

        let result = try ImageAllMigrationArchive.verify(at: root)
        XCTAssertEqual(result.migrationID, migrationID)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(result.resourceCount, 1)
        XCTAssertEqual(result.verifiedBytes, Int64(bytes.count))
        XCTAssertEqual(result.manifestSHA256.count, 64)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(item.tagDecisions.first?.decision, .rejected)
        XCTAssertEqual(item.collections.first?.included, true)

        try Data("synthetic-original-changed".utf8).write(
            to: root.appendingPathComponent("resources/\(resourceID.uuidString.lowercased()).jpg")
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .resourceChanged)
        }
    }

    func testMissingRequiredResourceIsReportedWithoutClaimingCompletion() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaID = UUID()
        let item = ImageAllMigrationItem(
            mediaID: mediaID, sourceLocalIdentifier: "fixture-local",
            mediaKind: .image, createdAtMs: nil,
            favoriteTarget: true, observedFavorite: false, factRevision: 2,
            tagDecisions: [], collections: [], resources: [
                .init(id: UUID(), role: "original", version: 1,
                      uniformTypeIdentifier: "public.jpeg",
                      required: true, status: .notLocal,
                      relativePath: nil, byteCount: nil, sha256: nil)
            ]
        )
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        let result = try ImageAllMigrationArchive.verify(at: root)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.incompleteMediaIDs, [mediaID])
        XCTAssertEqual(result.verifiedBytes, 0)
    }

    func testRejectsSymlinkAndUnfinishedOrDuplicateManifest() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceID = UUID()
        let bytes = Data("fixture".utf8)
        let item = try makeItem(root: root, resourceID: resourceID, bytes: bytes)
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 2), items: [item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .invalidManifest)
        }

        let manifest = root.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        try FileManager.default.removeItem(at: manifest)
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 2), items: [item, item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .duplicateIdentity)
        }

        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.removeItem(at: root.appendingPathComponent("resources"))
        let external = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("resources"), withDestinationURL: external
        )
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .unsafeResourcePath)
        }
    }

    func testPublishesIndependentVerifiedCopyWithoutChangingSource() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetParent = makeRoot()
        defer { try? FileManager.default.removeItem(at: targetParent) }
        let resourceID = UUID()
        let bytes = Data("independent synthetic original".utf8)
        let item = try makeItem(root: root, resourceID: resourceID, bytes: bytes)
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        let sourceVerification = try ImageAllMigrationArchive.verify(at: root)
        let copy = try ImageAllMigrationArchive.publishVerifiedCopy(
            from: root, to: targetParent
        )
        XCTAssertNotEqual(copy.path, root.path)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: copy), sourceVerification)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: root), sourceVerification)
        XCTAssertThrowsError(try ImageAllMigrationArchive.publishVerifiedCopy(
            from: root, to: targetParent
        )) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .destinationCollision)
        }
        XCTAssertThrowsError(try ImageAllMigrationArchive.publishVerifiedCopy(
            from: root, to: root
        )) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .destinationOverlap)
        }
    }

    func testRejectsResourcePathThatDoesNotUseReceiverGeneratedName() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceID = UUID()
        let bytes = Data("fixture".utf8)
        let original = try makeItem(root: root, resourceID: resourceID, bytes: bytes)
        let resource = try XCTUnwrap(original.resources.first)
        let item = ImageAllMigrationItem(
            mediaID: original.mediaID,
            sourceLocalIdentifier: original.sourceLocalIdentifier,
            mediaKind: original.mediaKind,
            createdAtMs: original.createdAtMs,
            favoriteTarget: original.favoriteTarget,
            observedFavorite: original.observedFavorite,
            factRevision: original.factRevision,
            tagDecisions: original.tagDecisions,
            collections: original.collections,
            resources: [.init(
                id: resource.id, role: resource.role, version: resource.version,
                uniformTypeIdentifier: resource.uniformTypeIdentifier,
                required: true, status: .present,
                relativePath: "resources/../escape.jpg",
                byteCount: resource.byteCount, sha256: resource.sha256
            )]
        )
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .unsafeResourcePath)
        }
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllArchive-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func header(migrationID: UUID, count: Int) -> ImageAllMigrationHeader {
        .init(migrationID: migrationID, sourceDeviceID: UUID(), sourceEpoch: UUID(),
              scopeRevision: 1, inventoryWatermark: 9, declaredItemCount: count)
    }

    private func makeItem(root: URL, resourceID: UUID, bytes: Data) throws -> ImageAllMigrationItem {
        let directory = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(resourceID.uuidString.lowercased()).jpg"
        try bytes.write(to: directory.appendingPathComponent(name))
        let hash = Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
        return ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "fixture-local",
            mediaKind: .image, createdAtMs: 1_000,
            favoriteTarget: true, observedFavorite: false, factRevision: 3,
            tagDecisions: [.init(tagID: UUID(), tagName: "family", decision: .rejected)],
            collections: [.init(collectionID: UUID(), collectionName: "trip", included: true)],
            resources: [
                .init(id: resourceID, role: "original", version: 1,
                      uniformTypeIdentifier: "public.jpeg",
                      required: true, status: .present,
                      relativePath: "resources/\(name)",
                      byteCount: Int64(bytes.count), sha256: hash)
            ]
        )
    }
}
