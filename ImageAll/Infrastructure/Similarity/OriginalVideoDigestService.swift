import CryptoKit
import Darwin
import Foundation
import GRDB

/// Explicit full-file work, separate from automatic poster/visual fingerprint completion.
/// One file descriptor and one 256 KiB buffer per call; callers schedule files serially.
struct OriginalVideoDigestService: Sendable {
    static let policy = "folder-original-sha256-v1"
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

    private struct FileIdentity: Equatable {
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
