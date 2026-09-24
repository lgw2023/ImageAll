import Foundation
import GRDB
import ImageAllRemoteProtocol

enum PhoneArchiveImportError: LocalizedError, Equatable {
    case incompleteArchive
    case migrationIdentityConflict
    case targetChanged
    case publishedCopyChanged
    case missingImportJournal

    var errorDescription: String? {
        switch self {
        case .incompleteArchive: "归档缺少必需资源，不能入库。"
        case .migrationIdentityConflict: "迁移身份或已有手机资产身份冲突，需要先对账。"
        case .targetChanged: "此迁移 ID 已绑定另一目标位置。"
        case .publishedCopyChanged: "Mac 已发布的归档副本与入库记录不一致。"
        case .missingImportJournal: "归档导入记录丢失，不能返回完成回执。"
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

/// Imports a verified phone package into dedicated catalog bindings. The
/// existing one-source Asset row remains untouched; archive resources are
/// owned by this migration until a deliberate MediaItem/Replica projection
/// exposes them in the unified gallery.
struct VerifiedPhoneArchiveImporter: Sendable {
    let database: CatalogDatabase

    func importArchive(
        from incoming: URL, to targetParent: URL,
        afterPublication: (() throws -> Void)? = nil
    ) throws -> PhoneArchiveImportReceipt {
        let (header, verification) = try ImageAllMigrationArchive.readVerifiedHeader(at: incoming)
        guard verification.isComplete else { throw PhoneArchiveImportError.incompleteArchive }
        let source = incoming.standardizedFileURL.resolvingSymlinksInPath()
        let target = targetParent.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path != target.path,
              !source.path.hasPrefix(target.path + "/"),
              !target.path.hasPrefix(source.path + "/") else {
            throw ImageAllMigrationArchiveError.destinationOverlap
        }
        let targetValues = try targetParent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard targetValues.isDirectory == true, targetValues.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
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
                guard savedHash == verification.manifestSHA256,
                      savedDevice == header.sourceDeviceID.uuidString.lowercased(),
                      savedEpoch == header.sourceEpoch.uuidString.lowercased(),
                      savedItemCount == verification.itemCount,
                      savedResourceCount == verification.resourceCount,
                      savedBytes == verification.verifiedBytes else {
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
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?, ?)
                """, arguments: [
                    id, header.sourceDeviceID.uuidString.lowercased(),
                    header.sourceEpoch.uuidString.lowercased(), header.scopeRevision,
                    header.inventoryWatermark, verification.manifestSHA256,
                    parent.path, targetBookmark, final.path, verification.itemCount,
                    verification.resourceCount, verification.verifiedBytes, now, now,
                ])
            return false
        }

        if FileManager.default.fileExists(atPath: final.path) {
            guard try ImageAllMigrationArchive.verify(at: final) == verification else {
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
            guard reread == verification else {
                throw PhoneArchiveImportError.publishedCopyChanged
            }
            try db.execute(sql: """
                UPDATE migration_import SET state = 'catalogCommitted', updated_at_ms = ?
                WHERE id = ? AND state = 'prepared'
                """, arguments: [now, id])
        }
        return receipt(header: header, verification: verification, url: final, replayed: false)
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
    }
}
