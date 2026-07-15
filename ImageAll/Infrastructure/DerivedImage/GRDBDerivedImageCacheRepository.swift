import Foundation
import GRDB

struct DerivedImageCacheLookupContext: Equatable, Sendable {
    let assetID: UUID
    let contentRevision: Int
}

struct GRDBDerivedImageCacheRepository: Sendable {
    let database: CatalogDatabase
    let faultInjector: any DerivedImageRepositoryFaultInjecting

    init(
        database: CatalogDatabase,
        faultInjector: any DerivedImageRepositoryFaultInjecting = NoDerivedImageRepositoryFaultInjector()
    ) {
        self.database = database
        self.faultInjector = faultInjector
    }

    func assetExists(assetID: UUID) throws -> Bool {
        try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            ) == 1
        }
    }

    func fetchCacheLookupContext(assetID: UUID) throws -> DerivedImageCacheLookupContext? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, content_revision FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            ) else {
                return nil
            }
            return DerivedImageCacheLookupContext(
                assetID: UUID(uuidString: row["id"])!,
                contentRevision: row["content_revision"]
            )
        }
    }

    func fetchGenerationContext(assetID: UUID) throws -> DerivedImageAssetGenerationContext? {
        try database.pool.read { db in
            try fetchGenerationContext(db: db, assetID: assetID)
        }
    }

    func fetchEntry(
        assetID: UUID,
        contentRevision: Int,
        representationVersion: Int,
        variant: DerivedImageVariant
    ) throws -> DerivedImageCacheEntryRow? {
        try database.pool.read { db in
            try fetchEntry(
                db: db,
                assetID: assetID,
                contentRevision: contentRevision,
                representationVersion: representationVersion,
                variant: variant
            )
        }
    }

    func fetchEntry(db: Database, assetID: UUID, contentRevision: Int, representationVersion: Int, variant: DerivedImageVariant) throws -> DerivedImageCacheEntryRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT *
            FROM derived_image_cache_entry
            WHERE asset_id = ?
                AND content_revision = ?
                AND representation_version = ?
                AND variant = ?
            """,
            arguments: [
                assetID.uuidString.lowercased(),
                contentRevision,
                representationVersion,
                variant.rawValue,
            ]
        ) else {
            return nil
        }
        return try mapEntry(row)
    }

    func publishedByteTotal() throws -> UInt64 {
        try database.pool.read { db in
            let total: Int64? = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(byte_size), 0) FROM derived_image_cache_entry"
            )
            guard let total, total >= 0 else { return 0 }
            return UInt64(total)
        }
    }

    func lruEntries() throws -> [DerivedImageCacheEntryRow] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM derived_image_cache_entry
                ORDER BY last_accessed_at_ms ASC, id ASC
                """
            )
            return try rows.map(mapEntry)
        }
    }

    func allEntries() throws -> [DerivedImageCacheEntryRow] {
        try lruEntries()
    }

    func deleteEntry(id: UUID) throws {
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM derived_image_cache_entry WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            )
        }
    }

    func touchEntry(id: UUID, accessedAtMs: Int64) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE derived_image_cache_entry
                SET last_accessed_at_ms = ?
                WHERE id = ?
                """,
                arguments: [accessedAtMs, id.uuidString.lowercased()]
            )
            if faultInjector.shouldFault(at: .lruTouch) {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
        }
    }

    func publishEntryReplacingKey(
        entry: DerivedImageCacheEntryRow,
        expected: DerivedImageAssetGenerationContext,
        replacementCandidateID: UUID? = nil
    ) throws -> PublishEntryOutcome {
        do {
            return try database.pool.write { db in
                guard try revalidate(db: db, expected: expected) else {
                    return .sourceChanged
                }
                if faultInjector.shouldFault(at: .revalidation) {
                    throw DerivedImageError.derivedCachePersistenceFailed
                }

                let current = try fetchEntry(
                    db: db,
                    assetID: entry.assetID,
                    contentRevision: entry.contentRevision,
                    representationVersion: entry.representationVersion,
                    variant: entry.variant
                )

                if let current {
                    if current.id == entry.id {
                        return .published(replacedEntry: nil)
                    }
                    if let candidateID = replacementCandidateID, current.id == candidateID {
                        let replacedEntry = current
                        try db.execute(
                            sql: "DELETE FROM derived_image_cache_entry WHERE id = ?",
                            arguments: [candidateID.uuidString.lowercased()]
                        )
                        if faultInjector.shouldFault(at: .insert) {
                            throw DerivedImageError.derivedCachePersistenceFailed
                        }
                        try insertEntry(db: db, entry: entry)
                        return .published(replacedEntry: replacedEntry)
                    }
                    return .lostRaceToExisting(winner: current)
                }

                try insertEntry(db: db, entry: entry)
                if faultInjector.shouldFault(at: .insert) {
                    throw DerivedImageError.derivedCachePersistenceFailed
                }
                return .published(replacedEntry: nil)
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            if let winner = try fetchEntry(
                assetID: entry.assetID,
                contentRevision: entry.contentRevision,
                representationVersion: entry.representationVersion,
                variant: entry.variant
            ) {
                return .lostRaceToExisting(winner: winner)
            }
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func revalidate(db: Database, expected: DerivedImageAssetGenerationContext) throws -> Bool {
        guard let current = try fetchGenerationContext(db: db, assetID: expected.assetID) else {
            return false
        }
        return current == expected
    }

    private func insertEntry(db: Database, entry: DerivedImageCacheEntryRow) throws {
        try db.execute(
            sql: """
            INSERT INTO derived_image_cache_entry (
                id, asset_id, content_revision, representation_version, variant,
                storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                created_at_ms, last_accessed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                entry.id.uuidString.lowercased(),
                entry.assetID.uuidString.lowercased(),
                entry.contentRevision,
                entry.representationVersion,
                entry.variant.rawValue,
                entry.storageFormat.rawValue,
                entry.pixelWidth,
                entry.pixelHeight,
                entry.byteSize,
                entry.encodedSHA256,
                entry.createdAtMs,
                entry.lastAccessedAtMs,
            ]
        )
    }

    private func fetchGenerationContext(db: Database, assetID: UUID) throws -> DerivedImageAssetGenerationContext? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
                a.id AS asset_id,
                a.source_id,
                a.content_revision,
                a.relative_path,
                a.file_name,
                a.media_type,
                a.availability,
                a.locator_state,
                a.locator_kind,
                s.state AS source_state,
                s.kind AS source_kind,
                f.size_bytes,
                f.modified_at_ns,
                f.resource_id
            FROM asset a
            JOIN source s ON s.id = a.source_id
            LEFT JOIN file_fingerprint f ON f.asset_id = a.id
            WHERE a.id = ?
            """,
            arguments: [assetID.uuidString.lowercased()]
        ) else {
            return nil
        }
        guard let relativePath: String = row["relative_path"],
              let fileName: String = row["file_name"],
              let sizeBytes: Int64 = row["size_bytes"],
              let modifiedAtNs: Int64 = row["modified_at_ns"]
        else {
            return nil
        }
        return DerivedImageAssetGenerationContext(
            assetID: UUID(uuidString: row["asset_id"])!,
            sourceID: UUID(uuidString: row["source_id"])!,
            contentRevision: row["content_revision"],
            relativePath: relativePath,
            fileName: fileName,
            mediaType: row["media_type"],
            availability: row["availability"],
            locatorState: row["locator_state"],
            locatorKind: row["locator_kind"],
            sourceState: row["source_state"],
            sourceKind: row["source_kind"],
            fingerprintSizeBytes: sizeBytes,
            fingerprintModifiedAtNs: modifiedAtNs,
            fingerprintResourceID: row["resource_id"]
        )
    }

    private func mapEntry(_ row: Row) throws -> DerivedImageCacheEntryRow {
        DerivedImageCacheEntryRow(
            id: UUID(uuidString: row["id"])!,
            assetID: UUID(uuidString: row["asset_id"])!,
            contentRevision: row["content_revision"],
            representationVersion: row["representation_version"],
            variant: DerivedImageVariant(rawValue: row["variant"])!,
            storageFormat: DerivedImageStorageFormat(rawValue: row["storage_format"])!,
            pixelWidth: row["pixel_width"],
            pixelHeight: row["pixel_height"],
            byteSize: row["byte_size"],
            encodedSHA256: row["encoded_sha256"],
            createdAtMs: row["created_at_ms"],
            lastAccessedAtMs: row["last_accessed_at_ms"]
        )
    }
}

enum PublishEntryOutcome: Equatable {
    case published(replacedEntry: DerivedImageCacheEntryRow?)
    case lostRaceToExisting(winner: DerivedImageCacheEntryRow)
    case sourceChanged
}

extension DerivedImageAssetGenerationContext {
    var isEligibleForGeneration: Bool {
        locatorKind == AssetLocatorKind.file.rawValue
            && locatorState == AssetLocatorState.current.rawValue
            && availability == AssetAvailability.available.rawValue
            && sourceKind == SourceKind.folder.rawValue
            && sourceState == SourceState.active.rawValue
            && DerivedImageRenderer.supportedSourceMediaTypes.contains(mediaType)
            && RelativePathRules.validate(relativePath).isSuccess
            && RelativePathRules.fileName(from: relativePath) == fileName
            && fingerprintSizeBytes > 0
            && fingerprintModifiedAtNs >= 0
    }

    func matchesHandleFacts(_ opened: DerivedImageOpenedFingerprint) -> Bool {
        opened.sizeBytes == fingerprintSizeBytes
            && opened.modifiedAtNs == fingerprintModifiedAtNs
            && opened.resourceID == fingerprintResourceID
    }

    func matches(_ opened: DerivedImageOpenedFingerprint) -> Bool {
        matchesHandleFacts(opened)
    }
}

private extension Result where Success == String, Failure == RelativePathValidationFailure {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
