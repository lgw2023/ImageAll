import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllMigrationExportCleanupTests: XCTestCase {
    struct Fixture: Codable {
        let parent: URL, root: URL
        let record: ImageAllMigrationStreamRecord
        let query: RemoteImportTaskQuery
        let nonce: UUID
        let receipt: RemoteExportCleanupReceipt
        func release(nonce override: UUID? = nil, before: (Int) throws -> Void = { _ in }) throws -> ImageAllMigrationCleanupResult {
            try ImageAllMigrationExportCleanup.release(root: root, query: query, hostID: record.hostID,
                deviceID: record.deviceID, nonce: override ?? nonce, receipt: receipt, beforeRelease: before)
        }
        var paths: [URL] { record.items.flatMap(\.resources).map { root.appendingPathComponent($0.relativePath!) } }
    }
    func fixture(inventoryWatermark: Int64 = 1, factRevision: Int64 = 1) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let checkpoint = try ImageAllMigrationExportCheckpoint(parent: parent, binding: Data(UUID().uuidString.utf8))
        defer { checkpoint.close() }
        var resources: [ImageAllMigrationResource] = []
        for i in 0..<2 {
            let location = try checkpoint.resourceLocation(key: "synthetic-\(i)", fileExtension: "bin")
            let bytes = Data(repeating: UInt8(40 + i), count: 4096)
            try bytes.write(to: location.url)
            resources.append(.init(id: location.id, role: "original", version: 1, uniformTypeIdentifier: "public.data",
                required: true, status: .present, relativePath: location.relativePath, byteCount: 4096,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
        }
        let header = ImageAllMigrationHeader(migrationID: checkpoint.migrationID, sourceDeviceID: UUID(), sourceEpoch: UUID(),
            scopeRevision: 1, inventoryWatermark: inventoryWatermark, declaredItemCount: 1)
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: factRevision, tagDecisions: [], collections: [], resources: resources)
        try ImageAllMigrationArchive.write(header: header, items: [item], to: checkpoint.root)
        let digest = try ImageAllMigrationStreamRecord.manifestSHA256(header: header, items: [item])
        let seal = ImageAllMigrationTransferSealReceipt(verification: try ImageAllMigrationArchive.verify(at: checkpoint.root))
        let record = try ImageAllMigrationStreamRecord(hostID: UUID(), deviceID: UUID(), header: header, items: [item], receipt: seal)
        try record.save(in: checkpoint.root)
        let query = RemoteImportTaskQuery(taskID: UUID(), migrationID: header.migrationID, sourceInstallID: header.sourceDeviceID,
            sourceEpoch: header.sourceEpoch, manifestSHA256: digest)
        let nonce = UUID()
        let receipt = RemoteExportCleanupReceipt(query: query, nonce: nonce, hostID: record.hostID, deviceID: record.deviceID,
            sourceID: UUID(), itemCount: 1, resourceCount: 2, verifiedBytes: 8192)
        return Fixture(parent: parent, root: checkpoint.root, record: record, query: query, nonce: nonce, receipt: receipt)
    }
    func publishFacts(_ f: Fixture, watermark: Int64) throws -> URL {
        let h = f.record.header
        let snapshot = ImageAllMigrationFactSnapshot(sourceDeviceID: h.sourceDeviceID,
            sourceEpoch: h.sourceEpoch, scopeRevision: h.scopeRevision,
            snapshotSequence: h.inventoryWatermark + 3, factWatermark: watermark,
            items: f.record.items.map { .init(mediaID: $0.mediaID, observedFavorite: $0.observedFavorite,
                favoriteTarget: $0.favoriteTarget, tagDecisions: $0.tagDecisions, collections: $0.collections) })
        let input = f.parent.appendingPathComponent("synthetic-facts.json")
        try ImageAllMigrationFacts.write(snapshot, to: input)
        return try ImageAllMigrationFacts.publish(from: input, into: f.root)
    }

    func testCleanupUsesFactRevisionInsteadOfInventorySequence() throws {
        let f = try fixture(inventoryWatermark: 77, factRevision: 0)
        defer { try? FileManager.default.removeItem(at: f.parent) }
        let facts = try publishFacts(f, watermark: 0)
        let before = try Data(contentsOf: facts)
        XCTAssertNotNil(try ImageAllMigrationFacts.inspectPublished(at: f.root,
            sourceDeviceID: f.record.header.sourceDeviceID, sourceEpoch: f.record.header.sourceEpoch,
            scopeRevision: 1, inventoryWatermark: 77, minimumFactWatermark: 0,
            mediaIDs: Set(f.record.items.map(\.mediaID))).sha256)
        XCTAssertEqual(try f.release().logicalBytesReleased, 8192)
        XCTAssertEqual(try Data(contentsOf: facts), before)
        XCTAssertTrue(try f.release().alreadyReleased)
    }

    func testCleanupStillRejectsStaleAndChangedFacts() throws {
        let f = try fixture(inventoryWatermark: 77, factRevision: 5)
        defer { try? FileManager.default.removeItem(at: f.parent) }
        _ = try publishFacts(f, watermark: 4)
        XCTAssertThrowsError(try f.release()) { error in
            XCTAssertEqual(error as? ImageAllMigrationFactsError, .publishedFactsChanged)
        }
        XCTAssertEqual(try f.paths.map { try Data(contentsOf: $0).count }.reduce(0, +), 8192)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("export-retirement.json").path))

        let g = try fixture(inventoryWatermark: 77, factRevision: 0)
        defer { try? FileManager.default.removeItem(at: g.parent) }
        let file = try publishFacts(g, watermark: 0)
        var changed = try Data(contentsOf: file)
        changed.append(32) // Valid JSON whitespace changes the bound digest.
        try changed.write(to: file)
        XCTAssertThrowsError(try g.release())
        XCTAssertEqual(try g.paths.map { try Data(contentsOf: $0).count }.reduce(0, +), 8192)
    }

    func testReleaseAndRepeatPreserveMetadataAndBlockExport() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let before = try Data(contentsOf: f.root.appendingPathComponent(ImageAllMigrationStreamRecord.filename))
        XCTAssertEqual(try f.release().logicalBytesReleased, 8192)
        XCTAssertTrue(try f.release().alreadyReleased)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(ImageAllMigrationStreamRecord.filename)), before)
        let checkpoint = try ImageAllMigrationExportCheckpoint(streamingRoot: f.root)
        defer { checkpoint.close() }
        XCTAssertThrowsError(try checkpoint.resourceLocation(key: "again", fileExtension: "bin"))
    }
    func testRejectsOldReceiptActiveExporterDamageAndReplacement() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        XCTAssertThrowsError(try f.release(nonce: UUID()))
        let active = try ImageAllMigrationExportCheckpoint(streamingRoot: f.root)
        XCTAssertThrowsError(try f.release()); active.close()
        let bytes = try Data(contentsOf: f.paths[0])
        try Data(repeating: 99, count: bytes.count).write(to: f.paths[0])
        XCTAssertThrowsError(try f.release())
        try bytes.write(to: f.paths[0])
        enum Stop: Error { case interrupted }
        XCTAssertThrowsError(try f.release(before: { _ in throw Stop.interrupted }))
        try FileManager.default.removeItem(at: f.paths[0]); try bytes.write(to: f.paths[0])
        XCTAssertThrowsError(try f.release())
        XCTAssertEqual(try Data(contentsOf: f.paths[1]).count, 4096)
    }
    func testInterruptedReleaseResumesWithNoDuplicateAndAbsentWindowIsAllowed() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        enum Stop: Error { case interrupted }
        XCTAssertThrowsError(try f.release(before: { if $0 == 1 { throw Stop.interrupted } }))
        XCTAssertEqual(try f.paths.map { try Data(contentsOf: $0).count }.reduce(0,+), 4096)
        XCTAssertEqual(try f.release().logicalBytesReleased, 4096)
        XCTAssertEqual(try f.release().logicalBytesReleased, 0)
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.parent) }
        try FileManager.default.removeItem(at: g.paths[0])
        XCTAssertEqual(try g.release().logicalBytesReleased, 4096)
    }
    func testUnknownFilesLinksAndPartialIntentFailClosed() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let unknown = f.root.appendingPathComponent("resources/unknown.bin")
        try Data([1]).write(to: unknown); XCTAssertThrowsError(try f.release())
        try FileManager.default.removeItem(at: unknown)
        try FileManager.default.linkItem(at: f.paths[0], to: f.parent.appendingPathComponent("alias"))
        XCTAssertThrowsError(try f.release())
        try FileManager.default.removeItem(at: f.parent.appendingPathComponent("alias"))
        try Data("partial".utf8).write(to: f.root.appendingPathComponent("export-retirement.json"))
        XCTAssertThrowsError(try f.release())
        XCTAssertEqual(try Data(contentsOf: f.paths[1]).count, 4096)
    }
    func testReplacedDirectoryAfterIntentIsRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        enum Stop: Error { case interrupted }
        XCTAssertThrowsError(try f.release(before: { _ in throw Stop.interrupted }))
        let moved = f.parent.appendingPathComponent("original-directory")
        try FileManager.default.moveItem(at: f.root, to: moved)
        try FileManager.default.copyItem(at: moved, to: f.root)
        XCTAssertThrowsError(try f.release())
        XCTAssertEqual(try Data(contentsOf: f.paths[0]).count, 4096)
    }

    func testProcessInterruptionBoundary() throws {
        guard let path = ProcessInfo.processInfo.environment["IMAGEALL_EXPORT_CRASH_ROOT"],
              let mode = ProcessInfo.processInfo.environment["IMAGEALL_EXPORT_CRASH_MODE"] else {
            throw XCTSkip("independent process harness only")
        }
        let evidence = URL(fileURLWithPath: path), file = evidence.appendingPathComponent("fixture.json")
        if mode == "crash" {
            let f = try fixture()
            try JSONEncoder().encode(f).write(to: file)
            _ = try f.release(before: { index in
                if index == 1 {
                    try Data("ready".utf8).write(to: evidence.appendingPathComponent("ready"))
                    raise(SIGSTOP)
                }
            })
            XCTFail("expected external process termination")
        } else {
            let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
            defer { try? FileManager.default.removeItem(at: f.parent) }
            // Model a newly obtained, task-bound completion receipt after restart.
            let nonce = UUID()
            let receipt = RemoteExportCleanupReceipt(query: f.query, nonce: nonce, hostID: f.record.hostID,
                deviceID: f.record.deviceID, sourceID: f.receipt.sourceID, itemCount: 1, resourceCount: 2, verifiedBytes: 8192)
            let result = try ImageAllMigrationExportCleanup.release(root: f.root, query: f.query,
                hostID: f.record.hostID, deviceID: f.record.deviceID, nonce: nonce, receipt: receipt)
            XCTAssertEqual(result.logicalBytesReleased, 4096)
            XCTAssertEqual(try ImageAllMigrationExportCleanup.release(root: f.root, query: f.query,
                hostID: f.record.hostID, deviceID: f.record.deviceID, nonce: nonce, receipt: receipt).logicalBytesReleased, 0)
            XCTAssertEqual(try ImageAllMigrationStreamRecord.read(in: f.root), f.record)
        }
    }

}
