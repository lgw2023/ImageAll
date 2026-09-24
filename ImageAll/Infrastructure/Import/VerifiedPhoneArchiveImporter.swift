import CryptoKit
import Foundation
import GRDB
import ImageAllRemoteProtocol
import UniformTypeIdentifiers
import os

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
    case validationStale
    case assetBindingCandidateChanged
    case assetAlreadyBound
    case assetKindMismatch
    case tagAliasCandidateChanged
    case tagAliasAlreadyMapped
    case tagSyncCandidateChanged
    case tagSyncPending

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
        case .validationStale: "验收记录所绑定的归档、恢复副本或事实水位已变化，请重新核查。"
        case .assetBindingCandidateChanged: "Mac 资产或来源已变化，请重新搜索并确认。"
        case .assetAlreadyBound: "此 Mac 资产已关联其他媒体，不能重复关联。"
        case .assetKindMismatch: "手机归档与 Mac 资产的媒体类型不一致。"
        case .tagAliasCandidateChanged: "标签身份或事实版本已变化，请重新对账。"
        case .tagAliasAlreadyMapped: "此手机或 Mac 标签已映射到另一标签，需先对账。"
        case .tagSyncCandidateChanged: "Mac 资产或标签决定已变化，请刷新对账后重试。"
        case .tagSyncPending: "这项标签已有待核查的跨存储提交，请先恢复或处理该操作。"
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

struct PhoneArchiveValidationRecord: Identifiable, Sendable {
    let id: UUID
    let migrationID: UUID
    let archivePath: String
    let archiveVolumeUUID: String?
    let recoveryArchivePath: String
    let recoveryCatalogPath: String
    let recoveryParentBookmark: Data?
    let manifestSHA256: String
    let factSnapshotSHA256: String
    let factSnapshotSequence: Int64
    let factWatermark: Int64
    let itemCount: Int
    let resourceCount: Int
    let verifiedBytes: Int64
    let hostID: UUID
    let deviceID: UUID
    let sourceVerifiedAtMs: Int64
    let createdAtMs: Int64
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
    let assetBindingCount: Int
}

struct PhoneArchiveAssetCandidate: Identifiable, Sendable, Equatable {
    let id: UUID
    let sourceID: UUID
    let displayName: String
    let sourceName: String
    let sourceUpdatedAtMs: Int64
    let locatorDescription: String
    let mediaType: String
    let contentRevision: Int64
    let createdAtMs: Int64?
    let boundMediaID: UUID?
}

struct PhoneArchiveAssetBindingReceipt: Sendable, Equatable {
    let mediaID: UUID
    let assetID: UUID
    let replayed: Bool
}

struct PhoneArchiveBoundAsset: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let sourceName: String
    let locatorDescription: String
    let evidenceKind: String
    let createdAtMs: Int64
    let confirmationEventID: UUID
}

enum PhoneArchiveTagComparisonState: Sendable, Equatable {
    case same
    case decisionDiffers
    case macDecisionMissing
    case macTagMissing
    case nameAliasRequired
    case identityConflict
    case macTagArchived
    case nameDiffers
}

struct PhoneArchiveTagComparison: Identifiable, Sendable {
    var id: UUID { phoneTagID }
    let phoneTagID: UUID
    let phoneTagName: String
    let phoneDecision: RemoteLocalLibraryDecision
    let macTagID: UUID?
    let macTagName: String?
    let macTagUpdatedAtMs: Int64?
    let macDecision: String?
    let macDecisionUpdatedAtMs: Int64?
    let macDecisionRevision: Int64?
    let state: PhoneArchiveTagComparisonState
    let aliasConfirmationEventID: UUID?
}

struct PhoneArchiveTagAliasReceipt: Sendable, Equatable {
    let phoneTagID: UUID
    let macTagID: UUID
    let replayed: Bool
}

struct PhoneArchiveMacTagApplicationReceipt: Sendable, Equatable {
    let operationID: UUID
    let macTagID: UUID
    let decision: RemoteLocalLibraryDecision
    let macDecisionRevision: Int64
    let replayed: Bool
}

struct PhoneArchiveMacTagOutboundIntent: Identifiable, Sendable, Equatable {
    enum State: String, Sendable {
        case prepared
        case committed
        case conflict
    }

    let id: UUID
    let migrationID: UUID
    let mediaID: UUID
    let assetID: UUID
    let bindingConfirmationEventID: UUID
    let sourceInstallID: UUID
    let sourceEpoch: UUID
    let phoneDeviceID: UUID
    let phoneScopeRevision: Int64
    let phoneTagID: UUID
    let phoneTagName: String
    let macTagID: UUID
    let macExpectedRevision: Int64
    let macExpectedDecision: RemoteLocalLibraryDecision
    let phoneExpectedRevision: Int64
    let phoneExpectedDecision: RemoteLocalLibraryDecision
    let desiredDecision: RemoteLocalLibraryDecision
    let state: State
    let phoneResultingRevision: Int64?
    let phoneChangeSequence: Int64?
    let createdAtMs: Int64
}

struct PhoneArchiveMacTagRecoveryResult: Sendable, Equatable {
    let prepared: Int
    let committed: Int
    let stillPending: Int
    let failedVerification: Int
}

struct PhoneArchiveMacOnlyTagDecision: Identifiable, Sendable {
    var id: UUID { tagID }
    let tagID: UUID
    let tagName: String
    let decision: String
}

struct PhoneArchiveBoundFactComparison: Sendable {
    let sourceInstallID: UUID
    let sourceEpoch: UUID
    let bindingConfirmationEventID: UUID
    let factSnapshotSequence: Int64
    let tags: [PhoneArchiveTagComparison]
    let macOnlyTags: [PhoneArchiveMacOnlyTagDecision]
    let phoneFavoriteTarget: Bool?
    let macFavoriteTarget: Bool?
    let phoneCollectionNames: [String]
    let phoneAppleAlbumNames: [String]
}

struct PhoneArchiveSourceLink: Sendable, Equatable {
    let migrationID: UUID
    let mediaID: UUID
    let sourceLocalIdentifier: String
    let mediaKind: String

    func matches(_ asset: RemoteLocalLibraryAsset) -> Bool {
        asset.id == mediaID
            && asset.localIdentifier == sourceLocalIdentifier
            && asset.mediaKind.rawValue == mediaKind
    }
}

struct PhoneArchiveImportedFacts: Sendable, Equatable {
    let observedFavorite: Bool
    let favoriteTarget: Bool?
    let tagDecisions: [ImageAllMigrationTagDecision]
    let collections: [ImageAllMigrationCollectionMembership]
    let appleAlbums: [ImageAllMigrationAppleAlbumMembership]
}

struct PhoneArchiveVerifiedPreview: Sendable {
    let originalURL: URL
    let facts: PhoneArchiveImportedFacts
}

/// Imports a verified phone package into dedicated catalog bindings. The
/// existing one-source Asset row remains untouched; archive resources are
/// owned by this migration until a deliberate MediaItem/Replica projection
/// exposes them in the unified gallery.
struct VerifiedPhoneArchiveImporter: Sendable {
    let database: CatalogDatabase

