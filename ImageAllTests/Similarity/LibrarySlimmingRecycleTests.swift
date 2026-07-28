import CryptoKit
import Darwin
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
        XCTAssertEqual(
            RecycleCountdownFormatter.recordCleanupText(
                cleanupAfterMs: now + LibrarySlimmingRecyclePolicy.dayMs * 3,
                nowMs: now
            ),
            "ImageAll 将在 3 天后清理此记录"
        )
    }

    func testMutationAccessRejectsReadOnlyBookmarkUntilUserGrantsWriteAccess() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(relativePath: "album/read-only.jpg", contents: Data("readonly".utf8))
        let bookmarks = RecordingMutationBookmarkPort(resolvedURL: env.sourceRoot)
        let access = FolderMutationAccessService(
            database: env.database,
            bookmarkPort: bookmarks
        )

        XCTAssertThrowsError(
            try access.withWritableSourceRoot(sourceID: env.sourceID) { _ in () }
        ) { error in
            XCTAssertEqual(
                error as? LibrarySlimmingRecycleError,
                .mutationAuthorizationRequired
            )
        }
        XCTAssertEqual(bookmarks.resolveCount, 0)
    }

    func testMutationAccessRejectsWritableBookmarkForDisabledSource() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(
            relativePath: "album/disabled.jpg",
            contents: Data("disabled".utf8)
        )
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source_mutation_authorization (
                    source_id, bookmark, updated_at_ms
                ) VALUES (?, ?, ?)
                """,
                arguments: [
                    env.sourceID.uuidString.lowercased(),
                    Data("writable".utf8),
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
            try db.execute(
                sql: """
                UPDATE source
                SET state = 'disabled'
                WHERE id = ?
                """,
                arguments: [env.sourceID.uuidString.lowercased()]
            )
        }
        let bookmarks = RecordingMutationBookmarkPort(resolvedURL: env.sourceRoot)
        let access = FolderMutationAccessService(
            database: env.database,
            bookmarkPort: bookmarks
        )

        XCTAssertThrowsError(
            try access.withWritableSourceRoot(sourceID: env.sourceID) { _ in () }
        ) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .invalidState)
        }
        XCTAssertEqual(bookmarks.resolveCount, 0)
    }

    func testMutationAccessTreatsUnresolvableWriteBookmarkAsAuthorizationRequired() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(
            relativePath: "album/stale.jpg",
            contents: Data("stale".utf8)
        )
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source_mutation_authorization (
                    source_id, bookmark, updated_at_ms
                ) VALUES (?, ?, ?)
                """,
                arguments: [
                    env.sourceID.uuidString.lowercased(),
                    Data("stale-writable".utf8),
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        let access = FolderMutationAccessService(
            database: env.database,
            bookmarkPort: FailingMutationBookmarkPort()
        )

        XCTAssertThrowsError(
            try access.withWritableSourceRoot(sourceID: env.sourceID) { _ in () }
        ) { error in
            XCTAssertEqual(
                error as? LibrarySlimmingRecycleError,
                .mutationAuthorizationRequired
            )
        }
    }

    @MainActor
    func testMutationAuthorizationPersistsWritableBookmarkForSameSourceRoot() async throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(relativePath: "album/authorize.jpg", contents: Data("authorize".utf8))
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [env.sourceRoot]
        let writableBookmark = Data("writable-bookmark".utf8)
        let bookmarks = RecordingMutationBookmarkPort(
            resolvedURL: env.sourceRoot,
            writableBookmark: writableBookmark
        )
        let authorization = FolderMutationAuthorizationCoordinator(
            database: env.database,
            picker: picker,
            bookmarkPort: bookmarks,
            rootValidator: FolderRootValidator(),
            relationshipChecker: FoundationFolderRootRelationshipChecker(),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let sourceID = env.sourceID
        let database = env.database

        let outcome = try await authorization.authorizeMutation(sourceID: sourceID)

        XCTAssertEqual(outcome, .authorized(sourceID: sourceID))
        let stored: Data? = try await database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT bookmark
                FROM source_mutation_authorization
                WHERE source_id = ?
                """,
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(stored, writableBookmark)
        XCTAssertEqual(bookmarks.writableCreationCount, 1)
    }

    @MainActor
    func testMutationAuthorizationRejectsDifferentFolderWithoutPersistingBookmark() async throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(
            relativePath: "album/reject-mismatch.jpg",
            contents: Data("mismatch".utf8)
        )
        let otherRoot = env.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [otherRoot]
        let bookmarks = RecordingMutationBookmarkPort(resolvedURL: env.sourceRoot)
        let authorization = FolderMutationAuthorizationCoordinator(
            database: env.database,
            picker: picker,
            bookmarkPort: bookmarks,
            rootValidator: FolderRootValidator(),
            relationshipChecker: FoundationFolderRootRelationshipChecker(),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let sourceID = env.sourceID
        let database = env.database

        do {
            _ = try await authorization.authorizeMutation(sourceID: sourceID)
            XCTFail("different folder must not receive mutation authorization")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .identityMismatch)
        }
        let stored: Data? = try await database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT bookmark
                FROM source_mutation_authorization
                WHERE source_id = ?
                """,
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertNil(stored)
        XCTAssertEqual(bookmarks.writableCreationCount, 0)
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

    func testPurgeFailureKeepsAssetAndRecycleEntryTracked() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "purge/failure.jpg",
            contents: Data("keep-tracked".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET quarantine_relative_path = '../unsafe' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }

        XCTAssertThrowsError(try service.purgeNow(entryID: entry.id)) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .ioFailure)
        }

        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        let assetCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(assetCount, 1)
    }

    func testSuccessfulPurgeRetainsOnlyScrubbedAuditTombstone() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "purge/tombstone.jpg",
            contents: Data("tombstone".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        try service.purgeNow(entryID: entry.id)

        let tombstone = try env.database.pool.read { db -> Row? in
            try Row.fetchOne(
                db,
                sql: """
                SELECT asset_id, state, quarantine_relative_path, original_relative_path
                FROM recycle_entry WHERE id = ?
                """,
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        let row = try XCTUnwrap(tombstone)
        XCTAssertNil(row["asset_id"] as String?)
        XCTAssertEqual(row["state"] as String, RecycleEntryState.purged.rawValue)
        XCTAssertNil(row["quarantine_relative_path"] as String?)
        XCTAssertNil(row["original_relative_path"] as String?)
    }

    func testPurgeRemovesTagDecisionsBeforeDeletingCatalogAsset() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "purge/tagged.jpg",
            contents: Data("tagged".utf8)
        )
        let tagID = UUID()
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (
                    id, name, normalized_name, state, created_at_ms, updated_at_ms, group_id
                ) VALUES (?, 'Tagged', 'tagged', 'active', ?, ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                    TagGroupSeed.other.id.uuidString.lowercased(),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [
                    seeded.assetID.uuidString.lowercased(),
                    tagID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        try service.purgeNow(entryID: entry.id)

        let decisionCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset_tag_decision WHERE asset_id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(decisionCount, 0)
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

    func testCrossVolumeRoundTripPreservesFileMetadata() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "metadata/preserved.jpg",
            contents: Data("metadata".utf8)
        )
        XCTAssertEqual(chmod(seeded.fileURL.path, mode_t(0o640)), 0)
        let attributeName = "com.imageall.recycle-test"
        let attributeValue = Data("finder-metadata".utf8)
        try setExtendedAttribute(
            attributeValue,
            name: attributeName,
            at: seeded.fileURL
        )
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: seeded.fileURL.path
        )
        let originalModifiedAt = try XCTUnwrap(
            originalAttributes[.modificationDate] as? Date
        )

        var service = env.makeRecycleService()
        service.quarantineIO.forceCrossVolumeCopy = true
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            try XCTUnwrap(entry.quarantineRelativePath)
        )

        let quarantineAttributes = try FileManager.default.attributesOfItem(
            atPath: quarantineURL.path
        )
        XCTAssertEqual(
            (quarantineAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o640
        )
        XCTAssertEqual(
            try extendedAttribute(name: attributeName, at: quarantineURL),
            attributeValue
        )
        XCTAssertEqual(
            try XCTUnwrap(quarantineAttributes[.modificationDate] as? Date)
                .timeIntervalSince1970,
            originalModifiedAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        try service.restore(entryID: entry.id)

        let restoredAttributes = try FileManager.default.attributesOfItem(
            atPath: seeded.fileURL.path
        )
        XCTAssertEqual(
            (restoredAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o640
        )
        XCTAssertEqual(
            try extendedAttribute(name: attributeName, at: seeded.fileURL),
            attributeValue
        )
        XCTAssertEqual(
            try XCTUnwrap(restoredAttributes[.modificationDate] as? Date)
                .timeIntervalSince1970,
            originalModifiedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testCrossVolumeCopyFailsClosedWhenSourceChangesDuringCopy() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let original = Data("copy-start".utf8)
        let replacement = Data("changed-during-copy".utf8)
        let seeded = try env.seedAsset(
            relativePath: "concurrent/changed.jpg",
            contents: original
        )
        var service = env.makeRecycleService()
        service.quarantineIO.forceCrossVolumeCopy = true
        service.quarantineIO.beforeSourceFinalVerification = {
            try? replacement.write(to: seeded.fileURL)
        }

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), replacement)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testRecycleFailsClosedWhenFileChangedAfterCatalogScan() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let original = Data("catalog-version".utf8)
        let replacement = Data("replacement-version".utf8)
        let seeded = try env.seedAsset(
            relativePath: "identity/changed.jpg",
            contents: original
        )
        try replacement.write(to: seeded.fileURL)
        let service = env.makeRecycleService()

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), replacement)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testRecycleFailsClosedWhenFileIdentityChangesEvenIfBytesMatch() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("same-bytes-new-file".utf8)
        let seeded = try env.seedAsset(
            relativePath: "identity/replaced.jpg",
            contents: bytes
        )
        let replacementURL = seeded.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("replacement.tmp")
        try bytes.write(to: replacementURL)
        try FileManager.default.removeItem(at: seeded.fileURL)
        try FileManager.default.moveItem(at: replacementURL, to: seeded.fileURL)
        let service = env.makeRecycleService()

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), bytes)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testFailedMutationAuthorizationCanBeRetriedAfterGrant() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "retry/authorization.jpg",
            contents: Data("retry".utf8)
        )
        let denied = env.makeRecycleService(
            mutationAccess: DirectFolderMutationAccess(rootsBySourceID: [:])
        )
        let first = try denied.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        XCTAssertEqual(first.failedAssetIDs, [seeded.assetID])
        XCTAssertEqual(first.authorizationRequiredSourceIDs, [env.sourceID])

        let granted = env.makeRecycleService()
        let second = try granted.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(second.recycledEntryIDs.count, 1)
        XCTAssertTrue(second.failedAssetIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try granted.listRecycledEntries().count, 1)
    }

    func testRecoveryFinalizesMoveInterruptedAfterFilesystemSuccess() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "recovery/pending.jpg",
            contents: Data("pending-recovery".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testRecoveryTreatsMissingOriginalParentDirectoryAsMissingObject() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "recovery/removed-parent/pending.jpg",
            contents: Data("missing-parent".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try FileManager.default.removeItem(at: seeded.fileURL.deletingLastPathComponent())
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
    }

    func testRecoveryRetainsQuarantineWhenOriginalPathWasRecreated() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let originalBytes = Data("original-before-interruption".utf8)
        let replacementBytes = Data("replacement-after-interruption".utf8)
        let seeded = try env.seedAsset(
            relativePath: "recovery/recreated.jpg",
            contents: originalBytes
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            try XCTUnwrap(entry.quarantineRelativePath)
        )
        try replacementBytes.write(to: seeded.fileURL)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), replacementBytes)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), originalBytes)
        let row = try env.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT state, error_code FROM recycle_entry WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(row?["state"] as String?, RecycleEntryState.failed.rawValue)
        XCTAssertEqual(row?["error_code"] as String?, "interruptedConflict")
    }

    func testRecoveryFinalizesRestoreInterruptedAfterFilesystemSuccess() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("restore-recovery".utf8)
        let seeded = try env.seedAsset(
            relativePath: "recovery/restoring.jpg",
            contents: bytes
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'restoring' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        try FolderQuarantineIO().moveOutOfQuarantine(
            quarantineRootURL: env.quarantineRoot,
            quarantineRelativePath: try XCTUnwrap(entry.quarantineRelativePath),
            sourceRootURL: env.sourceRoot,
            originalRelativePath: try XCTUnwrap(entry.originalRelativePath)
        )

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), bytes)
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.available.rawValue)
    }

    func testRecoveryFinalizesPurgeInterruptedAfterFilesystemSuccess() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "recovery/purging.jpg",
            contents: Data("purge-recovery".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'purging' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        try FolderQuarantineIO().deleteQuarantineObject(
            quarantineRootURL: env.quarantineRoot,
            quarantineRelativePath: try XCTUnwrap(entry.quarantineRelativePath)
        )

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        let tombstone = try env.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT asset_id, state, quarantine_relative_path, original_relative_path
                FROM recycle_entry WHERE id = ?
                """,
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        let row = try XCTUnwrap(tombstone)
        XCTAssertNil(row["asset_id"] as String?)
        XCTAssertEqual(row["state"] as String, RecycleEntryState.purged.rawValue)
        XCTAssertNil(row["quarantine_relative_path"] as String?)
        XCTAssertNil(row["original_relative_path"] as String?)
        let assetCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(assetCount, 0)
    }

    func testPhotosAssetIsSkipped() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset()
        let service = env.makeRecycleService()
        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertEqual(outcome.authorizationDeniedPhotosAssetIDs, [photosID])
    }

    func testPhotosSoftDeleteWritesRecycleEntryWithoutQuarantine() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "local-photos-1")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["local-photos-1"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertEqual(fake.movedToRecentlyDeleted, ["local-photos-1"])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        XCTAssertEqual(entry.sourceKind, .photos)
        XCTAssertEqual(entry.photosLocalIdentifier, "local-photos-1")
        XCTAssertNil(entry.quarantineRelativePath)
        let quarantineChildren = try FileManager.default.contentsOfDirectory(
            at: env.quarantineRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(quarantineChildren.isEmpty)
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, "recycled")
    }

    func testPhotosAuthorizationDeniedDoesNotMutate() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "denied-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.authorization = .denied
        let service = env.makeRecycleService(photosMutation: fake)
        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertEqual(outcome.authorizationDeniedPhotosAssetIDs, [photosID])
        XCTAssertTrue(fake.movedToRecentlyDeleted.isEmpty)
    }

    func testPhotosPendingRecoveryFinalizesWhenSystemAssetIsNoLongerAvailable() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "pending-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["pending-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        XCTAssertEqual(fake.movedToRecentlyDeleted, ["pending-id"])
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testPhotosReconcileMarksRestoredWhenAvailableAgain() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "restore-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["restore-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertEqual(fake.presenceByID["restore-id"], .recentlyDeleted)
        fake.presenceByID["restore-id"] = .available
        let advancedClock = FixedJobClock(
            nowMs: FolderReconcileTestSupport.baseTimeMs
                + LibrarySlimmingRecyclePolicy.photosDeleteConvergenceGraceMs
                + 1
        )
        let advancedService = env.makeRecycleService(
            clock: advancedClock,
            photosMutation: fake
        )
        let converged = try advancedService.reconcilePhotosRecycleEntries()
        XCTAssertEqual(converged, 1)
        XCTAssertTrue(try advancedService.listRecycledEntries().isEmpty)
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, "available")
    }

    func testPhotosReconcileDoesNotRestoreDuringDeleteConvergenceGrace() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "converging-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["converging-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        fake.presenceByID["converging-id"] = .available

        let converged = try service.reconcilePhotosRecycleEntries()

        XCTAssertEqual(converged, 0)
        XCTAssertEqual(try service.listRecycledEntries().map(\.assetID), [photosID])
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testSlimmingHiddenAssetIDsIncludesRecycledAssets() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(relativePath: "hidden.jpg", contents: Data("x".utf8))
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        let hidden = try service.slimmingHiddenAssetIDs(from: [seeded.assetID, UUID()])

        XCTAssertEqual(hidden, Set([seeded.assetID]))
    }

    func testPhotosRestoreWhileRecentlyDeletedRequiresPhotosApp() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "still-deleted")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["still-deleted"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        XCTAssertThrowsError(try service.restore(entryID: entry.id)) { error in
            XCTAssertEqual(
                error as? LibrarySlimmingRecycleError,
                .photosRestoreRequiresPhotosApp
            )
        }
        XCTAssertEqual(try service.listRecycledEntries().count, 1)
    }

    func testPhotosPurgeIsManagedBySystemPhotos() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "purge-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["purge-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        XCTAssertThrowsError(try service.purgeNow(entryID: entry.id)) { error in
            XCTAssertEqual(
                error as? LibrarySlimmingRecycleError,
                .photosManagedBySystem
            )
        }
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        let assetCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(assetCount, 1)
    }

    func testPhotosInterruptedPurgeReturnsToRecycleBinWithoutSystemMutation() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "interrupted-purge-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["interrupted-purge-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'purging' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        XCTAssertEqual(fake.movedToRecentlyDeleted, ["interrupted-purge-id"])
    }

    func testPhotosReconcilePurgesMissingAfterExpiry() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let clock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let photosID = try env.seedPhotosAsset(localIdentifier: "missing-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["missing-id"] = .available
        let service = env.makeRecycleService(clock: clock, photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
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
        fake.presenceByID["missing-id"] = .missing
        let converged = try service.reconcilePhotosRecycleEntries()
        XCTAssertEqual(converged, 1)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
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

    func testPurgeJobIsScheduledForEarliestRecycleExpiry() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let clock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let queue = GRDBJobQueue(
            database: env.database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000)
        )
        let seeded = try env.seedAsset(
            relativePath: "schedule/expiry.jpg",
            contents: Data("scheduled".utf8)
        )
        let service = env.makeRecycleService(clock: clock, jobQueue: queue)
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        try service.enqueuePurgeExpired()

        let scheduledAt = try env.database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT not_before_ms FROM job WHERE kind = ?",
                arguments: [LibrarySlimmingPurgeJobFactory.kind]
            )
        }
        XCTAssertEqual(scheduledAt, entry.purgeAfterMs)
    }
}

private final class RecordingMutationBookmarkPort: SecurityScopedBookmarkPort, @unchecked Sendable {
    let resolvedURL: URL
    let writableBookmark: Data
    private(set) var resolveCount = 0
    private(set) var writableCreationCount = 0

    init(
        resolvedURL: URL,
        writableBookmark: Data = Data("writable".utf8)
    ) {
        self.resolvedURL = resolvedURL
        self.writableBookmark = writableBookmark
    }

    func createReadOnlyBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func createWritableBookmark(for url: URL) throws -> Data {
        writableCreationCount += 1
        return writableBookmark
    }

    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
        resolveCount += 1
        return BookmarkResolveResult(url: resolvedURL, isStale: false)
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

private struct FailingMutationBookmarkPort: SecurityScopedBookmarkPort {
    func createReadOnlyBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
        throw FolderAuthorizationError.authorizationUnavailable
    }

    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
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
        clock: any JobClock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs),
        mutationAccess: (any FolderMutationAccessing)? = nil,
        jobQueue: (any JobQueue)? = nil,
        photosMutation: (any PhotosLibraryMutationPort)? = nil
    ) -> LibrarySlimmingRecycleService {
        LibrarySlimmingRecycleService(
            database: database,
            mutationAccess: mutationAccess
                ?? DirectFolderMutationAccess(rootsBySourceID: [sourceID: sourceRoot]),
            quarantineRootURL: quarantineRoot,
            clock: clock,
            jobQueue: jobQueue,
            photosMutation: photosMutation
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
            let resources = FoundationFolderFileResourceReader()
            guard let sizeBytes = resources.fileSizeBytes(for: fileURL),
                  let modifiedAtNs = resources.modifiedAtNs(for: fileURL)
            else {
                throw LibrarySlimmingRecycleError.ioFailure
            }
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (
                    asset_id, size_bytes, modified_at_ns, resource_id, sha256
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    sizeBytes,
                    modifiedAtNs,
                    resources.resourceIdentifier(for: fileURL),
                    Data(SHA256.hash(data: contents)),
                ]
            )
        }
        return SeededAsset(assetID: assetID, fileURL: fileURL)
    }

    func seedPhotosAsset(localIdentifier: String = "local-id") throws -> UUID {
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
                ) VALUES (?, ?, 'photos', NULL, ?, 'current', 'public.jpeg', 1, 'available', ?, ?, NULL)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    photosSourceID.uuidString.lowercased(),
                    localIdentifier,
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        return assetID
    }
}

private final class FakePhotosLibraryMutationPort: PhotosLibraryMutationPort, @unchecked Sendable {
    var authorization: PhotosAuthorizationState = .authorized
    var presenceByID: [String: PhotosAssetPresence] = [:]
    private(set) var movedToRecentlyDeleted: [String] = []

    func authorizationState() -> PhotosAuthorizationState {
        authorization
    }

    func requestAuthorization() async -> PhotosAuthorizationState {
        authorization
    }

    func moveToRecentlyDeleted(localIdentifiers: [String]) throws {
        guard authorization == .authorized else {
            throw PhotosLibraryMutationError.authorizationDenied
        }
        for id in localIdentifiers {
            guard presenceByID[id] == .available else {
                throw PhotosLibraryMutationError.assetNotFound
            }
            movedToRecentlyDeleted.append(id)
            presenceByID[id] = .recentlyDeleted
        }
    }

    func presence(localIdentifier: String) throws -> PhotosAssetPresence {
        guard authorization == .authorized else {
            throw PhotosLibraryMutationError.authorizationDenied
        }
        return presenceByID[localIdentifier] ?? .missing
    }

}

private func setExtendedAttribute(_ data: Data, name: String, at url: URL) throws {
    let result = url.path.withCString { path in
        name.withCString { attributeName in
            data.withUnsafeBytes { bytes in
                setxattr(
                    path,
                    attributeName,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func extendedAttribute(name: String, at url: URL) throws -> Data {
    let size = url.path.withCString { path in
        name.withCString { attributeName in
            getxattr(path, attributeName, nil, 0, 0, 0)
        }
    }
    guard size >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var data = Data(count: size)
    let readCount = data.withUnsafeMutableBytes { bytes in
        url.path.withCString { path in
            name.withCString { attributeName in
                getxattr(
                    path,
                    attributeName,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
    }
    guard readCount == size else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return data
}
