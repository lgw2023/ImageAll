import CryptoKit
import Foundation
import GRDB
import ImageAllRemoteProtocol

enum PhoneArchiveImportError: LocalizedError, Equatable {
    case incompleteArchive
    case migrationIdentityConflict
    case targetChanged
    case publishedCopyChanged
    case missingImportJournal
    case targetOverlapsMacLibrary
    case targetIsolationIndeterminate
    case factScopeMismatch
    case staleFactSnapshot
    case factSnapshotConflict
    case catalogDiverged
    case recoveryDestinationNotEmpty
    case insufficientRecoverySpace

    var errorDescription: String? {
        switch self {
        case .incompleteArchive: "归档缺少必需资源，不能入库。"
        case .migrationIdentityConflict: "迁移身份或已有手机资产身份冲突，需要先对账。"
        case .targetChanged: "此迁移 ID 已绑定另一目标位置。"
        case .publishedCopyChanged: "Mac 已发布的归档副本与入库记录不一致。"
        case .missingImportJournal: "归档导入记录丢失，不能返回完成回执。"
        case .targetOverlapsMacLibrary: "保存目录与 Mac 已授权的图库来源重叠，请选择独立目录。"
        case .targetIsolationIndeterminate: "无法确认保存目录与 Mac 图库来源隔离，请检查来源磁盘授权。"
        case .factScopeMismatch: "整理信息快照与所选归档批次的来源或资产集合不一致。"
        case .staleFactSnapshot: "整理信息快照早于已导入版本，请从手机重新导出。"
        case .factSnapshotConflict: "同一整理信息版本的内容不一致，需要先对账。"
        case .catalogDiverged: "Mac 归档与入库账本不一致，不能通过完整性核查。"
        case .recoveryDestinationNotEmpty: "恢复验收需要单独的空目录，以免覆盖现有文件或 catalog。"
        case .insufficientRecoverySpace: "恢复目录可用空间不足以容纳独立归档副本，请选择其他磁盘。"
        }
    }
}

struct PhoneArchiveImportReceipt: Sendable, Equatable {
    let migrationID: UUID
    let archiveURL: URL
    let manifestSHA256: String
    let itemCount: Int
    let resourceCount: Int
    let verifiedBytes: Int64
    let replayed: Bool
}

struct PhoneArchiveFactReceipt: Sendable, Equatable {
    let migrationID: UUID
    let itemCount: Int
    let snapshotSequence: Int64
    let factWatermark: Int64
    let replayed: Bool
}

struct PhoneArchiveIntegrityReport: Sendable, Equatable {
    let migrationID: UUID
    let manifestSHA256: String
    let itemCount: Int
    let resourceCount: Int
    let verifiedBytes: Int64
    let factSnapshotSequence: Int64
    let factWatermark: Int64
    let phoneSyncCheckpoint: ImageAllMigrationSyncCheckpoint?
    let factSnapshot: ImageAllMigrationFactSnapshot?
}

struct PhoneArchiveRecoveryReport: Sendable, Equatable {
    let integrity: PhoneArchiveIntegrityReport
    let restoredArchiveURL: URL
    let recoveredCatalogURL: URL
}

struct PhoneArchiveImportedBatch: Identifiable, Sendable {
    let id: UUID
    let archivePath: String
    let targetParentPath: String
    let targetBookmark: Data?
    let itemCount: Int
    let resourceCount: Int
    let verifiedBytes: Int64
    let importedAtMs: Int64
    let factSnapshotSequence: Int64
    let appleAlbumCoverage: ImageAllMigrationAppleAlbumCoverage?
}

struct PhoneArchiveImportedItem: Identifiable, Sendable {
    let id: UUID
    let sourceLocalIdentifier: String
    let mediaKind: String
    let createdAtMs: Int64?
    let resourceCount: Int
    let tagCount: Int
    let collectionCount: Int
    let appleAlbumCount: Int
}

/// Imports a verified phone package into dedicated catalog bindings. The
/// existing one-source Asset row remains untouched; archive resources are
/// owned by this migration until a deliberate MediaItem/Replica projection
/// exposes them in the unified gallery.
struct VerifiedPhoneArchiveImporter: Sendable {
    let database: CatalogDatabase

