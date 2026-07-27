import Foundation
import GRDB
import XCTest
@testable import ImageAll

final class LibrarySlimmingRecycleTests: XCTestCase {
    func testCountdownFormatterUsesDaysAndHours() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(
            RecycleCountdownFormatter.text(purgeAfterMs: now + LibrarySlimmingRecyclePolicy.dayMs * 3, nowMs: now),
            "3 天后永久删除"
        )
        XCTAssertEqual(
            RecycleCountdownFormatter.text(purgeAfterMs: now + 5 * 60 * 60 * 1_000, nowMs: now),
            "5 小时后永久删除"
        )
        XCTAssertEqual(
            RecycleCountdownFormatter.text(purgeAfterMs: now - 1, nowMs: now),
            "即将永久删除"
        )
    }

    func testSameVolumeMoveRestoreAndPurge() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }

        let bytes = Data("recycle-fixture".utf8)
        let seeded = try env.seedAsset(relativePath: "album/a.jpg", contents: bytes)
        let service = env.makeRecycleService()

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertTrue(outcome.skippedPhotosAssetIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))

        let entries = try service.listRecycledEntries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(entry.quarantineRelativePath!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        XCTAssertEqual(try Data(contentsOf: quarantineURL), bytes)

        let availability: String = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            ) ?? ""
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)

        try service.restore(entryID: entry.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), bytes)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)

        // Re-recycle then purge.
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let recycled = try XCTUnwrap(try service.listRecycledEntries().first)
        try service.purgeNow(entryID: recycled.id)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
        let assetStillThere = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(assetStillThere, 0)
    }

    func testRestoreConflictKeepsRecycleEntry() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("conflict".utf8)
        let seeded = try env.seedAsset(relativePath: "only.jpg", contents: bytes)
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        // Place a conflict file at the original path.
        try Data("other".utf8).write(to: seeded.fileURL)

        XCTAssertThrowsError(try service.restore(entryID: entry.id)) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .restoreConflict)
        }
        XCTAssertEqual(try service.listRecycledEntries().count, 1)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(entry.quarantineRelativePath!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testCrossVolumeCopyPathViaForceFlag() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data(repeating: 7, count: 4096)
        let seeded = try env.seedAsset(relativePath: "cross.jpg", contents: bytes)
        var service = env.makeRecycleService()
        service.quarantineIO.forceCrossVolumeCopy = true

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(entry.quarantineRelativePath!)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), bytes)
    }

    func testPhotosAssetIsSkipped() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset()
        let service = env.makeRecycleService()
        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [photosID])
        XCTAssertEqual(outcome.skippedPhotosAssetIDs, [photosID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
    }

    func testPurgeExpiredRemovesDueEntries() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(relativePath: "due.jpg", contents: Data("x".utf8))
        let clock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let service = env.makeRecycleService(clock: clock)
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        // Force expiry without violating purge_after_ms >= trashed_at_ms.
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET trashed_at_ms = ?, purge_after_ms = ?
                WHERE id = ?
                """,
                arguments: [clock.nowMs - 2, clock.nowMs - 1, entry.id.uuidString.lowercased()]
            )
        }
        let purged = try service.purgeExpired(nowMs: clock.nowMs)
        XCTAssertEqual(purged, 1)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }
}

private final class RecycleTestEnv {
    let root: URL
    let sourceRoot: URL
    let quarantineRoot: URL
    let database: CatalogDatabase
    let sourceID: UUID
    private var didInsertSource = false

    struct SeededAsset {
        let assetID: UUID
        let fileURL: URL
    }

    init(label: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllRecycle-\(label)-\(UUID().uuidString)", isDirectory: true)
        sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let support = root.appendingPathComponent("Application Support/ImageAll", isDirectory: true)
        quarantineRoot = QuarantinePathLayout.rootURL(applicationSupportDirectory: support)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        sourceID = UUID()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeRecycleService(
        clock: any JobClock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
    ) -> LibrarySlimmingRecycleService {
        LibrarySlimmingRecycleService(
            database: database,
            mutationAccess: DirectFolderMutationAccess(rootsBySourceID: [sourceID: sourceRoot]),
            quarantineRootURL: quarantineRoot,
            clock: clock
        )
    }

    @discardableResult
    func seedAsset(relativePath: String, contents: Data) throws -> SeededAsset {
        let assetID = UUID()
        let fileURL = sourceRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL)
        let fileName = RelativePathRules.fileName(from: relativePath) ?? fileURL.lastPathComponent
        try database.pool.write { db in
            if !didInsertSource {
                try db.execute(
                    sql: """
                    INSERT INTO source (
                        id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, 'folder', 'Fixture', ?, 0, 0, 'active', ?, ?)
                    """,
                    arguments: [
                        sourceID.uuidString.lowercased(),
                        Data("bookmark".utf8),
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                    ]
                )
                didInsertSource = true
            }
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'file', ?, NULL, 'current', 'public.jpeg', 1, 'available', ?, ?, ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    sourceID.uuidString.lowercased(),
                    relativePath,
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                    fileName,
                ]
            )
        }
        return SeededAsset(assetID: assetID, fileURL: fileURL)
    }

    func seedPhotosAsset() throws -> UUID {
        let photosSourceID = UUID()
        let assetID = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Photos', NULL, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    photosSourceID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'local-id', 'current', 'public.jpeg', 1, 'available', ?, ?, NULL)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    photosSourceID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        return assetID
    }
}
