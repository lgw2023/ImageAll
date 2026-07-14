import Foundation
import GRDB

struct NewSourceWithAssetInput: Sendable {
    let sourceID: UUID
    let sourceKind: SourceKind
    let displayName: String
    let bookmark: Data?
    let assetID: UUID
    let locatorKind: AssetLocatorKind
    let relativePath: String?
    let photosLocalIdentifier: String?
    let mediaType: String
    let timestampMs: Int64
}

struct NewAssetInput: Sendable {
    let assetID: UUID
    let sourceID: UUID
    let locatorKind: AssetLocatorKind
    let relativePath: String?
    let photosLocalIdentifier: String?
    let mediaType: String
    let timestampMs: Int64
}

struct FileFingerprintInput: Sendable {
    let assetID: UUID
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
    let sha256: Data?
}

struct CatalogRepository: Sendable {
    let database: CatalogDatabase

    func createSourceWithAsset(_ input: NewSourceWithAssetInput) throws {
        try database.pool.write { db in
            try validateSourceLocatorPair(sourceKind: input.sourceKind, locatorKind: input.locatorKind)

            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    input.sourceID.uuidString.lowercased(),
                    input.sourceKind.rawValue,
                    input.displayName,
                    input.bookmark,
                    input.timestampMs,
                    input.timestampMs,
                ]
            )

            try insertAssetRecord(db, input: NewAssetInput(
                assetID: input.assetID,
                sourceID: input.sourceID,
                locatorKind: input.locatorKind,
                relativePath: input.relativePath,
                photosLocalIdentifier: input.photosLocalIdentifier,
                mediaType: input.mediaType,
                timestampMs: input.timestampMs
            ), sourceKind: input.sourceKind)
        }
    }

    func insertAsset(_ input: NewAssetInput) throws {
        try database.pool.write { db in
            let sourceKind = try fetchSourceKind(db, sourceID: input.sourceID)
            try insertAssetRecord(db, input: input, sourceKind: sourceKind)
        }
    }

    func upsertFileFingerprint(_ input: FileFingerprintInput) throws {
        try database.pool.write { db in
            guard let locatorKindRaw: String = try String.fetchOne(
                db,
                sql: "SELECT locator_kind FROM asset WHERE id = ?",
                arguments: [input.assetID.uuidString.lowercased()]
            ) else {
                throw CatalogRepositoryError.referenceNotFound
            }
            guard locatorKindRaw == AssetLocatorKind.file.rawValue else {
                throw CatalogRepositoryError.photosFingerprintNotAllowed
            }

            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (
                    asset_id, size_bytes, modified_at_ns, resource_id, sha256
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    size_bytes = excluded.size_bytes,
                    modified_at_ns = excluded.modified_at_ns,
                    resource_id = excluded.resource_id,
                    sha256 = excluded.sha256
                """,
                arguments: [
                    input.assetID.uuidString.lowercased(),
                    input.sizeBytes,
                    input.modifiedAtNs,
                    input.resourceID,
                    input.sha256,
                ]
            )
        }
    }

    private func fetchSourceKind(_ db: Database, sourceID: UUID) throws -> SourceKind {
        guard let raw: String = try String.fetchOne(
            db,
            sql: "SELECT kind FROM source WHERE id = ?",
            arguments: [sourceID.uuidString.lowercased()]
        ) else {
            throw CatalogRepositoryError.referenceNotFound
        }
        guard let kind = SourceKind(rawValue: raw) else {
            throw CatalogRepositoryError.referenceNotFound
        }
        return kind
    }

    private func validateSourceLocatorPair(sourceKind: SourceKind, locatorKind: AssetLocatorKind) throws {
        switch (sourceKind, locatorKind) {
        case (.folder, .file), (.photos, .photos):
            return
        default:
            throw CatalogRepositoryError.sourceLocatorKindMismatch
        }
    }

    private func insertAssetRecord(
        _ db: Database,
        input: NewAssetInput,
        sourceKind: SourceKind
    ) throws {
        try validateSourceLocatorPair(sourceKind: sourceKind, locatorKind: input.locatorKind)

        try db.execute(
            sql: """
            INSERT INTO asset (
                id, source_id, locator_kind, relative_path, photos_local_identifier,
                locator_state, media_type, content_revision, availability,
                record_created_at_ms, record_updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, 'current', ?, 1, 'available', ?, ?)
            """,
            arguments: [
                input.assetID.uuidString.lowercased(),
                input.sourceID.uuidString.lowercased(),
                input.locatorKind.rawValue,
                input.relativePath,
                input.photosLocalIdentifier,
                input.mediaType,
                input.timestampMs,
                input.timestampMs,
            ]
        )
    }
}
