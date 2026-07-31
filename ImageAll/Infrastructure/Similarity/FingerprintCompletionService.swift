import CryptoKit
import Foundation
import GRDB

struct FingerprintCompletionService: FingerprintCompletionPort {
    let database: CatalogDatabase
    let sourceAccess: FolderReconcileSourceAccessService
    let sourceReader: DerivedImageSourceReader
    let photosOriginals: (any PhotosOriginalContentPort)?
    let photosOriginalCache: PhotosOriginalCacheService?
    let photosFeatureImages: (any PhotosFeaturePrintImagePort)?
    let downloadedPreviews: (any DownloadedPreviewCachePort)?
    let clock: any JobClock
    let assetRepository: GRDBDerivedImageCacheRepository
    let videoPosterGenerator: any DerivedVideoPosterGenerating

    init(
        database: CatalogDatabase,
        sourceAccess: FolderReconcileSourceAccessService,
        sourceReader: DerivedImageSourceReader = DerivedImageSourceReader(),
        photosOriginals: (any PhotosOriginalContentPort)? = nil,
        photosOriginalCache: PhotosOriginalCacheService? = nil,
        photosFeatureImages: (any PhotosFeaturePrintImagePort)? = nil,
        downloadedPreviews: (any DownloadedPreviewCachePort)? = nil,
        clock: any JobClock,
        assetRepository: GRDBDerivedImageCacheRepository? = nil,
        videoPosterGenerator: any DerivedVideoPosterGenerating =
            AVFoundationDerivedVideoPosterGenerator()
    ) {
        self.database = database
        self.sourceAccess = sourceAccess
        self.sourceReader = sourceReader
        self.photosOriginals = photosOriginals
        self.photosOriginalCache = photosOriginalCache
        self.photosFeatureImages = photosFeatureImages
        self.downloadedPreviews = downloadedPreviews
        self.clock = clock
        self.assetRepository = assetRepository ?? GRDBDerivedImageCacheRepository(database: database)
        self.videoPosterGenerator = videoPosterGenerator
    }

    func completeAsset(assetID: UUID) throws -> AssetContentFingerprint {
        switch try loadLocatorKind(assetID: assetID) {
        case .file:
            return try completeFolderAsset(assetID: assetID)
        case .photos:
            return try completePhotosAsset(assetID: assetID)
        }
    }

