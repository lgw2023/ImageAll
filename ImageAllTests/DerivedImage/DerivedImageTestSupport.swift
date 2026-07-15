import CoreGraphics
import Foundation
import GRDB
import XCTest
@testable import ImageAll

enum DerivedImageTestSupport {
    final class TempEnvironment: @unchecked Sendable {
        let root: URL
        let databaseURL: URL
        let cachesDirectory: URL
        let sourceRoot: URL
        let database: CatalogDatabase
        let bookmark: Data
        let sourceID: UUID
        let assetID: UUID

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

        func seedAvailableAsset(
            relativePath: String = "photos/sample.jpg",
            fileName: String = "sample.jpg",
            mediaType: String = "public.jpeg",
            contentRevision: Int = 1,
            contents: Data? = nil
        ) throws -> URL {
            let data = contents ?? FolderReconcileTestSupport.minimalJPEGData()
            let fileURL = try writeSource(relativePath: relativePath, contents: data)
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            let sizeBytes = Int64(values.fileSize ?? data.count)
            let modifiedAtNs = Int64((values.contentModificationDate ?? Date()).timeIntervalSince1970 * 1_000_000_000)
            let resourceID: Data?
            if let object = values.fileResourceIdentifier as? Data {
                resourceID = object
            } else if let number = values.fileResourceIdentifier as? NSNumber {
                resourceID = number.stringValue.data(using: .utf8)
            } else {
                resourceID = nil
            }

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

        func makeService(
            faultInjector: any DerivedImageCacheStoreFaultInjecting = NoDerivedImageCacheStoreFaultInjector(),
            volumeReader: (any DerivedImageVolumeCapacityReading)? = nil,
            clock: FixedJobClock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
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
                cachesDirectory: cachesDirectory,
                sourceAccess: access,
                volumeReader: volumeReader ?? FoundationDerivedImageVolumeCapacityReader(),
                clock: clock,
                faultInjector: faultInjector
            )
            return (service, bookmarkPort)
        }

        func cacheVersionRoot() -> URL {
            DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
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
    }

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

    static let generousVolume = GenerousVolumeReader(
        availableBytes: 50 * 1024 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024 * 1024
    )
}

extension DatabaseTestSupport {
    static func makeV002OnlyMigrator() -> DatabaseMigrator {
        var migrator = makeV001OnlyMigrator()
        V002AddStage1CatalogQuerySupportMigration.register(on: &migrator)
        return migrator
    }
}
