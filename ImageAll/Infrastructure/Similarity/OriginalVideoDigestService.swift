import CryptoKit
import Darwin
import Foundation
import GRDB

/// Explicit full-file work, separate from automatic poster/visual fingerprint completion.
/// One file descriptor and one 256 KiB buffer per call; callers schedule files serially.
struct OriginalVideoDigestService: Sendable {
    static let policy = "folder-original-sha256-v1"
    static let analysisPolicy = "video-original-sha256-v2"
    static let chunkByteCount = 256 * 1_024
    let database: CatalogDatabase
    let sourceAccess: FolderReconcileSourceAccessService
    let clock: any JobClock

    struct Result: Sendable, Equatable {
        let assetID: UUID
        let contentRevision: Int
        let sha256: Data
        let byteCount: Int64
        let reused: Bool
    }

    func completeFolderVideo(
        assetID: UUID,
        checkCancellation: () throws -> Void = {},
        onProgress: (_ completedBytes: Int64, _ totalBytes: Int64) throws -> Void = { _, _ in }
    ) throws -> Result {
        try checkCancellation()
        let repository = GRDBDerivedImageCacheRepository(database: database)
        guard let context = try repository.fetchGenerationContext(assetID: assetID) else {
            throw FingerprintCompletionError.notFound
        }
        // Original bytes do not require a known duration or a decodable poster.
        guard context.mediaKind == .video,
              context.locatorKind == AssetLocatorKind.file.rawValue,
              context.locatorState == AssetLocatorState.current.rawValue,
              context.availability == AssetAvailability.available.rawValue,
              context.sourceKind == SourceKind.folder.rawValue,
              context.sourceState == SourceState.active.rawValue,
              case .success(_) = RelativePathRules.validate(context.relativePath),
              RelativePathRules.fileName(from: context.relativePath) == context.fileName,
              context.fingerprintSizeBytes > 0, context.fingerprintModifiedAtNs >= 0 else {
            throw FingerprintCompletionError.ineligible
        }
        do {
            return try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
                let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: rootURL)
                defer { Darwin.close(rootFD) }
                let fileFD = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
                    directoryFD: rootFD, relativePath: context.relativePath)
                defer { Darwin.close(fileFD) }
                let before = try FileIdentity.read(fileFD)
                let catalogFacts = try DerivedImageSourceFingerprintFacts.handleFacts(
                    fd: fileFD, reader: FoundationFolderFileResourceReader())
                guard context.matchesHandleFacts(catalogFacts), before.size > 0 else {
                    throw FingerprintCompletionError.sourceChanged
                }
                let cached = try reusableDigest(context: context, identity: before)
                let digest: Data
                if let cached {
                    digest = cached
                    try onProgress(before.size, before.size)
                } else {
                    try onProgress(0, before.size)
                    var hasher = SHA256()
                    var buffer = [UInt8](repeating: 0, count: Self.chunkByteCount)
                    var completed: Int64 = 0
                    while true {
                        try checkCancellation()
                        let count = buffer.withUnsafeMutableBytes { Darwin.read(fileFD, $0.baseAddress, $0.count) }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw DerivedImageSecureIOError.ioFailure
                        }
                        if count == 0 { break }
                        completed += Int64(count)
                        guard completed <= before.size else { throw FingerprintCompletionError.sourceChanged }
                        buffer.withUnsafeBytes {
                            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress, count: count))
                        }
                        try onProgress(completed, before.size)
                    }
                    guard completed == before.size else { throw FingerprintCompletionError.sourceChanged }
                    digest = Data(hasher.finalize())
                }
                try checkCancellation()
                guard try FileIdentity.read(fileFD) == before else { throw FingerprintCompletionError.sourceChanged }
                // Reopen the locator as well: an unchanged open inode can have been renamed/replaced.
                let currentFD = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
                    directoryFD: rootFD, relativePath: context.relativePath)
                defer { Darwin.close(currentFD) }
                guard try FileIdentity.read(currentFD) == before else { throw FingerprintCompletionError.sourceChanged }
                try persist(digest: digest, context: context, identity: before, checkCancellation: checkCancellation)
                try checkCancellation()
                return Result(assetID: assetID, contentRevision: context.contentRevision,
                    sha256: digest, byteCount: before.size, reused: cached != nil)
            }
        } catch {
            // A failed revalidation must not leave an older digest looking current.
            try database.pool.write { db in
                try db.execute(sql: "DELETE FROM asset_original_content_digest WHERE asset_id = ? AND content_revision = ?",
                    arguments: [assetID.uuidString.lowercased(), context.contentRevision])
            }
            throw error
        }
    }

    /// Read-only revalidation of previously hashed bytes. Reuse is permitted only
    /// while the open file and current locator retain the exact recorded identity,
    /// including ctime. No new digest is published as a side effect of cleanup.
    func validateFolderVideoEvidence(
        assetID: UUID, contentRevision: Int, sha256: Data, descriptorIdentity: String
    ) throws {
        guard let context = try GRDBDerivedImageCacheRepository(database: database)
            .fetchGenerationContext(assetID: assetID),
              context.mediaKind == .video, context.contentRevision == contentRevision,
              context.locatorKind == AssetLocatorKind.file.rawValue,
              context.locatorState == AssetLocatorState.current.rawValue,
              context.availability == AssetAvailability.available.rawValue else {
            throw FingerprintCompletionError.sourceChanged
        }
        try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
            let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: rootURL)
            defer { Darwin.close(rootFD) }
            let fileFD = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
                directoryFD: rootFD, relativePath: context.relativePath)
            defer { Darwin.close(fileFD) }
            let before = try FileIdentity.read(fileFD)
            let catalogFacts = try DerivedImageSourceFingerprintFacts.handleFacts(
                fd: fileFD, reader: FoundationFolderFileResourceReader())
            guard before.token == descriptorIdentity,
                  context.matchesHandleFacts(catalogFacts),
                  try reusableDigest(context: context, identity: before) == sha256 else {
                throw FingerprintCompletionError.sourceChanged
            }
            let currentFD = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
                directoryFD: rootFD, relativePath: context.relativePath)
            defer { Darwin.close(currentFD) }
            guard try FileIdentity.read(fileFD) == before,
                  try FileIdentity.read(currentFD) == before else {
                throw FingerprintCompletionError.sourceChanged
            }
        }
    }

    struct FileIdentity: Equatable {
        let size: Int64
        let modifiedAtNs: Int64
        let token: String

        static func read(_ fd: Int32) throws -> FileIdentity {
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
                throw DerivedImageSecureIOError.ioFailure
            }
            let modified = Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec)
            // ctime prevents reuse after in-place writes followed by restoration of size/mtime.
            let token = "\(value.st_dev):\(value.st_ino):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec):\(modified)"
            return FileIdentity(size: Int64(value.st_size), modifiedAtNs: modified, token: token)
        }
    }

    private func reusableDigest(context: DerivedImageAssetGenerationContext, identity: FileIdentity) throws -> Data? {
        try database.pool.read { db in
            let digest = try Data.fetchOne(db, sql: """
                SELECT sha256 FROM asset_original_content_digest
                WHERE asset_id = ? AND content_revision = ? AND source_id = ?
                  AND provenance = ? AND relative_path = ? AND size_bytes = ?
                  AND modified_at_ns = ? AND descriptor_identity = ?
                  AND catalog_resource_id IS ?
                """, arguments: [context.assetID.uuidString.lowercased(), context.contentRevision,
                    context.sourceID.uuidString.lowercased(), Self.policy, context.relativePath,
                    identity.size, context.fingerprintModifiedAtNs, identity.token, context.fingerprintResourceID])
            return digest?.count == 32 ? digest : nil
        }
    }

    private func persist(digest: Data, context: DerivedImageAssetGenerationContext, identity: FileIdentity,
        checkCancellation: () throws -> Void
    ) throws {
        // Cancellation can query the job queue and heartbeat; never invoke it while
        // holding the catalog writer, which the heartbeat also needs.
        try checkCancellation()
        try database.pool.write { db in
            let valid = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM asset a JOIN source s ON s.id = a.source_id
                    JOIN file_fingerprint f ON f.asset_id = a.id
                    WHERE a.id = ? AND a.content_revision = ? AND a.source_id = ?
                      AND a.media_kind = 'video' AND a.locator_kind = 'file'
                      AND a.locator_state = 'current' AND a.availability = 'available'
                      AND a.relative_path = ? AND s.kind = 'folder' AND s.state = 'active'
                      AND f.size_bytes = ? AND f.modified_at_ns = ? AND f.resource_id IS ?
                )
                """, arguments: [context.assetID.uuidString.lowercased(), context.contentRevision,
                    context.sourceID.uuidString.lowercased(), context.relativePath,
                    identity.size, context.fingerprintModifiedAtNs, context.fingerprintResourceID]) ?? false
            guard valid else { throw FingerprintCompletionError.sourceChanged }
            try db.execute(sql: """
                INSERT INTO asset_original_content_digest
                    (asset_id, content_revision, source_id, provenance, relative_path, size_bytes,
                     modified_at_ns, descriptor_identity, catalog_resource_id, sha256, verified_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET content_revision = excluded.content_revision,
                    source_id = excluded.source_id, provenance = excluded.provenance,
                    relative_path = excluded.relative_path, size_bytes = excluded.size_bytes,
                    modified_at_ns = excluded.modified_at_ns, descriptor_identity = excluded.descriptor_identity,
                    catalog_resource_id = excluded.catalog_resource_id, sha256 = excluded.sha256,
                    verified_at_ms = excluded.verified_at_ms
                """, arguments: [context.assetID.uuidString.lowercased(), context.contentRevision,
                    context.sourceID.uuidString.lowercased(), Self.policy, context.relativePath,
                    identity.size, context.fingerprintModifiedAtNs, identity.token, context.fingerprintResourceID,
                    digest, clock.nowMs])
        }
    }
}

struct PhotosOriginalVideoDigestService: Sendable {
    static let policy = "photokit-video-resource-sha256-v1"
    let database: CatalogDatabase
    let reader: any PhotosOriginalVideoContentPort
    let clock: any JobClock

    func complete(assetID: UUID, checkCancellation: () throws -> Void = {},
        onByteProgress: (Int64, Int64) -> Void = { _, _ in }) throws {
        let before = try context(assetID: assetID)
        try checkCancellation()
        do {
            // PhotoKit exposes no stable public resource byte revision. Re-read the
            // resource on every explicit scan instead of trusting metadata-only reuse.
            let digest = try reader.requestLocalOriginalVideoDigest(localIdentifier: before.localIdentifier,
                checkCancellation: checkCancellation, onByteProgress: onByteProgress)
            try checkCancellation()
            guard digest.sha256.count == 32, digest.byteCount > 0, !digest.resourceIdentity.isEmpty else {
                throw FingerprintCompletionError.sourceChanged
            }
            try persist(before, digest: digest, status: "verified")
            try checkCancellation()
        } catch is CancellationError {
            try removeEvidence(before)
            throw CancellationError()
        } catch {
            let status: String
            switch error {
            case PhotosLibraryError.cloudOnly: status = "cloudOnly"
            case FingerprintCompletionError.ineligible: status = "unsupported"
            case FingerprintCompletionError.sourceChanged: status = "sourceChanged"
            default: status = "unavailable"
            }
            try removeEvidence(before)
            if (try? context(assetID: assetID)) == before {
                try persist(before, digest: nil, status: status)
            }
            // The job can still analyze a locally available poster independently.
            if error is PhotosLibraryError || error is FingerprintCompletionError { return }
            throw error
        }
    }

    private struct Context: Equatable {
        let assetID: UUID
        let sourceID: String
        let revision: Int
        let localIdentifier: String
    }

    private func context(assetID: UUID) throws -> Context {
        try database.pool.read { db in try context(assetID: assetID, db: db) }
    }

    private func context(assetID: UUID, db: Database) throws -> Context {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT a.source_id, a.content_revision, a.photos_local_identifier
            FROM asset a JOIN source s ON s.id = a.source_id
            WHERE a.id = ? AND a.media_kind = 'video' AND a.locator_kind = 'photos'
              AND a.locator_state = 'current' AND a.availability = 'available'
              AND s.kind = 'photos' AND s.state = 'active'
            """, arguments: [assetID.uuidString.lowercased()]),
              let localIdentifier: String = row["photos_local_identifier"], !localIdentifier.isEmpty else {
            throw FingerprintCompletionError.ineligible
        }
        return Context(assetID: assetID, sourceID: row["source_id"], revision: row["content_revision"],
            localIdentifier: localIdentifier)
    }

    private func persist(_ before: Context, digest: PhotosOriginalVideoDigest?, status: String) throws {
        try database.pool.write { db in
            guard try context(assetID: before.assetID, db: db) == before else {
                throw FingerprintCompletionError.sourceChanged
            }
            try db.execute(sql: """
                INSERT INTO asset_photos_original_video_digest
                    (asset_id, content_revision, source_id, photos_local_identifier, provenance,
                     resource_identity, has_adjustments, size_bytes, sha256, status, checked_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    content_revision = excluded.content_revision, source_id = excluded.source_id,
                    photos_local_identifier = excluded.photos_local_identifier, provenance = excluded.provenance,
                    resource_identity = excluded.resource_identity, has_adjustments = excluded.has_adjustments,
                    size_bytes = excluded.size_bytes, sha256 = excluded.sha256,
                    status = excluded.status, checked_at_ms = excluded.checked_at_ms
                """, arguments: [before.assetID.uuidString.lowercased(), before.revision, before.sourceID,
                    before.localIdentifier, Self.policy, digest?.resourceIdentity, digest?.hasAdjustments == true ? 1 : 0,
                    digest?.byteCount, digest?.sha256, status, clock.nowMs])
        }
    }

    private func removeEvidence(_ before: Context) throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM asset_photos_original_video_digest WHERE asset_id = ? AND content_revision = ?",
                arguments: [before.assetID.uuidString.lowercased(), before.revision])
        }
    }
}

