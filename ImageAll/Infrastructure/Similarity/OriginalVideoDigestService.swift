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

    func analyze(assetID: UUID, expectedRevision: Int? = nil, forceRebuild: Bool = false, checkCancellation: () throws -> Void = {},
                 onFrame: (VideoAnalysisFrame) throws -> Void = { _ in }) throws -> VideoAnalysisSamplingResult {
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
            return result
        }
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