    /// Persists a historical candidate after both catalogs independently
    /// agree. Current validity is never inferred from this row alone.
    func recordValidation(
        migrationID: UUID, archiveRoot: URL,
        recovery: PhoneArchiveRecoveryReport,
        recoveryParentBookmark: Data? = nil
    ) throws -> PhoneArchiveValidationRecord {
        let original = try auditImportedArchive(
            migrationID: migrationID, archiveRoot: archiveRoot
        )
        guard let snapshot = original.factSnapshot,
              let checkpoint = snapshot.syncCheckpoint,
              checkpoint.archiveManifestSHA256 == original.manifestSHA256,
              let sourceVerifiedAtMs = checkpoint.sourceVerifiedAtMs,
              original == recovery.integrity,
              try ImageAllMigrationArchive.readVerifiedHeader(
                  at: archiveRoot
              ).0.appleAlbumCoverage == .selectedAssetsOnly else {
            throw PhoneArchiveImportError.validationStale
        }
        let restored = try Self.readOnlyImporter(at: recovery.recoveredCatalogURL)
            .auditImportedArchive(
                migrationID: migrationID, archiveRoot: recovery.restoredArchiveURL
            )
        guard restored == original,
              recovery.restoredArchiveURL.standardizedFileURL != archiveRoot.standardizedFileURL
        else { throw PhoneArchiveImportError.validationStale }
        let digest = try Self.factDigest(snapshot)
        let volume = try archiveRoot.resourceValues(
            forKeys: [.volumeUUIDStringKey]
        ).volumeUUIDString
        let record = PhoneArchiveValidationRecord(
            id: UUID(), migrationID: migrationID,
            archivePath: archiveRoot.standardizedFileURL.path,
            archiveVolumeUUID: volume,
            recoveryArchivePath: recovery.restoredArchiveURL.standardizedFileURL.path,
            recoveryCatalogPath: recovery.recoveredCatalogURL.standardizedFileURL.path,
            recoveryParentBookmark: recoveryParentBookmark,
            manifestSHA256: original.manifestSHA256,
            factSnapshotSHA256: digest,
            factSnapshotSequence: original.factSnapshotSequence,
            factWatermark: original.factWatermark,
            itemCount: original.itemCount, resourceCount: original.resourceCount,
            verifiedBytes: original.verifiedBytes,
            hostID: checkpoint.hostID, deviceID: checkpoint.deviceID,
            sourceVerifiedAtMs: sourceVerifiedAtMs,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try database.pool.write { db in
            let batch = try Row.fetchOne(db, sql: """
                SELECT archive_path, manifest_sha256, fact_snapshot_sequence,
                       fact_snapshot_sha256 FROM migration_import
                WHERE id = ? AND state = 'catalogCommitted'
                """, arguments: [migrationID.uuidString.lowercased()])
            guard let batch,
                  (batch["archive_path"] as String) == record.archivePath,
                  (batch["manifest_sha256"] as String) == record.manifestSHA256,
                  (batch["fact_snapshot_sequence"] as Int64) == record.factSnapshotSequence,
                  (batch["fact_snapshot_sha256"] as String?) == record.factSnapshotSHA256 else {
                throw PhoneArchiveImportError.validationStale
            }
            try db.execute(sql: """
                INSERT INTO migration_import_validation (
                    id, migration_id, archive_path, archive_volume_uuid,
                    recovery_archive_path, recovery_catalog_path, recovery_parent_bookmark,
                    manifest_sha256,
                    fact_snapshot_sha256, fact_snapshot_sequence, fact_watermark,
                    item_count, resource_count, verified_bytes, host_id, device_id,
                    source_verified_at_ms, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    record.id.uuidString.lowercased(), migrationID.uuidString.lowercased(),
                    record.archivePath, record.archiveVolumeUUID,
                    record.recoveryArchivePath, record.recoveryCatalogPath,
                    record.recoveryParentBookmark,
                    record.manifestSHA256, record.factSnapshotSHA256,
                    record.factSnapshotSequence, record.factWatermark,
                    record.itemCount, record.resourceCount, record.verifiedBytes,
                    record.hostID.uuidString.lowercased(), record.deviceID.uuidString.lowercased(),
                    record.sourceVerifiedAtMs, record.createdAtMs,
                ])
        }
        return record
    }

    func latestValidationRecord(migrationID: UUID) throws -> PhoneArchiveValidationRecord? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM migration_import_validation WHERE migration_id = ?
                ORDER BY created_at_ms DESC, id DESC LIMIT 1
                """, arguments: [migrationID.uuidString.lowercased()]) else { return nil }
            guard let id = UUID(uuidString: row["id"]),
                  let hostID = UUID(uuidString: row["host_id"]),
                  let deviceID = UUID(uuidString: row["device_id"]) else {
                throw PhoneArchiveImportError.validationStale
            }
            return PhoneArchiveValidationRecord(
                id: id, migrationID: migrationID,
                archivePath: row["archive_path"],
                archiveVolumeUUID: row["archive_volume_uuid"],
                recoveryArchivePath: row["recovery_archive_path"],
                recoveryCatalogPath: row["recovery_catalog_path"],
                recoveryParentBookmark: row["recovery_parent_bookmark"],
                manifestSHA256: row["manifest_sha256"],
                factSnapshotSHA256: row["fact_snapshot_sha256"],
                factSnapshotSequence: row["fact_snapshot_sequence"],
                factWatermark: row["fact_watermark"],
                itemCount: row["item_count"], resourceCount: row["resource_count"],
                verifiedBytes: row["verified_bytes"],
                hostID: hostID, deviceID: deviceID,
                sourceVerifiedAtMs: row["source_verified_at_ms"],
                createdAtMs: row["created_at_ms"]
            )
        }
    }

    /// Rechecks the saved evidence after restart, including both archive
    /// copies. The caller must additionally compare the live Host watermark.
    func auditValidationRecord(
        _ record: PhoneArchiveValidationRecord
    ) throws -> PhoneArchiveIntegrityReport {
        let archive = URL(fileURLWithPath: record.archivePath, isDirectory: true)
        let original = try auditImportedArchive(
            migrationID: record.migrationID, archiveRoot: archive
        )
        let volume = try archive.resourceValues(
            forKeys: [.volumeUUIDStringKey]
        ).volumeUUIDString
        guard volume == record.archiveVolumeUUID,
              original.manifestSHA256 == record.manifestSHA256,
              original.factSnapshotSequence == record.factSnapshotSequence,
              original.factWatermark == record.factWatermark,
              original.itemCount == record.itemCount,
              original.resourceCount == record.resourceCount,
              original.verifiedBytes == record.verifiedBytes,
              let snapshot = original.factSnapshot,
              try Self.factDigest(snapshot) == record.factSnapshotSHA256,
              let checkpoint = snapshot.syncCheckpoint,
              checkpoint.hostID == record.hostID,
              checkpoint.deviceID == record.deviceID,
              checkpoint.sourceVerifiedAtMs == record.sourceVerifiedAtMs else {
            throw PhoneArchiveImportError.validationStale
        }
        let restored = try Self.readOnlyImporter(
            at: URL(fileURLWithPath: record.recoveryCatalogPath)
        ).auditImportedArchive(
            migrationID: record.migrationID,
            archiveRoot: URL(fileURLWithPath: record.recoveryArchivePath, isDirectory: true)
        )
        guard restored == original else { throw PhoneArchiveImportError.validationStale }
        return original
    }

    private static func readOnlyImporter(at url: URL) throws -> VerifiedPhoneArchiveImporter {
        var configuration = Configuration()
        configuration.readonly = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return VerifiedPhoneArchiveImporter(database: CatalogDatabase(pool: pool))
    }

    private static func factDigest(_ snapshot: ImageAllMigrationFactSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(snapshot))
            .map { String(format: "%02x", $0) }.joined()
    }

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
        if let checkpoint = latest?.syncCheckpoint,
           let boundManifest = checkpoint.archiveManifestSHA256,
           boundManifest != verification.manifestSHA256 {
            throw PhoneArchiveImportError.catalogDiverged
        }
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
                    guard let identity = try Row.fetchOne(db, sql: """
                        SELECT mi.source_install_id, mi.source_epoch,
                               mi.source_local_identifier, mi.media_kind,
                               r.storage_kind, r.source_install_id AS replica_install_id,
                               r.source_epoch AS replica_epoch
                        FROM media_item mi
                        JOIN media_replica r ON r.media_id = mi.id
                        WHERE mi.id = ? AND r.migration_id = ?
                        """, arguments: [mediaKey, migrationKey]),
                          (identity["source_install_id"] as String) == deviceKey,
                          (identity["source_epoch"] as String) == epochKey,
                          (identity["source_local_identifier"] as String) == rowIdentifier,
                          (identity["media_kind"] as String) == rowKind,
                          (identity["storage_kind"] as String) == "macArchive",
                          (identity["replica_install_id"] as String) == deviceKey,
                          (identity["replica_epoch"] as String) == epochKey else {
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
            let catalogReplicas = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM media_replica WHERE migration_id = ?",
                arguments: [migrationKey]
            ) ?? 0
            guard seen.count == verification.itemCount,
                  catalogItems == verification.itemCount,
                  catalogReplicas == verification.itemCount else {
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
        if let boundManifest = snapshot.syncCheckpoint?.archiveManifestSHA256,
           boundManifest != expected.manifestSHA256 {
            throw PhoneArchiveImportError.factScopeMismatch
        }
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

    /// A verified manifest source identity is the only automatic association
    /// between a shared phone directory entry and a committed Mac archive.
    func sourceLinks(
        sourceInstallID: UUID, sourceEpoch: UUID
    ) throws -> [UUID: PhoneArchiveSourceLink] {
        try database.pool.read { db in
            var links: [UUID: PhoneArchiveSourceLink] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.media_id, i.migration_id,
                       i.source_local_identifier, i.media_kind
                FROM migration_import_item i
                JOIN migration_import m ON m.id = i.migration_id
                JOIN media_item mi ON mi.id = i.media_id
                    AND mi.source_install_id = i.source_device_id
                    AND mi.source_epoch = i.source_epoch
                    AND mi.source_local_identifier = i.source_local_identifier
                    AND mi.media_kind = i.media_kind
                JOIN media_replica r ON r.media_id = mi.id
                    AND r.migration_id = i.migration_id
                    AND r.source_install_id = i.source_device_id
                    AND r.source_epoch = i.source_epoch
                    AND r.storage_kind = 'macArchive'
                WHERE i.source_device_id = ? AND i.source_epoch = ?
                  AND m.state = 'catalogCommitted'
                ORDER BY i.media_id
                """, arguments: [
                    sourceInstallID.uuidString.lowercased(), sourceEpoch.uuidString.lowercased(),
                ])
            for row in rows {
                let rawMedia: String = row["media_id"]
                let rawMigration: String = row["migration_id"]
                guard let mediaID = UUID(uuidString: rawMedia),
                      let migrationID = UUID(uuidString: rawMigration),
                      links[mediaID] == nil else {
                    throw PhoneArchiveImportError.catalogDiverged
                }
                links[mediaID] = PhoneArchiveSourceLink(
                    migrationID: migrationID, mediaID: mediaID,
                    sourceLocalIdentifier: row["source_local_identifier"],
                    mediaKind: row["media_kind"]
                )
            }
            return links
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
                        AS apple_album_count,
                       (SELECT COUNT(*) FROM media_asset_binding b
                        WHERE b.media_id = i.media_id) AS asset_binding_count
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
                    appleAlbumCount: row["apple_album_count"],
                    assetBindingCount: row["asset_binding_count"]
                )
            }
        }
    }

    /// Metadata-only search. Matching bytes or filenames never create a binding.
    func assetBindingCandidates(
        migrationID: UUID, mediaID: UUID, search: String
    ) throws -> [PhoneArchiveAssetCandidate] {
        let term = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard term.count >= 2 else { return [] }
        return try database.pool.read { db in
            let kind = try importedMediaKind(db, migrationID: migrationID, mediaID: mediaID)
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.source_id, a.file_name, a.relative_path,
                       a.photos_local_identifier, a.media_type, a.content_revision,
                       a.media_created_at_ms, s.display_name AS source_name,
                       s.updated_at_ms AS source_updated_at_ms,
                       b.media_id AS bound_media_id
                FROM asset a
                JOIN source s ON s.id = a.source_id
                LEFT JOIN media_asset_binding b ON b.asset_id = a.id
                WHERE a.locator_state = 'current' AND a.availability = 'available'
                  AND s.state = 'active'
                  AND (
                    instr(lower(coalesce(a.file_name, '')), lower(?)) > 0
                    OR instr(lower(coalesce(a.relative_path, '')), lower(?)) > 0
                    OR instr(lower(coalesce(a.photos_local_identifier, '')), lower(?)) > 0
                    OR instr(lower(s.display_name), lower(?)) > 0
                    OR lower(a.id) = lower(?)
                  )
                ORDER BY a.media_created_at_ms DESC, a.id
                LIMIT 500
                """, arguments: [term, term, term, term, term])
            return try rows.compactMap { row -> PhoneArchiveAssetCandidate? in
                let mediaType: String = row["media_type"]
                guard Self.assetKind(mediaType) == kind else { return nil }
                let rawID: String = row["id"]
                let rawSourceID: String = row["source_id"]
                guard let id = UUID(uuidString: rawID),
                      let sourceID = UUID(uuidString: rawSourceID) else {
                    throw PhoneArchiveImportError.catalogDiverged
                }
                let fileName: String? = row["file_name"]
                let relativePath: String? = row["relative_path"]
                let photosLocator: String? = row["photos_local_identifier"]
                let boundMedia: String? = row["bound_media_id"]
                return PhoneArchiveAssetCandidate(
                    id: id, sourceID: sourceID,
                    displayName: fileName ?? relativePath?.split(separator: "/").last.map(String.init)
                        ?? "未命名 Mac 资产",
                    sourceName: row["source_name"],
                    sourceUpdatedAtMs: row["source_updated_at_ms"],
                    locatorDescription: relativePath ?? photosLocator ?? rawID,
                    mediaType: mediaType, contentRevision: row["content_revision"],
                    createdAtMs: row["media_created_at_ms"],
                    boundMediaID: boundMedia.flatMap(UUID.init(uuidString:))
                )
            }.prefix(50).map { $0 }
        }
    }

