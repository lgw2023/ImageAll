import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

enum DerivedImageTestSupport {
    static func makeLibraryAssetImageLoader(
        database: CatalogDatabase,
        fileImages: any DerivedImageCachePort,
        maximumConcurrentLoads: Int
    ) -> LibraryAssetImageLoader {
        LibraryAssetImageLoader(
            database: database,
            fileImages: fileImages,
            photosImages: UnavailablePhotosLibraryAccess(),
            maximumConcurrentLoads: maximumConcurrentLoads
        )
    }

    private struct UnavailablePhotosLibraryAccess: PhotosLibraryAccessPort {
        func authorizationState() -> PhotosAuthorizationState {
            .denied
        }

        func requestAuthorization() async -> PhotosAuthorizationState {
            .denied
        }

        func supportedStaticImageCount() throws -> Int {
            throw PhotosLibraryError.libraryUnavailable
        }

        func enumerateStaticImages(
            startingAt startOffset: Int,
            batchSize: Int,
            onAssetEnumerated: () throws -> Void,
            onBatch: (PhotosAssetEnumerationBatch) throws -> Void
        ) throws {
            throw PhotosLibraryError.libraryUnavailable
        }

        func requestLocalImage(
            localIdentifier: String,
            variant: PhotosImageVariant
        ) async throws -> Data {
            throw PhotosLibraryError.libraryUnavailable
        }
    }

    struct GenerationCatalogFacts: Equatable {
        let assetID: UUID
        let sourceID: UUID
        let sourceKind: String
        let locatorKind: String
        let locatorState: String
        let mediaType: String
        let contentRevision: Int
        let availability: String
        let relativePath: String
        let fileName: String
        let sourceState: String
        let fingerprintSizeBytes: Int64?
        let fingerprintModifiedAtNs: Int64?
        let fingerprintResourceID: Data?
    }

    struct SourceFileSnapshot: Equatable, Sendable {
        let url: URL
        let bytes: Data
        let modifiedAtNs: Int64
    }

    final class TempEnvironment: @unchecked Sendable {
        let root: URL
        let databaseURL: URL
        let cachesDirectory: URL
        let sourceRoot: URL
        let database: CatalogDatabase
        let bookmark: Data
        let sourceID: UUID
        var assetID: UUID

        init(label: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImageAllDerivedTests-\(label)-\(UUID().uuidString)", isDirectory: true)
            cachesDirectory = root.appendingPathComponent("Caches/ImageAll", isDirectory: true)
            sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
            databaseURL = root.appendingPathComponent("catalog.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            database = try CatalogDatabase.open(at: databaseURL)
            sourceID = UUID()
            assetID = UUID()
            bookmark = sourceRoot.path.data(using: .utf8) ?? Data()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func writeSource(relativePath: String, contents: Data) throws -> URL {
            let url = sourceRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
            return url
        }

        func productionFingerprint(for fileURL: URL) -> (Int64, Int64, Data?) {
            let reader = FoundationFolderFileResourceReader()
            let sizeBytes = reader.fileSizeBytes(for: fileURL) ?? 0
            let modifiedAtNs = reader.modifiedAtNs(for: fileURL) ?? 0
            let resourceID = reader.resourceIdentifier(for: fileURL)
            return (sizeBytes, modifiedAtNs, resourceID)
        }

        @discardableResult
        func seedAvailableAsset(
            relativePath: String = "photos/sample.jpg",
            fileName: String = "sample.jpg",
            mediaType: String = "public.jpeg",
            contentRevision: Int = 1,
            contents: Data? = nil
        ) throws -> URL {
            let data = contents ?? FolderReconcileTestSupport.minimalJPEGData()
            let fileURL = try writeSource(relativePath: relativePath, contents: data)
            let (sizeBytes, modifiedAtNs, resourceID) = productionFingerprint(for: fileURL)

            try database.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO source (
                        id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, 'folder', 'Fixture', ?, 0, 0, 'active', ?, ?)
                    """,
                    arguments: [sourceID.uuidString.lowercased(), bookmark, FolderReconcileTestSupport.baseTimeMs, FolderReconcileTestSupport.baseTimeMs]
                )
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms, file_name
                    ) VALUES (?, ?, 'file', ?, NULL, 'current', ?, ?, 'available', ?, ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        sourceID.uuidString.lowercased(),
                        relativePath,
                        mediaType,
                        contentRevision,
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                        fileName,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns, resource_id, sha256)
                    VALUES (?, ?, ?, ?, NULL)
                    """,
                    arguments: [assetID.uuidString.lowercased(), sizeBytes, modifiedAtNs, resourceID]
                )
            }
            return fileURL
        }

        @discardableResult
        func seedViaProductionReconcile(
            relativePath: String = "photos/sample.jpg",
            contents: Data? = nil
        ) async throws -> URL {
            let data = contents ?? FolderReconcileTestSupport.minimalJPEGData()
            let fileURL = try writeSource(relativePath: relativePath, contents: data)
            try FolderReconcileTestSupport.seedActiveFolderSource(
                database: database,
                sourceID: sourceID,
                bookmark: bookmark
            )
            let queue = FolderReconcileTestSupport.makeQueue(database: database)
            let (handler, _) = FolderReconcileTestSupport.makeHandler(
                database: database,
                root: sourceRoot,
                bookmark: bookmark
            )
            let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
            _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
            _ = try XCTUnwrap(
                try coordinator.claimAndExecuteOnce(
                    ClaimNextInput(owner: "derived-reconcile", leaseDurationMs: 1000)
                )
            )
            let resolvedID = try await database.pool.read { db -> UUID? in
                guard let id: String = try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM asset
                    WHERE source_id = ? AND relative_path = ? AND locator_state = 'current'
                    """,
                    arguments: [sourceID.uuidString.lowercased(), relativePath]
                ) else {
                    return nil
                }
                return UUID(uuidString: id)
            }
            guard let resolvedID else {
                throw NSError(domain: "DerivedImageTestSupport", code: 1)
            }
            assetID = resolvedID
            return fileURL
        }

        func runProductionReconcileForFixture() async throws {
            try FolderReconcileTestSupport.seedActiveFolderSource(
                database: database,
                sourceID: sourceID,
                bookmark: bookmark
            )
            let queue = FolderReconcileTestSupport.makeQueue(database: database)
            let (handler, _) = FolderReconcileTestSupport.makeHandler(
                database: database,
                root: sourceRoot,
                bookmark: bookmark
            )
            let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
            _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
            let result = try XCTUnwrap(
                try coordinator.claimAndExecuteOnce(
                    ClaimNextInput(owner: "derived-scale-reconcile", leaseDurationMs: 60_000)
                )
            )
            guard result.snapshot.state == .completed else {
                throw NSError(domain: "DerivedImageTestSupport", code: 5)
            }
        }

        func makeService(
            cachesDirectory overrideCachesDirectory: URL? = nil,
            faultInjector: any DerivedImageCacheStoreFaultInjecting = NoDerivedImageCacheStoreFaultInjector(),
            repositoryFaultInjector: any DerivedImageRepositoryFaultInjecting = NoDerivedImageRepositoryFaultInjector(),
            publishCheckpoint: (any DerivedImagePublishCheckpointing)? = nil,
            finalPublishCheckpoint: (any DerivedImageFinalPublishCheckpointing)? = nil,
            maintenanceCheckpoint: (any DerivedImageMaintenanceCheckpointing)? = nil,
            sourceReader: DerivedImageSourceReader? = nil,
            volumeReader: (any DerivedImageVolumeCapacityReading)? = nil,
            clock: any JobClock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs),
            downloadedPreviewQuotaBytes: UInt64 = DownloadedPreviewCachePolicy.publishedQuotaBytes
        ) -> (DerivedImageCacheService, FolderReconcileTestSupport.TestBookmarkPort) {
            let bookmarkPort = FolderReconcileTestSupport.TestBookmarkPort(rootByBookmark: [bookmark: sourceRoot])
            let access = FolderReconcileSourceAccessService(
                repository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: bookmarkPort,
                rootValidator: FolderRootValidator(),
                clock: clock
            )
            let service = DerivedImageCacheService(
                database: database,
                cachesDirectory: overrideCachesDirectory ?? cachesDirectory,
                sourceAccess: access,
                sourceReader: sourceReader ?? DerivedImageSourceReader(),
                volumeReader: volumeReader ?? FoundationDerivedImageVolumeCapacityReader(),
                clock: clock,
                faultInjector: faultInjector,
                repositoryFaultInjector: repositoryFaultInjector,
                publishCheckpoint: publishCheckpoint ?? NoDerivedImagePublishCheckpoint(),
                finalPublishCheckpoint: finalPublishCheckpoint ?? NoDerivedImageFinalPublishCheckpoint(),
                maintenanceCheckpoint: maintenanceCheckpoint ?? NoDerivedImageMaintenanceCheckpoint(),
                downloadedPreviewQuotaBytes: downloadedPreviewQuotaBytes
            )
            return (service, bookmarkPort)
        }

        func cacheArtifactCounts() async throws -> (entries: Int, objects: Int, stagingFiles: Int) {
            let entries = try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0
            }
            let objects = try countCacheObjects()
            let staging = DerivedImageCachePathLayout.stagingDirectory(under: cacheVersionRoot())
            let stagingFiles: Int
            if FileManager.default.fileExists(atPath: staging.path),
               let names = try? FileManager.default.contentsOfDirectory(atPath: staging.path)
            {
                stagingFiles = names.count
            } else {
                stagingFiles = 0
            }
            return (entries, objects, stagingFiles)
        }

        func generationCatalogFacts() async throws -> GenerationCatalogFacts {
            try await database.pool.read { db in
                guard let asset = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                        a.id AS asset_id,
                        a.source_id,
                        a.locator_kind,
                        a.locator_state,
                        a.media_type,
                        a.content_revision,
                        a.availability,
                        a.relative_path,
                        a.file_name,
                        s.state AS source_state,
                        s.kind AS source_kind
                    FROM asset a
                    JOIN source s ON s.id = a.source_id
                    WHERE a.id = ?
                    """,
                    arguments: [assetID.uuidString.lowercased()]
                ) else {
                    throw NSError(domain: "DerivedImageTestSupport", code: 2)
                }
                let fingerprint = try Row.fetchOne(
                    db,
                    sql: "SELECT size_bytes, modified_at_ns, resource_id FROM file_fingerprint WHERE asset_id = ?",
                    arguments: [assetID.uuidString.lowercased()]
                )
                guard let assetIDString: String = asset["asset_id"],
                      let sourceIDString: String = asset["source_id"],
                      let parsedAssetID = UUID(uuidString: assetIDString),
                      let parsedSourceID = UUID(uuidString: sourceIDString)
                else {
                    throw NSError(domain: "DerivedImageTestSupport", code: 3)
                }
                return GenerationCatalogFacts(
                    assetID: parsedAssetID,
                    sourceID: parsedSourceID,
                    sourceKind: asset["source_kind"],
                    locatorKind: asset["locator_kind"],
                    locatorState: asset["locator_state"],
                    mediaType: asset["media_type"],
                    contentRevision: asset["content_revision"],
                    availability: asset["availability"],
                    relativePath: asset["relative_path"],
                    fileName: asset["file_name"],
                    sourceState: asset["source_state"],
                    fingerprintSizeBytes: fingerprint?["size_bytes"],
                    fingerprintModifiedAtNs: fingerprint?["modified_at_ns"],
                    fingerprintResourceID: fingerprint?["resource_id"]
                )
            }
        }