extension PhotosOriginalVideoDigestService {
    static func summary(database: CatalogDatabase, assetIDs: [UUID]) throws -> PhotosOriginalVideoAnalysisSummary {
        try database.pool.read { db in
            var result = PhotosOriginalVideoAnalysisSummary()
            let ids = Array(Set(assetIDs)).map { $0.uuidString.lowercased() }
            for offset in stride(from: 0, to: ids.count, by: 400) {
                let batch = Array(ids[offset..<min(offset + 400, ids.count)])
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.status, d.has_adjustments
                    FROM asset_photos_original_video_digest d JOIN asset a ON a.id = d.asset_id
                    WHERE a.id IN (\(placeholders)) AND a.media_kind = 'video'
                      AND a.locator_kind = 'photos' AND a.content_revision = d.content_revision
                      AND a.source_id = d.source_id AND a.photos_local_identifier = d.photos_local_identifier
                    """, arguments: StatementArguments(batch))
                for row in rows {
                    let status: String = row["status"]
                    if status == "cloudOnly" { result.cloudOnlyCount += 1 }
                    else if status != "verified" { result.unavailableCount += 1 }
                    if status == "verified", (row["has_adjustments"] as Int) == 1 {
                        result.adjustedOriginalCount += 1
                    }
                }
            }
            return result
        }
    }
}

/// Folder analysis checkpoints use the same no-follow physical identity as full
/// original verification, without rereading the entire movie for every frame.
struct FolderVideoAnalysisService: Sendable {
    let database: CatalogDatabase
    let sourceAccess: FolderReconcileSourceAccessService
    let clock: any JobClock
    var photosSource: (any PhotosVideoAnalysisSourcePort)? = nil

    func analyze(assetID: UUID, expectedRevision: Int? = nil, forceRebuild: Bool = false, checkCancellation: () throws -> Void = {},
                 onFrame: (VideoAnalysisFrame) throws -> Void = { _ in },
                 onCompleted: (VideoAnalysisSamplingResult, VideoAnalysisFrameCache.Key) throws -> Void = { _, _ in }) throws -> VideoAnalysisSamplingResult {
        if let context = try photosContext(assetID: assetID) {
            guard expectedRevision == nil || expectedRevision == context.revision else { throw FeaturePrintError.sourceChanged }
            return try analyzePhotos(assetID: assetID, context: context, forceRebuild: forceRebuild,
                checkCancellation: checkCancellation, onFrame: onFrame, onCompleted: onCompleted)
        }
        let repository = GRDBDerivedImageCacheRepository(database: database)
        guard let context = try repository.fetchGenerationContext(assetID: assetID),
              expectedRevision == nil || context.contentRevision == expectedRevision,
              context.isEligibleForGeneration, context.mediaKind == .video,
              context.locatorKind == AssetLocatorKind.file.rawValue,
              let duration = context.durationMs, duration > 0 else {
            throw FingerprintCompletionError.ineligible
        }
        return try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { root in
            let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: root)
            defer { Darwin.close(rootFD) }
            let fd = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(directoryFD: rootFD, relativePath: context.relativePath)
            defer { Darwin.close(fd) }
            let identity = try OriginalVideoDigestService.FileIdentity.read(fd)
            guard context.matchesHandleFacts(try DerivedImageSourceFingerprintFacts.handleFacts(
                fd: fd, reader: FoundationFolderFileResourceReader())) else { throw FingerprintCompletionError.sourceChanged }
            let cache = VideoAnalysisFrameCache(database: database, clock: clock)
            let key = VideoAnalysisFrameCache.Key(assetID: assetID, contentRevision: context.contentRevision,
                policy: VideoAnalysisSamplingPolicy.identity,
                sourceIdentity: "\(context.sourceID):\(context.relativePath):\(duration):\(identity.token):\(identity.size)")
            func validate() throws {
                try checkCancellation()
                guard try OriginalVideoDigestService.FileIdentity.read(fd) == identity,
                      try repository.fetchGenerationContext(assetID: assetID) == context else {
                    throw FingerprintCompletionError.sourceChanged
                }
                let current = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(directoryFD: rootFD, relativePath: context.relativePath)
                defer { Darwin.close(current) }
                guard try OriginalVideoDigestService.FileIdentity.read(current) == identity else {
                    throw FingerprintCompletionError.sourceChanged
                }
            }
            try validate()
            if forceRebuild { try cache.discardCurrentRepresentation(key: key) }
            let cached = try cache.frames(key: key)
            let result = try AVFoundationVideoAnalysisSampler().sample(
                sourceFileDescriptorURL: DerivedImageSourceFingerprintFacts.fileDescriptorURL(for: fd),
                mediaType: context.mediaType, durationMs: duration,
                checkCancellation: validate, cachedFrames: cached, onFrame: { frame in
                    try validate()
                    try cache.store(frame, key: key)
                    try onFrame(frame)
                })
            try validate()
            try onCompleted(result, key)
            try validate()
            return result
        }
    }

    private struct PhotosContext: Equatable {
        let revision: Int
        let sourceID: String
        let localIdentifier: String
        let updatedAt: Int64
    }

    private func photosContext(assetID: UUID) throws -> PhotosContext? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT a.content_revision, a.source_id, a.photos_local_identifier, a.record_updated_at_ms
                FROM asset a JOIN source s ON s.id = a.source_id
                WHERE a.id = ? AND a.media_kind = 'video' AND a.locator_kind = 'photos'
                AND a.locator_state = 'current' AND a.availability = 'available'
                AND s.kind = 'photos' AND s.state = 'active'
                """, arguments: [assetID.uuidString.lowercased()]),
                  let local: String = row["photos_local_identifier"], !local.isEmpty else { return nil }
            return PhotosContext(revision: row["content_revision"], sourceID: row["source_id"],
                localIdentifier: local, updatedAt: row["record_updated_at_ms"])
        }
    }

