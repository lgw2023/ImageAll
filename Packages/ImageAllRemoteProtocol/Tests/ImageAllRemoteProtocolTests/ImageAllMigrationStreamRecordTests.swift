import CryptoKit
import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllMigrationStreamRecordTests: XCTestCase {
    func testSealedMetadataSurvivesResourceReleaseAndRejectsChangedIdentityOrManifest() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let checkpoint = try ImageAllMigrationExportCheckpoint(parent: parent, binding: Data("stream".utf8))
        let root = checkpoint.root
        let resource = try checkpoint.resourceLocation(key: "asset|0", fileExtension: "bin")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: resource.url)
        let header = ImageAllMigrationHeader(migrationID: checkpoint.migrationID, sourceDeviceID: UUID(),
            sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 2, declaredItemCount: 1,
            appleAlbumCoverage: .selectedAssetsOnly)
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic",
            mediaKind: .image, createdAtMs: nil, favoriteTarget: nil, observedFavorite: false,
            factRevision: 1, tagDecisions: [], collections: [], resources: [.init(
                id: resource.id, role: "original", version: 1, uniformTypeIdentifier: "public.data",
                required: true, status: .present, relativePath: resource.relativePath,
                byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
        try ImageAllMigrationArchive.write(header: header, items: [item], to: root)
        let receipt = ImageAllMigrationTransferSealReceipt(verification: try ImageAllMigrationArchive.verify(at: root))
        let record = try ImageAllMigrationStreamRecord(hostID: UUID(), deviceID: UUID(),
            header: header, items: [item], receipt: receipt)
        try FileManager.default.removeItem(at: resource.url)
        try record.save(in: root)
        XCTAssertThrowsError(try ImageAllMigrationExportCheckpoint(streamingRoot: root))
        checkpoint.close()
        let reopened = try ImageAllMigrationExportCheckpoint(streamingRoot: root)
        defer { reopened.close() }
        let read = try ImageAllMigrationStreamRecord.read(in: root)
        XCTAssertEqual(read, record)
        XCTAssertEqual(read.header.migrationID, reopened.migrationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path))
        let otherPair = try ImageAllMigrationStreamRecord(hostID: UUID(), deviceID: UUID(),
            header: header, items: [item], receipt: receipt)
        XCTAssertThrowsError(try otherPair.save(in: root))
        XCTAssertEqual(try ImageAllMigrationStreamRecord.read(in: root), record)
        let manifest = root.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        let originalManifest = try Data(contentsOf: manifest)
        try Data("changed".utf8).write(to: manifest)
        XCTAssertThrowsError(try ImageAllMigrationStreamRecord.read(in: root))
        try originalManifest.write(to: manifest)
        let recordURL = root.appendingPathComponent(ImageAllMigrationStreamRecord.filename)
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        var changedReceipt = try XCTUnwrap(changed["receipt"] as? [String: Any])
        changedReceipt["verifiedBytes"] = 9
        changed["receipt"] = changedReceipt
        try JSONSerialization.data(withJSONObject: changed).write(to: recordURL)
        XCTAssertThrowsError(try ImageAllMigrationStreamRecord.read(in: root))
        try FileManager.default.removeItem(at: recordURL)
        try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: manifest)
        XCTAssertThrowsError(try ImageAllMigrationStreamRecord.read(in: root))
        XCTAssertThrowsError(try record.save(in: root))
        XCTAssertEqual(try Data(contentsOf: manifest), originalManifest)
    }
}