        func stableAssetFacts() async throws -> (revision: Int, sizeBytes: Int64?, modifiedAtNs: Int64?) {
            try await database.pool.read { db in
                let revision: Int? = try Int.fetchOne(
                    db,
                    sql: "SELECT content_revision FROM asset WHERE id = ?",
                    arguments: [assetID.uuidString.lowercased()]
                )
                let fingerprint = try Row.fetchOne(
                    db,
                    sql: "SELECT size_bytes, modified_at_ns FROM file_fingerprint WHERE asset_id = ?",
                    arguments: [assetID.uuidString.lowercased()]
                )
                return (
                    revision ?? -1,
                    fingerprint?["size_bytes"],
                    fingerprint?["modified_at_ns"]
                )
            }
        }

        func sourceFileURL(relativePath: String = "photos/sample.jpg") -> URL {
            sourceRoot.appendingPathComponent(relativePath)
        }

        func sourceFileSnapshot(for url: URL) throws -> SourceFileSnapshot {
            let (_, modifiedAtNs, _) = productionFingerprint(for: url)
            return SourceFileSnapshot(
                url: url,
                bytes: try Data(contentsOf: url),
                modifiedAtNs: modifiedAtNs
            )
        }

        func cacheVersionRoot() -> URL {
            DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
        }

        func countCacheObjects() throws -> Int {
            let objects = DerivedImageCachePathLayout.objectsDirectory(under: cacheVersionRoot())
            guard FileManager.default.fileExists(atPath: objects.path) else { return 0 }
            guard let enumerator = FileManager.default.enumerator(
                at: objects,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return 0
            }
            var count = 0
            for case let url as URL in enumerator {
                if url.hasDirectoryPath { continue }
                count += 1
            }
            return count
        }

