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

        func cleanup() {
            for root in roots.reversed() {
                try? FileManager.default.removeItem(at: root)
            }
            roots.removeAll()
        }
    }

    struct TestBookmarkPort: SecurityScopedBookmarkPort {
        let rootByBookmark: [Data: URL]

        func createReadOnlyBookmark(for url: URL) throws -> Data {
            url.path.data(using: .utf8) ?? Data()
        }

        func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
            guard let url = rootByBookmark[bookmark] ?? URL(string: String(data: bookmark, encoding: .utf8) ?? "", relativeTo: nil) else {
                throw NSError(domain: "TestBookmarkPort", code: 1)
            }
            return BookmarkResolveResult(url: url, isStale: false)
        }

        func startAccessing(_ url: URL) -> Bool { true }
        func stopAccessing(_ url: URL) {}
    }

    static func makeQueue(database: CatalogDatabase, nowMs: Int64 = baseTimeMs) -> GRDBJobQueue {
        GRDBJobQueue(
            database: database,
            clock: FixedJobClock(nowMs: nowMs),
            retryPolicy: FixedDelayRetryPolicy(delayMs: 5_000)
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
            leaseContextProvider: GRDBJobLeaseContextProvider()
        )
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
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
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
        }
    }

    static func setMode(_ mode: FaultStage, database: CatalogDatabase) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE reconcile_fault_control SET mode = ?", arguments: [mode.rawValue])
        }
    }
}