    func completeFolderAsset(assetID: UUID) throws -> AssetContentFingerprint {
        guard let context = try assetRepository.fetchGenerationContext(assetID: assetID) else {
            throw FingerprintCompletionError.notFound
        }
        guard context.isEligibleForGeneration else {
            throw FingerprintCompletionError.ineligible
        }

        let algoVersion = IdenticalDuplicatePolicy.perceptualAlgoVersion(for: context.mediaKind)
        if let existing = try loadCompletedFingerprint(
            assetID: assetID,
            contentRevision: context.contentRevision,
            algoVersion: algoVersion
        ) {
            return existing
        }

        let input: (contentBytes: Data?, visualBytes: Data, expectedMediaType: String?)
        do {
            input = try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
                guard context.mediaKind == .video else {
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
                    return (initial.bytes, initial.bytes, context.mediaType)
                }
                guard let durationMs = context.durationMs, durationMs > 0 else {
                    throw FingerprintCompletionError.decodeFailed
                }
                let poster = try sourceReader.withOpenSourceFileDescriptorURL(
                    rootURL: rootURL,
                    relativePath: context.relativePath
                ) { descriptorURL, openedFingerprint in
                    guard context.matchesHandleFacts(openedFingerprint) else {
                        throw FingerprintCompletionError.sourceChanged
                    }
                    do {
                        return try videoPosterGenerator.makePosterBytes(
                            sourceFileDescriptorURL: descriptorURL,
                            mediaType: context.mediaType,
                            durationMs: durationMs,
                            maximumPixelSize: 1_024
                        )
                    } catch {
                        throw FingerprintCompletionError.decodeFailed
                    }
                }
                return (nil, poster, nil)
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

        let analysis: PerceptualImageAnalysis
        do {
            analysis = try PerceptualImageHash.analyze(
                sourceBytes: input.visualBytes,
                expectedMediaType: input.expectedMediaType
            )
        } catch {
            throw FingerprintCompletionError.decodeFailed
        }
        let sha256 = input.contentBytes.map { Data(SHA256.hash(data: $0)) }
            ?? PerceptualImageHash.visualContentDigest(analysis)
        let digestOrigin: AssetContentDigestOrigin =
            input.contentBytes == nil ? .visualDerivative : .verifiedOriginalBytes
        let perceptual = PerceptualImageHash.encodeHash(analysis.dHash)

        let nowMs = clock.nowMs
        do {
            try persist(
                assetID: assetID,
                contentRevision: context.contentRevision,
                expectedSize: context.fingerprintSizeBytes,
                expectedModifiedAtNs: context.fingerprintModifiedAtNs,
                expectedResourceID: context.fingerprintResourceID,
                fileSHA256: input.contentBytes == nil ? nil : sha256,
                sha256: sha256,
                digestOrigin: digestOrigin,
                perceptualHash: perceptual,
                verificationSignature: analysis.verificationSignature,
                pixelWidth: analysis.pixelWidth,
                pixelHeight: analysis.pixelHeight,
                nowMs: nowMs,
                algoVersion: algoVersion
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
            digestOrigin: digestOrigin,
            perceptualHash: perceptual,
            verificationSignature: analysis.verificationSignature,
            pixelWidth: analysis.pixelWidth,
            pixelHeight: analysis.pixelHeight,
            perceptualAlgoVersion: algoVersion
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

    func completePendingAssets(limit: Int) throws -> [AssetContentFingerprint] {
        let capped = max(0, limit)
        guard capped > 0 else { return [] }
        let pendingIDs = try listPendingAssetIDs(limit: capped, folderOnly: false)
        var results: [AssetContentFingerprint] = []
        results.reserveCapacity(pendingIDs.count)
        for assetID in pendingIDs {
            do {
                results.append(try completeAsset(assetID: assetID))
            } catch FingerprintCompletionError.ineligible,
                    FingerprintCompletionError.notFound,
                    FingerprintCompletionError.sourceChanged,
                    FingerprintCompletionError.sourceUnavailable,
                    FingerprintCompletionError.authorizationRequired,
                    FingerprintCompletionError.decodeFailed
            {
                continue
            }
        }
        return results
    }

    private func listPendingAssetIDs(limit: Int) throws -> [UUID] {
        try listPendingAssetIDs(limit: limit, folderOnly: true)
    }

    private func listPendingAssetIDs(limit: Int, folderOnly: Bool) throws -> [UUID] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT a.id AS asset_id
                FROM asset a
                JOIN source s ON s.id = a.source_id
                LEFT JOIN asset_similarity_fingerprint p
                    ON p.asset_id = a.id
                    AND p.content_revision = a.content_revision
                    AND p.algo_version = CASE a.media_kind
                        WHEN 'video' THEN ?
                        ELSE ?
                    END
                LEFT JOIN file_fingerprint f ON f.asset_id = a.id
                WHERE a.locator_state = 'current'
                  AND a.availability = 'available'
                  AND s.state = 'active'
                  AND (
                    (
                        a.locator_kind = 'file'
                        AND s.kind = 'folder'
                        AND f.asset_id IS NOT NULL
                    )
                    OR (
                        ? = 0
                        AND a.locator_kind = 'photos'
                        AND s.kind = 'photos'
                        AND a.photos_local_identifier IS NOT NULL
                    )
                  )
                  AND (
                    p.asset_id IS NULL
                    OR p.content_sha256 IS NULL
                    OR p.verification_signature IS NULL
                  )
                ORDER BY a.id
                LIMIT ?
                """,
                arguments: [
                    IdenticalDuplicatePolicy.videoPosterPerceptualAlgoVersion,
                    IdenticalDuplicatePolicy.perceptualAlgoVersion,
                    folderOnly ? 1 : 0,
                    limit,
                ]
            )
            return rows.compactMap { row in
                UUID(uuidString: row["asset_id"])
            }
        }
    }

    private enum CompletionLocatorKind {
        case file
        case photos
    }

    private func loadLocatorKind(assetID: UUID) throws -> CompletionLocatorKind {
        try database.pool.read { db in
            guard let raw: String = try String.fetchOne(
                db,
                sql: """
                SELECT locator_kind
                FROM asset
                WHERE id = ?
                  AND locator_state = 'current'
                  AND availability = 'available'
                """,
                arguments: [assetID.uuidString.lowercased()]
            ) else {
                throw FingerprintCompletionError.notFound
            }
            switch raw {
            case AssetLocatorKind.file.rawValue:
                return .file
            case AssetLocatorKind.photos.rawValue:
                return .photos
            default:
                throw FingerprintCompletionError.ineligible
            }
        }
    }

    private func loadCompletedFingerprint(
        assetID: UUID,
        contentRevision: Int,
        algoVersion: String = IdenticalDuplicatePolicy.perceptualAlgoVersion
    ) throws -> AssetContentFingerprint? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    p.content_sha256,
                    p.content_digest_origin,
                    p.perceptual_hash,
                    p.verification_signature,
                    p.pixel_width,
                    p.pixel_height,
                    p.algo_version,
                    p.content_revision
                FROM asset_similarity_fingerprint p
                WHERE p.asset_id = ?
                  AND p.content_sha256 IS NOT NULL
                  AND p.verification_signature IS NOT NULL
                  AND p.pixel_width IS NOT NULL
                  AND p.pixel_height IS NOT NULL
                  AND p.content_revision = ?
                  AND p.algo_version = ?
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    contentRevision,
                    algoVersion,
                ]
            ) else {
                return nil
            }
            let sha256: Data = row["content_sha256"]
            guard let digestOrigin = AssetContentDigestOrigin(
                rawValue: row["content_digest_origin"]
            ) else {
                return nil
            }
            let perceptual: Data = row["perceptual_hash"]
            let verification: Data = row["verification_signature"]
            let pixelWidth: Int = row["pixel_width"]
            let pixelHeight: Int = row["pixel_height"]
            let algo: String = row["algo_version"]
            guard sha256.count == 32,
                  perceptual.count == 8,
                  verification.count == 768,
                  pixelWidth > 0,
                  pixelHeight > 0
            else {
                return nil
            }
            return AssetContentFingerprint(
                assetID: assetID,
                contentRevision: contentRevision,
                sha256: sha256,
                digestOrigin: digestOrigin,
                perceptualHash: perceptual,
                verificationSignature: verification,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                perceptualAlgoVersion: algo
            )
        }
    }

    private struct PhotosCompletionContext {
        let localIdentifier: String
        let contentRevision: Int
        let mediaType: String
        let mediaKind: MediaKind
    }

    private enum PhotosSourceBytesOrigin: Equatable {
        case durableCache
        case localOriginal
        case previewCache
        case localFeatureImage
    }

    private func completePhotosAsset(assetID: UUID) throws -> AssetContentFingerprint {
        let context = try loadPhotosContext(assetID: assetID)
        if context.mediaKind == .video {
            return try completePhotosVideoAsset(assetID: assetID, context: context)
        }
        if let existing = try loadCompletedFingerprint(
            assetID: assetID,
            contentRevision: context.contentRevision
        ), existing.digestOrigin == .verifiedOriginalBytes {
            return existing
        }
        guard photosOriginals != nil
            || photosOriginalCache != nil
            || photosFeatureImages != nil
            || downloadedPreviews != nil
        else {
            throw FingerprintCompletionError.ineligible
        }

        let loaded: (bytes: Data, origin: PhotosSourceBytesOrigin)
        do {
            loaded = try loadPhotosSourceBytes(assetID: assetID, context: context)
        } catch let error as FingerprintCompletionError {
            throw error
        } catch let error as PhotosLibraryError {
            switch error {
            case .authorizationDenied, .authorizationRestricted:
                throw FingerprintCompletionError.authorizationRequired
            case .libraryUnavailable, .cloudOnly, .changeTokenInvalid, .persistenceFailure:
                throw FingerprintCompletionError.sourceUnavailable
            }
        } catch {
            throw FingerprintCompletionError.persistenceFailed
        }
        let bytes = loaded.bytes
        guard !bytes.isEmpty else {
            throw FingerprintCompletionError.sourceUnavailable
        }
        if loaded.origin == .localOriginal,
           let photosOriginalCache
        {
            _ = try? photosOriginalCache.store(
                assetID: assetID,
                contentRevision: context.contentRevision,
                localIdentifier: context.localIdentifier,
                mediaType: context.mediaType,
                sourceBytes: bytes
            )
        }

        let sha256 = Data(SHA256.hash(data: bytes))
        let digestOrigin: AssetContentDigestOrigin
        switch loaded.origin {
        case .durableCache, .localOriginal:
            digestOrigin = .verifiedOriginalBytes
        case .previewCache, .localFeatureImage:
            digestOrigin = .visualDerivative
        }
        let analysis: PerceptualImageAnalysis
        do {
            analysis = try PerceptualImageHash.analyze(
                sourceBytes: bytes,
                expectedMediaType: context.mediaType
            )
        } catch {
            throw FingerprintCompletionError.decodeFailed
        }
        let perceptual = PerceptualImageHash.encodeHash(analysis.dHash)
        do {
            try persistPhotosFingerprint(
                assetID: assetID,
                context: context,
                sha256: sha256,
                digestOrigin: digestOrigin,
                perceptualHash: perceptual,
                verificationSignature: analysis.verificationSignature,
                pixelWidth: analysis.pixelWidth,
                pixelHeight: analysis.pixelHeight
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
            digestOrigin: digestOrigin,
            perceptualHash: perceptual,
            verificationSignature: analysis.verificationSignature,
            pixelWidth: analysis.pixelWidth,
            pixelHeight: analysis.pixelHeight,
            perceptualAlgoVersion: IdenticalDuplicatePolicy.perceptualAlgoVersion
        )
    }

    private func completePhotosVideoAsset(
        assetID: UUID,
        context: PhotosCompletionContext
    ) throws -> AssetContentFingerprint {
        let algoVersion = IdenticalDuplicatePolicy.videoPosterPerceptualAlgoVersion
        if let existing = try loadCompletedFingerprint(
            assetID: assetID,
            contentRevision: context.contentRevision,
            algoVersion: algoVersion
        ) {
            return existing
        }
        guard let photosFeatureImages else {
            throw FingerprintCompletionError.ineligible
        }

        let posterBytes: Data
        do {
            posterBytes = try photosFeatureImages.requestLocalFeatureImage(
                localIdentifier: context.localIdentifier
            )
        } catch let error as PhotosLibraryError {
            switch error {
            case .authorizationDenied, .authorizationRestricted:
                throw FingerprintCompletionError.authorizationRequired
            case .libraryUnavailable, .cloudOnly, .changeTokenInvalid, .persistenceFailure:
                throw FingerprintCompletionError.sourceUnavailable
            }
        } catch {
            throw FingerprintCompletionError.sourceUnavailable
        }
        guard !posterBytes.isEmpty else {
            throw FingerprintCompletionError.sourceUnavailable
        }

        let analysis: PerceptualImageAnalysis
        do {
            analysis = try PerceptualImageHash.analyze(
                sourceBytes: posterBytes,
                expectedMediaType: nil
            )
        } catch {
            throw FingerprintCompletionError.decodeFailed
        }
        let sha256 = PerceptualImageHash.visualContentDigest(analysis)
        let perceptual = PerceptualImageHash.encodeHash(analysis.dHash)
        do {
            try persistPhotosFingerprint(
                assetID: assetID,
                context: context,
                sha256: sha256,
                digestOrigin: .visualDerivative,
                perceptualHash: perceptual,
                verificationSignature: analysis.verificationSignature,
                pixelWidth: analysis.pixelWidth,
                pixelHeight: analysis.pixelHeight,
                algoVersion: algoVersion
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
            digestOrigin: .visualDerivative,
            perceptualHash: perceptual,
            verificationSignature: analysis.verificationSignature,
            pixelWidth: analysis.pixelWidth,
            pixelHeight: analysis.pixelHeight,
            perceptualAlgoVersion: algoVersion
        )
    }

    private func loadPhotosSourceBytes(
        assetID: UUID,
        context: PhotosCompletionContext
    ) throws -> (bytes: Data, origin: PhotosSourceBytesOrigin) {
        if let photosOriginalCache,
           let cached = try photosOriginalCache.load(
               assetID: assetID,
               contentRevision: context.contentRevision,
               localIdentifier: context.localIdentifier
           ),
           !cached.isEmpty
        {
            return (cached, .durableCache)
        }

        if let photosOriginals {
            do {
                let local = try photosOriginals.requestOriginalImageData(
                    localIdentifier: context.localIdentifier
                )
                if !local.isEmpty {
                    return (local, .localOriginal)
                }
            } catch let error as PhotosLibraryError {
                switch error {
                case .authorizationDenied, .authorizationRestricted:
                    throw FingerprintCompletionError.authorizationRequired
                case .cloudOnly, .libraryUnavailable, .changeTokenInvalid, .persistenceFailure:
                    break
                }
            }
        }

        if let downloadedPreviews,
           let preview = try downloadedPreviews.loadDownloadedPreview(assetID: assetID),
           !preview.isEmpty
        {
            return (preview, .previewCache)
        }

        if let photosFeatureImages {
            do {
                let feature = try photosFeatureImages.requestLocalFeatureImage(
                    localIdentifier: context.localIdentifier
                )
                if !feature.isEmpty {
                    return (feature, .localFeatureImage)
                }
            } catch let error as PhotosLibraryError {
                switch error {
                case .authorizationDenied, .authorizationRestricted:
                    throw FingerprintCompletionError.authorizationRequired
                case .cloudOnly, .libraryUnavailable, .changeTokenInvalid, .persistenceFailure:
                    break
                }
            }
        }

        throw FingerprintCompletionError.sourceUnavailable
    }

    private func loadPhotosContext(assetID: UUID) throws -> PhotosCompletionContext {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    a.photos_local_identifier,
                    a.content_revision,
                    a.media_type,
                    a.media_kind
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE a.id = ?
                  AND a.locator_kind = 'photos'
                  AND a.locator_state = 'current'
                  AND a.availability = 'available'
                  AND s.kind = 'photos'
                  AND s.state = 'active'
                """,
                arguments: [assetID.uuidString.lowercased()]
            ),
                let localIdentifier: String = row["photos_local_identifier"]
            else {
                throw FingerprintCompletionError.ineligible
            }
            guard let mediaKind = MediaKind(rawValue: row["media_kind"]) else {
                throw FingerprintCompletionError.ineligible
            }
            return PhotosCompletionContext(
                localIdentifier: localIdentifier,
                contentRevision: row["content_revision"],
                mediaType: row["media_type"],
                mediaKind: mediaKind
            )
        }
    }

    private func persistPhotosFingerprint(
        assetID: UUID,
        context: PhotosCompletionContext,
        sha256: Data,
        digestOrigin: AssetContentDigestOrigin,
        perceptualHash: Data,
        verificationSignature: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        algoVersion: String = IdenticalDuplicatePolicy.perceptualAlgoVersion
    ) throws {
        try database.pool.write { db in
            let current = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM asset a
                    JOIN source s ON s.id = a.source_id
                    WHERE a.id = ?
                      AND a.photos_local_identifier = ?
                      AND a.content_revision = ?
                      AND a.media_type = ?
                      AND a.locator_kind = 'photos'
                      AND a.locator_state = 'current'
                      AND a.availability = 'available'
                      AND s.kind = 'photos'
                      AND s.state = 'active'
                )
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    context.localIdentifier,
                    context.contentRevision,
                    context.mediaType,
                ]
            ) ?? false
            guard current else {
                throw FingerprintCompletionError.sourceChanged
            }
            try upsertSimilarityFingerprint(
                db: db,
                assetID: assetID,
                contentRevision: context.contentRevision,
                sha256: sha256,
                digestOrigin: digestOrigin,
                perceptualHash: perceptualHash,
                verificationSignature: verificationSignature,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                nowMs: clock.nowMs,
                algoVersion: algoVersion
            )
        }
    }

    private func persist(
        assetID: UUID,
        contentRevision: Int,
        expectedSize: Int64,
        expectedModifiedAtNs: Int64,
        expectedResourceID: Data?,
        fileSHA256: Data?,
        sha256: Data,
        digestOrigin: AssetContentDigestOrigin,
        perceptualHash: Data,
        verificationSignature: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        nowMs: Int64,
        algoVersion: String = IdenticalDuplicatePolicy.perceptualAlgoVersion
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
                    fileSHA256,
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

            try upsertSimilarityFingerprint(
                db: db,
                assetID: assetID,
                contentRevision: contentRevision,
                sha256: sha256,
                digestOrigin: digestOrigin,
                perceptualHash: perceptualHash,
                verificationSignature: verificationSignature,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                nowMs: nowMs,
                algoVersion: algoVersion
            )
        }
    }

    private func upsertSimilarityFingerprint(
        db: Database,
        assetID: UUID,
        contentRevision: Int,
        sha256: Data,
        digestOrigin: AssetContentDigestOrigin,
        perceptualHash: Data,
        verificationSignature: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        nowMs: Int64,
        algoVersion: String = IdenticalDuplicatePolicy.perceptualAlgoVersion
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO asset_similarity_fingerprint (
                asset_id, content_revision, algo_version, perceptual_hash,
                created_at_ms, updated_at_ms, content_sha256, content_digest_origin,
                verification_signature, pixel_width, pixel_height
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET
                content_revision = excluded.content_revision,
                algo_version = excluded.algo_version,
                perceptual_hash = excluded.perceptual_hash,
                content_sha256 = excluded.content_sha256,
                content_digest_origin = excluded.content_digest_origin,
                verification_signature = excluded.verification_signature,
                pixel_width = excluded.pixel_width,
                pixel_height = excluded.pixel_height,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [
                assetID.uuidString.lowercased(),
                contentRevision,
                algoVersion,
                perceptualHash,
                nowMs,
                nowMs,
                sha256,
                digestOrigin.rawValue,
                verificationSignature,
                pixelWidth,
                pixelHeight,
            ]
        )
    }
}

