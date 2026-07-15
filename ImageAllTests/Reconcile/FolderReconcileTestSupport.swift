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
        clock: FixedJobClock? = nil
    ) -> (FolderReconcileHandler, TestBookmarkPort) {
        let bookmarkPort = TestBookmarkPort(rootByBookmark: [bookmark: root])
        let access = makeSourceAccess(database: database, bookmarkPort: bookmarkPort, clock: clock)
        let handler = FolderReconcileHandler(rootAccess: access, enumerationConfig: enumerationConfig)
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

    static func minimalHEIFData() -> Data? {
        if #available(macOS 10.13, *) {
            if let heif = minimalEncodedImageData(uti: UTType.heif.identifier) {
                return heif
            }
            // When the host cannot encode HEIF, verify the .heif read path with HEIC-compatible bytes.
            return minimalHEICData()
        }
        return nil
    }

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
        }
    }

    static func setMode(_ mode: FaultStage, database: CatalogDatabase) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE reconcile_fault_control SET mode = ?", arguments: [mode.rawValue])
        }
    }
}