    /// The caller presents both identities and asks for an explicit user action.
    /// This records identity only; existing Mac and phone facts stay independent.
    func confirmAssetBinding(
        migrationID: UUID, mediaID: UUID, candidate: PhoneArchiveAssetCandidate
    ) throws -> PhoneArchiveAssetBindingReceipt {
        try database.pool.write { db in
            let kind = try importedMediaKind(db, migrationID: migrationID, mediaID: mediaID)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT a.source_id, a.file_name, a.relative_path,
                       a.photos_local_identifier, a.media_type, a.content_revision,
                       a.media_created_at_ms, s.display_name AS source_name,
                       s.updated_at_ms AS source_updated_at_ms
                FROM asset a JOIN source s ON s.id = a.source_id
                WHERE a.id = ? AND a.locator_state = 'current'
                  AND a.availability = 'available' AND s.state = 'active'
                """, arguments: [candidate.id.uuidString.lowercased()]) else {
                throw PhoneArchiveImportError.assetBindingCandidateChanged
            }
            let mediaType: String = row["media_type"]
            guard Self.assetKind(mediaType) == kind else {
                throw PhoneArchiveImportError.assetKindMismatch
            }
            let sourceID: String = row["source_id"]
            let fileName: String? = row["file_name"]
            let relativePath: String? = row["relative_path"]
            let photosLocator: String? = row["photos_local_identifier"]
            let revision: Int64 = row["content_revision"]
            let createdAtMs: Int64? = row["media_created_at_ms"]
            let sourceName: String = row["source_name"]
            let sourceUpdatedAtMs: Int64 = row["source_updated_at_ms"]
            guard sourceID == candidate.sourceID.uuidString.lowercased(),
                  (fileName ?? relativePath?.split(separator: "/").last.map(String.init)
                    ?? "未命名 Mac 资产") == candidate.displayName,
                  (relativePath ?? photosLocator ?? candidate.id.uuidString.lowercased())
                    == candidate.locatorDescription,
                  mediaType == candidate.mediaType,
                  revision == candidate.contentRevision,
                  createdAtMs == candidate.createdAtMs,
                  sourceName == candidate.sourceName,
                  sourceUpdatedAtMs == candidate.sourceUpdatedAtMs else {
                throw PhoneArchiveImportError.assetBindingCandidateChanged
            }
            let existing: String? = try String.fetchOne(db, sql: """
                SELECT media_id FROM media_asset_binding WHERE asset_id = ?
                """, arguments: [candidate.id.uuidString.lowercased()])
            if let existing {
                guard existing == mediaID.uuidString.lowercased() else {
                    throw PhoneArchiveImportError.assetAlreadyBound
                }
                return PhoneArchiveAssetBindingReceipt(
                    mediaID: mediaID, assetID: candidate.id, replayed: true
                )
            }
            let confirmedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
            try db.execute(sql: """
                INSERT INTO media_asset_binding (
                    media_id, asset_id, evidence_kind, created_at_ms
                ) VALUES (?, ?, 'userConfirmed', ?)
                """, arguments: [
                    mediaID.uuidString.lowercased(), candidate.id.uuidString.lowercased(),
                    confirmedAtMs,
                ])
            try db.execute(sql: """
                INSERT INTO media_asset_binding_event (
                    id, media_id, asset_id, event_kind, confirmed_event_id, created_at_ms
                ) VALUES (?, ?, ?, 'confirmed', NULL, ?)
                """, arguments: [
                    UUID().uuidString.lowercased(), mediaID.uuidString.lowercased(),
                    candidate.id.uuidString.lowercased(),
                    confirmedAtMs,
                ])
            return PhoneArchiveAssetBindingReceipt(
                mediaID: mediaID, assetID: candidate.id, replayed: false
            )
        }
    }

    func revokeAssetBinding(
        migrationID: UUID, mediaID: UUID, assetID: UUID, confirmationEventID: UUID
    ) throws -> PhoneArchiveAssetBindingReceipt {
        try database.pool.write { db in
            _ = try importedMediaKind(db, migrationID: migrationID, mediaID: mediaID)
            let media = mediaID.uuidString.lowercased()
            let asset = assetID.uuidString.lowercased()
            let confirmation = confirmationEventID.uuidString.lowercased()
            guard let event = try Row.fetchOne(db, sql: """
                SELECT id, event_kind, confirmed_event_id
                FROM media_asset_binding_event
                WHERE media_id = ? AND asset_id = ?
                ORDER BY sequence DESC LIMIT 1
                """, arguments: [media, asset]) else {
                throw PhoneArchiveImportError.assetBindingCandidateChanged
            }
            let active: String? = try String.fetchOne(db, sql: """
                SELECT media_id FROM media_asset_binding WHERE asset_id = ?
                """, arguments: [asset])
            if let active, active != media {
                throw PhoneArchiveImportError.assetAlreadyBound
            }
            let eventKind: String = event["event_kind"]
            let eventID: String = event["id"]
            if active == nil {
                let priorConfirmation: String? = event["confirmed_event_id"]
                guard eventKind == "revoked", priorConfirmation == confirmation else {
                    throw PhoneArchiveImportError.assetBindingCandidateChanged
                }
                return PhoneArchiveAssetBindingReceipt(
                    mediaID: mediaID, assetID: assetID, replayed: true
                )
            }
            guard eventKind == "confirmed", eventID == confirmation else {
                throw PhoneArchiveImportError.assetBindingCandidateChanged
            }
            try db.execute(sql: """
                DELETE FROM media_asset_binding WHERE media_id = ? AND asset_id = ?
                """, arguments: [media, asset])
            try db.execute(sql: """
                INSERT INTO media_asset_binding_event (
                    id, media_id, asset_id, event_kind, confirmed_event_id, created_at_ms
                ) VALUES (?, ?, ?, 'revoked', ?, ?)
                """, arguments: [
                    UUID().uuidString.lowercased(), media, asset, confirmation,
                    Int64(Date().timeIntervalSince1970 * 1_000),
                ])
            return PhoneArchiveAssetBindingReceipt(
                mediaID: mediaID, assetID: assetID, replayed: false
            )
        }
    }

    func boundAssets(migrationID: UUID, mediaID: UUID) throws -> [PhoneArchiveBoundAsset] {
        try database.pool.read { db in
            _ = try importedMediaKind(db, migrationID: migrationID, mediaID: mediaID)
            return try Row.fetchAll(db, sql: """
                SELECT a.id, a.file_name, a.relative_path,
                       a.photos_local_identifier, s.display_name AS source_name,
                       b.evidence_kind, b.created_at_ms,
                       e.id AS confirmation_event_id, e.event_kind
                FROM media_asset_binding b
                JOIN asset a ON a.id = b.asset_id
                JOIN source s ON s.id = a.source_id
                LEFT JOIN media_asset_binding_event e ON e.sequence = (
                    SELECT MAX(last.sequence) FROM media_asset_binding_event last
                    WHERE last.media_id = b.media_id AND last.asset_id = b.asset_id
                )
                WHERE b.media_id = ? ORDER BY b.created_at_ms, a.id
                """, arguments: [mediaID.uuidString.lowercased()]).map { row in
                let rawID: String = row["id"]
                let rawConfirmation: String? = row["confirmation_event_id"]
                let eventKind: String? = row["event_kind"]
                guard let id = UUID(uuidString: rawID),
                      let rawConfirmation,
                      let confirmationEventID = UUID(uuidString: rawConfirmation),
                      eventKind == "confirmed" else {
                    throw PhoneArchiveImportError.catalogDiverged
                }
                let fileName: String? = row["file_name"]
                let relativePath: String? = row["relative_path"]
                let photosLocator: String? = row["photos_local_identifier"]
                return PhoneArchiveBoundAsset(
                    id: id,
                    displayName: fileName ?? relativePath?.split(separator: "/").last.map(String.init)
                        ?? "未命名 Mac 资产",
                    sourceName: row["source_name"],
                    locatorDescription: relativePath ?? photosLocator ?? rawID,
                    evidenceKind: row["evidence_kind"], createdAtMs: row["created_at_ms"],
                    confirmationEventID: confirmationEventID
                )
            }
        }
    }

    func confirmTagAlias(
        migrationID: UUID, mediaID: UUID, assetID: UUID,
        phoneTagID: UUID, phoneTagName: String, macTagID: UUID,
        macTagUpdatedAtMs: Int64, expectedFactSnapshotSequence: Int64
    ) throws -> PhoneArchiveTagAliasReceipt {
        try database.pool.write { db in
            let scope = try boundTagAliasScope(
                db, migrationID: migrationID, mediaID: mediaID, assetID: assetID
            )
            guard scope.snapshotSequence == expectedFactSnapshotSequence,
                  let storedPhoneName = try String.fetchOne(db, sql: """
                    SELECT tag_name FROM migration_import_tag_decision
                    WHERE source_device_id = ? AND source_epoch = ?
                      AND media_id = ? AND tag_id = ?
                    """, arguments: [
                        scope.install, scope.epoch, mediaID.uuidString.lowercased(),
                        phoneTagID.uuidString.lowercased(),
                    ]), storedPhoneName == phoneTagName,
                  phoneTagID != macTagID else {
                throw PhoneArchiveImportError.tagAliasCandidateChanged
            }
            let phone = phoneTagID.uuidString.lowercased()
            let mac = macTagID.uuidString.lowercased()
            let exactMacTagForPhone: String? = try String.fetchOne(db, sql: """
                SELECT id FROM tag WHERE id = ?
                """, arguments: [phone])
            let phoneTagAlreadyUsingMacID: String? = try String.fetchOne(db, sql: """
                SELECT tag_id FROM migration_import_tag_decision
                WHERE source_device_id = ? AND source_epoch = ? AND tag_id = ?
                  AND tag_id != ? LIMIT 1
                """, arguments: [scope.install, scope.epoch, mac, phone])
            guard exactMacTagForPhone == nil,
                  phoneTagAlreadyUsingMacID == nil else {
                throw PhoneArchiveImportError.tagAliasAlreadyMapped
            }
            let existing: String? = try String.fetchOne(db, sql: """
                SELECT mac_tag_id FROM phone_tag_alias
                WHERE source_install_id = ? AND source_epoch = ? AND phone_tag_id = ?
                """, arguments: [scope.install, scope.epoch, phone])
            if let existing {
                guard existing == mac else { throw PhoneArchiveImportError.tagAliasAlreadyMapped }
                return PhoneArchiveTagAliasReceipt(
                    phoneTagID: phoneTagID, macTagID: macTagID, replayed: true
                )
            }
            let claimedPhone: String? = try String.fetchOne(db, sql: """
                SELECT phone_tag_id FROM phone_tag_alias
                WHERE source_install_id = ? AND source_epoch = ? AND mac_tag_id = ?
                """, arguments: [scope.install, scope.epoch, mac])
            guard claimedPhone == nil else { throw PhoneArchiveImportError.tagAliasAlreadyMapped }
            guard case let .success(phoneName) = TagNameNormalizer.validateAndNormalize(phoneTagName),
                  let macTag = try Self.macTags(db, matching: "tag.id = ?", value: mac).first,
                  (macTag["state"] as String) == "active",
                  (macTag["updated_at_ms"] as Int64) == macTagUpdatedAtMs,
                  (macTag["effective_name"] as String) == phoneName.normalizedName else {
                throw PhoneArchiveImportError.tagAliasCandidateChanged
            }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            try db.execute(sql: """
                INSERT INTO phone_tag_alias (
                    source_install_id, source_epoch, phone_tag_id, mac_tag_id,
                    confirmed_phone_name, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    scope.install, scope.epoch, phone, mac, phoneTagName, now,
                ])
            try db.execute(sql: """
                INSERT INTO phone_tag_alias_event (
                    id, source_install_id, source_epoch, phone_tag_id, mac_tag_id,
                    event_kind, confirmed_event_id, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, 'confirmed', NULL, ?)
                """, arguments: [
                    UUID().uuidString.lowercased(), scope.install, scope.epoch,
                    phone, mac, now,
                ])
            return PhoneArchiveTagAliasReceipt(
                phoneTagID: phoneTagID, macTagID: macTagID, replayed: false
            )
        }
    }

    func revokeTagAlias(
        migrationID: UUID, mediaID: UUID, assetID: UUID,
        phoneTagID: UUID, macTagID: UUID, confirmationEventID: UUID
    ) throws -> PhoneArchiveTagAliasReceipt {
        try database.pool.write { db in
            let scope = try boundTagAliasScope(
                db, migrationID: migrationID, mediaID: mediaID, assetID: assetID
            )
            let phone = phoneTagID.uuidString.lowercased()
            let mac = macTagID.uuidString.lowercased()
            let current: String? = try String.fetchOne(db, sql: """
                SELECT mac_tag_id FROM phone_tag_alias
                WHERE source_install_id = ? AND source_epoch = ? AND phone_tag_id = ?
                """, arguments: [scope.install, scope.epoch, phone])
            if let current, current != mac { throw PhoneArchiveImportError.tagAliasAlreadyMapped }
            guard let event = try Row.fetchOne(db, sql: """
                SELECT id, mac_tag_id, event_kind, confirmed_event_id
                FROM phone_tag_alias_event
                WHERE source_install_id = ? AND source_epoch = ? AND phone_tag_id = ?
                ORDER BY sequence DESC LIMIT 1
                """, arguments: [scope.install, scope.epoch, phone]) else {
                throw PhoneArchiveImportError.tagAliasCandidateChanged
            }
            let eventKind: String = event["event_kind"]
            let eventID: String = event["id"]
            let eventMac: String = event["mac_tag_id"]
            let confirmation = confirmationEventID.uuidString.lowercased()
            guard eventMac == mac else {
                throw PhoneArchiveImportError.tagAliasCandidateChanged
            }
            if current == nil {
                let priorConfirmation: String? = event["confirmed_event_id"]
                guard eventKind == "revoked", priorConfirmation == confirmation else {
                    throw PhoneArchiveImportError.tagAliasCandidateChanged
                }
                return PhoneArchiveTagAliasReceipt(
                    phoneTagID: phoneTagID, macTagID: macTagID, replayed: true
                )
            }
            guard eventKind == "confirmed", eventID == confirmation else {
                throw PhoneArchiveImportError.tagAliasCandidateChanged
            }
            try db.execute(sql: """
                DELETE FROM phone_tag_alias
                WHERE source_install_id = ? AND source_epoch = ? AND phone_tag_id = ?
                """, arguments: [scope.install, scope.epoch, phone])
            try db.execute(sql: """
                INSERT INTO phone_tag_alias_event (
                    id, source_install_id, source_epoch, phone_tag_id, mac_tag_id,
                    event_kind, confirmed_event_id, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, 'revoked', ?, ?)
                """, arguments: [
                    UUID().uuidString.lowercased(), scope.install, scope.epoch,
                    phone, mac, confirmation, Int64(Date().timeIntervalSince1970 * 1_000),
                ])
            return PhoneArchiveTagAliasReceipt(
                phoneTagID: phoneTagID, macTagID: macTagID, replayed: false
            )
        }
    }

    private func boundTagAliasScope(
        _ db: Database, migrationID: UUID, mediaID: UUID, assetID: UUID
    ) throws -> (install: String, epoch: String, snapshotSequence: Int64) {
        _ = try importedMediaKind(db, migrationID: migrationID, mediaID: mediaID)
        guard let row = try Row.fetchOne(db, sql: """
            SELECT i.source_device_id, i.source_epoch, m.fact_snapshot_sequence,
                   (SELECT e.event_kind FROM media_asset_binding_event e
                    WHERE e.media_id = i.media_id AND e.asset_id = ?
                    ORDER BY e.sequence DESC LIMIT 1) AS latest_binding_event
            FROM migration_import_item i
            JOIN migration_import m ON m.id = i.migration_id
            JOIN media_asset_binding b ON b.media_id = i.media_id AND b.asset_id = ?
            WHERE i.migration_id = ? AND i.media_id = ?
              AND m.state = 'catalogCommitted'
            """, arguments: [
                assetID.uuidString.lowercased(), assetID.uuidString.lowercased(),
                migrationID.uuidString.lowercased(),
                mediaID.uuidString.lowercased(),
            ]) else {
            throw PhoneArchiveImportError.assetBindingCandidateChanged
        }
        let latestBindingEvent: String? = row["latest_binding_event"]
        guard latestBindingEvent == "confirmed" else {
            throw PhoneArchiveImportError.catalogDiverged
        }
        return (
            install: row["source_device_id"], epoch: row["source_epoch"],
            snapshotSequence: row["fact_snapshot_sequence"]
        )
    }

    /// Compares the stored phone archive facts with one explicitly bound Mac
    /// Asset in a single catalog snapshot. This is historical archive evidence,
    /// not proof that the phone's live shared ledger has reached this watermark.
    func compareBoundAssetFacts(
        migrationID: UUID, mediaID: UUID, assetID: UUID
    ) throws -> PhoneArchiveBoundFactComparison {
        try database.pool.read { db in
            try compareBoundAssetFacts(
                in: db, migrationID: migrationID, mediaID: mediaID, assetID: assetID
            )
        }
    }

    private func compareBoundAssetFacts(
        in db: Database, migrationID: UUID, mediaID: UUID, assetID: UUID
    ) throws -> PhoneArchiveBoundFactComparison {
            _ = try importedMediaKind(db, migrationID: migrationID, mediaID: mediaID)
            let migration = migrationID.uuidString.lowercased()
            let media = mediaID.uuidString.lowercased()
            let asset = assetID.uuidString.lowercased()
            guard let binding = try Row.fetchOne(db, sql: """
                SELECT i.source_device_id, i.source_epoch,
                       m.fact_snapshot_sequence,
                       (SELECT e.id FROM media_asset_binding_event e
                        WHERE e.media_id = i.media_id AND e.asset_id = ?
                        ORDER BY e.sequence DESC LIMIT 1) AS latest_event_id,
                       (SELECT e.event_kind FROM media_asset_binding_event e
                        WHERE e.media_id = i.media_id AND e.asset_id = ?
                        ORDER BY e.sequence DESC LIMIT 1) AS latest_event_kind
                FROM migration_import_item i
                JOIN migration_import m ON m.id = i.migration_id
                JOIN media_asset_binding b ON b.media_id = i.media_id
                    AND b.asset_id = ?
                WHERE i.migration_id = ? AND i.media_id = ?
                  AND m.state = 'catalogCommitted'
                """, arguments: [asset, asset, asset, migration, media]) else {
                throw PhoneArchiveImportError.assetBindingCandidateChanged
            }
            let latestEvent: String? = binding["latest_event_kind"]
            let latestEventID: String? = binding["latest_event_id"]
            guard latestEvent == "confirmed",
                  let bindingConfirmationEventID = latestEventID.flatMap(UUID.init(uuidString:)) else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            let install: String = binding["source_device_id"]
            let epoch: String = binding["source_epoch"]
            guard let sourceInstallID = UUID(uuidString: install),
                  let sourceEpoch = UUID(uuidString: epoch) else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            let phoneTags = try Row.fetchAll(db, sql: """
                SELECT tag_id, tag_name, decision
                FROM migration_import_tag_decision
                WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
                ORDER BY tag_id
                """, arguments: [install, epoch, media])
            var representedMacTagIDs = Set<String>()
            let comparisons = try phoneTags.map { row -> PhoneArchiveTagComparison in
                let rawPhoneID: String = row["tag_id"]
                let phoneName: String = row["tag_name"]
                let rawDecision: String = row["decision"]
                guard let phoneID = UUID(uuidString: rawPhoneID),
                      let phoneDecision = RemoteLocalLibraryDecision(rawValue: rawDecision) else {
                    throw PhoneArchiveImportError.catalogDiverged
                }
                let normalized: String?
                switch TagNameNormalizer.validateAndNormalize(phoneName) {
                case .success(let parts): normalized = parts.normalizedName
                case .failure: normalized = nil
                }
                let aliasMacID: String? = try String.fetchOne(db, sql: """
                    SELECT mac_tag_id FROM phone_tag_alias
                    WHERE source_install_id = ? AND source_epoch = ? AND phone_tag_id = ?
                    """, arguments: [install, epoch, rawPhoneID])
                let idMatches = try Self.macTags(
                    db, matching: "tag.id = ?", value: aliasMacID ?? rawPhoneID
                )
                let matched: Row?
                let state: PhoneArchiveTagComparisonState?
                if let aliasMacID {
                    guard let exact = idMatches.first,
                          (exact["id"] as String) == aliasMacID else {
                        throw PhoneArchiveImportError.catalogDiverged
                    }
                    matched = exact
                    let effectiveName: String = exact["effective_name"]
                    state = normalized == effectiveName ? nil : .nameDiffers
                } else if let exact = idMatches.first {
                    matched = exact
                    let effectiveName: String = exact["effective_name"]
                    state = normalized == effectiveName ? nil : .identityConflict
                } else if let normalized {
                    let nameMatches = try Self.macTags(
                        db, matching: "coalesce(concept.normalized_name, tag.normalized_name) = ?",
                        value: normalized
                    )
                    matched = nameMatches.count == 1 ? nameMatches[0] : nil
                    state = nameMatches.count > 1 ? .identityConflict
                        : (matched == nil ? .macTagMissing : .nameAliasRequired)
                } else {
                    matched = nil
                    state = .identityConflict
                }
                let rawMacID: String? = matched?["id"]
                let aliasConfirmationEventID: UUID?
                if aliasMacID != nil {
                    guard let event = try Row.fetchOne(db, sql: """
                        SELECT id, event_kind FROM phone_tag_alias_event
                        WHERE source_install_id = ? AND source_epoch = ?
                          AND phone_tag_id = ? ORDER BY sequence DESC LIMIT 1
                        """, arguments: [install, epoch, rawPhoneID]),
                          (event["event_kind"] as String) == "confirmed",
                          let parsed = UUID(uuidString: event["id"]) else {
                        throw PhoneArchiveImportError.catalogDiverged
                    }
                    aliasConfirmationEventID = parsed
                } else {
                    aliasConfirmationEventID = nil
                }
                if let rawMacID { representedMacTagIDs.insert(rawMacID) }
                let macDecisionRow: Row? = try rawMacID.flatMap { id in
                    try Row.fetchOne(db, sql: """
                        SELECT decision, updated_at_ms FROM asset_tag_decision
                        WHERE asset_id = ? AND tag_id = ?
                        """, arguments: [asset, id])
                }
                let macDecision: String? = macDecisionRow?["decision"]
                let macDecisionRevision: Int64? = try rawMacID.map { id in
                    try Int64.fetchOne(db, sql: """
                        SELECT revision FROM asset_tag_decision_revision
                        WHERE asset_id = ? AND tag_id = ?
                        """, arguments: [asset, id]) ?? 0
                }
                let macState: String? = matched?["state"]
                let resultState: PhoneArchiveTagComparisonState
                if let state {
                    resultState = state
                } else if macState == "archived" {
                    resultState = .macTagArchived
                } else if macDecision == (phoneDecision == .cleared ? nil : phoneDecision.rawValue) {
                    resultState = .same
                } else if macDecision == nil {
                    resultState = .macDecisionMissing
                } else {
                    resultState = .decisionDiffers
                }
                return PhoneArchiveTagComparison(
                    phoneTagID: phoneID, phoneTagName: phoneName,
                    phoneDecision: phoneDecision,
                    macTagID: rawMacID.flatMap(UUID.init(uuidString:)),
                    macTagName: matched?["name"],
                    macTagUpdatedAtMs: matched?["updated_at_ms"],
                    macDecision: macDecision,
                    macDecisionUpdatedAtMs: macDecisionRow?["updated_at_ms"],
                    macDecisionRevision: macDecisionRevision,
                    state: resultState,
                    aliasConfirmationEventID: aliasConfirmationEventID
                )
            }
            let macOnly = try Row.fetchAll(db, sql: """
                SELECT t.id, t.name, d.decision
                FROM asset_tag_decision d JOIN tag t ON t.id = d.tag_id
                WHERE d.asset_id = ? ORDER BY t.normalized_name, t.id
                """, arguments: [asset]).compactMap { row -> PhoneArchiveMacOnlyTagDecision? in
                let rawID: String = row["id"]
                guard !representedMacTagIDs.contains(rawID),
                      let id = UUID(uuidString: rawID) else { return nil }
                return PhoneArchiveMacOnlyTagDecision(
                    tagID: id, tagName: row["name"], decision: row["decision"]
                )
            }
            let phoneFavoriteRaw: Int? = try Int.fetchOne(db, sql: """
                SELECT favorite_target FROM migration_import_item
                WHERE migration_id = ? AND media_id = ?
                """, arguments: [migration, media])
            let macFavoriteRaw: Int? = try Int.fetchOne(db, sql: """
                SELECT desired_value FROM asset_favorite_state WHERE asset_id = ?
                """, arguments: [asset])
            let phoneCollections = try String.fetchAll(db, sql: """
                SELECT collection_name FROM migration_import_collection
                WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
                  AND included = 1 ORDER BY collection_id
                """, arguments: [install, epoch, media])
            let phoneAlbums = try String.fetchAll(db, sql: """
                SELECT coalesce(album_title, '未命名相册')
                FROM migration_import_apple_album_member
                WHERE migration_id = ? AND media_id = ?
                ORDER BY album_local_identifier
                """, arguments: [migration, media])
            return PhoneArchiveBoundFactComparison(
                sourceInstallID: sourceInstallID, sourceEpoch: sourceEpoch,
                bindingConfirmationEventID: bindingConfirmationEventID,
                factSnapshotSequence: binding["fact_snapshot_sequence"],
                tags: comparisons, macOnlyTags: macOnly,
                phoneFavoriteTarget: phoneFavoriteRaw.map { $0 == 1 },
                macFavoriteTarget: macFavoriteRaw.map { $0 == 1 },
                phoneCollectionNames: phoneCollections,
                phoneAppleAlbumNames: phoneAlbums
            )
    }

    /// Rechecks the catalog half of an explicit Mac-to-phone tag decision.
    /// The phone ledger's field revision is checked separately by its atomic writer.
    func validateBoundMacTagDecision(
        migrationID: UUID, mediaID: UUID, assetID: UUID,
        expectedComparison: PhoneArchiveBoundFactComparison,
        expectedTag: PhoneArchiveTagComparison
    ) throws -> RemoteLocalLibraryDecision {
        let current = try compareBoundAssetFacts(
            migrationID: migrationID, mediaID: mediaID, assetID: assetID
        )
        guard current.sourceInstallID == expectedComparison.sourceInstallID,
              current.sourceEpoch == expectedComparison.sourceEpoch,
              current.bindingConfirmationEventID == expectedComparison.bindingConfirmationEventID,
              current.factSnapshotSequence == expectedComparison.factSnapshotSequence,
              let tag = current.tags.first(where: { $0.phoneTagID == expectedTag.phoneTagID }),
              tag.phoneTagName == expectedTag.phoneTagName,
              tag.macTagID == expectedTag.macTagID,
              tag.macTagName == expectedTag.macTagName,
              tag.macTagUpdatedAtMs == expectedTag.macTagUpdatedAtMs,
              tag.macDecision == expectedTag.macDecision,
              tag.macDecisionUpdatedAtMs == expectedTag.macDecisionUpdatedAtMs,
              tag.macDecisionRevision == expectedTag.macDecisionRevision,
              tag.aliasConfirmationEventID == expectedTag.aliasConfirmationEventID,
              tag.state == expectedTag.state,
              tag.state == .same || tag.state == .decisionDiffers,
              let rawDecision = tag.macDecision,
              let decision = RemoteLocalLibraryDecision(rawValue: rawDecision),
              decision != .cleared else {
            throw PhoneArchiveImportError.tagSyncCandidateChanged
        }
        return decision
    }

    func outboundTagIntents(
        migrationID: UUID, mediaID: UUID, assetID: UUID
    ) throws -> [PhoneArchiveMacTagOutboundIntent] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM phone_tag_mac_outbound_intent
                WHERE migration_id = ? AND media_id = ? AND asset_id = ?
                  AND state != 'committed'
                ORDER BY created_at_ms, id
                """, arguments: [
                    migrationID.uuidString.lowercased(),
                    mediaID.uuidString.lowercased(), assetID.uuidString.lowercased(),
                ]).map(Self.outboundTagIntent(from:))
        }
    }

    /// Startup recovery only acknowledges a proven JSON commit. An intent with
    /// no receipt remains prepared for explicit version checked retry in the UI.
    func recoverPreparedOutboundMacTagDecisions(
        receiptFor: @escaping @Sendable (UUID, UUID) async throws
            -> RemoteLocalLibrarySyncStore.MacTagOperationReceipt?
    ) async throws -> PhoneArchiveMacTagRecoveryResult {
        let pending = try await database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM phone_tag_mac_outbound_intent
                WHERE state = 'prepared' ORDER BY created_at_ms, id
                """).map(Self.outboundTagIntent(from:))
        }
        var committed = 0
        var failedVerification = 0
        for intent in pending {
            do {
                guard let receipt = try await receiptFor(intent.phoneDeviceID, intent.id) else {
                    continue
                }
                _ = try finalizeOutboundMacTagDecision(
                    operationID: intent.id, receipt: receipt,
                    timestampMs: Int64(Date().timeIntervalSince1970 * 1_000)
                )
                committed += 1
            } catch {
                // Retain prepared: a missing or mismatched receipt cannot prove a commit.
                failedVerification += 1
            }
        }
        return PhoneArchiveMacTagRecoveryResult(
            prepared: pending.count, committed: committed,
            stillPending: pending.count - committed,
            failedVerification: failedVerification
        )
    }

    /// Persists the SQLite half before touching the independent JSON ledger.
    /// Pending intents block another submission for the same source field.
    func prepareOutboundMacTagDecision(
        operationID: UUID, migrationID: UUID, mediaID: UUID, assetID: UUID,
        expectedComparison: PhoneArchiveBoundFactComparison,
        expectedTag: PhoneArchiveTagComparison,
        phoneDeviceID: UUID, phoneScopeRevision: Int64,
        sharedFact: RemoteLocalLibrarySyncStore.SharedTagFact,
        timestampMs: Int64
    ) throws -> PhoneArchiveMacTagOutboundIntent {
        guard timestampMs >= 0, phoneScopeRevision >= 0,
              sharedFact.assetID == mediaID,
              sharedFact.tagID == expectedTag.phoneTagID,
              sharedFact.revision > 0,
              let macTagID = expectedTag.macTagID else {
            throw PhoneArchiveImportError.tagSyncCandidateChanged
        }
        return try database.pool.write { db in
            if let existing = try Row.fetchOne(db, sql: """
                SELECT * FROM phone_tag_mac_outbound_intent WHERE id = ?
                """, arguments: [operationID.uuidString.lowercased()]) {
                let intent = try Self.outboundTagIntent(from: existing)
                guard intent.migrationID == migrationID, intent.mediaID == mediaID,
                      intent.assetID == assetID,
                      intent.bindingConfirmationEventID ==
                          expectedComparison.bindingConfirmationEventID,
                      intent.sourceInstallID == expectedComparison.sourceInstallID,
                      intent.sourceEpoch == expectedComparison.sourceEpoch,
                      intent.phoneDeviceID == phoneDeviceID,
                      intent.phoneScopeRevision == phoneScopeRevision,
                      intent.phoneTagID == expectedTag.phoneTagID,
                      intent.macTagID == macTagID,
                      intent.phoneExpectedRevision == sharedFact.revision,
                      intent.phoneExpectedDecision == sharedFact.decision,
                      intent.desiredDecision.rawValue == expectedTag.macDecision else {
                    throw PhoneArchiveImportError.tagSyncCandidateChanged
                }
                return intent
            }
            let current = try compareBoundAssetFacts(
                in: db, migrationID: migrationID, mediaID: mediaID, assetID: assetID
            )
            guard current.sourceInstallID == expectedComparison.sourceInstallID,
                  current.sourceEpoch == expectedComparison.sourceEpoch,
                  current.bindingConfirmationEventID ==
                      expectedComparison.bindingConfirmationEventID,
                  current.factSnapshotSequence == expectedComparison.factSnapshotSequence,
                  let tag = current.tags.first(where: {
                      $0.phoneTagID == expectedTag.phoneTagID
                  }),
                  tag.phoneTagName == expectedTag.phoneTagName,
                  tag.macTagID == macTagID,
                  tag.macTagName == expectedTag.macTagName,
                  tag.macTagUpdatedAtMs == expectedTag.macTagUpdatedAtMs,
                  tag.macDecision == expectedTag.macDecision,
                  tag.macDecisionUpdatedAtMs == expectedTag.macDecisionUpdatedAtMs,
                  tag.macDecisionRevision == expectedTag.macDecisionRevision,
                  tag.aliasConfirmationEventID == expectedTag.aliasConfirmationEventID,
                  tag.state == expectedTag.state,
                  tag.state == .same || tag.state == .decisionDiffers,
                  let rawDecision = tag.macDecision,
                  let desired = RemoteLocalLibraryDecision(rawValue: rawDecision),
                  desired != sharedFact.decision else {
                throw PhoneArchiveImportError.tagSyncCandidateChanged
            }
            guard try String.fetchOne(db, sql: """
                SELECT id FROM phone_tag_mac_outbound_intent
                WHERE source_install_id = ? AND source_epoch = ?
                  AND media_id = ? AND phone_tag_id = ? AND state = 'prepared'
                LIMIT 1
                """, arguments: [
                    current.sourceInstallID.uuidString.lowercased(),
                    current.sourceEpoch.uuidString.lowercased(),
                    mediaID.uuidString.lowercased(),
                    tag.phoneTagID.uuidString.lowercased(),
                ]) == nil else {
                throw PhoneArchiveImportError.tagSyncPending
            }
            try db.execute(sql: """
                INSERT INTO phone_tag_mac_outbound_intent (
                    id, migration_id, media_id, asset_id,
                    binding_confirmation_event_id, source_install_id, source_epoch,
                    phone_device_id, phone_scope_revision, phone_tag_id, phone_tag_name,
                    mac_tag_id, mac_expected_revision, mac_expected_decision,
                    phone_expected_revision, phone_expected_decision,
                    desired_decision, state, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?)
                """, arguments: [
                    operationID.uuidString.lowercased(),
                    migrationID.uuidString.lowercased(), mediaID.uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    current.bindingConfirmationEventID.uuidString.lowercased(),
                    current.sourceInstallID.uuidString.lowercased(),
                    current.sourceEpoch.uuidString.lowercased(),
                    phoneDeviceID.uuidString.lowercased(), phoneScopeRevision,
                    tag.phoneTagID.uuidString.lowercased(), sharedFact.tagName,
                    macTagID.uuidString.lowercased(), tag.macDecisionRevision ?? 0,
                    desired.rawValue, sharedFact.revision,
                    sharedFact.decision.rawValue, desired.rawValue, timestampMs,
                ])
            guard let inserted = try Row.fetchOne(db, sql: """
                SELECT * FROM phone_tag_mac_outbound_intent WHERE id = ?
                """, arguments: [operationID.uuidString.lowercased()]) else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            return try Self.outboundTagIntent(from: inserted)
        }
    }

    func finalizeOutboundMacTagDecision(
        operationID: UUID,
        receipt: RemoteLocalLibrarySyncStore.MacTagOperationReceipt,
        timestampMs: Int64
    ) throws -> PhoneArchiveMacTagOutboundIntent {
        guard timestampMs >= 0 else { throw PhoneArchiveImportError.catalogDiverged }
        return try database.pool.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM phone_tag_mac_outbound_intent WHERE id = ?
                """, arguments: [operationID.uuidString.lowercased()]) else {
                throw PhoneArchiveImportError.missingImportJournal
            }
            let intent = try Self.outboundTagIntent(from: row)
            guard receipt.operationID == operationID,
                  receipt.deviceID == intent.phoneDeviceID,
                  receipt.installID == intent.sourceInstallID,
                  receipt.sourceEpoch == intent.sourceEpoch,
                  receipt.scopeRevision == intent.phoneScopeRevision,
                  receipt.assetID == intent.mediaID,
                  receipt.tagID == intent.phoneTagID,
                  receipt.decision == intent.desiredDecision,
                  receipt.expectedRevision == intent.phoneExpectedRevision,
                  receipt.resultingRevision == receipt.expectedRevision + 1 else {
                throw PhoneArchiveImportError.tagSyncCandidateChanged
            }
            if intent.state == .committed {
                guard intent.phoneResultingRevision == receipt.resultingRevision,
                      intent.phoneChangeSequence == receipt.changeSequence else {
                    throw PhoneArchiveImportError.catalogDiverged
                }
                return intent
            }
            guard intent.state == .prepared else {
                throw PhoneArchiveImportError.tagSyncCandidateChanged
            }
            try db.execute(sql: """
                UPDATE phone_tag_mac_outbound_intent
                SET state = 'committed', phone_resulting_revision = ?,
                    phone_change_sequence = ?, resolved_at_ms = ?
                WHERE id = ? AND state = 'prepared'
                """, arguments: [
                    receipt.resultingRevision, receipt.changeSequence,
                    max(timestampMs, intent.createdAtMs),
                    operationID.uuidString.lowercased(),
                ])
            guard let updated = try Row.fetchOne(db, sql: """
                SELECT * FROM phone_tag_mac_outbound_intent WHERE id = ?
                """, arguments: [operationID.uuidString.lowercased()]) else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            return try Self.outboundTagIntent(from: updated)
        }
    }

    func markOutboundMacTagConflict(
        operationID: UUID, timestampMs: Int64
    ) throws {
        guard timestampMs >= 0 else { throw PhoneArchiveImportError.catalogDiverged }
        try database.pool.write { db in
            try db.execute(sql: """
                UPDATE phone_tag_mac_outbound_intent
                SET state = 'conflict', resolved_at_ms = max(?, created_at_ms)
                WHERE id = ? AND state = 'prepared'
                """, arguments: [timestampMs, operationID.uuidString.lowercased()])
        }
    }

    private static func outboundTagIntent(
        from row: Row
    ) throws -> PhoneArchiveMacTagOutboundIntent {
        let rawMacDecision: String = row["mac_expected_decision"]
        let rawPhoneDecision: String = row["phone_expected_decision"]
        let rawDesiredDecision: String = row["desired_decision"]
        let rawState: String = row["state"]
        guard let id = UUID(uuidString: row["id"]),
              let migrationID = UUID(uuidString: row["migration_id"]),
              let mediaID = UUID(uuidString: row["media_id"]),
              let assetID = UUID(uuidString: row["asset_id"]),
              let bindingID = UUID(uuidString: row["binding_confirmation_event_id"]),
              let sourceInstallID = UUID(uuidString: row["source_install_id"]),
              let sourceEpoch = UUID(uuidString: row["source_epoch"]),
              let phoneDeviceID = UUID(uuidString: row["phone_device_id"]),
              let phoneTagID = UUID(uuidString: row["phone_tag_id"]),
              let macTagID = UUID(uuidString: row["mac_tag_id"]),
              let macExpectedDecision = RemoteLocalLibraryDecision(rawValue: rawMacDecision),
              let phoneExpectedDecision = RemoteLocalLibraryDecision(rawValue: rawPhoneDecision),
              let desiredDecision = RemoteLocalLibraryDecision(rawValue: rawDesiredDecision),
              let state = PhoneArchiveMacTagOutboundIntent.State(rawValue: rawState) else {
            throw PhoneArchiveImportError.catalogDiverged
        }
        return PhoneArchiveMacTagOutboundIntent(
            id: id, migrationID: migrationID, mediaID: mediaID, assetID: assetID,
            bindingConfirmationEventID: bindingID,
            sourceInstallID: sourceInstallID, sourceEpoch: sourceEpoch,
            phoneDeviceID: phoneDeviceID,
            phoneScopeRevision: row["phone_scope_revision"],
            phoneTagID: phoneTagID, phoneTagName: row["phone_tag_name"],
            macTagID: macTagID, macExpectedRevision: row["mac_expected_revision"],
            macExpectedDecision: macExpectedDecision,
            phoneExpectedRevision: row["phone_expected_revision"],
            phoneExpectedDecision: phoneExpectedDecision,
            desiredDecision: desiredDecision, state: state,
            phoneResultingRevision: row["phone_resulting_revision"],
            phoneChangeSequence: row["phone_change_sequence"],
            createdAtMs: row["created_at_ms"]
        )
    }

    /// Applies one explicitly reviewed shared phone decision to an existing
    /// Mac Asset. The catalog fact, monotonic revision and audit event commit
    /// together; the phone projection is rechecked by the caller around this
    /// transaction because it resides in a separate durable store.
    func applySharedPhoneTagDecisionToBoundAsset(
        operationID: UUID, migrationID: UUID, mediaID: UUID, assetID: UUID,
        expectedComparison: PhoneArchiveBoundFactComparison,
        expectedTag: PhoneArchiveTagComparison,
        phoneDeviceID: UUID, phoneScopeRevision: Int64,
        sharedFact: RemoteLocalLibrarySyncStore.SharedTagFact,
        timestampMs: Int64
    ) throws -> PhoneArchiveMacTagApplicationReceipt {
        guard timestampMs >= 0, phoneScopeRevision >= 0,
              sharedFact.assetID == mediaID,
              sharedFact.tagID == expectedTag.phoneTagID,
              sharedFact.revision > 0,
              let macTagID = expectedTag.macTagID else {
            throw PhoneArchiveImportError.tagSyncCandidateChanged
        }
        return try database.pool.write { db in
            let operation = operationID.uuidString.lowercased()
            if let prior = try Row.fetchOne(db, sql: """
                SELECT migration_id, media_id, asset_id,
                       binding_confirmation_event_id, source_install_id, source_epoch,
                       phone_device_id, phone_scope_revision, phone_tag_id, mac_tag_id,
                       phone_field_revision, phone_decision, resulting_mac_revision
                FROM phone_tag_mac_application_event WHERE id = ?
                """, arguments: [operation]) {
                guard (prior["migration_id"] as String) == migrationID.uuidString.lowercased(),
                      (prior["media_id"] as String) == mediaID.uuidString.lowercased(),
                      (prior["asset_id"] as String) == assetID.uuidString.lowercased(),
                      (prior["binding_confirmation_event_id"] as String) ==
                          expectedComparison.bindingConfirmationEventID.uuidString.lowercased(),
                      (prior["source_install_id"] as String) ==
                          expectedComparison.sourceInstallID.uuidString.lowercased(),
                      (prior["source_epoch"] as String) ==
                          expectedComparison.sourceEpoch.uuidString.lowercased(),
                      (prior["phone_device_id"] as String) == phoneDeviceID.uuidString.lowercased(),
                      (prior["phone_scope_revision"] as Int64) == phoneScopeRevision,
                      (prior["phone_tag_id"] as String) ==
                          expectedTag.phoneTagID.uuidString.lowercased(),
                      (prior["mac_tag_id"] as String) == macTagID.uuidString.lowercased(),
                      (prior["phone_field_revision"] as Int64) == sharedFact.revision,
                      (prior["phone_decision"] as String) == sharedFact.decision.rawValue else {
                    throw PhoneArchiveImportError.tagSyncCandidateChanged
                }
                return PhoneArchiveMacTagApplicationReceipt(
                    operationID: operationID, macTagID: macTagID,
                    decision: sharedFact.decision,
                    macDecisionRevision: prior["resulting_mac_revision"], replayed: true
                )
            }
            let current = try compareBoundAssetFacts(
                in: db, migrationID: migrationID, mediaID: mediaID, assetID: assetID
            )
            guard current.sourceInstallID == expectedComparison.sourceInstallID,
                  current.sourceEpoch == expectedComparison.sourceEpoch,
                  current.bindingConfirmationEventID == expectedComparison.bindingConfirmationEventID,
                  current.factSnapshotSequence == expectedComparison.factSnapshotSequence,
                  let tag = current.tags.first(where: { $0.phoneTagID == expectedTag.phoneTagID }),
                  tag.phoneTagName == expectedTag.phoneTagName,
                  tag.macTagID == macTagID,
                  tag.macTagName == expectedTag.macTagName,
                  tag.macTagUpdatedAtMs == expectedTag.macTagUpdatedAtMs,
                  tag.macDecision == expectedTag.macDecision,
                  tag.macDecisionUpdatedAtMs == expectedTag.macDecisionUpdatedAtMs,
                  tag.macDecisionRevision == expectedTag.macDecisionRevision,
                  tag.aliasConfirmationEventID == expectedTag.aliasConfirmationEventID,
                  tag.state == expectedTag.state,
                  tag.state == .same || tag.state == .decisionDiffers
                      || tag.state == .macDecisionMissing,
                  tag.macDecision != (sharedFact.decision == .cleared
                      ? nil : sharedFact.decision.rawValue) else {
                throw PhoneArchiveImportError.tagSyncCandidateChanged
            }
            let priorRevision = tag.macDecisionRevision ?? 0
            guard priorRevision < Int64.max else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            let tags = GRDBTagCatalogRepository(database: database)
            switch sharedFact.decision {
            case .accepted:
                _ = try tags.applyBatchDecision(
                    in: db, tagID: macTagID, assetIDs: [assetID],
                    decision: .accepted, timestampMs: timestampMs
                )
            case .rejected:
                _ = try tags.applyBatchDecision(
                    in: db, tagID: macTagID, assetIDs: [assetID],
                    decision: .rejected, timestampMs: timestampMs
                )
            case .cleared:
                try tags.clearDecision(
                    in: db, tagID: macTagID, assetID: assetID,
                    timestampMs: timestampMs
                )
            }
            guard let resultingRevision = try Int64.fetchOne(db, sql: """
                SELECT revision FROM asset_tag_decision_revision
                WHERE asset_id = ? AND tag_id = ?
                """, arguments: [assetID.uuidString.lowercased(),
                                 macTagID.uuidString.lowercased()]),
                  resultingRevision == priorRevision + 1 else {
                throw PhoneArchiveImportError.catalogDiverged
            }
            try db.execute(sql: """
                INSERT INTO phone_tag_mac_application_event (
                    id, migration_id, media_id, asset_id,
                    binding_confirmation_event_id, source_install_id, source_epoch,
                    phone_device_id, phone_scope_revision, phone_tag_id, mac_tag_id,
                    phone_field_revision, phone_decision, prior_mac_decision,
                    prior_mac_revision, resulting_mac_revision, committed_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    operation, migrationID.uuidString.lowercased(),
                    mediaID.uuidString.lowercased(), assetID.uuidString.lowercased(),
                    expectedComparison.bindingConfirmationEventID.uuidString.lowercased(),
                    expectedComparison.sourceInstallID.uuidString.lowercased(),
                    expectedComparison.sourceEpoch.uuidString.lowercased(),
                    phoneDeviceID.uuidString.lowercased(), phoneScopeRevision,
                    expectedTag.phoneTagID.uuidString.lowercased(),
                    macTagID.uuidString.lowercased(), sharedFact.revision,
                    sharedFact.decision.rawValue, tag.macDecision,
                    priorRevision, resultingRevision, timestampMs,
                ])
            return PhoneArchiveMacTagApplicationReceipt(
                operationID: operationID, macTagID: macTagID,
                decision: sharedFact.decision,
                macDecisionRevision: resultingRevision, replayed: false
            )
        }
    }

    private static func macTags(
        _ db: Database, matching predicate: String, value: String
    ) throws -> [Row] {
        try Row.fetchAll(db, sql: """
            SELECT tag.id, tag.name, tag.state, tag.updated_at_ms,
                   coalesce(concept.normalized_name, tag.normalized_name) AS effective_name
            FROM tag
            LEFT JOIN standard_tag_binding binding ON binding.tag_id = tag.id
            LEFT JOIN ontology_concept concept
                ON concept.ontology_id = binding.ontology_id
                AND concept.ontology_revision = binding.ontology_revision
                AND concept.concept_id = binding.concept_id
            WHERE \(predicate) ORDER BY tag.id LIMIT 2
            """, arguments: [value])
    }

    private func importedMediaKind(
        _ db: Database, migrationID: UUID, mediaID: UUID
    ) throws -> String {
        guard let kind = try String.fetchOne(db, sql: """
            SELECT mi.media_kind
            FROM migration_import_item i
            JOIN migration_import m ON m.id = i.migration_id
            JOIN media_item mi ON mi.id = i.media_id
                AND mi.source_install_id = i.source_device_id
                AND mi.source_epoch = i.source_epoch
            JOIN media_replica r ON r.media_id = mi.id
                AND r.migration_id = i.migration_id
            WHERE i.migration_id = ? AND i.media_id = ?
              AND m.state = 'catalogCommitted' AND r.storage_kind = 'macArchive'
            """, arguments: [
                migrationID.uuidString.lowercased(), mediaID.uuidString.lowercased(),
            ]) else {
            throw PhoneArchiveImportError.missingImportJournal
        }
        return kind
    }

    private static func assetKind(_ mediaType: String) -> String? {
        guard let type = UTType(mediaType) else { return nil }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
        return nil
    }

    func importedFacts(migrationID: UUID, mediaID: UUID) throws -> PhoneArchiveImportedFacts {
        let migration = migrationID.uuidString.lowercased()
        let media = mediaID.uuidString.lowercased()
        return try database.pool.read { db in
            guard let item = try Row.fetchOne(db, sql: """
                SELECT i.source_device_id, i.source_epoch,
                       i.observed_favorite, i.favorite_target
                FROM migration_import_item i
                JOIN migration_import m ON m.id = i.migration_id
                WHERE i.migration_id = ? AND i.media_id = ?
                  AND m.state = 'catalogCommitted'
                """, arguments: [migration, media]) else {
                throw PhoneArchiveImportError.missingImportJournal
            }
            let device: String = item["source_device_id"]
            let epoch: String = item["source_epoch"]
            let tags = try Row.fetchAll(db, sql: """
                SELECT tag_id, tag_name, decision
                FROM migration_import_tag_decision
                WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
                ORDER BY tag_id
                """, arguments: [device, epoch, media]).map { row in
                guard let tagID = UUID(uuidString: row["tag_id"]),
                      let decision = RemoteLocalLibraryDecision(rawValue: row["decision"])
                else { throw PhoneArchiveImportError.catalogDiverged }
                return ImageAllMigrationTagDecision(
                    tagID: tagID, tagName: row["tag_name"], decision: decision
                )
            }
            let collections = try Row.fetchAll(db, sql: """
                SELECT collection_id, collection_name
                FROM migration_import_collection
                WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?
                  AND included = 1 ORDER BY collection_id
                """, arguments: [device, epoch, media]).map { row in
                guard let id = UUID(uuidString: row["collection_id"])
                else { throw PhoneArchiveImportError.catalogDiverged }
                return ImageAllMigrationCollectionMembership(
                    collectionID: id, collectionName: row["collection_name"],
                    included: true
                )
            }
            let decoder = JSONDecoder()
            let albums = try Row.fetchAll(db, sql: """
                SELECT album_local_identifier, album_title,
                       folder_path_json, source_ordinal
                FROM migration_import_apple_album_member
                WHERE migration_id = ? AND media_id = ?
                ORDER BY album_local_identifier
                """, arguments: [migration, media]).map { row in
                let path: String = row["folder_path_json"]
                return ImageAllMigrationAppleAlbumMembership(
                    albumLocalIdentifier: row["album_local_identifier"],
                    albumTitle: row["album_title"],
                    folderPath: try decoder.decode(
                        [ImageAllMigrationAppleAlbumMembership.Folder].self,
                        from: Data(path.utf8)
                    ),
                    sourceOrdinal: row["source_ordinal"]
                )
            }
            let observed: Int = item["observed_favorite"]
            let target: Int? = item["favorite_target"]
            return PhoneArchiveImportedFacts(
                observedFavorite: observed == 1,
                favoriteTarget: target.map { $0 == 1 },
                tagDecisions: tags, collections: collections,
                appleAlbums: albums
            )
        }
    }

    func verifiedPreview(
        migrationID: UUID, mediaID: UUID, archiveRoot: URL
    ) throws -> PhoneArchiveVerifiedPreview {
        _ = try auditImportedArchive(
            migrationID: migrationID, archiveRoot: archiveRoot
        )
        return PhoneArchiveVerifiedPreview(
            originalURL: try verifiedOriginalURL(
                migrationID: migrationID, mediaID: mediaID,
                archiveRoot: archiveRoot
            ),
            facts: try importedFacts(migrationID: migrationID, mediaID: mediaID)
        )
    }

    /// Resolves originals for a gallery page after one complete archive and
    /// catalog audit. The caller keeps the target security scope open while
    /// producing thumbnails. Opening a full preview re-verifies the archive.
    func verifiedGalleryOriginalURLs(
        migrationID: UUID, archiveRoot: URL
    ) throws -> [UUID: URL] {
        _ = try auditImportedArchive(migrationID: migrationID, archiveRoot: archiveRoot)
        return try database.pool.read { db in
            var originals: [UUID: URL] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.media_id, r.relative_path
                FROM migration_import_item i
                JOIN migration_import_resource r
                  ON r.source_device_id = i.source_device_id
                 AND r.source_epoch = i.source_epoch
                 AND r.media_id = i.media_id
                WHERE i.migration_id = ? AND r.role = 'original'
                ORDER BY i.media_id, r.version
                """, arguments: [migrationID.uuidString.lowercased()])
            for row in rows {
                let media: String = row["media_id"]
                let relative: String = row["relative_path"]
                guard let id = UUID(uuidString: media),
                      relative.hasPrefix("resources/"),
                      relative.split(separator: "/").count == 2 else {
                    throw PhoneArchiveImportError.catalogDiverged
                }
                if originals[id] == nil {
                    originals[id] = archiveRoot.appendingPathComponent(relative)
                }
            }
            return originals
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
        do {
            try db.execute(sql: """
                INSERT INTO media_item (
                    id, source_install_id, source_epoch,
                    source_local_identifier, media_kind
                ) VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    media, device, epoch, item.sourceLocalIdentifier,
                    item.mediaKind.rawValue,
                ])
            try db.execute(sql: """
                INSERT INTO media_replica (
                    id, media_id, storage_kind, migration_id,
                    source_install_id, source_epoch, created_at_ms
                ) VALUES (?, ?, 'macArchive', ?, ?, ?, ?)
                """, arguments: [
                    UUID().uuidString.lowercased(), media,
                    header.migrationID.uuidString.lowercased(), device, epoch,
                    Int64(Date().timeIntervalSince1970 * 1_000),
                ])
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            // A global media ID or origin locator may not silently become a
            // second logical item or point at a different storage instance.
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
    private static let logger = Logger(
        subsystem: "com.gwlee.ImageAll", category: "PhoneArchiveImport"
    )

    static func attach(database: CatalogDatabase) {
        self.database = database
    }

    static func importer() -> VerifiedPhoneArchiveImporter? {
        database.map { VerifiedPhoneArchiveImporter(database: $0) }
    }

    static func recoverPreparedOutboundMacTagDecisions() {
        guard let importer = importer() else { return }
        let recoveryLogger = logger
        Task.detached(priority: .utility) {
            do {
                let result = try await importer.recoverPreparedOutboundMacTagDecisions {
                    deviceID, operationID in
                    try await RemoteHostProcessHolder.sharedPhoneMacTagOperation(
                        deviceID: deviceID, operationID: operationID
                    )
                }
                if result.prepared > 0 {
                    recoveryLogger.info(
                        "Mac tag outbound recovery: prepared=\(result.prepared), committed=\(result.committed), pending=\(result.stillPending), failed=\(result.failedVerification)"
                    )
                }
            } catch {
                recoveryLogger.error("Mac tag outbound recovery failed: \(String(describing: error))")
            }
        }
    }
}