enum PhotosOriginalCacheError: Error, Equatable {
    case unsafePath
    case persistenceFailed
    case assetChanged
    case previewWriteRejected
}

/// App-owned, non-evicting cache for full Photos still bytes used by exact
/// detection. It lives under Application Support rather than the disposable
/// preview cache.
struct PhotosOriginalCacheService: Sendable {
    let database: CatalogDatabase
    let rootURL: URL
    let clock: any JobClock

    func storageUsage() throws -> PhotosOriginalStorageUsage {
        try database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) AS entry_count,
                       COALESCE(SUM(byte_size), 0) AS registered_bytes
                FROM photos_original_cache_entry
                """
            )
            return PhotosOriginalStorageUsage(
                entryCount: row?["entry_count"] ?? 0,
                registeredBytes: row?["registered_bytes"] ?? 0
            )
        }
    }

    func clearAll() throws -> PhotosOriginalStorageClearResult {
        let entries: [(objectName: String, byteSize: Int64)] = try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT object_name, byte_size
                FROM photos_original_cache_entry
                ORDER BY created_at_ms, asset_id
                """
            ).map { row in
                (objectName: row["object_name"], byteSize: row["byte_size"])
            }
        }
        guard !entries.isEmpty else {
            return PhotosOriginalStorageClearResult(
                removedEntries: 0,
                removedBytes: 0,
                partialReclaim: false
            )
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: rootURL.path) {
            let rootValues: URLResourceValues
            do {
                rootValues = try rootURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
            } catch {
                throw PhotosOriginalCacheError.persistenceFailed
            }
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                throw PhotosOriginalCacheError.unsafePath
            }
        }

        var removedEntries = 0
        var removedBytes: Int64 = 0
        var partialReclaim = false
        for entry in entries {
            let objectURL: URL
            do {
                objectURL = try validatedObjectURL(objectName: entry.objectName)
            } catch {
                partialReclaim = true
                continue
            }

            if fileManager.fileExists(atPath: objectURL.path) {
                do {
                    let values = try objectURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                    )
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        partialReclaim = true
                        continue
                    }
                    try fileManager.removeItem(at: objectURL)
                    removedBytes += entry.byteSize
                } catch {
                    partialReclaim = true
                    continue
                }
            }

            do {
                let deleted = try database.pool.write { db in
                    try db.execute(
                        sql: """
                        DELETE FROM photos_original_cache_entry
                        WHERE object_name = ?
                        """,
                        arguments: [entry.objectName]
                    )
                    return db.changesCount
                }
                if deleted > 0 {
                    removedEntries += 1
                }
            } catch {
                partialReclaim = true
            }
        }
        return PhotosOriginalStorageClearResult(
            removedEntries: removedEntries,
            removedBytes: removedBytes,
            partialReclaim: partialReclaim
        )
    }

    func removePixelObject(assetID: UUID) throws {
        guard let objectName = try database.pool.read({ db in
            try String.fetchOne(
                db,
                sql: "SELECT object_name FROM photos_original_cache_entry WHERE asset_id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }) else {
            return
        }

        let objectURL = try validatedObjectURL(objectName: objectName)
        if FileManager.default.fileExists(atPath: objectURL.path) {
            let values: URLResourceValues
            do {
                values = try objectURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                throw PhotosOriginalCacheError.persistenceFailed
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PhotosOriginalCacheError.unsafePath
            }
            do {
                try FileManager.default.removeItem(at: objectURL)
            } catch {
                throw PhotosOriginalCacheError.persistenceFailed
            }
        }

        do {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    DELETE FROM photos_original_cache_entry
                    WHERE asset_id = ? AND object_name = ?
                    """,
                    arguments: [assetID.uuidString.lowercased(), objectName]
                )
            }
        } catch {
            throw PhotosOriginalCacheError.persistenceFailed
        }
    }

    func load(
        assetID: UUID,
        contentRevision: Int,
        localIdentifier: String
    ) throws -> Data? {
        guard let row = try database.pool.read({ db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT
                    c.object_name,
                    c.byte_size,
                    c.encoded_sha256
                FROM photos_original_cache_entry c
                JOIN asset a ON a.id = c.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE c.asset_id = ?
                  AND c.content_revision = ?
                  AND c.photos_local_identifier = ?
                  AND a.content_revision = c.content_revision
                  AND a.photos_local_identifier = c.photos_local_identifier
                  AND a.locator_kind = 'photos'
                  AND a.locator_state = 'current'
                  AND a.availability = 'available'
                  AND s.kind = 'photos'
                  AND s.state = 'active'
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    contentRevision,
                    localIdentifier,
                ]
            )
        }) else {
            return nil
        }
        let objectName: String = row["object_name"]
        let expectedSize: Int64 = row["byte_size"]
        let expectedSHA: Data = row["encoded_sha256"]
        let objectURL = try validatedObjectURL(objectName: objectName)
        guard let bytes = try? Data(contentsOf: objectURL),
              Int64(bytes.count) == expectedSize,
              Data(SHA256.hash(data: bytes)) == expectedSHA
        else {
            try invalidate(assetID: assetID, objectURL: objectURL)
            return nil
        }
        return bytes
    }

    func store(
        assetID: UUID,
        contentRevision: Int,
        localIdentifier: String,
        mediaType: String,
        sourceBytes: Data
    ) throws -> Data {
        guard !sourceBytes.isEmpty else {
            throw PhotosOriginalCacheError.persistenceFailed
        }
        try ensureRoot()
        let objectName = UUID().uuidString.lowercased()
        let objectURL = try validatedObjectURL(objectName: objectName)
        do {
            try sourceBytes.write(to: objectURL, options: [.atomic])
        } catch {
            throw PhotosOriginalCacheError.persistenceFailed
        }
        let encodedSHA = Data(SHA256.hash(data: sourceBytes))
        var replacedObjectName: String?
        do {
            try database.pool.write { db in
                let current = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM asset a
                        JOIN source s ON s.id = a.source_id
                        WHERE a.id = ?
                          AND a.content_revision = ?
                          AND a.photos_local_identifier = ?
                          AND a.media_type = ?
                          AND a.locator_kind = 'photos'
                          AND a.locator_state = 'current'
                          AND a.availability = 'available'
                          AND s.kind = 'photos'
                          AND s.state = 'active'
                    )
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        contentRevision,
                        localIdentifier,
                        mediaType,
                    ]
                ) ?? false
                guard current else {
                    throw PhotosOriginalCacheError.assetChanged
                }
                replacedObjectName = try String.fetchOne(
                    db,
                    sql: "SELECT object_name FROM photos_original_cache_entry WHERE asset_id = ?",
                    arguments: [assetID.uuidString.lowercased()]
                )
                try db.execute(
                    sql: """
                    INSERT INTO photos_original_cache_entry (
                        asset_id, content_revision, photos_local_identifier,
                        object_name, media_type,
                        byte_size, encoded_sha256, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        content_revision = excluded.content_revision,
                        photos_local_identifier = excluded.photos_local_identifier,
                        object_name = excluded.object_name,
                        media_type = excluded.media_type,
                        byte_size = excluded.byte_size,
                        encoded_sha256 = excluded.encoded_sha256,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        contentRevision,
                        localIdentifier,
                        objectName,
                        mediaType,
                        Int64(sourceBytes.count),
                        encodedSHA,
                        clock.nowMs,
                        clock.nowMs,
                    ]
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: objectURL)
            throw error
        }
        if let replacedObjectName, replacedObjectName != objectName,
           let oldURL = try? validatedObjectURL(objectName: replacedObjectName)
        {
            try? FileManager.default.removeItem(at: oldURL)
        }
        return sourceBytes
    }

    private func ensureRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PhotosOriginalCacheError.unsafePath
            }
        } catch let error as PhotosOriginalCacheError {
            throw error
        } catch {
            throw PhotosOriginalCacheError.persistenceFailed
        }
    }

    private func validatedObjectURL(objectName: String) throws -> URL {
        guard let uuid = UUID(uuidString: objectName),
              objectName == uuid.uuidString.lowercased()
        else {
            throw PhotosOriginalCacheError.unsafePath
        }
        let standardizedRoot = rootURL.standardizedFileURL
        let candidate = standardizedRoot.appendingPathComponent(objectName, isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == standardizedRoot else {
            throw PhotosOriginalCacheError.unsafePath
        }
        return candidate
    }

    private func invalidate(assetID: UUID, objectURL: URL) throws {
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM photos_original_cache_entry WHERE asset_id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        try? FileManager.default.removeItem(at: objectURL)
    }
}

