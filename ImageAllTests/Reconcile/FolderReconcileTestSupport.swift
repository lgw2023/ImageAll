import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

enum FolderReconcileTestSupport {
    static let baseTimeMs: Int64 = 1_700_000_200_000
    static let leaseDurationMs: Int64 = 60_000

    final class TempFixtureRoot {
        private static let prefix = "ImageAllReconcileTests-"
        private(set) var roots: [URL] = []

        func makeRoot(label: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(Self.prefix)\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            roots.append(url)
            return url
        }

        func writeFile(
            root: URL,
            relativePath: String,
            contents: Data,
            modificationDate: Date? = nil
        ) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url)
            if let modificationDate {
                try FileManager.default.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: url.path
                )
            }
            return url
        }

        func snapshotTree(root: URL) throws -> [String: Data] {
            var result: [String: Data] = [:]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                return result
            }
            for case let url as URL in enumerator {
                let rel = String(url.path.dropFirst(root.path.count + 1))
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    result[rel] = try Data(contentsOf: url)
                }
            }
            return result
        }

        struct FileSnapshot: Equatable {
            let bytes: Data?
            let isDirectory: Bool
            let modificationDate: Date?
            let resourceID: Data?
        }

        func snapshotDetailed(root: URL) throws -> [String: FileSnapshot] {
            var result: [String: FileSnapshot] = [:]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey,
                    .isDirectoryKey,
                ]
            ) else {
                return result
            }
            for case let url as URL in enumerator {
                let rel = String(url.path.dropFirst(root.path.count + 1))
                let values = try url.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey,
                    .isDirectoryKey,
                ])
                let resourceID: Data?
                if let object = values.fileResourceIdentifier as? Data {
                    resourceID = object
                } else if let number = values.fileResourceIdentifier as? NSNumber {
                    resourceID = number.stringValue.data(using: .utf8)
                } else {
                    resourceID = nil
                }
                let isDirectory = values.isDirectory == true
                let bytes: Data? = isDirectory ? nil : try Data(contentsOf: url)
                result[rel] = FileSnapshot(
                    bytes: bytes,
                    isDirectory: isDirectory,
                    modificationDate: values.contentModificationDate,
                    resourceID: resourceID
                )
            }
            return result
        }

        func cleanup() {
            for root in roots.reversed() {
                try? FileManager.default.removeItem(at: root)
            }
            roots.removeAll()
        }
    }

    final class TestBookmarkPort: SecurityScopedBookmarkPort, @unchecked Sendable {
        let rootByBookmark: [Data: URL]
        var scopeStartCount = 0
        var scopeStopCount = 0

        init(rootByBookmark: [Data: URL]) {
            self.rootByBookmark = rootByBookmark
        }

        func createReadOnlyBookmark(for url: URL) throws -> Data {
            url.path.data(using: .utf8) ?? Data()
        }

        func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
            guard let url = rootByBookmark[bookmark] ?? URL(string: String(data: bookmark, encoding: .utf8) ?? "", relativeTo: nil) else {
                throw NSError(domain: "TestBookmarkPort", code: 1)
            }
            return BookmarkResolveResult(url: url, isStale: false)
        }

        func startAccessing(_ url: URL) -> Bool {
            scopeStartCount += 1
            return true
        }

        func stopAccessing(_ url: URL) {
            scopeStopCount += 1
        }
    }

    static func makeSourceAccess(
        database: CatalogDatabase,
        bookmarkPort: TestBookmarkPort,
        clock: FixedJobClock? = nil
    ) -> FolderReconcileSourceAccessService {
        FolderReconcileSourceAccessService(
            repository: GRDBFolderSourceAuthorizationRepository(database: database),
            bookmarkPort: bookmarkPort,
            rootValidator: FolderRootValidator(),
            clock: clock ?? FixedJobClock(nowMs: baseTimeMs)
        )
    }

    static func makeCoordinator(
        queue: GRDBJobQueue,
        handler: FolderReconcileHandler,
        leaseDurationMs: Int64 = FolderReconcileTestSupport.leaseDurationMs
    ) -> JobExecutionCoordinator {
        JobExecutionCoordinator(
            queue: queue,
            registry: InMemoryJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
    }

    static func makeQueue(database: CatalogDatabase, nowMs: Int64 = baseTimeMs) -> GRDBJobQueue {
        GRDBJobQueue(
            database: database,
            clock: FixedJobClock(nowMs: nowMs),
            retryPolicy: FixedDelayRetryPolicy(delayMs: 5_000)
        )
    }

    static func makeHandler(
        database: CatalogDatabase,
        root: URL,
        bookmark: Data,
        enumerationConfig: FolderEnumerationConfig = .productionDefault,
        mediaResourceInjection: FolderMediaResourceValueInjection = .none,
        clock: FixedJobClock? = nil
    ) -> (FolderReconcileHandler, TestBookmarkPort) {
        let bookmarkPort = TestBookmarkPort(rootByBookmark: [bookmark: root])
        let access = makeSourceAccess(database: database, bookmarkPort: bookmarkPort, clock: clock)
        let handler = FolderReconcileHandler(
            rootAccess: access,
            enumerationConfig: enumerationConfig,
            mediaResourceInjection: mediaResourceInjection
        )
        return (handler, bookmarkPort)
    }

    static func seedActiveFolderSource(
        database: CatalogDatabase,
        sourceID: UUID,
        bookmark: Data,
        displayName: String = "Fixture"
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', ?, ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    displayName,
                    bookmark,
                    baseTimeMs,
                    baseTimeMs,
                ]
            )
        }
    }

    static func enqueueReconcileJob(
        queue: GRDBJobQueue,
        sourceID: UUID,
        jobID: UUID = UUID()
    ) throws -> JobRecordSnapshot {
        try queue.enqueue(
            try FolderReconcileJobFactory.makeEnqueueCommand(
                jobID: jobID,
                sourceID: sourceID,
                notBeforeMs: baseTimeMs
            )
        )
    }

    static func minimalPNGData() -> Data {
        let width = 2
        let height = 1
        var pixels = [UInt8](repeating: 0xFF, count: width * height * 4)
        pixels[3] = 0x00
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func minimalJPEGData() -> Data {
        return minimalEncodedImageData(uti: UTType.jpeg.identifier) ?? Data()
    }

    static func minimalTIFFData() -> Data? {
        minimalEncodedImageData(uti: UTType.tiff.identifier)
    }

    static func reconcilePayload(sourceID: UUID) -> Data {
        let payload: [String: Any] = [
            "contract_version": FolderReconcileJobFactory.contractVersion,
            "source_id": sourceID.uuidString.lowercased(),
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static func beginGenerationInput(
        lease: JobLeaseToken,
        sourceID: UUID,
        leaseDurationMs: Int64 = FolderReconcileTestSupport.leaseDurationMs
    ) -> FolderBeginGenerationInput {
        FolderBeginGenerationInput(
            lease: lease,
            sourceID: sourceID,
            payloadVersion: FolderReconcileJobFactory.payloadVersion,
            payload: reconcilePayload(sourceID: sourceID),
            leaseDurationMs: leaseDurationMs
        )
    }

    /// Auditable 1x1 lossy WebP fixture for decode verification when encoding is unavailable.
    static let minimalStaticWebPData = Data([
        0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x20, 0x18, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00, 0x9d,
        0x01, 0x2a, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00, 0x34, 0x25, 0xa4, 0x00,
        0x03, 0x70, 0x00, 0xfe, 0xfb, 0xfd, 0x50, 0x00,
    ])

    static func minimalWebPData() -> Data {
        minimalStaticWebPData
    }

    static func minimalHEICData() -> Data? {
        if #available(macOS 10.13, *) {
            return minimalEncodedImageData(uti: UTType.heic.identifier)
        }
        return nil
    }

    static func minimalHEIFData() -> Data {
        minimalStaticHEIFData
    }

    static func minimalBMPData() -> Data? {
        minimalEncodedImageData(uti: UTType.bmp.identifier)
    }

    /// Source: https://github.com/mathiasbynens/small/blob/master/heif.heif (MIT), ftyp major/compatible brand patched `heic`→`heif` so host ImageIO reports `public.heif` (not `public.heic`). Verified: `CGImageSourceGetType` == `public.heif`, count == 1.
    static let minimalStaticHEIFData = Data([
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x66, 0x00, 0x00, 0x00, 0x00, 0x6d, 0x69, 0x66, 0x31, 0x68, 0x65, 0x69, 0x66, 0x00, 0x00, 0x01, 0x2a, 0x6d, 0x65, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x68, 0x64, 0x6c, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0x69, 0x63, 0x74, 0x00, 0x5c, 0x00, 0x63, 0x00, 0x31, 0x00, 0x35, 0x00, 0x78, 0x00, 0x32, 0x00, 0x00, 0x00, 0x00, 0x0e, 0x70, 0x69, 0x74, 0x6d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x22, 0x69, 0x6c, 0x6f, 0x63, 0x00, 0x00, 0x00, 0x00, 0x44, 0x40, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x4a, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x23, 0x69, 0x69, 0x6e, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x15, 0x69, 0x6e, 0x66, 0x65, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x68, 0x76, 0x63, 0x31, 0x00, 0x00, 0x00, 0x00, 0xaa, 0x69, 0x70, 0x72, 0x70, 0x00, 0x00, 0x00, 0x8d, 0x69, 0x70, 0x63, 0x6f, 0x00, 0x00, 0x00, 0x71, 0x68, 0x76, 0x63, 0x43, 0x01, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xf0, 0x00, 0xfc, 0xfd, 0xf8, 0xf8, 0x00, 0x00, 0x0f, 0x03, 0x20, 0x00, 0x01, 0x00, 0x17, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9f, 0xa8, 0x00, 0x00, 0x03, 0x00, 0x00, 0xff, 0xba, 0x02, 0x40, 0x21, 0x00, 0x01, 0x00, 0x26, 0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9f, 0xa8, 0x00, 0x00, 0x03, 0x00, 0x00, 0xff, 0xa0, 0x20, 0x81, 0x05, 0x96, 0xea, 0x49, 0x28, 0xae, 0x01, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x01, 0x08, 0x22, 0x00, 0x01, 0x00, 0x06, 0x44, 0x01, 0xc1, 0x71, 0x89, 0x12, 0x00, 0x00, 0x00, 0x14, 0x69, 0x73, 0x70, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x15, 0x69, 0x70, 0x6d, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x02, 0x81, 0x02, 0x00, 0x00, 0x00, 0x40, 0x6d, 0x64, 0x61, 0x74, 0x00, 0x00, 0x00, 0x34, 0x28, 0x01, 0xaf, 0x05, 0xb8, 0x14, 0x83, 0xea, 0x23, 0x40, 0x1f, 0xf7, 0x5f, 0xee, 0x7f, 0xb5, 0xfd, 0x6f, 0xce, 0xfc, 0xef, 0xce, 0xfc, 0xef, 0xcf, 0x7c, 0xf7, 0xcf, 0x7c, 0xf7, 0xcf, 0x7c, 0xf7, 0xcf, 0x7c, 0xf7, 0xfe, 0x14, 0x11, 0x33, 0x09, 0x65, 0x03, 0x5e, 0xda, 0x72, 0xb4, 0xe9, 0xc5, 0x20, 0xd6, 0xc0,
    ])

    static func minimalEncodedImageData(uti: String) -> Data? {
        let width = 2
        let height = 2
        var pixels = [UInt8](repeating: 0x80, count: width * height * 4)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return data as Data
    }

    static func imageIOActualType(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceGetType(source) as String?
    }

    static func minimalOrientedJPEGData(orientation: Int) -> Data? {
        guard let base = minimalEncodedImageData(uti: UTType.jpeg.identifier) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(base as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let props = [kCGImagePropertyOrientation: orientation] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return out as Data
    }

    static func minimalMultiFrameTIFFData() -> Data? {
        guard let frame = minimalEncodedImageData(uti: UTType.tiff.identifier),
              let source = CGImageSourceCreateWithData(frame as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 2, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return out as Data
    }

    struct AssetRow: Equatable {
        let id: String
        let relativePath: String
        let locatorState: String
        let availability: String
        let contentRevision: Int
        let lastSeenGeneration: Int?
        let sizeBytes: Int64?
        let modifiedAtNs: Int64?
        let resourceID: Data?
        let sha256: Data?
        let tagCount: Int
    }

    static func fetchAssetRows(database: CatalogDatabase, sourceID: UUID) throws -> [AssetRow] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT a.id, a.relative_path, a.locator_state, a.availability, a.content_revision,
                       a.last_seen_generation, f.size_bytes, f.modified_at_ns, f.resource_id, f.sha256,
                       (SELECT COUNT(*) FROM asset_tag_decision d
                        WHERE d.asset_id = a.id AND d.decision = 'accepted') AS tag_count
                FROM asset a
                LEFT JOIN file_fingerprint f ON f.asset_id = a.id
                WHERE a.source_id = ?
                ORDER BY a.relative_path, a.locator_state
                """,
                arguments: [sourceID.uuidString.lowercased()]
            )
            return rows.map { row in
                AssetRow(
                    id: row["id"],
                    relativePath: row["relative_path"],
                    locatorState: row["locator_state"],
                    availability: row["availability"],
                    contentRevision: row["content_revision"],
                    lastSeenGeneration: row["last_seen_generation"],
                    sizeBytes: row["size_bytes"],
                    modifiedAtNs: row["modified_at_ns"],
                    resourceID: row["resource_id"],
                    sha256: row["sha256"],
                    tagCount: row["tag_count"]
                )
            }
        }
    }

    static func seedActiveTag(database: CatalogDatabase, assetID: String, label: String) throws {
        let tagID = UUID().uuidString.lowercased()
        let normalized = label.lowercased()
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, 'active', ?, ?)
                """,
                arguments: [tagID, label, normalized, baseTimeMs, baseTimeMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [assetID, tagID, baseTimeMs]
            )
        }
    }

    static func imageIOCanEncode(_ uti: String) -> Bool {
        minimalEncodedImageData(uti: uti) != nil
    }
}

enum FolderReconcileTestFaults {
    enum FaultStage: Int {
        case none = 0
        case failBeginSourceUpdate = 1
        case failAssetInsert = 2
        case failBatchCheckpoint = 3
        case failFinalMissing = 4
        case failFinalCompletion = 5
        case failFinalSuccessor = 6
        case failFingerprintInsert = 7
        case failBatchLeaseRenew = 8
        case failBatchProgress = 9
    }

    static func install(on database: CatalogDatabase) throws {
        try database.pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS reconcile_fault_control (mode INTEGER NOT NULL DEFAULT 0) STRICT
                """)
            try db.execute(sql: "DELETE FROM reconcile_fault_control")
            try db.execute(sql: "INSERT INTO reconcile_fault_control (mode) VALUES (0)")

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_begin_source_update")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_begin_source_update
                BEFORE UPDATE OF scan_generation ON source
                WHEN (SELECT mode FROM reconcile_fault_control) = 1
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_begin_source_update'); END
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_asset_insert")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_asset_insert
                BEFORE INSERT ON asset
                WHEN (SELECT mode FROM reconcile_fault_control) = 2
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_asset_insert'); END
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_batch_checkpoint")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_batch_checkpoint
                BEFORE UPDATE OF checkpoint ON job
                WHEN (SELECT mode FROM reconcile_fault_control) = 3
                  AND NEW.state = 'running'
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_batch_checkpoint'); END
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_final_missing")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_final_missing
                BEFORE UPDATE OF availability ON asset
                WHEN (SELECT mode FROM reconcile_fault_control) = 4
                  AND NEW.availability = 'missing'
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_final_missing'); END
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_final_completion")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_final_completion
                BEFORE UPDATE OF state ON job
                WHEN (SELECT mode FROM reconcile_fault_control) = 5
                  AND NEW.state = 'completed'
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_final_completion'); END
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_final_successor")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_final_successor
                BEFORE INSERT ON job
                WHEN (SELECT mode FROM reconcile_fault_control) = 6
                  AND NEW.kind = 'folder.reconcile.v1'
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_final_successor'); END
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_fingerprint_insert")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_fingerprint_insert
                BEFORE INSERT ON file_fingerprint
                WHEN (SELECT mode FROM reconcile_fault_control) = 7
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_fingerprint_insert'); END
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_batch_lease_renew")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_batch_lease_renew
                BEFORE UPDATE OF lease_expires_at_ms ON job
                WHEN (SELECT mode FROM reconcile_fault_control) = 8
                  AND NEW.state = 'running'
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_batch_lease_renew'); END
                """)

            try db.execute(sql: "DROP TRIGGER IF EXISTS reconcile_fail_batch_progress")
            try db.execute(sql: """
                CREATE TRIGGER reconcile_fail_batch_progress
                BEFORE UPDATE OF progress_completed ON job
                WHEN (SELECT mode FROM reconcile_fault_control) = 9
                  AND NEW.state = 'running'
                BEGIN SELECT RAISE(ABORT, 'reconcile_fail_batch_progress'); END
                """)
        }
    }

    static func setMode(_ mode: FaultStage, database: CatalogDatabase) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE reconcile_fault_control SET mode = ?", arguments: [mode.rawValue])
        }
    }
}