    private func analyzePhotos(assetID: UUID, context: PhotosContext, forceRebuild: Bool,
        checkCancellation: () throws -> Void, onFrame: (VideoAnalysisFrame) throws -> Void,
        onCompleted: (VideoAnalysisSamplingResult, VideoAnalysisFrameCache.Key) throws -> Void) throws -> VideoAnalysisSamplingResult {
        guard let photosSource else { throw FeaturePrintError.sourceUnavailable }
        return try photosSource.withLocalVideoAnalysisSource(localIdentifier: context.localIdentifier,
            checkCancellation: checkCancellation) { source in
                guard source.url.isFileURL, source.durationMs > 0, !source.resourceIdentity.isEmpty else {
                    throw FeaturePrintError.assetIneligible
                }
                let fd = try DerivedImageSecureIO.openReadOnlyNoFollow(at: source.url)
                defer { Darwin.close(fd) }
                let physical = try OriginalVideoDigestService.FileIdentity.read(fd)
                let key = VideoAnalysisFrameCache.Key(assetID: assetID, contentRevision: context.revision,
                    policy: VideoAnalysisSamplingPolicy.identity,
                    sourceIdentity: "photos:\(context.sourceID):\(context.localIdentifier):\(source.resourceIdentity):\(source.durationMs):\(source.mediaType):\(physical.token):\(physical.size)")
                func validate() throws {
                    try checkCancellation()
                    guard try photosContext(assetID: assetID) == context,
                          try OriginalVideoDigestService.FileIdentity.read(fd) == physical else { throw FeaturePrintError.sourceChanged }
                    let current = try DerivedImageSecureIO.openReadOnlyNoFollow(at: source.url)
                    defer { Darwin.close(current) }
                    guard try OriginalVideoDigestService.FileIdentity.read(current) == physical else { throw FeaturePrintError.sourceChanged }
                }
                try validate()
                let cache = VideoAnalysisFrameCache(database: database, clock: clock)
                if forceRebuild { try cache.discardCurrentRepresentation(key: key) }
                let result = try AVFoundationVideoAnalysisSampler().sample(
                    sourceFileDescriptorURL: DerivedImageSourceFingerprintFacts.fileDescriptorURL(for: fd),
                    mediaType: source.mediaType, durationMs: source.durationMs,
                    checkCancellation: validate, cachedFrames: cache.frames(key: key), onFrame: { frame in
                        try validate()
                        try cache.store(frame, key: key)
                        try onFrame(frame)
                    })
                try validate()
                try onCompleted(result, key)
                try validate()
                return result
            }
    }

