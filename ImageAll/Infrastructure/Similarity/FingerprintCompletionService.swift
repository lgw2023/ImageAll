import CryptoKit
import Foundation
import GRDB

struct FingerprintCompletionService: FingerprintCompletionPort {
    let database: CatalogDatabase
    let sourceAccess: FolderReconcileSourceAccessService
    let sourceReader: DerivedImageSourceReader
    let clock: any JobClock
    let assetRepository: GRDBDerivedImageCacheRepository

    init(
        database: CatalogDatabase,
        sourceAccess: FolderReconcileSourceAccessService,
        sourceReader: DerivedImageSourceReader = DerivedImageSourceReader(),
        clock: any JobClock,
        assetRepository: GRDBDerivedImageCacheRepository? = nil
    ) {
        self.database = database
        self.sourceAccess = sourceAccess
        self.sourceReader = sourceReader
        self.clock = clock
        self.assetRepository = assetRepository ?? GRDBDerivedImageCacheRepository(database: database)
    }

    func completeFolderAsset(assetID: UUID) throws -> AssetContentFingerprint {
        guard let context = try assetRepository.fetchGenerationContext(assetID: assetID) else {
            throw FingerprintCompletionError.notFound
        }
        guard context.isEligibleForGeneration else {
            throw FingerprintCompletionError.ineligible
        }

        if let existing = try loadCompletedFingerprint(
            assetID: assetID,
            contentRevision: context.contentRevision
        ) {
            return existing
        }

        let bytes: Data
        do {
            bytes = try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
                let initial = try sourceReader.readSourceBytes(
                    rootURL: rootURL,
                    relativePath: context.relativePath
                )
                guard context.matchesHandleFacts(initial.initialFingerprint),
                      initial.preHandleFstat.sizeBytes == initial.postHandleFstat.sizeBytes,
                      initial.preHandleFstat.modifiedAtNs == initial.postHandleFstat.modifiedAtNs,
                      initial.initialFingerprint.resourceID == initial.postResourceID
                else {
                    throw FingerprintCompletionError.sourceChanged
                }
                return initial.bytes
            }
        } catch let error as FingerprintCompletionError {
            throw error
        } catch let error as FolderReconcileHandlerError {
            switch error {
            case .authorizationRequired:
                throw FingerprintCompletionError.authorizationRequired
            case .sourceUnavailable, .enumerationIncomplete:
                throw FingerprintCompletionError.sourceUnavailable
            }
        } catch {
            throw FingerprintCompletionError.sourceUnavailable
        }

        let sha256 = Data(SHA256.hash(data: bytes))
        let perceptual: Data
        do {
            let hash = try PerceptualImageHash.dHash64(
                sourceBytes: bytes,
                expectedMediaType: context.mediaType
            )
            perceptual = PerceptualImageHash.encodeHash(hash)
        } catch {
            throw FingerprintCompletionError.decodeFailed
        }

        let nowMs = clock.nowMs
        do {
            try persist(
                assetID: assetID,
                contentRevision: context.contentRevision,
                expectedSize: context.fingerprintSizeBytes,
                expectedModifiedAtNs: context.fingerprintModifiedAtNs,
                expectedResourceID: context.fingerprintResourceID,
                sha256: sha256,
                perceptualHash: perceptual,
                nowMs: nowMs
            )
        } catch let error as FingerprintCompletionError {
            throw error
        } catch {
            throw FingerprintCompletionError.persistenceFailed
        }