        func listCacheObjectFiles() throws -> [String] {
            let objects = DerivedImageCachePathLayout.objectsDirectory(under: cacheVersionRoot())
            guard let enumerator = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: [.isRegularFileKey]) else {
                return []
            }
            return enumerator.compactMap { item -> String? in
                guard let url = item as? URL else { return nil }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                    return nil
                }
                return url.lastPathComponent
            }.sorted()
        }

        func finalObjectURL(entryID: UUID, format: DerivedImageStorageFormat) -> URL {
            DerivedImageCachePathLayout.objectURL(
                versionRoot: cacheVersionRoot(),
                entryID: entryID,
                format: format
            )
        }

        func finalObjectExists(entryID: UUID, format: DerivedImageStorageFormat) -> Bool {
            FileManager.default.fileExists(atPath: finalObjectURL(entryID: entryID, format: format).path)
        }

        func stagingFileExists(name: String) -> Bool {
            let staging = DerivedImageCachePathLayout.stagingDirectory(under: cacheVersionRoot())
            return FileManager.default.fileExists(atPath: staging.appendingPathComponent(name).path)
        }

        func jobRecordCount() async throws -> Int {
            try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job") ?? 0
            }
        }

        func tagRecordCount() async throws -> Int {
            try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0
            }
        }

        func entryLastAccessedMs(id: UUID) async throws -> Int64 {
            try await database.pool.read { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT last_accessed_at_ms FROM derived_image_cache_entry WHERE id = ?",
                    arguments: [id.uuidString.lowercased()]
                ) ?? -1
            }
        }

        func cacheEntryExists(id: UUID) async throws -> Bool {
            try await database.pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM derived_image_cache_entry WHERE id = ? LIMIT 1",
                    arguments: [id.uuidString.lowercased()]
                ) != nil
            }
        }

        func fetchCacheEntryIDs(assetID: UUID? = nil) async throws -> [UUID] {
            try await database.pool.read { db in
                let rows: [String]
                if let assetID {
                    rows = try String.fetchAll(
                        db,
                        sql: "SELECT id FROM derived_image_cache_entry WHERE asset_id = ? ORDER BY id",
                        arguments: [assetID.uuidString.lowercased()]
                    )
                } else {
                    rows = try String.fetchAll(db, sql: "SELECT id FROM derived_image_cache_entry ORDER BY id")
                }
                return rows.compactMap { UUID(uuidString: $0) }
            }
        }

        func removeCacheObject(entryID: UUID, format: DerivedImageStorageFormat) throws {
            let url = finalObjectURL(entryID: entryID, format: format)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }

        func truncateCacheObject(entryID: UUID, format: DerivedImageStorageFormat, keepBytes: Int) throws {
            let url = finalObjectURL(entryID: entryID, format: format)
            var bytes = try Data(contentsOf: url)
            guard keepBytes < bytes.count else { return }
            bytes = bytes.prefix(keepBytes)
            try bytes.write(to: url, options: .atomic)
        }

        func tamperCacheObjectSameByteSize(entryID: UUID, format: DerivedImageStorageFormat) throws {
            let url = finalObjectURL(entryID: entryID, format: format)
            var bytes = try Data(contentsOf: url)
            guard !bytes.isEmpty else {
                bytes.append(0xFF)
                try bytes.write(to: url, options: .atomic)
                return
            }
            let index = bytes.count / 2
            bytes[index] ^= 0xFF
            try bytes.write(to: url, options: .atomic)
        }

        func replaceCacheObjectBytes(entryID: UUID, format: DerivedImageStorageFormat, bytes: Data) throws {
            try bytes.write(to: finalObjectURL(entryID: entryID, format: format), options: .atomic)
        }

        func updateCacheEntryByteSizeAndHash(id: UUID, byteSize: Int64, encodedSHA256: Data) async throws {
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                    UPDATE derived_image_cache_entry
                    SET byte_size = ?, encoded_sha256 = ?
                    WHERE id = ?
                    """,
                    arguments: [byteSize, encodedSHA256, id.uuidString.lowercased()]
                )
            }
        }

        func updateCacheEntryPixelDimensions(id: UUID, pixelWidth: Int, pixelHeight: Int) async throws {
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                    UPDATE derived_image_cache_entry
                    SET pixel_width = ?, pixel_height = ?
                    WHERE id = ?
                    """,
                    arguments: [pixelWidth, pixelHeight, id.uuidString.lowercased()]
                )
            }
        }

        func pinnedSeedFingerprintReader(for fileURL: URL) async throws -> PinnedSeedFingerprintReader {
            let (sizeBytes, modifiedAtNs, _) = productionFingerprint(for: fileURL)
            let resourceID = try await database.pool.read { db -> Data? in
                try Data.fetchOne(
                    db,
                    sql: "SELECT resource_id FROM file_fingerprint WHERE asset_id = ?",
                    arguments: [assetID.uuidString.lowercased()]
                )
            }
            return PinnedSeedFingerprintReader(
                sizeBytes: sizeBytes,
                modifiedAtNs: modifiedAtNs,
                resourceID: resourceID
            )
        }

        func cacheEntrySnapshots() async throws -> [CacheEntrySnapshot] {
            let repository = GRDBDerivedImageCacheRepository(database: database)
            return try repository.allEntries().map(CacheEntrySnapshot.init(row:)).sorted()
        }

        func cacheTreeSnapshot() throws -> [CacheTreeItem] {
            DerivedImageTestSupport.captureCacheTree(cachesDirectory: cachesDirectory)
        }

        func sourceTreeSnapshot() throws -> [SourceTreeItem] {
            try DerivedImageTestSupport.captureSourceTree(sourceRoot: sourceRoot)
        }

        func readCacheObjectBytesNoFollow(
            entryID: UUID,
            format: DerivedImageStorageFormat,
            expectedSize: Int64
        ) throws -> Data {
            let store = DerivedImageCacheStore(cachesDirectory: cachesDirectory)
            let session = try store.ensureLayout()
            defer { session.closeHandles() }
            guard let bytes = try session.readObject(
                entryID: entryID,
                format: format,
                expectedSize: expectedSize
            ) else {
                throw NSError(domain: "DerivedImageTestSupport", code: 4)
            }
            return bytes
        }

        @discardableResult
        func plantLegalStagingOrphan(bytes: Data) throws -> String {
            let store = DerivedImageCacheStore(cachesDirectory: cachesDirectory)
            let session = try store.ensureLayout()
            defer { session.closeHandles() }
            let name = DerivedImageCachePathLayout.stagingFileName()
            let fd = try session.writeStagingExclusive(name: name, bytes: bytes)
            Darwin.close(fd)
            return name
        }

        func externalSentinelDirectory() -> URL {
            root.appendingPathComponent("external-sentinel", isDirectory: true)
        }

        @discardableResult
        func plantExternalSentinel(
            name: String = "sentinel.bin",
            bytes: Data = Data([0x01, 0x02, 0x03, 0x04])
        ) throws -> URL {
            let directory = externalSentinelDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }

        func makeAliasCachesDirectory() throws -> URL {
            let externalTree = root.appendingPathComponent("external-tree", isDirectory: true)
            try FileManager.default.createDirectory(at: externalTree, withIntermediateDirectories: true)
            let alias = root.appendingPathComponent("alias")
            if FileManager.default.fileExists(atPath: alias.path) {
                try FileManager.default.removeItem(at: alias)
            }
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: externalTree)
            let aliasCaches = alias
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("ImageAll", isDirectory: true)
            try FileManager.default.createDirectory(at: aliasCaches, withIntermediateDirectories: true)
            return aliasCaches
        }

        func derivedImagesExistsUnderExternalTree() -> Bool {
            let externalTree = root.appendingPathComponent("external-tree", isDirectory: true)
            let derived = externalTree
                .appendingPathComponent("DerivedImages", isDirectory: true)
            return FileManager.default.fileExists(atPath: derived.path)
        }

        func insertSyntheticCacheEntry(
            id: UUID,
            assetID: UUID? = nil,
            variant: DerivedImageVariant = .gridSmall,
            byteSize: Int64? = nil,
            lastAccessedAtMs: Int64 = FolderReconcileTestSupport.baseTimeMs,
            createdAtMs: Int64 = FolderReconcileTestSupport.baseTimeMs
        ) async throws {
            let resolvedAssetID = assetID ?? self.assetID
            let placeholderHash = Data(repeating: 0xAB, count: 32)
            let resolvedByteSize = byteSize ?? 1024
            let pixelSize = variant == .gridRegular ? 512 : 256
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO derived_image_cache_entry (
                        id, asset_id, content_revision, representation_version, variant,
                        storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                        created_at_ms, last_accessed_at_ms
                    ) VALUES (?, ?, 1, 1, ?, 'jpeg', ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id.uuidString.lowercased(),
                        resolvedAssetID.uuidString.lowercased(),
                        variant.rawValue,
                        pixelSize,
                        pixelSize,
                        resolvedByteSize,
                        placeholderHash,
                        createdAtMs,
                        lastAccessedAtMs,
                    ]
                )
            }
        }

        func seedScaleCacheEntriesAndObjects(count: Int) async throws {
            precondition(count > 0)
            let objectBytes = Data([0xAB])
            let objectHash = DerivedImageTestSupport.sha256Data(for: objectBytes)
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                    WITH RECURSIVE synthetic_entry(entry_index) AS (
                        SELECT 0
                        UNION ALL
                        SELECT entry_index + 1
                        FROM synthetic_entry
                        WHERE entry_index + 1 < ?
                    )
                    INSERT INTO derived_image_cache_entry (
                        id, asset_id, content_revision, representation_version, variant,
                        storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                        created_at_ms, last_accessed_at_ms
                    )
                    SELECT
                        printf('40000000-0000-4000-8000-%012x', entry_index),
                        ?,
                        entry_index + 1,
                        1,
                        'gridSmall',
                        'jpeg',
                        256,
                        256,
                        1,
                        ?,
                        1_700_000_000_000 + entry_index,
                        1_700_000_000_000 + entry_index
                    FROM synthetic_entry
                    """,
                    arguments: [count, assetID.uuidString.lowercased(), objectHash]
                )
            }

            let session = try DerivedImageCacheStore(cachesDirectory: cachesDirectory).ensureLayout()
            session.closeHandles()
            var createdShards = Set<String>()
            for index in 0 ..< count {
                let entryID = UUID(
                    uuidString: String(format: "40000000-0000-4000-8000-%012x", index)
                )!
                let objectURL = finalObjectURL(entryID: entryID, format: .jpeg)
                let shard = objectURL.deletingLastPathComponent()
                if createdShards.insert(shard.lastPathComponent).inserted {
                    try FileManager.default.createDirectory(
                        at: shard,
                        withIntermediateDirectories: true
                    )
                }
                try objectBytes.write(to: objectURL)
            }
        }

        func deleteAssetCascadingCacheEntry(assetID: UUID? = nil) async throws {
            let resolvedAssetID = assetID ?? self.assetID
            try await database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM asset WHERE id = ?",
                    arguments: [resolvedAssetID.uuidString.lowercased()]
                )
            }
        }

        enum CacheLayoutComponent: Sendable {
            case derivedImagesRoot
            case versionRoot
            case stagingDirectory
            case objectsDirectory
            case shard(entryID: UUID)
        }

        func replaceCacheLayoutComponentWithSymlink(
            _ component: CacheLayoutComponent,
            linkTarget: URL
        ) throws {
            let derivedRoot = cachesDirectory.appendingPathComponent(
                DerivedImageCachePathLayout.rootComponent,
                isDirectory: true
            )
            let versionRoot = DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
            let targetURL: URL
            switch component {
            case .derivedImagesRoot:
                targetURL = derivedRoot
            case .versionRoot:
                targetURL = versionRoot
            case .stagingDirectory:
                targetURL = DerivedImageCachePathLayout.stagingDirectory(under: versionRoot)
            case .objectsDirectory:
                targetURL = DerivedImageCachePathLayout.objectsDirectory(under: versionRoot)
            case let .shard(entryID):
                targetURL = DerivedImageCachePathLayout.objectURL(
                    versionRoot: versionRoot,
                    entryID: entryID,
                    format: .jpeg
                ).deletingLastPathComponent()
            }
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: linkTarget)
        }

        func plantIllegalObjectNameInObjectsTree() throws {
            let versionRoot = cacheVersionRoot()
            let objects = DerivedImageCachePathLayout.objectsDirectory(under: versionRoot)
            let shard = objects.appendingPathComponent("aa", isDirectory: true)
            try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
            let illegal = shard.appendingPathComponent("not-a-valid-entry-id.jpg")
            try Data([0x01]).write(to: illegal)
        }

        func plantUnknownObjectsDirectoryLevel() throws {
            let versionRoot = cacheVersionRoot()
            let unknown = DerivedImageCachePathLayout.objectsDirectory(under: versionRoot)
                .appendingPathComponent("unknown-level", isDirectory: true)
            try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
            try Data([0x02]).write(to: unknown.appendingPathComponent("rogue.bin"))
        }

        func plantObjectSymlinkInObjectsTree(linkTarget: URL, entryID: UUID) throws {
            let versionRoot = cacheVersionRoot()
            let shard = DerivedImageCachePathLayout.shardName(for: entryID)
            let objects = DerivedImageCachePathLayout.objectsDirectory(under: versionRoot)
            let shardDir = objects.appendingPathComponent(shard, isDirectory: true)
            try FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
            let linkName = "\(entryID.uuidString.lowercased()).jpg"
            let linkURL = shardDir.appendingPathComponent(linkName)
            if FileManager.default.fileExists(atPath: linkURL.path) {
                try FileManager.default.removeItem(at: linkURL)
            }
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: linkTarget)
        }

        func plantShardSymlinkInObjectsTree(linkTarget: URL, shardName: String) throws {
            let versionRoot = cacheVersionRoot()
            let objects = DerivedImageCachePathLayout.objectsDirectory(under: versionRoot)
            let shardLink = objects.appendingPathComponent(shardName)
            if FileManager.default.fileExists(atPath: shardLink.path) {
                try FileManager.default.removeItem(at: shardLink)
            }
            try FileManager.default.createSymbolicLink(at: shardLink, withDestinationURL: linkTarget)
        }

        func plantUnreferencedFinalObject(entryID: UUID, bytes: Data) throws {
            let url = finalObjectURL(entryID: entryID, format: .jpeg)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: url)
        }

        func replacePublishedObjectWithSymlink(
            entryID: UUID,
            format: DerivedImageStorageFormat,
            linkTarget: URL
        ) throws {
            let objectURL = finalObjectURL(entryID: entryID, format: format)
            if FileManager.default.fileExists(atPath: objectURL.path) {
                try FileManager.default.removeItem(at: objectURL)
            }
            try FileManager.default.createSymbolicLink(at: objectURL, withDestinationURL: linkTarget)
        }

        func objectRelativeComponent(entryID: UUID, format: DerivedImageStorageFormat) -> String {
            DerivedImageCachePathLayout.objectRelativePath(entryID: entryID, format: format)
        }

        func layoutComponentURL(_ component: CacheLayoutComponent, entryID: UUID? = nil) -> URL {
            let derivedRoot = cachesDirectory.appendingPathComponent(
                DerivedImageCachePathLayout.rootComponent,
                isDirectory: true
            )
            let versionRoot = DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
            switch component {
            case .derivedImagesRoot:
                return derivedRoot
            case .versionRoot:
                return versionRoot
            case .stagingDirectory:
                return DerivedImageCachePathLayout.stagingDirectory(under: versionRoot)
            case .objectsDirectory:
                return DerivedImageCachePathLayout.objectsDirectory(under: versionRoot)
            case let .shard(resolvedEntryID):
                return DerivedImageCachePathLayout.objectURL(
                    versionRoot: versionRoot,
                    entryID: resolvedEntryID,
                    format: .jpeg
                ).deletingLastPathComponent()
            }
        }

        func assertLayoutComponentStillSymlink(
            _ component: CacheLayoutComponent,
            entryID: UUID? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let resolvedEntryID: UUID?
            if case let .shard(id) = component {
                resolvedEntryID = id
            } else {
                resolvedEntryID = entryID
            }
            let url = layoutComponentURL(component, entryID: resolvedEntryID)
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                XCTFail("expected replaced layout component to exist", file: file, line: line)
                return
            }
            XCTAssertEqual(
                status.st_mode & S_IFMT,
                S_IFLNK,
                "replaced layout component must remain a symlink",
                file: file,
                line: line
            )
        }

        enum CacheFixtureNoFollowKind: Equatable {
            case symlink
            case directory
            case regularFile
            case missing
            case other
        }

        func noFollowCacheFixtureKind(relativeComponent: String) throws -> CacheFixtureNoFollowKind {
            let versionRoot = cacheVersionRoot()
            let versionRootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: versionRoot)
            defer { Darwin.close(versionRootFD) }

            let parts = relativeComponent.split(separator: "/").map(String.init)
            guard let leafName = parts.last else { return .missing }

            var currentFD = versionRootFD
            var ownsCurrent = false
            defer {
                if ownsCurrent {
                    Darwin.close(currentFD)
                }
            }

            for component in parts.dropLast() {
                let mode: mode_t
                do {
                    mode = try DerivedImageSecureIO.fstatatEntry(
                        directoryFD: currentFD,
                        name: component,
                        follow: false
                    ).mode & S_IFMT
                } catch {
                    return .missing
                }
                if mode == S_IFLNK {
                    return .symlink
                }
                guard mode == S_IFDIR else {
                    return .other
                }
                let nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard nextFD >= 0 else {
                    return .missing
                }
                if ownsCurrent {
                    Darwin.close(currentFD)
                }
                currentFD = nextFD
                ownsCurrent = true
            }

            let leafMode: mode_t
            do {
                leafMode = try DerivedImageSecureIO.fstatatEntry(
                    directoryFD: currentFD,
                    name: leafName,
                    follow: false
                ).mode & S_IFMT
            } catch {
                return .missing
            }
            switch leafMode {
            case S_IFLNK:
                return .symlink
            case S_IFDIR:
                return .directory
            case S_IFREG:
                return .regularFile
            default:
                return .other
            }
        }
    }

    struct ThrowingVolumeReader: DerivedImageVolumeCapacityReading {
        enum ProbeFailure: Error, Equatable { case probeFailed }

        func volumeFacts(at url: URL) throws -> DerivedImageVolumeFacts? {
            throw ProbeFailure.probeFailed
        }
    }

    final class SequentialVolumeReader: DerivedImageVolumeCapacityReading, @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = 0
        private let sequence: [DerivedImageVolumeFacts]
        let totalBytes: UInt64

        init(sequence: [DerivedImageVolumeFacts]) {
            self.sequence = sequence
            self.totalBytes = sequence.last?.totalBytes ?? sequence.first?.totalBytes ?? 0
        }

        var queryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return consumed
        }

        func volumeFacts(at url: URL) throws -> DerivedImageVolumeFacts? {
            lock.lock()
            defer { lock.unlock() }
            let index = min(consumed, sequence.count - 1)
            consumed += 1
            return sequence[index]
        }
    }

    final class ConstantVolumeReader: DerivedImageVolumeCapacityReading, @unchecked Sendable {
        let availableBytes: UInt64
        let totalBytes: UInt64
        private let lock = NSLock()
        private var queryCount = 0

        init(availableBytes: UInt64, totalBytes: UInt64) {
            self.availableBytes = availableBytes
            self.totalBytes = totalBytes
        }

        var volumeQueryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return queryCount
        }

        func volumeFacts(at url: URL) throws -> DerivedImageVolumeFacts? {
            lock.lock()
            queryCount += 1
            lock.unlock()
            return DerivedImageVolumeFacts(availableBytes: availableBytes, totalBytes: totalBytes)
        }
    }

    static func renderIncomingGridSmallArtifact() throws -> DerivedImageEncodedArtifact {
        try DerivedImageRenderer().render(
            sourceBytes: FolderReconcileTestSupport.minimalJPEGData(),
            variant: .gridSmall
        )
    }

    static func assertZeroCacheArtifacts(
        env: TempEnvironment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0, file: file, line: line)
        XCTAssertEqual(counts.objects, 0, file: file, line: line)
        XCTAssertEqual(counts.stagingFiles, 0, file: file, line: line)
    }

    static func assertCapacityFailClosedUntouched(
        env: TempEnvironment,
        bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort,
        catalogBefore: FaultMatrixCatalogSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await assertZeroCacheArtifacts(env: env, file: file, line: line)
        assertBookmarkPortScopeBalanced(bookmarkPort, file: file, line: line)
        let catalogAfter = try await captureFaultMatrixCatalogSnapshot(env: env)
        assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter,
            file: file,
            line: line
        )
    }

    static func assertMaintenanceResultStructure(
        _ result: DerivedImageMaintenanceResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mirror = Mirror(reflecting: result)
        XCTAssertEqual(mirror.children.count, 4, file: file, line: line)
        let description = String(describing: result)
        XCTAssertFalse(description.contains("/"), "maintenance result must not expose paths", file: file, line: line)
        XCTAssertFalse(description.contains("\\"), "maintenance result must not expose paths", file: file, line: line)
    }

    static func assertMaintenanceSecondRunAllZero(
        _ result: DerivedImageMaintenanceResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertMaintenanceResultStructure(result, file: file, line: line)
        XCTAssertEqual(result.removedEntries, 0, file: file, line: line)
        XCTAssertEqual(result.removedObjects, 0, file: file, line: line)
        XCTAssertEqual(result.removedBytes, 0, file: file, line: line)
        XCTAssertEqual(result.unsafeObjects, 0, file: file, line: line)
    }

    static func assertExternalSentinelUnchanged(
        before: SourceFileSnapshot,
        after: SourceFileSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.bytes, before.bytes, file: file, line: line)
        XCTAssertEqual(after.modifiedAtNs, before.modifiedAtNs, file: file, line: line)
    }

    static let gib: UInt64 = 1024 * 1024 * 1024

    struct GenerousVolumeReader: DerivedImageVolumeCapacityReading {
        let availableBytes: UInt64
        let totalBytes: UInt64

        func volumeFacts(at url: URL) throws -> DerivedImageVolumeFacts? {
            DerivedImageVolumeFacts(availableBytes: availableBytes, totalBytes: totalBytes)
        }
    }

    struct FailingVolumeReader: DerivedImageVolumeCapacityReading {
        func volumeFacts(at url: URL) throws -> DerivedImageVolumeFacts? { nil }
    }

    final class SinglePointFaultInjector: DerivedImageCacheStoreFaultInjecting, @unchecked Sendable {
        let point: DerivedImageCacheStoreFaultPoint
        init(point: DerivedImageCacheStoreFaultPoint) { self.point = point }
        func shouldFault(at point: DerivedImageCacheStoreFaultPoint) -> Bool { point == self.point }
    }

    final class SinglePointRepositoryFaultInjector: DerivedImageRepositoryFaultInjecting, @unchecked Sendable {
        let point: DerivedImageRepositoryFaultPoint
        init(point: DerivedImageRepositoryFaultPoint) { self.point = point }
        func shouldFault(at point: DerivedImageRepositoryFaultPoint) -> Bool { point == self.point }
    }

    enum CacheTreeItemType: String, Equatable, Sendable {
        case staging
        case object
        case unknown
    }

    enum SourceTreeEntryType: String, Equatable, Sendable {
        case regularFile
        case directory
        case symlink
        case unknown
    }

    struct CacheTreeItem: Equatable, Sendable, Comparable {
        let relativeComponent: String
        let type: CacheTreeItemType
        let byteSize: Int64
        let contentHash: Data

        static func < (lhs: CacheTreeItem, rhs: CacheTreeItem) -> Bool {
            lhs.relativeComponent < rhs.relativeComponent
        }
    }

    struct SourceTreeItem: Equatable, Sendable, Comparable {
        let relativeComponent: String
        let entryType: SourceTreeEntryType
        let byteSize: Int64
        let modifiedAtNs: Int64
        let contentHash: Data

        static func < (lhs: SourceTreeItem, rhs: SourceTreeItem) -> Bool {
            lhs.relativeComponent < rhs.relativeComponent
        }
    }

    struct CacheEntrySnapshot: Equatable, Sendable, Comparable {
        let id: UUID
        let assetID: UUID
        let contentRevision: Int
        let representationVersion: Int
        let variant: DerivedImageVariant
        let storageFormat: DerivedImageStorageFormat
        let pixelWidth: Int
        let pixelHeight: Int
        let byteSize: Int64
        let encodedSHA256: Data
        let createdAtMs: Int64
        let lastAccessedAtMs: Int64

        init(row: DerivedImageCacheEntryRow) {
            id = row.id
            assetID = row.assetID
            contentRevision = row.contentRevision
            representationVersion = row.representationVersion
            variant = row.variant
            storageFormat = row.storageFormat
            pixelWidth = row.pixelWidth
            pixelHeight = row.pixelHeight
            byteSize = row.byteSize
            encodedSHA256 = row.encodedSHA256
            createdAtMs = row.createdAtMs
            lastAccessedAtMs = row.lastAccessedAtMs
        }

        static func < (lhs: CacheEntrySnapshot, rhs: CacheEntrySnapshot) -> Bool {
            lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    struct FaultMatrixCatalogSnapshot: Equatable, Sendable {
        let catalogFacts: GenerationCatalogFacts
        let sourceTree: [SourceTreeItem]
        let jobCount: Int
        let tagCount: Int
    }

    final class LoggingStoreFaultInjector: DerivedImageCacheStoreFaultInjecting, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [DerivedImageCacheStoreFaultPoint: Int] = [:]
        let faultPoint: DerivedImageCacheStoreFaultPoint

        init(faultPoint: DerivedImageCacheStoreFaultPoint) {
            self.faultPoint = faultPoint
        }

        func shouldFault(at point: DerivedImageCacheStoreFaultPoint) -> Bool {
            lock.lock()
            counts[point, default: 0] += 1
            lock.unlock()
            return point == faultPoint
        }

        func callCount(for point: DerivedImageCacheStoreFaultPoint) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[point] ?? 0
        }

        func totalCalls() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }
    }

    final class LoggingRepositoryFaultInjector: DerivedImageRepositoryFaultInjecting, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [DerivedImageRepositoryFaultPoint: Int] = [:]
        let faultPoint: DerivedImageRepositoryFaultPoint

        init(faultPoint: DerivedImageRepositoryFaultPoint) {
            self.faultPoint = faultPoint
        }

        func shouldFault(at point: DerivedImageRepositoryFaultPoint) -> Bool {
            lock.lock()
            counts[point, default: 0] += 1
            lock.unlock()
            return point == faultPoint
        }

        func callCount(for point: DerivedImageRepositoryFaultPoint) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[point] ?? 0
        }

        func totalCalls() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }
    }

    struct StagingWriteFaultObservation: Equatable, Sendable {
        let cacheTree: [CacheTreeItem]
        let partialStagingByteSize: Int64?
    }

    /// Faults at `.stagingWrite` and records the cache tree observed at the production seam.
    final class StagingWriteObservingFaultInjector: DerivedImageCacheStoreFaultInjecting, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [DerivedImageCacheStoreFaultPoint: Int] = [:]
        private var observationStorage: StagingWriteFaultObservation?
        let cachesDirectory: URL

        init(cachesDirectory: URL) {
            self.cachesDirectory = cachesDirectory
        }

        var observation: StagingWriteFaultObservation? {
            lock.lock()
            defer { lock.unlock() }
            return observationStorage
        }

        func shouldFault(at point: DerivedImageCacheStoreFaultPoint) -> Bool {
            lock.lock()
            counts[point, default: 0] += 1
            if point == .stagingWrite {
                let tree = DerivedImageTestSupport.captureCacheTree(cachesDirectory: cachesDirectory)
                let stagingItems = tree.filter { $0.type == .staging }
                let partialSize = stagingItems.first?.byteSize
                observationStorage = StagingWriteFaultObservation(
                    cacheTree: tree,
                    partialStagingByteSize: partialSize
                )
            }
            lock.unlock()
            return point == .stagingWrite
        }

        func callCount(for point: DerivedImageCacheStoreFaultPoint) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[point] ?? 0
        }
    }

    /// Faults at `.stagingSync` after staging write and marks the sole staging regular file immutable so defer cleanup fails.
    final class StagingSyncCleanupBlockingFaultInjector: DerivedImageCacheStoreFaultInjecting, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [DerivedImageCacheStoreFaultPoint: Int] = [:]
        private var blockedRelativeComponent: String?
        let cachesDirectory: URL

        init(cachesDirectory: URL) {
            self.cachesDirectory = cachesDirectory
        }

        var blockedStagingRelativeComponent: String? {
            lock.lock()
            defer { lock.unlock() }
            return blockedRelativeComponent
        }

        func shouldFault(at point: DerivedImageCacheStoreFaultPoint) -> Bool {
            lock.lock()
            counts[point, default: 0] += 1
            if point == .stagingSync {
                let stagingItems = DerivedImageTestSupport.captureCacheTree(cachesDirectory: cachesDirectory)
                    .filter { $0.type == .staging }
                if stagingItems.count == 1 {
                    blockedRelativeComponent = stagingItems[0].relativeComponent
                    try? DerivedImageTestSupport.setStagingImmutableFlag(
                        cachesDirectory: cachesDirectory,
                        relativeComponent: stagingItems[0].relativeComponent,
                        enabled: true
                    )
                }
            }
            lock.unlock()
            return point == .stagingSync
        }

        func callCount(for point: DerivedImageCacheStoreFaultPoint) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[point] ?? 0
        }

        func restoreBlockedStagingArtifact() {
            lock.lock()
            let relative = blockedRelativeComponent
            blockedRelativeComponent = nil
            lock.unlock()
            guard let relative else { return }
            try? DerivedImageTestSupport.setStagingImmutableFlag(
                cachesDirectory: cachesDirectory,
                relativeComponent: relative,
                enabled: false
            )
            try? DerivedImageTestSupport.removeCacheTreeEntry(
                cachesDirectory: cachesDirectory,
                relativeComponent: relative
            )
        }
    }

    static func captureCacheTree(cachesDirectory: URL) -> [CacheTreeItem] {
        let versionRoot = DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
        guard FileManager.default.fileExists(atPath: versionRoot.path) else { return [] }

        var items: [CacheTreeItem] = []
        do {
            let versionRootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: versionRoot)
            defer { Darwin.close(versionRootFD) }

            for topName in try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: versionRootFD).sorted() {
                if topName == DerivedImageCachePathLayout.stagingComponent {
                    try appendCacheStagingEntries(
                        versionRootFD: versionRootFD,
                        stagingComponent: topName,
                        into: &items
                    )
                } else if topName == DerivedImageCachePathLayout.objectsComponent {
                    try appendCacheObjectEntries(
                        versionRootFD: versionRootFD,
                        objectsComponent: topName,
                        into: &items
                    )
                } else {
                    appendCacheUnknownEntry(
                        directoryFD: versionRootFD,
                        name: topName,
                        relativeComponent: topName,
                        into: &items
                    )
                }
            }
        } catch {
            items.append(
                CacheTreeItem(
                    relativeComponent: "version-root-unenumerable",
                    type: .unknown,
                    byteSize: 0,
                    contentHash: Data()
                )
            )
        }
        return items.sorted()
    }

    static func captureSourceTree(sourceRoot: URL) throws -> [SourceTreeItem] {
        var items: [SourceTreeItem] = []
        let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: sourceRoot)
        defer { Darwin.close(rootFD) }
        try appendSourceDirectoryEntries(
            directoryFD: rootFD,
            relativePrefix: "",
            into: &items
        )
        return items.sorted()
    }

    static func captureFaultMatrixCatalogSnapshot(env: TempEnvironment) async throws -> FaultMatrixCatalogSnapshot {
        FaultMatrixCatalogSnapshot(
            catalogFacts: try await env.generationCatalogFacts(),
            sourceTree: try env.sourceTreeSnapshot(),
            jobCount: try await env.jobRecordCount(),
            tagCount: try await env.tagRecordCount()
        )
    }

    static func assertFaultMatrixCatalogSnapshotUnchanged(
        before: FaultMatrixCatalogSnapshot,
        after: FaultMatrixCatalogSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.catalogFacts, before.catalogFacts, file: file, line: line)
        XCTAssertEqual(after.sourceTree, before.sourceTree, file: file, line: line)
        XCTAssertEqual(after.jobCount, before.jobCount, file: file, line: line)
        XCTAssertEqual(after.tagCount, before.tagCount, file: file, line: line)
    }

    static func assertCacheEntrySnapshotsEqual(
        _ before: [CacheEntrySnapshot],
        _ after: [CacheEntrySnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after, before, file: file, line: line)
    }

    static func assertCacheTreeSnapshotsEqual(
        _ before: [CacheTreeItem],
        _ after: [CacheTreeItem],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after, before, file: file, line: line)
    }

    static func parseObjectEntryID(from relativeComponent: String) -> UUID? {
        guard DerivedImageCachePathLayout.isKnownObjectRelativePath(relativeComponent) else {
            return nil
        }
        let prefix = "\(DerivedImageCachePathLayout.objectsComponent)/"
        let remainder = String(relativeComponent.dropFirst(prefix.count))
        let parts = remainder.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let fileName = String(parts[1])
        let stem = fileName.split(separator: ".", omittingEmptySubsequences: false)[0]
        return UUID(uuidString: String(stem))
    }

    static func assertInvalidCandidateInsertFailurePreservesOldArtifactsAndSingleNewOrphan(
        baseline: DerivedImagePayload,
        oldObjectBefore: CacheTreeItem,
        entriesBefore: [CacheEntrySnapshot],
        entriesAfter: [CacheEntrySnapshot],
        treeAfter: [CacheTreeItem],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertCacheEntrySnapshotsEqual(entriesBefore, entriesAfter, file: file, line: line)

        let oldObjectAfter = treeAfter.first { $0.relativeComponent == oldObjectBefore.relativeComponent }
        XCTAssertEqual(oldObjectAfter?.relativeComponent, oldObjectBefore.relativeComponent, file: file, line: line)
        XCTAssertEqual(oldObjectAfter?.byteSize, oldObjectBefore.byteSize, file: file, line: line)
        XCTAssertEqual(oldObjectAfter?.contentHash, oldObjectBefore.contentHash, file: file, line: line)

        XCTAssertTrue(treeAfter.filter { $0.type == .staging }.isEmpty, file: file, line: line)
        XCTAssertTrue(treeAfter.filter { $0.type == .unknown }.isEmpty, file: file, line: line)

        let objectItems = treeAfter.filter { $0.type == .object }
        XCTAssertEqual(objectItems.count, 2, file: file, line: line)

        let expectedByteSize = Int64(baseline.encodedBytes.count)
        let expectedHash = sha256Data(for: baseline.encodedBytes)
        let orphanItems = objectItems.filter { $0.relativeComponent != oldObjectBefore.relativeComponent }
        XCTAssertEqual(orphanItems.count, 1, file: file, line: line)
        guard let orphan = orphanItems.first else {
            XCTFail("expected exactly one new orphan object", file: file, line: line)
            return
        }
        XCTAssertNotEqual(orphan.relativeComponent, oldObjectBefore.relativeComponent, file: file, line: line)
        XCTAssertEqual(orphan.byteSize, expectedByteSize, file: file, line: line)
        XCTAssertEqual(orphan.contentHash, expectedHash, file: file, line: line)

        let orphanID = parseObjectEntryID(from: orphan.relativeComponent)
        XCTAssertNotNil(orphanID, file: file, line: line)
        if let orphanID {
            XCTAssertFalse(entriesAfter.contains { $0.id == orphanID }, file: file, line: line)
        }
    }

    static func assertBookmarkPortScopeBalanced(
        _ bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            bookmarkPort.scopeStartCount,
            bookmarkPort.scopeStopCount,
            "security scope start/stop must balance",
            file: file,
            line: line
        )
    }

    static func assertBookmarkPortHasZeroScopeAccess(
        _ bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(bookmarkPort.scopeStartCount, 0, file: file, line: line)
        XCTAssertEqual(bookmarkPort.scopeStopCount, 0, file: file, line: line)
    }

    static func setStagingImmutableFlag(
        cachesDirectory: URL,
        relativeComponent: String,
        enabled: Bool
    ) throws {
        let versionRoot = DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
        var url = versionRoot.appendingPathComponent(relativeComponent)
        var values = URLResourceValues()
        values.isUserImmutable = enabled
        try url.setResourceValues(values)
    }

    static func removeCacheTreeEntry(cachesDirectory: URL, relativeComponent: String) throws {
        let versionRoot = DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
        let url = versionRoot.appendingPathComponent(relativeComponent)
        try FileManager.default.removeItem(at: url)
    }

    private static func appendCacheStagingEntries(
        versionRootFD: Int32,
        stagingComponent: String,
        into items: inout [CacheTreeItem]
    ) throws {
        let stagingFD = openat(versionRootFD, stagingComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stagingFD >= 0 else {
            items.append(
                CacheTreeItem(
                    relativeComponent: stagingComponent,
                    type: .unknown,
                    byteSize: 0,
                    contentHash: Data()
                )
            )
            return
        }
        defer { Darwin.close(stagingFD) }

        for name in try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: stagingFD).sorted() {
            let relative = "\(stagingComponent)/\(name)"
            appendCacheTreeLeaf(
                directoryFD: stagingFD,
                name: name,
                relativeComponent: relative,
                regularType: .staging,
                into: &items
            )
        }
    }

    private static func appendCacheObjectEntries(
        versionRootFD: Int32,
        objectsComponent: String,
        into items: inout [CacheTreeItem]
    ) throws {
        let objectsFD = openat(versionRootFD, objectsComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard objectsFD >= 0 else {
            items.append(
                CacheTreeItem(
                    relativeComponent: objectsComponent,
                    type: .unknown,
                    byteSize: 0,
                    contentHash: Data()
                )
            )
            return
        }
        defer { Darwin.close(objectsFD) }

        for shard in try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: objectsFD).sorted() {
            let shardRelative = "\(objectsComponent)/\(shard)"
            let shardMode: mode_t
            do {
                shardMode = try DerivedImageSecureIO.fstatatEntry(
                    directoryFD: objectsFD,
                    name: shard,
                    follow: false
                ).mode & S_IFMT
            } catch {
                appendCacheUnknownEntry(
                    directoryFD: objectsFD,
                    name: shard,
                    relativeComponent: shardRelative,
                    into: &items
                )
                continue
            }

            guard shardMode == S_IFDIR else {
                appendCacheUnknownEntry(
                    directoryFD: objectsFD,
                    name: shard,
                    relativeComponent: shardRelative,
                    into: &items
                )
                continue
            }

            guard DerivedImageCachePathLayout.isValidShardComponent(shard) else {
                appendCacheUnknownEntry(
                    directoryFD: objectsFD,
                    name: shard,
                    relativeComponent: shardRelative,
                    into: &items
                )
                continue
            }

            let shardFD = openat(objectsFD, shard, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard shardFD >= 0 else {
                items.append(
                    CacheTreeItem(
                        relativeComponent: shardRelative,
                        type: .unknown,
                        byteSize: 0,
                        contentHash: Data()
                    )
                )
                continue
            }
            defer { Darwin.close(shardFD) }

            for objectName in try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: shardFD).sorted() {
                let relative = "\(shardRelative)/\(objectName)"
                let regularType: CacheTreeItemType =
                    DerivedImageCachePathLayout.isKnownObjectRelativePath(relative) ? .object : .unknown
                appendCacheTreeLeaf(
                    directoryFD: shardFD,
                    name: objectName,
                    relativeComponent: relative,
                    regularType: regularType,
                    into: &items
                )
            }
        }
    }

    private static func appendCacheTreeLeaf(
        directoryFD: Int32,
        name: String,
        relativeComponent: String,
        regularType: CacheTreeItemType,
        into items: inout [CacheTreeItem]
    ) {
        let entryMode: mode_t
        do {
            entryMode = try DerivedImageSecureIO.fstatatEntry(
                directoryFD: directoryFD,
                name: name,
                follow: false
            ).mode & S_IFMT
        } catch {
            items.append(
                CacheTreeItem(
                    relativeComponent: relativeComponent,
                    type: .unknown,
                    byteSize: 0,
                    contentHash: Data()
                )
            )
            return
        }

        switch entryMode {
        case S_IFREG:
            let fileFD = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
            guard fileFD >= 0 else {
                items.append(
                    CacheTreeItem(
                        relativeComponent: relativeComponent,
                        type: .unknown,
                        byteSize: 0,
                        contentHash: Data()
                    )
                )
                return
            }
            defer { Darwin.close(fileFD) }
            do {
                let stats = try DerivedImageSecureIO.fstatRegularFile(fd: fileFD)
                let bytes = try DerivedImageSecureIO.readAllBytes(from: fileFD)
                items.append(
                    CacheTreeItem(
                        relativeComponent: relativeComponent,
                        type: regularType,
                        byteSize: stats.sizeBytes,
                        contentHash: sha256Data(for: bytes)
                    )
                )
            } catch {
                items.append(
                    CacheTreeItem(
                        relativeComponent: relativeComponent,
                        type: .unknown,
                        byteSize: 0,
                        contentHash: Data()
                    )
                )
            }
        case S_IFDIR, S_IFLNK:
            appendCacheUnknownEntry(
                directoryFD: directoryFD,
                name: name,
                relativeComponent: relativeComponent,
                into: &items
            )
        default:
            appendCacheUnknownEntry(
                directoryFD: directoryFD,
                name: name,
                relativeComponent: relativeComponent,
                into: &items
            )
        }
    }

    private static func appendCacheUnknownEntry(
        directoryFD: Int32,
        name: String,
        relativeComponent: String,
        into items: inout [CacheTreeItem]
    ) {
        _ = directoryFD
        _ = name
        items.append(
            CacheTreeItem(
                relativeComponent: relativeComponent,
                type: .unknown,
                byteSize: 0,
                contentHash: Data()
            )
        )
    }

    private static func appendSourceDirectoryEntries(
        directoryFD: Int32,
        relativePrefix: String,
        into items: inout [SourceTreeItem]
    ) throws {
        for name in try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: directoryFD).sorted() {
            let relative = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            let entryMode: mode_t
            do {
                entryMode = try DerivedImageSecureIO.fstatatEntry(
                    directoryFD: directoryFD,
                    name: name,
                    follow: false
                ).mode & S_IFMT
            } catch {
                items.append(
                    SourceTreeItem(
                        relativeComponent: relative,
                        entryType: .unknown,
                        byteSize: 0,
                        modifiedAtNs: 0,
                        contentHash: Data()
                    )
                )
                continue
            }

            switch entryMode {
            case S_IFREG:
                let fileFD = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
                guard fileFD >= 0 else {
                    items.append(
                        SourceTreeItem(
                            relativeComponent: relative,
                            entryType: .unknown,
                            byteSize: 0,
                            modifiedAtNs: 0,
                            contentHash: Data()
                        )
                    )
                    continue
                }
                defer { Darwin.close(fileFD) }
                do {
                    let stats = try DerivedImageSecureIO.fstatRegularFile(fd: fileFD)
                    let bytes = try DerivedImageSecureIO.readAllBytes(from: fileFD)
                    items.append(
                        SourceTreeItem(
                            relativeComponent: relative,
                            entryType: .regularFile,
                            byteSize: stats.sizeBytes,
                            modifiedAtNs: stats.modifiedAtNs,
                            contentHash: sha256Data(for: bytes)
                        )
                    )
                } catch {
                    items.append(
                        SourceTreeItem(
                            relativeComponent: relative,
                            entryType: .unknown,
                            byteSize: 0,
                            modifiedAtNs: 0,
                            contentHash: Data()
                        )
                    )
                }
            case S_IFDIR:
                items.append(
                    SourceTreeItem(
                        relativeComponent: relative,
                        entryType: .directory,
                        byteSize: 0,
                        modifiedAtNs: 0,
                        contentHash: Data()
                    )
                )
                let subFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard subFD >= 0 else {
                    items.append(
                        SourceTreeItem(
                            relativeComponent: relative,
                            entryType: .unknown,
                            byteSize: 0,
                            modifiedAtNs: 0,
                            contentHash: Data()
                        )
                    )
                    continue
                }
                defer { Darwin.close(subFD) }
                try appendSourceDirectoryEntries(
                    directoryFD: subFD,
                    relativePrefix: relative,
                    into: &items
                )
            case S_IFLNK:
                items.append(
                    SourceTreeItem(
                        relativeComponent: relative,
                        entryType: .symlink,
                        byteSize: 0,
                        modifiedAtNs: 0,
                        contentHash: Data()
                    )
                )
            default:
                items.append(
                    SourceTreeItem(
                        relativeComponent: relative,
                        entryType: .unknown,
                        byteSize: 0,
                        modifiedAtNs: 0,
                        contentHash: Data()
                    )
                )
            }
        }
    }

    /// On first `resourceIdentifier` call: return real FD resource ID, then append bytes to the source locator path.
    final class GrowSourceOnFirstResourceIDReader: FolderFileResourceReading, @unchecked Sendable {
        private let base = FoundationFolderFileResourceReader()
        private let lock = NSLock()
        private var resourceIDCallCount = 0
        private var didMutate = false
        let sourceLocatorURL: URL
        let appendBytes: Data

        init(sourceLocatorURL: URL, appendBytes: Data) {
            self.sourceLocatorURL = sourceLocatorURL
            self.appendBytes = appendBytes
        }

        var resourceIdentifierCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return resourceIDCallCount
        }

        func fileSizeBytes(for url: URL) -> Int64? {
            base.fileSizeBytes(for: url)
        }

        func modifiedAtNs(for url: URL) -> Int64? {
            base.modifiedAtNs(for: url)
        }

        func resourceIdentifier(for url: URL) -> Data? {
            lock.lock()
            resourceIDCallCount += 1
            let call = resourceIDCallCount
            lock.unlock()
            guard call == 1 else {
                return base.resourceIdentifier(for: url)
            }
            let realID = base.resourceIdentifier(for: url)
            lock.lock()
            let shouldMutate = !didMutate
            if shouldMutate {
                didMutate = true
            }
            lock.unlock()
            if shouldMutate {
                if let handle = try? FileHandle(forWritingTo: sourceLocatorURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: appendBytes)
                    try? handle.close()
                }
            }
            return realID
        }
    }

    /// On first `resourceIdentifier` call: return real FD resource ID, then set source locator mtime without changing bytes.
    final class SetMtimeOnFirstResourceIDReader: FolderFileResourceReading, @unchecked Sendable {
        private let base = FoundationFolderFileResourceReader()
        private let lock = NSLock()
        private var resourceIDCallCount = 0
        private var didMutate = false
        private var _postMutateModifiedAtNs: Int64?
        let sourceLocatorURL: URL
        let targetModifiedAtNs: Int64

        var postMutateModifiedAtNs: Int64? {
            lock.lock()
            defer { lock.unlock() }
            return _postMutateModifiedAtNs
        }

        init(sourceLocatorURL: URL, targetModifiedAtNs: Int64) {
            self.sourceLocatorURL = sourceLocatorURL
            self.targetModifiedAtNs = targetModifiedAtNs
        }

        var resourceIdentifierCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return resourceIDCallCount
        }

        func fileSizeBytes(for url: URL) -> Int64? {
            base.fileSizeBytes(for: url)
        }

        func modifiedAtNs(for url: URL) -> Int64? {
            base.modifiedAtNs(for: url)
        }

        func resourceIdentifier(for url: URL) -> Data? {
            lock.lock()
            resourceIDCallCount += 1
            let call = resourceIDCallCount
            lock.unlock()
            guard call == 1 else {
                return base.resourceIdentifier(for: url)
            }
            let realID = base.resourceIdentifier(for: url)
            lock.lock()
            let shouldMutate = !didMutate
            if shouldMutate {
                didMutate = true
            }
            lock.unlock()
            if shouldMutate {
                let date = Date(timeIntervalSince1970: Double(targetModifiedAtNs) / 1_000_000_000.0)
                try? FileManager.default.setAttributes(
                    [.modificationDate: date],
                    ofItemAtPath: sourceLocatorURL.path
                )
                let probeFD = open(sourceLocatorURL.path, O_RDONLY)
                if probeFD >= 0 {
                    defer { Darwin.close(probeFD) }
                    if let (_, mtime) = try? DerivedImageSecureIO.fstatRegularFile(fd: probeFD) {
                        lock.lock()
                        _postMutateModifiedAtNs = mtime
                        lock.unlock()
                    }
                }
            }
            return realID
        }
    }

    /// On second `resourceIdentifier` call: return same-FD resource ID, then atomically replace source locator bytes.
    final class ReplaceLocatorOnSecondResourceIDReader: FolderFileResourceReading, @unchecked Sendable {
        private let base = FoundationFolderFileResourceReader()
        private let lock = NSLock()
        private var resourceIDCallCount = 0
        private var didReplace = false
        private var _postReplaceModifiedAtNs: Int64?
        let sourceLocatorURL: URL
        let replacementBytes: Data

        var postReplaceModifiedAtNs: Int64? {
            lock.lock()
            defer { lock.unlock() }
            return _postReplaceModifiedAtNs
        }

        init(sourceLocatorURL: URL, replacementBytes: Data) {
            self.sourceLocatorURL = sourceLocatorURL
            self.replacementBytes = replacementBytes
        }

        var resourceIdentifierCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return resourceIDCallCount
        }

        func fileSizeBytes(for url: URL) -> Int64? {
            base.fileSizeBytes(for: url)
        }

        func modifiedAtNs(for url: URL) -> Int64? {
            base.modifiedAtNs(for: url)
        }

        func resourceIdentifier(for url: URL) -> Data? {
            lock.lock()
            resourceIDCallCount += 1
            let call = resourceIDCallCount
            lock.unlock()
            guard call == 2 else {
                return base.resourceIdentifier(for: url)
            }
            let capturedID = base.resourceIdentifier(for: url)
            lock.lock()
            let shouldReplace = !didReplace
            if shouldReplace {
                didReplace = true
            }
            lock.unlock()
            if shouldReplace {
                DerivedImageTestSupport.atomicReplaceFile(at: sourceLocatorURL, with: replacementBytes)
                let postMtime = base.modifiedAtNs(for: sourceLocatorURL)
                lock.lock()
                _postReplaceModifiedAtNs = postMtime
                lock.unlock()
            }
            return capturedID
        }
    }

    static func atomicReplaceFile(at url: URL, with bytes: Data) {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".replace-\(UUID().uuidString)")
        do {
            try bytes.write(to: temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    /// Returns fingerprint facts pinned at seed time so cache-corruption tests do not depend on
    /// nondeterministic `/dev/fd` resource identifiers from FoundationFolderFileResourceReader.
    struct PinnedSeedFingerprintReader: FolderFileResourceReading, Sendable {
        let sizeBytes: Int64
        let modifiedAtNs: Int64
        let resourceID: Data?

        func fileSizeBytes(for url: URL) -> Int64? { sizeBytes }
        func modifiedAtNs(for url: URL) -> Int64? { modifiedAtNs }
        func resourceIdentifier(for url: URL) -> Data? { resourceID }
    }

    /// Returns persisted resource ID on first `resourceIdentifier` call, scripted value on second.
    /// macOS cannot mutate real resource IDs on one inode; this boundary is explicit in test names.
    final class FlipSecondResourceIDReader: FolderFileResourceReading, @unchecked Sendable {
        private let base = FoundationFolderFileResourceReader()
        private let lock = NSLock()
        private var resourceIDCallCount = 0
        let persistedResourceID: Data?
        let scriptedSecondResourceID: Data

        init(persistedResourceID: Data?, scriptedSecondResourceID: Data) {
            self.persistedResourceID = persistedResourceID
            self.scriptedSecondResourceID = scriptedSecondResourceID
        }

        var resourceIdentifierCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return resourceIDCallCount
        }

        func fileSizeBytes(for url: URL) -> Int64? {
            base.fileSizeBytes(for: url)
        }

        func modifiedAtNs(for url: URL) -> Int64? {
            base.modifiedAtNs(for: url)
        }

        func resourceIdentifier(for url: URL) -> Data? {
            lock.lock()
            resourceIDCallCount += 1
            let call = resourceIDCallCount
            lock.unlock()
            if call == 1 {
                return persistedResourceID ?? base.resourceIdentifier(for: url)
            }
            return scriptedSecondResourceID
        }
    }

    final class PublishStagingCheckpoint: DerivedImagePublishCheckpointing, @unchecked Sendable {
        private let condition = NSCondition()
        private let releaseGate = DispatchSemaphore(value: 0)
        private var stagingName: String?
        private var reached = false
        private var released = false

        func waitUntilStagingReached(timeout: TimeInterval) throws -> String {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while !reached {
                guard condition.wait(until: deadline) else {
                    throw NSError(domain: "PublishStagingCheckpoint", code: 1)
                }
            }
            return stagingName!
        }

        func isGenerationReleased() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return released
        }

        func blockAfterStagingWritten(stagingName: String) {
            condition.lock()
            self.stagingName = stagingName
            reached = true
            condition.broadcast()
            condition.unlock()
            releaseGate.wait()
        }

        func releaseGeneration() {
            condition.lock()
            released = true
            condition.unlock()
            releaseGate.signal()
        }
    }

    final class FinalPublishCheckpoint: DerivedImageFinalPublishCheckpointing, @unchecked Sendable {
        struct PublishedSnapshot: Sendable {
            let entryID: UUID
            let storageFormat: DerivedImageStorageFormat
            let stagingName: String
        }

        private let condition = NSCondition()
        private let releaseGate = DispatchSemaphore(value: 0)
        private var entryID: UUID?
        private var storageFormat: DerivedImageStorageFormat?
        private var stagingName: String?
        private var reached = false
        private var released = false
        private var didSignalRelease = false

        func waitUntilFinalObjectPublished(timeout: TimeInterval) throws -> PublishedSnapshot {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while !reached {
                guard condition.wait(until: deadline) else {
                    throw NSError(domain: "FinalPublishCheckpoint", code: 1)
                }
            }
            return PublishedSnapshot(
                entryID: entryID!,
                storageFormat: storageFormat!,
                stagingName: stagingName!
            )
        }

        func isFinalPublishReleased() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return released
        }

        func blockAfterFinalObjectPublished(
            entryID: UUID,
            storageFormat: DerivedImageStorageFormat,
            stagingName: String
        ) {
            condition.lock()
            self.entryID = entryID
            self.storageFormat = storageFormat
            self.stagingName = stagingName
            reached = true
            condition.broadcast()
            condition.unlock()
            releaseGate.wait()
        }

        func releaseFinalPublish() {
            condition.lock()
            released = true
            let shouldSignal = !didSignalRelease
            if shouldSignal {
                didSignalRelease = true
            }
            condition.unlock()
            if shouldSignal {
                releaseGate.signal()
            }
        }
    }

    /// Synchronizes two concurrent publishers at staging write and final object publish.
    final class CrossInstanceRaceBarrier: DerivedImagePublishCheckpointing, DerivedImageFinalPublishCheckpointing, @unchecked Sendable {
        private let condition = NSCondition()
        private let requiredParticipants: Int
        private let callbackWaitTimeout: TimeInterval
        private var stagingBlocked = 0
        private var finalBlocked = 0
        private var stagingReleased = false
        private var finalReleased = false
        private var failureMessage: String?
        private var provisionalEntryIDs: [UUID] = []

        init(requiredParticipants: Int = 2, callbackWaitTimeout: TimeInterval = 15) {
            self.requiredParticipants = requiredParticipants
            self.callbackWaitTimeout = callbackWaitTimeout
        }

        func failure() -> String? {
            condition.lock()
            defer { condition.unlock() }
            return failureMessage
        }

        func provisionalEntryIDsSnapshot() -> [UUID] {
            condition.lock()
            defer { condition.unlock() }
            return provisionalEntryIDs
        }

        func releaseAll() {
            condition.lock()
            stagingReleased = true
            finalReleased = true
            condition.broadcast()
            condition.unlock()
        }

        func waitUntilStagingBlocked(timeout: TimeInterval) throws {
            try waitUntil({ stagingBlocked }, equals: requiredParticipants, timeout: timeout, label: "staging")
            if let failureMessage = failure() {
                throw NSError(
                    domain: "CrossInstanceRaceBarrier",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: failureMessage]
                )
            }
        }

        func releaseStaging() {
            condition.lock()
            stagingReleased = true
            condition.broadcast()
            condition.unlock()
        }

        func waitUntilFinalBlocked(timeout: TimeInterval) throws {
            try waitUntil({ finalBlocked }, equals: requiredParticipants, timeout: timeout, label: "final")
            if let failureMessage = failure() {
                throw NSError(
                    domain: "CrossInstanceRaceBarrier",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: failureMessage]
                )
            }
        }

        func releaseFinal() {
            condition.lock()
            finalReleased = true
            condition.broadcast()
            condition.unlock()
        }

        func blockAfterStagingWritten(stagingName: String) {
            condition.lock()
            stagingBlocked += 1
            condition.broadcast()
            let deadline = Date().addingTimeInterval(callbackWaitTimeout)
            while !stagingReleased && failureMessage == nil {
                guard condition.wait(until: deadline) else {
                    recordFailureLocked("timed out in staging callback after \(callbackWaitTimeout)s")
                    condition.unlock()
                    return
                }
            }
            condition.unlock()
        }

        func blockAfterFinalObjectPublished(
            entryID: UUID,
            storageFormat: DerivedImageStorageFormat,
            stagingName: String
        ) {
            condition.lock()
            provisionalEntryIDs.append(entryID)
            finalBlocked += 1
            condition.broadcast()
            let deadline = Date().addingTimeInterval(callbackWaitTimeout)
            while !finalReleased && failureMessage == nil {
                guard condition.wait(until: deadline) else {
                    recordFailureLocked("timed out in final publish callback after \(callbackWaitTimeout)s")
                    condition.unlock()
                    return
                }
            }
            condition.unlock()
        }

        private func recordFailureLocked(_ message: String) {
            if failureMessage == nil {
                failureMessage = message
            }
            stagingReleased = true
            finalReleased = true
            condition.broadcast()
        }

        private func waitUntil(
            _ count: () -> Int,
            equals target: Int,
            timeout: TimeInterval,
            label: String
        ) throws {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while count() < target && failureMessage == nil {
                guard condition.wait(until: deadline) else {
                    recordFailureLocked(
                        "timed out waiting for \(target) \(label) publishers; saw \(count())"
                    )
                    if let failureMessage {
                        throw NSError(
                            domain: "CrossInstanceRaceBarrier",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: failureMessage]
                        )
                    }
                    return
                }
            }
            if let failureMessage {
                throw NSError(
                    domain: "CrossInstanceRaceBarrier",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: failureMessage]
                )
            }
        }
    }

    static func sha256Data(for bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }

    static func assertCatalogSourceScopeAndAuxiliaryUntouched(
        env: TempEnvironment,
        fileURL: URL,
        factsBefore: GenerationCatalogFacts,
        sourceBefore: SourceFileSnapshot,
        bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort,
        jobBefore: Int,
        tagBefore: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, factsBefore, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fileURL), sourceBefore.bytes, file: file, line: line)
        let (_, modifiedAtNs, _) = env.productionFingerprint(for: fileURL)
        XCTAssertEqual(modifiedAtNs, sourceBefore.modifiedAtNs, file: file, line: line)
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount, file: file, line: line)
        let jobAfter = try await env.jobRecordCount()
        let tagAfter = try await env.tagRecordCount()
        XCTAssertEqual(jobAfter, jobBefore, file: file, line: line)
        XCTAssertEqual(tagAfter, tagBefore, file: file, line: line)
    }

    static func assertSingleFinalCacheConvergence(
        env: TempEnvironment,
        expectedEntryID: UUID,
        expectedFormat: DerivedImageStorageFormat,
        replacedEntryID: UUID? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 1, file: file, line: line)
        XCTAssertEqual(counts.objects, 1, file: file, line: line)
        XCTAssertEqual(counts.stagingFiles, 0, file: file, line: line)
        XCTAssertTrue(
            env.finalObjectExists(entryID: expectedEntryID, format: expectedFormat),
            file: file,
            line: line
        )
        if let replacedEntryID {
            let replacedStillExists = try await env.cacheEntryExists(id: replacedEntryID)
            XCTAssertFalse(replacedStillExists, file: file, line: line)
            XCTAssertFalse(
                env.finalObjectExists(entryID: replacedEntryID, format: expectedFormat),
                file: file,
                line: line
            )
        }
    }

    static func assertCheckpointReachedWithPublishedObject(
        env: TempEnvironment,
        snapshot: FinalPublishCheckpoint.PublishedSnapshot
    ) {
        XCTAssertTrue(env.finalObjectExists(entryID: snapshot.entryID, format: snapshot.storageFormat))
        XCTAssertFalse(env.stagingFileExists(name: snapshot.stagingName))
    }

    static func awaitDerivedSourceChanged(from loadTask: Task<DerivedImagePayload, Error>) async throws {
        do {
            _ = try await loadTask.value
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        } catch let error as DerivedImageError {
            XCTFail("expected derivedSourceChanged, got \(error)")
        }
    }

    static func assertFinalRevalidationRejected(
        env: TempEnvironment,
        bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort,
        snapshot: FinalPublishCheckpoint.PublishedSnapshot,
        expectedFacts: GenerationCatalogFacts,
        sourceFiles: [SourceFileSnapshot],
        jobCountBefore: Int,
        tagCountBefore: Int
    ) async throws {
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        XCTAssertFalse(env.finalObjectExists(entryID: snapshot.entryID, format: snapshot.storageFormat))
        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, expectedFacts)
        for sourceFile in sourceFiles {
            XCTAssertEqual(try Data(contentsOf: sourceFile.url), sourceFile.bytes)
            let (_, actualMtime, _) = env.productionFingerprint(for: sourceFile.url)
            XCTAssertEqual(actualMtime, sourceFile.modifiedAtNs)
        }
        let jobCountAfter = try await env.jobRecordCount()
        let tagCountAfter = try await env.tagRecordCount()
        XCTAssertEqual(jobCountAfter, jobCountBefore)
        XCTAssertEqual(tagCountAfter, tagCountBefore)
    }

    final class MaintenanceHoldCheckpoint: DerivedImageMaintenanceCheckpointing, @unchecked Sendable {
        private let condition = NSCondition()
        private let releaseGate = DispatchSemaphore(value: 0)
        private var held = false
        private var released = false

        func waitUntilMaintenanceHeld(timeout: TimeInterval) throws {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while !held {
                guard condition.wait(until: deadline) else {
                    throw NSError(domain: "MaintenanceHoldCheckpoint", code: 1)
                }
            }
        }

        func isMaintenanceReleased() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return released
        }

        func blockWhileMaintenanceHeld() {
            condition.lock()
            held = true
            condition.broadcast()
            condition.unlock()
            releaseGate.wait()
        }

        func releaseMaintenance() {
            condition.lock()
            released = true
            condition.unlock()
            releaseGate.signal()
        }
    }

    static let generousVolume = GenerousVolumeReader(
        availableBytes: 50 * 1024 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024 * 1024
    )

    enum DerivedImageRenderingTestFixtures {
        struct RGBA: Equatable {
            let r: UInt8
            let g: UInt8
            let b: UInt8
            let a: UInt8
        }

        static func canonicalUTI(for data: Data) throws -> String {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?
            else {
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 1)
            }
            return type
        }

        static func encodeImage(_ image: CGImage, uti: String, properties: CFDictionary? = nil) throws -> Data {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, uti as CFString, 1, nil) else {
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 2)
            }
            CGImageDestinationAddImage(dest, image, properties)
            guard CGImageDestinationFinalize(dest) else {
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 3)
            }
            return out as Data
        }

        static func makeQuadrantImage(width: Int, height: Int) -> CGImage {
            let tl = RGBA(r: 255, g: 0, b: 0, a: 255)
            let tr = RGBA(r: 0, g: 255, b: 0, a: 255)
            let bl = RGBA(r: 0, g: 0, b: 255, a: 255)
            let br = RGBA(r: 255, g: 255, b: 0, a: 255)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let color: RGBA
                    if x < width / 2 {
                        color = y < height / 2 ? tl : bl
                    } else {
                        color = y < height / 2 ? tr : br
                    }
                    let offset = (y * width + x) * 4
                    pixels[offset] = color.r
                    pixels[offset + 1] = color.g
                    pixels[offset + 2] = color.b
                    pixels[offset + 3] = color.a
                }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!
        }

        static func makeHorizontalStripeImage(width: Int, height: Int) -> CGImage {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let offset = (y * width + x) * 4
                    if x < width / 2 {
                        pixels[offset] = 220
                        pixels[offset + 1] = 20
                        pixels[offset + 2] = 20
                    } else {
                        pixels[offset] = 20
                        pixels[offset + 1] = 20
                        pixels[offset + 2] = 220
                    }
                    pixels[offset + 3] = 255
                }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!
        }

        static func makeSolidImage(width: Int, height: Int, rgba: RGBA) -> CGImage {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels[i] = rgba.r
                pixels[i + 1] = rgba.g
                pixels[i + 2] = rgba.b
                pixels[i + 3] = rgba.a
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!
        }

        static func makeAlphaPatchImage(size: Int) -> CGImage {
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            for y in 0 ..< size {
                for x in 0 ..< size {
                    let offset = (y * size + x) * 4
                    pixels[offset] = 100
                    pixels[offset + 1] = 150
                    pixels[offset + 2] = 200
                    let transparentPatch = x >= size * 3 / 4 && y >= size * 3 / 4
                    pixels[offset + 3] = transparentPatch ? 0 : 255
                }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            return CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!
        }

        static func jpegData(from image: CGImage, orientation: Int? = nil) throws -> Data {
            let props: CFDictionary?
            if let orientation {
                props = [kCGImagePropertyOrientation: orientation] as CFDictionary
            } else {
                props = nil
            }
            return try encodeImage(image, uti: UTType.jpeg.identifier, properties: props)
        }

        static func pngData(from image: CGImage, orientation: Int? = nil) throws -> Data {
            let props: CFDictionary?
            if let orientation {
                props = [kCGImagePropertyOrientation: orientation] as CFDictionary
            } else {
                props = nil
            }
            return try encodeImage(image, uti: UTType.png.identifier, properties: props)
        }

        static func probePNGOrientationRoundTrip(width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
            let probeImage = makeSolidImage(
                width: width,
                height: height,
                rgba: RGBA(r: 40, g: 50, b: 60, a: 255)
            )
            var failures: [String] = []
            for orientation in 1 ... 8 {
                let encoded = try pngData(from: probeImage, orientation: orientation)
                guard let read = sourceOrientation(for: encoded) else {
                    failures.append("orientation \(orientation): property missing after PNG encode")
                    continue
                }
                if read != orientation {
                    failures.append("orientation \(orientation): read \(read)")
                }
            }
            if !failures.isEmpty {
                XCTFail("ImageIO PNG orientation round-trip unsupported: \(failures.joined(separator: "; "))", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 12)
            }
        }

        static let metadataSentinelUserComment = "SENTINEL_EXIF_USER_COMMENT"
        static let metadataSentinelMapDatum = "SENTINEL_GPS_MAP_DATUM"
        static let metadataSentinelIPTCObject = "SENTINEL_IPTC_OBJECT"
        static let metadataSentinelIPTCCaption = "SENTINEL_IPTC_CAPTION"
        static let metadataSentinelTIFFDocument = "SENTINEL_TIFF_DOCUMENT"
        static let metadataSentinelDateTime = "2020:01:02 03:04:05"
        static let metadataSentinelLatitude = 12.345
        static let metadataSentinelLongitude = 67.890

        static func metadataSentinelJPEGData() throws -> Data {
            let image = makeSolidImage(width: 8, height: 8, rgba: RGBA(r: 90, g: 90, b: 90, a: 255))
            let exif: [CFString: Any] = [
                kCGImagePropertyExifUserComment: metadataSentinelUserComment,
                kCGImagePropertyExifDateTimeOriginal: metadataSentinelDateTime,
            ]
            let gps: [CFString: Any] = [
                kCGImagePropertyGPSMapDatum: metadataSentinelMapDatum,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSLatitude: metadataSentinelLatitude,
                kCGImagePropertyGPSLongitude: metadataSentinelLongitude,
            ]
            let iptc: [CFString: Any] = [
                kCGImagePropertyIPTCObjectName: metadataSentinelIPTCObject,
                kCGImagePropertyIPTCCaptionAbstract: metadataSentinelIPTCCaption,
            ]
            let tiff: [CFString: Any] = [
                kCGImagePropertyTIFFDocumentName: metadataSentinelTIFFDocument,
                kCGImagePropertyTIFFDateTime: metadataSentinelDateTime,
            ]
            let props = [
                kCGImagePropertyExifDictionary: exif as CFDictionary,
                kCGImagePropertyGPSDictionary: gps as CFDictionary,
                kCGImagePropertyIPTCDictionary: iptc as CFDictionary,
                kCGImagePropertyTIFFDictionary: tiff as CFDictionary,
            ] as CFDictionary
            return try encodeImage(image, uti: UTType.jpeg.identifier, properties: props)
        }

        static func requireEncodedData(uti: String, width: Int = 8, height: Int = 8) throws -> Data {
            let image = makeSolidImage(width: width, height: height, rgba: RGBA(r: 120, g: 130, b: 140, a: 255))
            let data = try encodeImage(image, uti: uti)
            guard !data.isEmpty else {
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 4)
            }
            return data
        }

        static func sourceOrientation(for data: Data) -> Int? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let orientation = props[kCGImagePropertyOrientation] as? Int
            else {
                return nil
            }
            return orientation
        }

        static func decodeRawImageWithoutOrientationTransform(from data: Data) throws -> CGImage {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 21)
            }
            return image
        }

        static func assertInteriorQuadrantCornersMatch(
            image: CGImage,
            width: Int,
            height: Int,
            expected: [RGBA],
            context: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let cornerLabels = ["TL", "TR", "BL", "BR"]
            let samplePoints: [(Int, Int)] = [
                (width / 4, height / 4),
                (width * 3 / 4, height / 4),
                (width / 4, height * 3 / 4),
                (width * 3 / 4, height * 3 / 4),
            ]
            for (index, point) in samplePoints.enumerated() {
                let actual = try rgbaPixel(in: image, x: point.0, y: point.1)
                assertColorsClose(
                    actual,
                    expected[index],
                    message: "\(context) corner \(cornerLabels[index])",
                    file: file,
                    line: line
                )
            }
        }

        static func decodeImage(from artifact: DerivedImageEncodedArtifact) throws -> CGImage {
            guard let source = CGImageSourceCreateWithData(artifact.bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 7)
            }
            return image
        }

        static func rgbaPixel(in image: CGImage, x: Int, y: Int) throws -> RGBA {
            guard x >= 0, y >= 0, x < image.width, y < image.height else {
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 8)
            }
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 9)
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // ImageIO-derived display images keep row 0 at the visual top in this raster path.
            let offset = (y * width + x) * 4
            return RGBA(r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2], a: pixels[offset + 3])
        }

        static func assertColorsClose(
            _ actual: RGBA,
            _ expected: RGBA,
            tolerance: Int = 48,
            message: String? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let prefix = message.map { "\($0): " } ?? ""
            XCTAssertLessThanOrEqual(
                abs(Int(actual.r) - Int(expected.r)),
                tolerance,
                "\(prefix)red channel",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                abs(Int(actual.g) - Int(expected.g)),
                tolerance,
                "\(prefix)green channel",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                abs(Int(actual.b) - Int(expected.b)),
                tolerance,
                "\(prefix)blue channel",
                file: file,
                line: line
            )
        }

        static func assertArtifactSelfConsistent(_ artifact: DerivedImageEncodedArtifact, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(Int64(artifact.bytes.count), artifact.byteSize, file: file, line: line)
            let expectedUTI = artifact.storageFormat == .jpeg ? UTType.jpeg.identifier : UTType.png.identifier
            let actualUTI = try canonicalUTI(for: artifact.bytes)
            XCTAssertEqual(actualUTI, expectedUTI, file: file, line: line)
            let image = try decodeImage(from: artifact)
            XCTAssertEqual(image.width, artifact.pixelWidth, file: file, line: line)
            XCTAssertEqual(image.height, artifact.pixelHeight, file: file, line: line)
            guard let source = CGImageSourceCreateWithData(artifact.bytes as CFData, nil) else {
                XCTFail("artifact must decode", file: file, line: line)
                return
            }
            XCTAssertEqual(CGImageSourceGetCount(source), 1, file: file, line: line)
        }

        private static func propertyString(_ value: Any?) -> String {
            guard let value else { return "" }
            return String(describing: value)
        }

        private static func propertyDouble(_ value: Any?) -> Double? {
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            if let double = value as? Double {
                return double
            }
            return nil
        }

        private static func assertBytesDoNotContainUTF8Sentinel(
            _ bytes: Data,
            _ sentinel: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            guard let needle = sentinel.data(using: .utf8), !needle.isEmpty else {
                XCTFail("sentinel UTF-8 encoding failed: \(sentinel)", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 22)
            }
            XCTAssertFalse(
                bytes.range(of: needle) != nil,
                "output bytes must not contain UTF-8 sentinel: \(sentinel)",
                file: file,
                line: line
            )
        }

        static func assertOutputMetadataSentinelsAbsent(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
            let textSentinels = [
                metadataSentinelUserComment,
                metadataSentinelMapDatum,
                metadataSentinelIPTCObject,
                metadataSentinelIPTCCaption,
                metadataSentinelTIFFDocument,
                metadataSentinelDateTime,
            ]
            for sentinel in textSentinels {
                try assertBytesDoNotContainUTF8Sentinel(bytes, sentinel, file: file, line: line)
            }

            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
                XCTFail("output metadata proof requires decodable image", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 13)
            }
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                XCTFail("output metadata proof requires readable properties", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 14)
            }

            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                XCTAssertNotEqual(propertyString(exif[kCGImagePropertyExifUserComment]), metadataSentinelUserComment, file: file, line: line)
                XCTAssertNotEqual(propertyString(exif[kCGImagePropertyExifDateTimeOriginal]), metadataSentinelDateTime, file: file, line: line)
            }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                XCTAssertNotEqual(propertyString(gps[kCGImagePropertyGPSMapDatum]), metadataSentinelMapDatum, file: file, line: line)
                if let latitude = propertyDouble(gps[kCGImagePropertyGPSLatitude]) {
                    XCTAssertNotEqual(latitude, metadataSentinelLatitude, accuracy: 0.0001, file: file, line: line)
                }
                if let longitude = propertyDouble(gps[kCGImagePropertyGPSLongitude]) {
                    XCTAssertNotEqual(longitude, metadataSentinelLongitude, accuracy: 0.0001, file: file, line: line)
                }
            }
            if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
                XCTAssertNotEqual(propertyString(iptc[kCGImagePropertyIPTCObjectName]), metadataSentinelIPTCObject, file: file, line: line)
                XCTAssertNotEqual(propertyString(iptc[kCGImagePropertyIPTCCaptionAbstract]), metadataSentinelIPTCCaption, file: file, line: line)
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                XCTAssertNotEqual(propertyString(tiff[kCGImagePropertyTIFFDocumentName]), metadataSentinelTIFFDocument, file: file, line: line)
                XCTAssertNotEqual(propertyString(tiff[kCGImagePropertyTIFFDateTime]), metadataSentinelDateTime, file: file, line: line)
            }
        }

        static func proveSourceMetadataSentinelsPresent(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                XCTFail("source metadata must decode", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 15)
            }
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                XCTFail("source metadata properties must decode", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 16)
            }
            guard let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
                XCTFail("source EXIF dictionary missing", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 17)
            }
            guard let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] else {
                XCTFail("source GPS dictionary missing", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 18)
            }
            guard let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else {
                XCTFail("source IPTC dictionary missing", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 19)
            }
            guard let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else {
                XCTFail("source TIFF dictionary missing", file: file, line: line)
                throw NSError(domain: "DerivedImageRenderingTestFixtures", code: 20)
            }

            XCTAssertEqual(propertyString(exif[kCGImagePropertyExifUserComment]), metadataSentinelUserComment, file: file, line: line)
            XCTAssertEqual(propertyString(exif[kCGImagePropertyExifDateTimeOriginal]), metadataSentinelDateTime, file: file, line: line)
            XCTAssertEqual(propertyString(gps[kCGImagePropertyGPSMapDatum]), metadataSentinelMapDatum, file: file, line: line)
            XCTAssertEqual(propertyString(gps[kCGImagePropertyGPSLatitudeRef]), "N", file: file, line: line)
            XCTAssertEqual(propertyString(gps[kCGImagePropertyGPSLongitudeRef]), "E", file: file, line: line)
            let latitude = try XCTUnwrap(propertyDouble(gps[kCGImagePropertyGPSLatitude]), file: file, line: line)
            let longitude = try XCTUnwrap(propertyDouble(gps[kCGImagePropertyGPSLongitude]), file: file, line: line)
            XCTAssertEqual(latitude, metadataSentinelLatitude, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(longitude, metadataSentinelLongitude, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(propertyString(iptc[kCGImagePropertyIPTCObjectName]), metadataSentinelIPTCObject, file: file, line: line)
            XCTAssertEqual(propertyString(iptc[kCGImagePropertyIPTCCaptionAbstract]), metadataSentinelIPTCCaption, file: file, line: line)
            XCTAssertEqual(propertyString(tiff[kCGImagePropertyTIFFDocumentName]), metadataSentinelTIFFDocument, file: file, line: line)
            XCTAssertEqual(propertyString(tiff[kCGImagePropertyTIFFDateTime]), metadataSentinelDateTime, file: file, line: line)
        }
    }
}