    func analyzeWithFeatures(assetID: UUID, expectedRevision: Int? = nil, forceRebuild: Bool = false,
                             checkCancellation: () throws -> Void = {}) throws
        -> (sampling: VideoAnalysisSamplingResult, features: VideoMultiFrameFeatureSet, reusedFeatures: Bool) {
        var features: VideoMultiFrameFeatureSet?
        var reused = false
        let cache = VideoAnalysisFeatureCache(database: database, clock: clock)
        let sampling = try analyze(assetID: assetID, expectedRevision: expectedRevision, forceRebuild: forceRebuild,
            checkCancellation: checkCancellation, onCompleted: { result, key in
                if !forceRebuild, let existing = try cache.load(key: key, sampling: result) {
                    features = existing
                    reused = true
                } else {
                    let generated = try VideoMultiFrameFeatureSet.generate(result, checkCancellation: checkCancellation)
                    try checkCancellation()
                    try cache.store(generated, key: key, sampling: result)
                    features = generated
                }
            })
        guard let features else { throw FeaturePrintError.generationFailed }
        return (sampling, features, reused)
    }
}

/// SQLite owns cache atomicity; no external cache paths can escape a managed root.
/// Partial checkpoints are reusable evidence, not a completed asset analysis.
struct VideoAnalysisFrameCache {
    static let maximumTotalBytes = 64 * 1_024 * 1_024
    let database: CatalogDatabase
    let clock: any JobClock
    struct Key {
        let assetID: UUID
        let contentRevision: Int
        let policy: String
        let sourceIdentity: String
        var arguments: StatementArguments {
            [assetID.uuidString.lowercased(), contentRevision, policy, sourceIdentity]
        }
    }
    func discardCurrentRepresentation(key: Key) throws {
        try database.pool.write { db in
            try db.execute(sql: """
                DELETE FROM video_analysis_frame
                WHERE asset_id = ? AND content_revision = ? AND policy = ? AND source_identity = ?
                """, arguments: key.arguments)
        }
    }