        return AssetContentFingerprint(
            assetID: assetID,
            contentRevision: context.contentRevision,
            sha256: sha256,
            perceptualHash: perceptual,
            perceptualAlgoVersion: IdenticalDuplicatePolicy.perceptualAlgoVersion
        )
    }

    func completePendingFolderAssets(limit: Int) throws -> [AssetContentFingerprint] {
        let capped = max(0, limit)
        guard capped > 0 else { return [] }
        let pendingIDs = try listPendingAssetIDs(limit: capped)
        var results: [AssetContentFingerprint] = []
        results.reserveCapacity(pendingIDs.count)
        for assetID in pendingIDs {
            do {
                results.append(try completeFolderAsset(assetID: assetID))
            } catch FingerprintCompletionError.ineligible,
                    FingerprintCompletionError.notFound,
                    FingerprintCompletionError.sourceChanged,
                    FingerprintCompletionError.sourceUnavailable,
                    FingerprintCompletionError.authorizationRequired,
                    FingerprintCompletionError.decodeFailed {
                continue
            }
        }
        return results
    }

    private func listPendingAssetIDs(limit: Int) throws -> [UUID] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT a.id AS asset_id
                FROM asset a
                JOIN source s ON s.id = a.source_id
                JOIN file_fingerprint f ON f.asset_id = a.id
                LEFT JOIN asset_similarity_fingerprint p
                    ON p.asset_id = a.id
                    AND p.content_revision = a.content_revision
                    AND p.algo_version = ?
                WHERE a.locator_kind = 'file'
                  AND a.locator_state = 'current'
                  AND a.availability = 'available'
                  AND s.kind = 'folder'
                  AND s.state = 'active'
                  AND (f.sha256 IS NULL OR p.asset_id IS NULL)
                ORDER BY a.id
                LIMIT ?
                """,
                arguments: [IdenticalDuplicatePolicy.perceptualAlgoVersion, limit]
            )
            return rows.compactMap { row in
                UUID(uuidString: row["asset_id"])
            }
        }
    }

    private func loadCompletedFingerprint(
        assetID: UUID,
        contentRevision: Int
    ) throws -> AssetContentFingerprint? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT f.sha256, p.perceptual_hash, p.algo_version, p.content_revision
                FROM file_fingerprint f
                JOIN asset_similarity_fingerprint p ON p.asset_id = f.asset_id
                WHERE f.asset_id = ?
                  AND f.sha256 IS NOT NULL
                  AND p.content_revision = ?
                  AND p.algo_version = ?
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    contentRevision,
                    IdenticalDuplicatePolicy.perceptualAlgoVersion,
                ]
            ) else {
                return nil
            }
            let sha256: Data = row["sha256"]
            let perceptual: Data = row["perceptual_hash"]
            let algo: String = row["algo_version"]
            guard sha256.count == 32, perceptual.count == 8 else { return nil }
            return AssetContentFingerprint(
                assetID: assetID,
                contentRevision: contentRevision,
                sha256: sha256,
                perceptualHash: perceptual,
                perceptualAlgoVersion: algo
            )
        }
    }

    private func persist(
        assetID: UUID,
        contentRevision: Int,
        expectedSize: Int64,
        expectedModifiedAtNs: Int64,
        expectedResourceID: Data?,
        sha256: Data,
        perceptualHash: Data,
        nowMs: Int64
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE file_fingerprint
                SET sha256 = ?
                WHERE asset_id = ?
                  AND size_bytes = ?
                  AND modified_at_ns = ?
                  AND (
                    (resource_id IS NULL AND ? IS NULL)
                    OR resource_id = ?
                  )
                """,
                arguments: [
                    sha256,
                    assetID.uuidString.lowercased(),
                    expectedSize,
                    expectedModifiedAtNs,
                    expectedResourceID,
                    expectedResourceID,
                ]
            )
            guard db.changesCount == 1 else {
                throw FingerprintCompletionError.sourceChanged
            }

            try db.execute(
                sql: """
                INSERT INTO asset_similarity_fingerprint (
                    asset_id, content_revision, algo_version, perceptual_hash,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    content_revision = excluded.content_revision,
                    algo_version = excluded.algo_version,
                    perceptual_hash = excluded.perceptual_hash,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    contentRevision,
                    IdenticalDuplicatePolicy.perceptualAlgoVersion,
                    perceptualHash,
                    nowMs,
                    nowMs,
                ]
            )
        }
    }
}