    /// Reconstructs a separate catalog and archive copy from the published
    /// package, then audits both ledgers against the same verified bytes and
    /// latest fact checkpoint. The caller chooses and retains an empty target.
    func verifyIndependentRecovery(
        migrationID: UUID, archiveRoot: URL, into emptyDirectory: URL
    ) throws -> PhoneArchiveRecoveryReport {
        let original = try auditImportedArchive(
            migrationID: migrationID, archiveRoot: archiveRoot
        )
        let source = archiveRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let destination = emptyDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination != source,
              !destination.hasPrefix(source + "/"),
              !source.hasPrefix(destination + "/") else {
            throw ImageAllMigrationArchiveError.destinationOverlap
        }
        try validateTargetDirectory(emptyDirectory)
        guard try FileManager.default.contentsOfDirectory(
            atPath: emptyDirectory.path
        ).isEmpty else {
            throw PhoneArchiveImportError.recoveryDestinationNotEmpty
        }
        let reserve = max(Int64(64 * 1_024 * 1_024), original.verifiedBytes / 10)
        let (requiredBytes, overflow) = original.verifiedBytes.addingReportingOverflow(reserve)
        guard !overflow else { throw PhoneArchiveImportError.insufficientRecoverySpace }
        let capacity = try emptyDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < requiredBytes {
            throw PhoneArchiveImportError.insufficientRecoverySpace
        }
        let catalogURL = emptyDirectory.appendingPathComponent("recovered-catalog.sqlite")
        let recovered = VerifiedPhoneArchiveImporter(
            database: try CatalogDatabase.open(at: catalogURL)
        )
        let receipt = try recovered.importArchive(
            from: archiveRoot, to: emptyDirectory
        )
        let integrity = try recovered.auditImportedArchive(
            migrationID: migrationID, archiveRoot: receipt.archiveURL
        )
        guard integrity == original else {
            throw PhoneArchiveImportError.catalogDiverged
        }
        return PhoneArchiveRecoveryReport(
            integrity: integrity, restoredArchiveURL: receipt.archiveURL,
            recoveredCatalogURL: catalogURL
        )
    }