    func frames(key: Key) throws -> [Int64: VideoAnalysisFrame] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.* FROM video_analysis_frame f JOIN asset a ON a.id = f.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE f.asset_id = ? AND f.content_revision = ? AND f.policy = ? AND f.source_identity = ?
                  AND a.content_revision = f.content_revision AND a.media_kind = 'video'
                  AND a.locator_state = 'current' AND a.availability = 'available' AND s.state = 'active'
                ORDER BY f.requested_ms LIMIT 5
                """, arguments: key.arguments)
            var result: [Int64: VideoAnalysisFrame] = [:]
            for row in rows {
                let bytes: Data = row["jpeg"]
                guard Data(SHA256.hash(data: bytes)) == (row["sha256"] as Data) else { continue }
                let time: Int64 = row["requested_ms"]
                result[time] = VideoAnalysisFrame(requestedTimeMs: time, actualTimeMs: row["actual_ms"], jpegBytes: bytes)
            }
            return result
        }
    }
    func store(_ frame: VideoAnalysisFrame, key: Key) throws {
        guard !frame.jpegBytes.isEmpty, frame.jpegBytes.count <= VideoAnalysisSamplingPolicy.maximumEncodedBytes else {
            throw VideoAnalysisSamplingError.encodedBudgetExceeded
        }
        try database.pool.write { db in
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM asset a JOIN source s ON s.id = a.source_id
                WHERE a.id = ? AND a.content_revision = ? AND a.media_kind = 'video'
                AND a.locator_state = 'current' AND a.availability = 'available' AND s.state = 'active')
                """, arguments: [key.assetID.uuidString.lowercased(), key.contentRevision]) == true else {
                throw FingerprintCompletionError.sourceChanged
            }
            // One active representation per asset; policy switches explicitly rebuild.
            try db.execute(sql: """
                DELETE FROM video_analysis_frame WHERE asset_id = ?
                AND (content_revision != ? OR policy != ? OR source_identity != ?)
                """, arguments: key.arguments)
            var args = key.arguments
            args += [frame.requestedTimeMs, frame.actualTimeMs, frame.jpegBytes,
                     Data(SHA256.hash(data: frame.jpegBytes)), clock.nowMs]
            try db.execute(sql: "INSERT OR REPLACE INTO video_analysis_frame VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: args)
            let assetBytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(jpeg)),0) FROM video_analysis_frame WHERE asset_id = ?",
                arguments: [key.assetID.uuidString.lowercased()]) ?? 0
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM video_analysis_frame WHERE asset_id = ?",
                arguments: [key.assetID.uuidString.lowercased()]) ?? 0
            guard assetBytes <= VideoAnalysisSamplingPolicy.maximumEncodedBytes, count <= 5 else {
                throw VideoAnalysisSamplingError.encodedBudgetExceeded
            }
            while (try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(jpeg)),0) FROM video_analysis_frame") ?? 0) > Self.maximumTotalBytes {
                try db.execute(sql: "DELETE FROM video_analysis_frame WHERE rowid = (SELECT rowid FROM video_analysis_frame ORDER BY created_at_ms, rowid LIMIT 1)")
            }
        }
    }
}