extension PhotosOriginalCacheService: DownloadedPreviewCachePort {
    func loadDownloadedPreview(assetID: UUID) throws -> Data? {
        guard let context: (Int, String) = try database.pool.read({ db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT content_revision, photos_local_identifier
                FROM asset
                WHERE id = ?
                  AND photos_local_identifier IS NOT NULL
                """,
                arguments: [assetID.uuidString.lowercased()]
            ), let localIdentifier: String = row["photos_local_identifier"] else {
                return nil
            }
            return (row["content_revision"], localIdentifier)
        }) else {
            return nil
        }
        return try load(
            assetID: assetID,
            contentRevision: context.0,
            localIdentifier: context.1
        )
    }

    func storeDownloadedPreview(assetID: UUID, sourceBytes: Data) async throws -> Data {
        _ = assetID
        _ = sourceBytes
        // This conformance is deliberately read-only for Feature Print input
        // loading. Preview bytes are transformed and must never masquerade as
        // the durable full original used by exact duplicate detection.
        throw PhotosOriginalCacheError.previewWriteRejected
    }
}

/// Read-through composition for feature generation: prefer the durable full
/// Photos original when present, preserve the existing disposable preview as a
/// fallback, and route all preview writes only to the disposable cache.
struct PrioritizedDownloadedPreviewCache: DownloadedPreviewCachePort {
    let primary: any DownloadedPreviewCachePort
    let fallback: any DownloadedPreviewCachePort

    func loadDownloadedPreview(assetID: UUID) throws -> Data? {
        if let primaryBytes = try primary.loadDownloadedPreview(assetID: assetID) {
            return primaryBytes
        }
        return try fallback.loadDownloadedPreview(assetID: assetID)
    }

    func storeDownloadedPreview(assetID: UUID, sourceBytes: Data) async throws -> Data {
        try await fallback.storeDownloadedPreview(assetID: assetID, sourceBytes: sourceBytes)
    }
}