    /// Re-verifies the independently published media package and compares each
    /// portable record with the dedicated Mac import ledger. This is a local
    /// integrity check, not a source-sync or migration-complete receipt.
    func auditImportedArchive(
        migrationID: UUID, archiveRoot: URL
    ) throws -> PhoneArchiveIntegrityReport {
        let (header, verification) = try ImageAllMigrationArchive.readVerifiedHeader(
            at: archiveRoot
        )
        guard header.migrationID == migrationID, verification.isComplete else {
            throw PhoneArchiveImportError.incompleteArchive
        }
        let latest = try ImageAllMigrationFacts.latestPublishedURL(in: archiveRoot)
            .map { try ImageAllMigrationFacts.read(at: $0) }
        let facts = Dictionary(uniqueKeysWithValues: (latest?.items ?? []).map {
            ($0.mediaID, $0)
        })
        let factDigest: String? = try latest.map { snapshot in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(snapshot))
                .map { String(format: "%02x", $0) }.joined()
        }
        let migrationKey = migrationID.uuidString.lowercased()
        let deviceKey = header.sourceDeviceID.uuidString.lowercased()
        let epochKey = header.sourceEpoch.uuidString.lowercased()
        let folderEncoder = JSONEncoder()
        folderEncoder.outputFormatting = [.sortedKeys]
        return try database.pool.read { db in
            guard let batch = try Row.fetchOne(
                db, sql: "SELECT * FROM migration_import WHERE id = ? AND state = 'catalogCommitted'",
                arguments: [migrationKey]
            ) else { throw PhoneArchiveImportError.missingImportJournal }
            let savedPath: String = batch["archive_path"]
            let savedDevice: String = batch["source_device_id"]
            let savedEpoch: String = batch["source_epoch"]
            let savedScope: Int64 = batch["scope_revision"]
            let savedInventory: Int64 = batch["inventory_watermark"]
            let savedManifest: String = batch["manifest_sha256"]
            let savedItems: Int = batch["item_count"]
            let savedResources: Int = batch["resource_count"]
            let savedBytes: Int64 = batch["verified_bytes"]
            let savedFactSequence: Int64 = batch["fact_snapshot_sequence"]
            let savedFactWatermark: Int64 = batch["fact_watermark"]
            let savedFactDigest: String? = batch["fact_snapshot_sha256"]
            let savedAlbumCoverage: String? = batch["apple_album_coverage"]
            guard URL(fileURLWithPath: savedPath).standardizedFileURL == archiveRoot.standardizedFileURL,
                  savedDevice == deviceKey, savedEpoch == epochKey,
                  savedScope == header.scopeRevision,
                  savedInventory == header.inventoryWatermark,
                  savedManifest == verification.manifestSHA256,
                  savedItems == verification.itemCount,
                  savedResources == verification.resourceCount,
                  savedBytes == verification.verifiedBytes,
                  savedFactSequence == (latest?.snapshotSequence ?? 0),
                  savedFactWatermark == (latest?.factWatermark ?? 0),
                  savedFactDigest == factDigest,
                  savedAlbumCoverage == header.appleAlbumCoverage?.rawValue else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            var seen = Set<UUID>()
            _ = try ImageAllMigrationArchive.visitVerifiedRecords(
                at: archiveRoot,
                onHeader: { record in
                    guard record == header else {
                        throw PhoneArchiveImportError.catalogDiverged
                    }
                },
                onItem: { item in
                    guard seen.insert(item.mediaID).inserted else {
                        throw PhoneArchiveImportError.catalogDiverged
                    }
                    let mediaKey = item.mediaID.uuidString.lowercased()
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT * FROM migration_import_item
                        WHERE migration_id = ? AND media_id = ?
                        """, arguments: [migrationKey, mediaKey]) else {
                        throw PhoneArchiveImportError.catalogDiverged
                    }
                    let rowDevice: String = row["source_device_id"]
                    let rowEpoch: String = row["source_epoch"]
                    let rowIdentifier: String = row["source_local_identifier"]
                    let rowKind: String = row["media_kind"]
                    let rowCreated: Int64? = row["created_at_ms"]
                    let rowFavorite: Int = row["observed_favorite"]
                    let rowTarget: Int? = row["favorite_target"]
                    let rowRevision: Int64 = row["fact_revision"]
                    let fact = facts[item.mediaID]
                    let expectedTarget: Bool? = if let fact {
                        fact.favoriteTarget
                    } else {
                        item.favoriteTarget
                    }
                    guard rowDevice == deviceKey, rowEpoch == epochKey,
                          rowIdentifier == item.sourceLocalIdentifier,
                          rowKind == item.mediaKind.rawValue,
                          rowCreated == item.createdAtMs,
                          rowFavorite == ((fact?.observedFavorite ?? item.observedFavorite) ? 1 : 0),
                          rowTarget == expectedTarget.map({ $0 ? 1 : 0 }),
                          rowRevision == (latest?.factWatermark ?? item.factRevision) else {
                        throw PhoneArchiveImportError.catalogDiverged
                    }
                    try auditResources(
                        item.resources, db: db, device: deviceKey,
                        epoch: epochKey, media: mediaKey
                    )
                    try auditTags(
                        fact?.tagDecisions ?? item.tagDecisions,
                        db: db, device: deviceKey, epoch: epochKey, media: mediaKey
                    )
                    try auditCollections(
                        fact?.collections ?? item.collections,
                        db: db, device: deviceKey, epoch: epochKey, media: mediaKey
                    )
                    try auditAppleAlbums(
                        item.appleAlbums ?? [], db: db,
                        migration: migrationKey, media: mediaKey,
                        encoder: folderEncoder
                    )
                }
            )
            let catalogItems = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM migration_import_item WHERE migration_id = ?",
                arguments: [migrationKey]
            ) ?? 0
            guard seen.count == verification.itemCount,
                  catalogItems == verification.itemCount else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            return PhoneArchiveIntegrityReport(
                migrationID: migrationID, manifestSHA256: savedManifest,
                itemCount: savedItems, resourceCount: savedResources,
                verifiedBytes: savedBytes,
                factSnapshotSequence: savedFactSequence,
                factWatermark: savedFactWatermark,
                phoneSyncCheckpoint: latest?.syncCheckpoint,
                factSnapshot: latest
            )
        }
    }

    private func auditResources(
        _ expected: [ImageAllMigrationResource], db: Database,
        device: String, epoch: String, media: String
    ) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM migration_import_resource
            WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
            """, arguments: [device, epoch, media])
        guard rows.count == expected.count else {
            throw PhoneArchiveImportError.catalogDiverged
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { row -> (String, Row) in
            (row["id"], row)
        })
        for resource in expected {
            guard let row = byID[resource.id.uuidString.lowercased()],
                  resource.status == .present,
                  let path = resource.relativePath,
                  let count = resource.byteCount,
                  let hash = resource.sha256 else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            let role: String = row["role"]
            let version: Int64 = row["version"]
            let uti: String = row["uti"]
            let storedPath: String = row["relative_path"]
            let storedCount: Int64 = row["byte_count"]
            let storedHash: String = row["sha256"]
            guard role == resource.role, version == resource.version,
                  uti == resource.uniformTypeIdentifier,
                  storedPath == path, storedCount == count,
                  storedHash == hash else {
                throw PhoneArchiveImportError.catalogDiverged
            }
        }
    }

    private func auditTags(
        _ expected: [ImageAllMigrationTagDecision], db: Database,
        device: String, epoch: String, media: String
    ) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM migration_import_tag_decision
            WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
            """, arguments: [device, epoch, media])
        guard rows.count == expected.count else {
            throw PhoneArchiveImportError.catalogDiverged
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { row -> (String, Row) in
            (row["tag_id"], row)
        })
        for tag in expected {
            guard let row = byID[tag.tagID.uuidString.lowercased()] else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            let name: String = row["tag_name"]
            let decision: String = row["decision"]
            guard name == tag.tagName, decision == tag.decision.rawValue else {
                throw PhoneArchiveImportError.catalogDiverged
            }
        }
    }

    private func auditCollections(
        _ expected: [ImageAllMigrationCollectionMembership], db: Database,
        device: String, epoch: String, media: String
    ) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM migration_import_collection
            WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
            """, arguments: [device, epoch, media])
        guard rows.count == expected.count else {
            throw PhoneArchiveImportError.catalogDiverged
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { row -> (String, Row) in
            (row["collection_id"], row)
        })
        for collection in expected {
            guard let row = byID[collection.collectionID.uuidString.lowercased()] else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            let name: String = row["collection_name"]
            let included: Int = row["included"]
            guard name == collection.collectionName,
                  included == (collection.included ? 1 : 0) else {
                throw PhoneArchiveImportError.catalogDiverged
            }
        }
    }

    private func auditAppleAlbums(
        _ expected: [ImageAllMigrationAppleAlbumMembership], db: Database,
        migration: String, media: String, encoder: JSONEncoder
    ) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM migration_import_apple_album_member
            WHERE migration_id = ? AND media_id = ?
            """, arguments: [migration, media])
        guard rows.count == expected.count else {
            throw PhoneArchiveImportError.catalogDiverged
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { row -> (String, Row) in
            (row["album_local_identifier"], row)
        })
        for album in expected {
            guard let row = byID[album.albumLocalIdentifier] else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            let title: String? = row["album_title"]
            let folderPath: String = row["folder_path_json"]
            let ordinal: Int64 = row["source_ordinal"]
            let expectedPath = String(
                decoding: try encoder.encode(album.folderPath), as: UTF8.self
            )
            guard title == album.albumTitle, folderPath == expectedPath,
                  ordinal == album.sourceOrdinal else {
                throw PhoneArchiveImportError.catalogDiverged
            }
        }
    }

    func validateTargetDirectory(_ targetParent: URL) throws {
        let values = try targetParent.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        do {
            try PortableExportSourceIsolationValidator(
                sourceRepository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: FoundationSecurityScopedBookmarkAdapter(),
                relationshipChecker: FoundationFolderRootRelationshipChecker()
            ).validate(parentDirectoryURL: targetParent)
        } catch PortableCatalogExportError.destinationOverlapsSource {
            throw PhoneArchiveImportError.targetOverlapsMacLibrary
        } catch {
            throw PhoneArchiveImportError.targetIsolationIndeterminate
        }
    }

    func reconcileFacts(
        from url: URL, migrationID: UUID, archiveRoot: URL? = nil,
        afterFactPublication: (() throws -> Void)? = nil
    ) throws -> PhoneArchiveFactReceipt {
        let read = try ImageAllMigrationFacts.readWithDigest(at: url)
        let snapshot = read.snapshot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(snapshot))
            .map { String(format: "%02x", $0) }.joined()
        let id = migrationID.uuidString.lowercased()
        let expected = try preflightFactSnapshot(snapshot, digest: digest, migrationID: id)
        let archive = archiveRoot ?? expected.archiveURL
        guard archive.lastPathComponent == "ImageAll-Archive-\(id)" else {
            throw PhoneArchiveImportError.targetChanged
        }
        let before = try ImageAllMigrationArchive.verify(at: archive)
        guard before.manifestSHA256 == expected.manifestSHA256,
              before.itemCount == expected.itemCount,
              before.resourceCount == expected.resourceCount,
              before.verifiedBytes == expected.verifiedBytes else {
            throw PhoneArchiveImportError.publishedCopyChanged
        }
        if let latestURL = try ImageAllMigrationFacts.latestPublishedURL(in: archive) {
            let latest = try ImageAllMigrationFacts.readWithDigest(at: latestURL)
            guard snapshot.snapshotSequence >= latest.snapshot.snapshotSequence,
                  snapshot.factWatermark >= latest.snapshot.factWatermark else {
                throw PhoneArchiveImportError.staleFactSnapshot
            }
            if snapshot.snapshotSequence == latest.snapshot.snapshotSequence,
               read.sha256 != latest.sha256 {
                throw PhoneArchiveImportError.factSnapshotConflict
            }
        }
        _ = try ImageAllMigrationFacts.publish(from: url, into: archive)
        let after = try ImageAllMigrationArchive.verify(at: archive)
        guard after.hasSameMedia(as: before), after.factsSHA256 != nil else {
            throw PhoneArchiveImportError.publishedCopyChanged
        }
        try afterFactPublication?()
        return try database.pool.write { db in
            guard let batch = try Row.fetchOne(
                db, sql: "SELECT * FROM migration_import WHERE id = ? AND state = 'catalogCommitted'",
                arguments: [id]
            ) else { throw PhoneArchiveImportError.missingImportJournal }
            let sourceDevice: String = batch["source_device_id"]
            let sourceEpoch: String = batch["source_epoch"]
            let scopeRevision: Int64 = batch["scope_revision"]
            let inventoryWatermark: Int64 = batch["inventory_watermark"]
            let count: Int = batch["item_count"]
            let previousSequence: Int64 = batch["fact_snapshot_sequence"]
            let previousHash: String? = batch["fact_snapshot_sha256"]
            guard sourceDevice == snapshot.sourceDeviceID.uuidString.lowercased(),
                  sourceEpoch == snapshot.sourceEpoch.uuidString.lowercased(),
                  scopeRevision == snapshot.scopeRevision,
                  count == snapshot.items.count else {
                throw PhoneArchiveImportError.factScopeMismatch
            }
            guard snapshot.snapshotSequence >= inventoryWatermark,
                  snapshot.snapshotSequence >= previousSequence else {
                throw PhoneArchiveImportError.staleFactSnapshot
            }
            if snapshot.snapshotSequence == previousSequence {
                guard previousHash == digest else {
                    throw PhoneArchiveImportError.factSnapshotConflict
                }
                return PhoneArchiveFactReceipt(
                    migrationID: migrationID, itemCount: count,
                    snapshotSequence: snapshot.snapshotSequence,
                    factWatermark: snapshot.factWatermark, replayed: true
                )
            }
            let highestFactRevision = try Int64.fetchOne(
                db, sql: "SELECT MAX(fact_revision) FROM migration_import_item WHERE migration_id = ?",
                arguments: [id]
            ) ?? 0
            guard snapshot.factWatermark >= highestFactRevision else {
                throw PhoneArchiveImportError.staleFactSnapshot
            }
            for item in snapshot.items {
                let media = item.mediaID.uuidString.lowercased()
                guard try Int.fetchOne(db, sql: """
                    SELECT 1 FROM migration_import_item WHERE migration_id = ? AND media_id = ?
                    """, arguments: [id, media]) != nil else {
                    throw PhoneArchiveImportError.factScopeMismatch
                }
                try db.execute(sql: """
                    UPDATE migration_import_item
                    SET observed_favorite = ?, favorite_target = ?, fact_revision = ?
                    WHERE migration_id = ? AND media_id = ?
                    """, arguments: [
                        item.observedFavorite ? 1 : 0,
                        item.favoriteTarget.map { $0 ? 1 : 0 }, snapshot.factWatermark,
                        id, media,
                    ])
                try db.execute(sql: """
                    DELETE FROM migration_import_tag_decision
                    WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
                    """, arguments: [sourceDevice, sourceEpoch, media])
                try db.execute(sql: """
                    DELETE FROM migration_import_collection
                    WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
                    """, arguments: [sourceDevice, sourceEpoch, media])
                for tag in item.tagDecisions {
                    try db.execute(sql: """
                        INSERT INTO migration_import_tag_decision (
                            source_device_id, source_epoch, media_id, tag_id, tag_name, decision
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            sourceDevice, sourceEpoch, media, tag.tagID.uuidString.lowercased(),
                            tag.tagName, tag.decision.rawValue,
                        ])
                }
                for collection in item.collections {
                    try db.execute(sql: """
                        INSERT INTO migration_import_collection (
                            source_device_id, source_epoch, media_id,
                            collection_id, collection_name, included
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            sourceDevice, sourceEpoch, media,
                            collection.collectionID.uuidString.lowercased(),
                            collection.collectionName, collection.included ? 1 : 0,
                        ])
                }
            }
            try db.execute(sql: """
                UPDATE migration_import
                SET fact_snapshot_sequence = ?, fact_watermark = ?, fact_snapshot_sha256 = ?,
                    updated_at_ms = ? WHERE id = ?
                """, arguments: [
                    snapshot.snapshotSequence, snapshot.factWatermark, digest,
                    Int64(Date().timeIntervalSince1970 * 1_000), id,
                ])
            return PhoneArchiveFactReceipt(
                migrationID: migrationID, itemCount: count,
                snapshotSequence: snapshot.snapshotSequence,
                factWatermark: snapshot.factWatermark, replayed: false
            )
        }
    }

    private func preflightFactSnapshot(
        _ snapshot: ImageAllMigrationFactSnapshot, digest: String, migrationID: String
    ) throws -> (
        archiveURL: URL, manifestSHA256: String, itemCount: Int,
        resourceCount: Int, verifiedBytes: Int64
    ) {
        try database.pool.read { db in
            guard let batch = try Row.fetchOne(db, sql: """
                SELECT * FROM migration_import WHERE id = ? AND state = 'catalogCommitted'
                """, arguments: [migrationID]) else {
                throw PhoneArchiveImportError.missingImportJournal
            }
            let sourceDevice: String = batch["source_device_id"]
            let sourceEpoch: String = batch["source_epoch"]
            let scopeRevision: Int64 = batch["scope_revision"]
            let inventoryWatermark: Int64 = batch["inventory_watermark"]
            let itemCount: Int = batch["item_count"]
            let previousSequence: Int64 = batch["fact_snapshot_sequence"]
            let previousHash: String? = batch["fact_snapshot_sha256"]
            guard sourceDevice == snapshot.sourceDeviceID.uuidString.lowercased(),
                  sourceEpoch == snapshot.sourceEpoch.uuidString.lowercased(),
                  scopeRevision == snapshot.scopeRevision,
                  itemCount == snapshot.items.count else {
                throw PhoneArchiveImportError.factScopeMismatch
            }
            guard snapshot.snapshotSequence >= inventoryWatermark,
                  snapshot.snapshotSequence >= previousSequence else {
                throw PhoneArchiveImportError.staleFactSnapshot
            }
            if snapshot.snapshotSequence == previousSequence && previousHash != digest {
                throw PhoneArchiveImportError.factSnapshotConflict
            }
            let highestFactRevision = try Int64.fetchOne(db, sql: """
                SELECT MAX(fact_revision) FROM migration_import_item WHERE migration_id = ?
                """, arguments: [migrationID]) ?? 0
            guard snapshot.factWatermark >= highestFactRevision else {
                throw PhoneArchiveImportError.staleFactSnapshot
            }
            for item in snapshot.items {
                guard try Int.fetchOne(db, sql: """
                    SELECT 1 FROM migration_import_item WHERE migration_id = ? AND media_id = ?
                    """, arguments: [migrationID, item.mediaID.uuidString.lowercased()]) != nil else {
                    throw PhoneArchiveImportError.factScopeMismatch
                }
            }
            let path: String = batch["archive_path"]
            return (
                URL(fileURLWithPath: path, isDirectory: true),
                batch["manifest_sha256"], itemCount,
                batch["resource_count"], batch["verified_bytes"]
            )
        }
    }

    func importedBatches() throws -> [PhoneArchiveImportedBatch] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, archive_path, target_parent_path, target_bookmark,
                       item_count, resource_count, verified_bytes, updated_at_ms,
                       fact_snapshot_sequence, apple_album_coverage
                FROM migration_import WHERE state = 'catalogCommitted'
                ORDER BY updated_at_ms DESC
                """).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return PhoneArchiveImportedBatch(
                    id: id,
                    archivePath: row["archive_path"],
                    targetParentPath: row["target_parent_path"],
                    targetBookmark: row["target_bookmark"],
                    itemCount: row["item_count"],
                    resourceCount: row["resource_count"],
                    verifiedBytes: row["verified_bytes"],
                    importedAtMs: row["updated_at_ms"],
                    factSnapshotSequence: row["fact_snapshot_sequence"],
                    appleAlbumCoverage: (row["apple_album_coverage"] as String?)
                        .flatMap(ImageAllMigrationAppleAlbumCoverage.init(rawValue:))
                )
            }
        }
    }

    func importedItems(migrationID: UUID, offset: Int, limit: Int = 100) throws -> [PhoneArchiveImportedItem] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT i.media_id, i.source_local_identifier, i.media_kind, i.created_at_ms,
                       (SELECT COUNT(*) FROM migration_import_resource r
                        WHERE r.source_device_id = i.source_device_id AND r.source_epoch = i.source_epoch
                          AND r.media_id = i.media_id) AS resource_count,
                       (SELECT COUNT(*) FROM migration_import_tag_decision t
                        WHERE t.source_device_id = i.source_device_id AND t.source_epoch = i.source_epoch
                          AND t.media_id = i.media_id) AS tag_count,
                       (SELECT COUNT(*) FROM migration_import_collection c
                        WHERE c.source_device_id = i.source_device_id AND c.source_epoch = i.source_epoch
                          AND c.media_id = i.media_id AND c.included = 1) AS collection_count,
                       (SELECT COUNT(*) FROM migration_import_apple_album_member a
                        WHERE a.migration_id = i.migration_id AND a.media_id = i.media_id)
                        AS apple_album_count
                FROM migration_import_item i
                JOIN migration_import m ON m.id = i.migration_id
                WHERE i.migration_id = ? AND m.state = 'catalogCommitted'
                ORDER BY i.created_at_ms, i.media_id LIMIT ? OFFSET ?
                """, arguments: [migrationID.uuidString.lowercased(), limit, offset]).compactMap { row in
                guard let id = UUID(uuidString: row["media_id"]) else { return nil }
                return PhoneArchiveImportedItem(
                    id: id, sourceLocalIdentifier: row["source_local_identifier"],
                    mediaKind: row["media_kind"], createdAtMs: row["created_at_ms"],
                    resourceCount: row["resource_count"], tagCount: row["tag_count"],
                    collectionCount: row["collection_count"],
                    appleAlbumCount: row["apple_album_count"]
                )
            }
        }
    }

    /// The caller keeps the target parent's security scope open while using
    /// the returned URL. Package verification binds this resource to the
    /// committed manifest before any external application opens it.
    func verifiedOriginalURL(migrationID: UUID, mediaID: UUID, archiveRoot: URL) throws -> URL {
        let expected = try database.pool.read { db -> (String, Int, Int, Int64, String)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.manifest_sha256, m.item_count, m.resource_count, m.verified_bytes,
                       r.relative_path
                FROM migration_import m
                JOIN migration_import_item i ON i.migration_id = m.id
                JOIN migration_import_resource r
                  ON r.source_device_id = i.source_device_id AND r.source_epoch = i.source_epoch
                 AND r.media_id = i.media_id
                WHERE m.id = ? AND i.media_id = ? AND m.state = 'catalogCommitted'
                  AND r.role = 'original'
                ORDER BY r.version LIMIT 1
                """, arguments: [migrationID.uuidString.lowercased(), mediaID.uuidString.lowercased()]
            ) else { return nil }
            return (row["manifest_sha256"], row["item_count"], row["resource_count"],
                    row["verified_bytes"], row["relative_path"])
        }
        guard let expected else { throw PhoneArchiveImportError.missingImportJournal }
        let root = archiveRoot.standardizedFileURL
        let verification = try ImageAllMigrationArchive.verify(at: root)
        guard verification.migrationID == migrationID,
              verification.manifestSHA256 == expected.0,
              verification.itemCount == expected.1,
              verification.resourceCount == expected.2,
              verification.verifiedBytes == expected.3,
              verification.isComplete else {
            throw PhoneArchiveImportError.publishedCopyChanged
        }
        let relative = expected.4
        guard relative.hasPrefix("resources/"), relative.split(separator: "/").count == 2 else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        return root.appendingPathComponent(relative)
    }

    func importArchive(
        from incoming: URL, to targetParent: URL,
        afterPublication: (() throws -> Void)? = nil
    ) throws -> PhoneArchiveImportReceipt {
        let (header, verification) = try ImageAllMigrationArchive.readVerifiedHeader(at: incoming)
        guard verification.isComplete else { throw PhoneArchiveImportError.incompleteArchive }
        let source = incoming.standardizedFileURL.resolvingSymlinksInPath()
        let target = targetParent.standardizedFileURL.resolvingSymlinksInPath()
        let receiverOwnedStage = source.lastPathComponent == "package"
            && source.deletingLastPathComponent().lastPathComponent
                == ".imageall-transfer-\(header.migrationID.uuidString.lowercased())"
            && source.deletingLastPathComponent().deletingLastPathComponent() == target
        guard source.path != target.path,
              (!source.path.hasPrefix(target.path + "/") || receiverOwnedStage),
              !target.path.hasPrefix(source.path + "/") else {
            throw ImageAllMigrationArchiveError.destinationOverlap
        }
        try validateTargetDirectory(targetParent)
        let parent = targetParent.standardizedFileURL
        let targetBookmark = try? targetParent.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let final = parent.appendingPathComponent(
            "ImageAll-Archive-\(header.migrationID.uuidString.lowercased())", isDirectory: true
        )
        let id = header.migrationID.uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let alreadyCommitted = try database.pool.write { db -> Bool in
            if let row = try Row.fetchOne(
                db, sql: "SELECT * FROM migration_import WHERE id = ?", arguments: [id]
            ) {
                let savedHash: String = row["manifest_sha256"]
                let savedPath: String = row["archive_path"]
                let savedParent: String = row["target_parent_path"]
                let savedDevice: String = row["source_device_id"]
                let savedEpoch: String = row["source_epoch"]
                let savedItemCount: Int = row["item_count"]
                let savedResourceCount: Int = row["resource_count"]
                let savedBytes: Int64 = row["verified_bytes"]
                let savedAppleAlbumCoverage: String? = row["apple_album_coverage"]
                guard savedHash == verification.manifestSHA256,
                      savedDevice == header.sourceDeviceID.uuidString.lowercased(),
                      savedEpoch == header.sourceEpoch.uuidString.lowercased(),
                      savedItemCount == verification.itemCount,
                      savedResourceCount == verification.resourceCount,
                      savedBytes == verification.verifiedBytes,
                      savedAppleAlbumCoverage == header.appleAlbumCoverage?.rawValue else {
                    throw PhoneArchiveImportError.migrationIdentityConflict
                }
                guard savedPath == final.path, savedParent == parent.path else {
                    throw PhoneArchiveImportError.targetChanged
                }
                let state: String = row["state"]
                return state == "catalogCommitted"
            }
            try db.execute(sql: """
                INSERT INTO migration_import (
                    id, source_device_id, source_epoch, scope_revision,
                    inventory_watermark, manifest_sha256, target_parent_path, target_bookmark,
                    archive_path, item_count, resource_count, verified_bytes,
                    apple_album_coverage,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?, ?)
                """, arguments: [
                    id, header.sourceDeviceID.uuidString.lowercased(),
                    header.sourceEpoch.uuidString.lowercased(), header.scopeRevision,
                    header.inventoryWatermark, verification.manifestSHA256,
                    parent.path, targetBookmark, final.path, verification.itemCount,
                    verification.resourceCount, verification.verifiedBytes,
                    header.appleAlbumCoverage?.rawValue, now, now,
                ])
            return false
        }

        if FileManager.default.fileExists(atPath: final.path) {
            guard try ImageAllMigrationArchive.verify(at: final).hasSameMedia(as: verification) else {
                throw PhoneArchiveImportError.publishedCopyChanged
            }
        } else {
            guard !alreadyCommitted else { throw PhoneArchiveImportError.publishedCopyChanged }
            let published = try ImageAllMigrationArchive.publishVerifiedCopy(
                from: incoming, to: parent
            )
            guard published.standardizedFileURL == final else {
                throw PhoneArchiveImportError.publishedCopyChanged
            }
        }
        try afterPublication?()

        if alreadyCommitted {
            try recoverPublishedFactsIfNeeded(at: final, migrationID: header.migrationID)
            try reconcileNewStagedFacts(
                from: incoming, into: final, migrationID: header.migrationID
            )
            return receipt(header: header, verification: verification, url: final, replayed: true)
        }

        try database.pool.write { db in
            guard let state = try String.fetchOne(
                db, sql: "SELECT state FROM migration_import WHERE id = ?", arguments: [id]
            ), state == "prepared" else {
                throw PhoneArchiveImportError.missingImportJournal
            }
            let reread = try ImageAllMigrationArchive.visitVerifiedRecords(
                at: final,
                onHeader: { publishedHeader in
                    guard publishedHeader == header else {
                        throw PhoneArchiveImportError.publishedCopyChanged
                    }
                },
                onItem: { item in
                    try insert(item: item, header: header, db: db)
                }
            )
            guard reread.hasSameMedia(as: verification) else {
                throw PhoneArchiveImportError.publishedCopyChanged
            }
            try db.execute(sql: """
                UPDATE migration_import SET state = 'catalogCommitted', updated_at_ms = ?
                WHERE id = ? AND state = 'prepared'
                """, arguments: [now, id])
        }
        try recoverPublishedFactsIfNeeded(at: final, migrationID: header.migrationID)
        try reconcileNewStagedFacts(
            from: incoming, into: final, migrationID: header.migrationID
        )
        return receipt(header: header, verification: verification, url: final, replayed: false)
    }

    private func reconcileNewStagedFacts(
        from incoming: URL, into published: URL, migrationID: UUID
    ) throws {
        let directory = incoming.appendingPathComponent(
            ImageAllMigrationFacts.sidecarDirectoryName, isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for name in names {
            let source = directory.appendingPathComponent(name)
            let next = try ImageAllMigrationFacts.readWithDigest(at: source)
            if let currentURL = try ImageAllMigrationFacts.latestPublishedURL(in: published) {
                let current = try ImageAllMigrationFacts.readWithDigest(at: currentURL)
                if next.snapshot.snapshotSequence < current.snapshot.snapshotSequence { continue }
                if next.snapshot.snapshotSequence == current.snapshot.snapshotSequence {
                    guard next.sha256 == current.sha256 else {
                        throw PhoneArchiveImportError.factSnapshotConflict
                    }
                    continue
                }
            }
            _ = try reconcileFacts(
                from: source, migrationID: migrationID, archiveRoot: published
            )
        }
    }

    private func recoverPublishedFactsIfNeeded(at archive: URL, migrationID: UUID) throws {
        guard let latest = try ImageAllMigrationFacts.latestPublishedURL(in: archive) else { return }
        _ = try reconcileFacts(from: latest, migrationID: migrationID, archiveRoot: archive)
    }

    private func receipt(
        header: ImageAllMigrationHeader,
        verification: ImageAllMigrationVerification,
        url: URL,
        replayed: Bool
    ) -> PhoneArchiveImportReceipt {
        PhoneArchiveImportReceipt(
            migrationID: header.migrationID, archiveURL: url,
            manifestSHA256: verification.manifestSHA256,
            itemCount: verification.itemCount,
            resourceCount: verification.resourceCount,
            verifiedBytes: verification.verifiedBytes, replayed: replayed
        )
    }

    private func insert(
        item: ImageAllMigrationItem,
        header: ImageAllMigrationHeader,
        db: Database
    ) throws {
        let device = header.sourceDeviceID.uuidString.lowercased()
        let epoch = header.sourceEpoch.uuidString.lowercased()
        let media = item.mediaID.uuidString.lowercased()
        do {
            try db.execute(sql: """
                INSERT INTO migration_import_item (
                    source_device_id, source_epoch, media_id, migration_id,
                    source_local_identifier, media_kind, created_at_ms,
                    observed_favorite, favorite_target, fact_revision
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    device, epoch, media, header.migrationID.uuidString.lowercased(),
                    item.sourceLocalIdentifier, item.mediaKind.rawValue,
                    item.createdAtMs, item.observedFavorite ? 1 : 0,
                    item.favoriteTarget.map { $0 ? 1 : 0 }, item.factRevision,
                ])
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            // A second archive for the same source identity needs explicit
            // revision reconciliation, even when bytes happen to match.
            throw PhoneArchiveImportError.migrationIdentityConflict
        }
        for resource in item.resources {
            guard resource.status == .present,
                  let path = resource.relativePath,
                  let count = resource.byteCount,
                  let hash = resource.sha256 else {
                throw PhoneArchiveImportError.incompleteArchive
            }
            try db.execute(sql: """
                INSERT INTO migration_import_resource (
                    id, source_device_id, source_epoch, media_id, role,
                    version, uti, relative_path, byte_count, sha256
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    resource.id.uuidString.lowercased(), device, epoch, media,
                    resource.role, resource.version, resource.uniformTypeIdentifier,
                    path, count, hash,
                ])
        }
        for tag in item.tagDecisions {
            try db.execute(sql: """
                INSERT INTO migration_import_tag_decision (
                    source_device_id, source_epoch, media_id, tag_id,
                    tag_name, decision
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    device, epoch, media, tag.tagID.uuidString.lowercased(),
                    tag.tagName, tag.decision.rawValue,
                ])
        }
        for collection in item.collections {
            try db.execute(sql: """
                INSERT INTO migration_import_collection (
                    source_device_id, source_epoch, media_id, collection_id,
                    collection_name, included
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    device, epoch, media, collection.collectionID.uuidString.lowercased(),
                    collection.collectionName, collection.included ? 1 : 0,
                ])
        }
        let folderEncoder = JSONEncoder()
        folderEncoder.outputFormatting = [.sortedKeys]
        for album in item.appleAlbums ?? [] {
            let folderPath = String(
                decoding: try folderEncoder.encode(album.folderPath), as: UTF8.self
            )
            try db.execute(sql: """
                INSERT INTO migration_import_apple_album_member (
                    migration_id, source_device_id, source_epoch, media_id,
                    album_local_identifier, album_title, folder_path_json, source_ordinal
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    header.migrationID.uuidString.lowercased(), device, epoch, media,
                    album.albumLocalIdentifier, album.albumTitle, folderPath,
                    album.sourceOrdinal,
                ])
        }
    }
}

@MainActor
enum PhoneArchiveImportProcessHolder {
    private static var database: CatalogDatabase?

    static func attach(database: CatalogDatabase) {
        self.database = database
    }

    static func importer() -> VerifiedPhoneArchiveImporter? {
        database.map { VerifiedPhoneArchiveImporter(database: $0) }
    }
}