/// Rebuildable feature evidence; never a training run, tag decision or byte proof.
struct VideoAnalysisFeatureCache {
    let database: CatalogDatabase
    let clock: any JobClock

    private func inputHash(_ sampling: VideoAnalysisSamplingResult) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(sampling.policyIdentity.utf8))
        for frame in sampling.frames {
            hasher.update(data: Data("/\(frame.requestedTimeMs)/\(frame.actualTimeMs)/".utf8))
            hasher.update(data: Data(SHA256.hash(data: frame.jpegBytes)))
        }
        return Data(hasher.finalize())
    }

    func load(key: VideoAnalysisFrameCache.Key, sampling: VideoAnalysisSamplingResult) throws -> VideoMultiFrameFeatureSet? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT f.* FROM video_analysis_feature f JOIN asset a ON a.id = f.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE f.asset_id = ? AND f.content_revision = ? AND f.source_identity = ? AND f.representation = ?
                AND a.content_revision = f.content_revision AND a.media_kind = 'video'
                AND a.locator_state = 'current' AND a.availability = 'available' AND s.state = 'active'
                """, arguments: [key.assetID.uuidString.lowercased(), key.contentRevision, key.sourceIdentity,
                    VideoMultiFrameFeatureSet.identity]),
                  (row["input_sha256"] as Data) == inputHash(sampling) else { return nil }
            let payload: Data = row["payload"]
            guard Data(SHA256.hash(data: payload)) == (row["payload_sha256"] as Data),
                  let value = try? JSONDecoder().decode(VideoMultiFrameFeatureSet.self, from: payload),
                  value.representationIdentity == VideoMultiFrameFeatureSet.identity,
                  value.frames.map(\.timeMs) == sampling.frames.map(\.actualTimeMs),
                  !value.aggregate.isEmpty, value.aggregate.allSatisfy(\.isFinite),
                  value.frames.allSatisfy({ $0.values.count == value.aggregate.count && $0.values.allSatisfy(\.isFinite) }) else { return nil }
            return value
        }
    }

    func store(_ value: VideoMultiFrameFeatureSet, key: VideoAnalysisFrameCache.Key,
               sampling: VideoAnalysisSamplingResult) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= 262_144, value.representationIdentity == VideoMultiFrameFeatureSet.identity else {
            throw FeaturePrintError.cachePersistenceFailed
        }
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO video_analysis_feature
                SELECT a.id, a.content_revision, ?, ?, ?, ?, ?, ? FROM asset a JOIN source s ON s.id = a.source_id
                WHERE a.id = ? AND a.content_revision = ? AND a.media_kind = 'video'
                AND a.locator_state = 'current' AND a.availability = 'available' AND s.state = 'active'
                """, arguments: [key.sourceIdentity, value.representationIdentity, inputHash(sampling), payload,
                    Data(SHA256.hash(data: payload)), clock.nowMs, key.assetID.uuidString.lowercased(), key.contentRevision])
            guard db.changesCount == 1 else { throw FeaturePrintError.sourceChanged }
            while (try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(payload)),0) FROM video_analysis_feature") ?? 0) > 16 * 1_024 * 1_024 {
                try db.execute(sql: "DELETE FROM video_analysis_feature WHERE rowid = (SELECT rowid FROM video_analysis_feature ORDER BY created_at_ms, rowid LIMIT 1)")
            }
        }
    }
}

extension FolderVideoAnalysisService {
    struct ContentCandidate: Sendable, Identifiable {
        let id: UUID
        let contentRevision: Int
        let fileName: String
        let score: Float
        let currentTimeMs: Int64
        let candidateTimeMs: Int64
    }
    struct ContentCandidates: Sendable {
        let items: [ContentCandidate]
        let skippedCount: Int
        let limited: Bool
    }

    /// Explicit bounded comparison of existing analyses. Does not enroll unseen
    /// assets, create duplicate groups or authorize any media mutation.
    func contentCandidates(assetID: UUID, expectedRevision: Int,
                           checkCancellation: () throws -> Void = {}) throws -> ContentCandidates {
        let base = try analyzeWithFeatures(assetID: assetID, expectedRevision: expectedRevision,
            checkCancellation: checkCancellation)
        let rows = try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.content_revision, a.file_name FROM video_analysis_feature f
                JOIN asset a ON a.id = f.asset_id JOIN source s ON s.id = a.source_id
                JOIN asset current ON current.id = ?
                WHERE a.id != current.id AND a.media_kind = 'video' AND a.locator_kind IN ('file', 'photos')
                AND a.locator_state = 'current' AND a.availability = 'available' AND s.state = 'active'
                AND f.content_revision = a.content_revision AND f.representation = ?
                AND current.content_revision = ? AND current.duration_ms > 0
                AND a.duration_ms BETWEEN current.duration_ms * 0.8 AND current.duration_ms * 1.2
                ORDER BY f.created_at_ms DESC, a.id LIMIT 21
                """, arguments: [assetID.uuidString.lowercased(), VideoMultiFrameFeatureSet.identity, expectedRevision])
        }
        var items: [ContentCandidate] = []
        var skipped = 0
        for row in rows.prefix(20) {
            try checkCancellation()
            guard let id = UUID(uuidString: row["id"]) else { skipped += 1; continue }
            let revision: Int = row["content_revision"]
            do {
                let other = try analyzeWithFeatures(assetID: id, expectedRevision: revision,
                    checkCancellation: checkCancellation)
                let match = try base.features.contentMatch(to: other.features)
                items.append(ContentCandidate(id: id, contentRevision: revision,
                    fileName: row["file_name"] ?? "视频", score: match.score,
                    currentTimeMs: match.leftTimeMs, candidateTimeMs: match.rightTimeMs))
            } catch is CancellationError { throw CancellationError() }
            catch { try checkCancellation(); skipped += 1 }
        }
        let current = try analyzeWithFeatures(assetID: assetID, expectedRevision: expectedRevision,
            checkCancellation: checkCancellation)
        guard current.features == base.features else { throw FeaturePrintError.sourceChanged }
        items.sort { $0.score == $1.score ? $0.id.uuidString < $1.id.uuidString : $0.score > $1.score }
        return ContentCandidates(items: items, skippedCount: skipped, limited: rows.count > 20)
    }
}

/// Reads only the frozen inputs of a current pending prediction. Never decodes or rebuilds media.
struct VideoPredictionEvidenceReader: Sendable {
    let database: CatalogDatabase
    struct Snapshot: Sendable {
        let modelRevision: Int
        let frames: [Frame]
    }
    struct Frame: Sendable {
        let actualTimeMs: Int64
        let jpegBytes: Data?
    }
    func read(assetID: UUID, revision: Int, tagID: UUID) throws -> Snapshot? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.video_evidence_json, p.model_revision FROM prediction p
                JOIN tag_model m ON m.media_kind = p.media_kind AND m.tag_id = p.tag_id AND m.current_revision = p.model_revision
                JOIN tag_model_revision r ON r.media_kind = p.media_kind AND r.tag_id = p.tag_id AND r.revision = p.model_revision
                JOIN asset a ON a.id = p.asset_id AND a.content_revision = p.content_revision
                JOIN source s ON s.id = a.source_id AND s.state = 'active'
                JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                WHERE p.asset_id = ? AND p.content_revision = ? AND p.tag_id = ?
                  AND p.media_kind = 'video' AND a.media_kind = 'video' AND p.state = 'pendingReview'
                  AND a.locator_state = 'current' AND a.availability = 'available' AND r.preprocessing_revision = 2
                  AND NOT EXISTS (SELECT 1 FROM asset_tag_decision d WHERE d.asset_id = p.asset_id AND d.tag_id = p.tag_id)
                """, arguments: [assetID.uuidString.lowercased(), revision, tagID.uuidString.lowercased()]),
                  let json: String = row["video_evidence_json"], json.utf8.count <= 8192,
                  let evidence = try? JSONDecoder().decode(VideoPredictionEvidence.self, from: Data(json.utf8)),
                  evidence.isValid(assetID: assetID, revision: revision) else { return nil }
            let frames = try evidence.frames.map { frame in
                let bytes = try Data.fetchOne(db, sql: """
                    SELECT jpeg FROM video_analysis_frame WHERE asset_id = ? AND content_revision = ?
                    AND policy = ? AND actual_ms = ? AND sha256 = ? LIMIT 1
                    """, arguments: [assetID.uuidString.lowercased(), revision, VideoAnalysisSamplingPolicy.identity,
                                       frame.actualTimeMs, frame.jpegSHA256])
                return Frame(actualTimeMs: frame.actualTimeMs,
                    jpegBytes: bytes.flatMap { Data(SHA256.hash(data: $0)) == frame.jpegSHA256 ? $0 : nil })
            }
            return Snapshot(modelRevision: row["model_revision"], frames: frames)
        }
    }
}
