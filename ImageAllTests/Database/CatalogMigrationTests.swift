import GRDB
import XCTest
@testable import ImageAll

final class CatalogMigrationTests: XCTestCase {
    func testFreshDatabaseAppliesV001Once() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertEqual(
            try database.appliedMigrationIDs(),
            CatalogMigrationID.knownOrdered
        )
    }

    func testReopeningDatabaseIsIdempotentAndPreservesData() throws {
        let url = try makeTempDatabaseURL()
        let sourceID = UUID()
        let assetID = UUID()

        let first = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: first)
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: sourceID,
            assetID: assetID
        )

        let second = try CatalogDatabase.open(at: url)
        XCTAssertEqual(
            try second.appliedMigrationIDs(),
            CatalogMigrationID.knownOrdered
        )

        let count = try second.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testV012RepairsMissingStandardTagBindingAndRestoresTagCreate() throws {
        let url = try makeTempDatabaseURL()
        let sourceID = UUID()
        let assetID = UUID()
        let seeded = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: seeded)
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: sourceID,
            assetID: assetID
        )
        try seeded.pool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE standard_tag_binding")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [CatalogMigrationID.v012RepairStandardTagBinding]
            )
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            XCTAssertFalse(try db.tableExists("standard_tag_binding"))
        }
        try seeded.pool.close()

        let repaired = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try repaired.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
        try repaired.pool.read { db in
            XCTAssertTrue(try db.tableExists("standard_tag_binding"))
        }

        let tags = GRDBTagCatalogRepository(database: repaired)
        let listedBefore = try tags.listTags(includeArchived: false)
        XCTAssertTrue(listedBefore.isEmpty)

        let created = try tags.createTagAndApply(
            rawName: "老婆",
            assetIDs: [assetID],
            decision: .accepted,
            timestampMs: DatabaseTestSupport.timestampMs
        )
        XCTAssertEqual(created.displayName, "老婆")
        let listedAfter = try tags.listTags(includeArchived: false)
        XCTAssertEqual(listedAfter.map(\.displayName), ["老婆"])
        let detail = try GRDBAssetCatalogQueryRepository(database: repaired)
            .fetchInspectorDetail(assetID: assetID)
        XCTAssertEqual(
            detail.tags.first(where: { $0.tagID == created.tagID })?.decision,
            .accepted
        )
    }

    func testV013ClearsPhotosSyncCursorForOneTimeMissingAssetRepair() throws {
        let url = try makeTempDatabaseURL()
        let sourceID = UUID()
        let seeded = try CatalogDatabase.open(at: url)
        try seeded.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, sync_cursor, state,
                    created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Apple Photos', NULL, ?, 'active', ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    Data("photos-token".utf8),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [CatalogMigrationID.v013PhotosMissingAssetRepair]
            )
        }
        try seeded.pool.close()

        let migrated = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try migrated.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
        let cursor = try migrated.pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT sync_cursor FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertNil(cursor)
    }

    func testCurrentCatalogScopeIdentityIsCanonicalAndStableAcrossReopen() throws {
        let url = try makeTempDatabaseURL()

        let first = try CatalogDatabase.open(at: url)
        let firstScopeID = try first.catalogScopeID()
        let parsed = try XCTUnwrap(UUID(uuidString: firstScopeID))
        XCTAssertEqual(firstScopeID, parsed.uuidString.lowercased())

        let second = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try second.catalogScopeID(), firstScopeID)
    }

    func testCurrentSchemaMaintainsTrigramAssetSearchIndex() throws {
        let url = try makeTempDatabaseURL()
        let sourceID = UUID()
        let assetID = UUID()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: sourceID,
            assetID: assetID
        )

        func matchedAssetIDs(_ query: String) throws -> [String] {
            try database.pool.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT asset.id
                    FROM asset_search
                    INNER JOIN asset ON asset.rowid = asset_search.rowid
                    WHERE asset_search MATCH ?
                    """,
                    arguments: [query]
                )
            }
        }

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET file_name = 'needle-file.jpg', relative_path = 'archive/needle-file.jpg' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(try matchedAssetIDs("\"needle-file\""), [assetID.uuidString.lowercased()])

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET file_name = 'renamed-photo.jpg', relative_path = 'archive/renamed-photo.jpg' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertTrue(try matchedAssetIDs("\"needle-file\"").isEmpty)
        XCTAssertEqual(try matchedAssetIDs("\"renamed-photo\""), [assetID.uuidString.lowercased()])

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [assetID.uuidString.lowercased()])
        }
        XCTAssertTrue(try matchedAssetIDs("\"renamed-photo\"").isEmpty)
        XCTAssertTrue(CatalogMigrationID.knownOrdered.contains("v006_add_asset_text_search"))
    }

    func testV006BackfillsAssetTextFromExistingV005Database() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try DatabaseTestSupport.makeV005OnlyMigrator().migrate(pool)

        let database = CatalogDatabase(pool: pool)
        let sourceID = UUID()
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: CatalogRepository(database: database),
            sourceID: sourceID,
            assetID: assetID
        )
        try pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET file_name = 'before-upgrade.jpg', relative_path = 'archive/before-upgrade.jpg' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }

        try CatalogDatabase.makeMigrator().migrate(pool)

        let matchedIDs = try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT asset.id
                FROM asset_search
                INNER JOIN asset ON asset.rowid = asset_search.rowid
                WHERE asset_search MATCH '"before-upgrade"'
                """
            )
        }
        XCTAssertEqual(matchedIDs, [assetID.uuidString.lowercased()])
    }

    func testScaleMigrationConfigurationAcceptsOnlySmokeAndMillionCounts() throws {
        XCTAssertEqual(try CatalogQueryTestSupport.scaleMigrationAssetCount(environmentValue: nil), 10_000)
        XCTAssertEqual(try CatalogQueryTestSupport.scaleMigrationAssetCount(environmentValue: "10000"), 10_000)
        XCTAssertEqual(try CatalogQueryTestSupport.scaleMigrationAssetCount(environmentValue: "1000000"), 1_000_000)
        XCTAssertThrowsError(
            try CatalogQueryTestSupport.scaleMigrationAssetCount(environmentValue: "100000")
        ) { error in
            XCTAssertEqual(
                error as? CatalogQueryTestSupport.ScaleFixtureError,
                .unsupportedMigrationAssetCount("100000")
            )
        }
    }

    func testConfiguredV005ToV006StartupMigrationCalibratesCapacityEnvelope() throws {
        let environment = ProcessInfo.processInfo.environment
        #if IMAGEALL_MIGRATION_MILLION
        let configuredAssetCount = "1000000"
        #else
        let configuredAssetCount = environment["IMAGEALL_SYNTHETIC_MIGRATION_ASSET_COUNT"]
        #endif
        let assetCount = try CatalogQueryTestSupport.scaleMigrationAssetCount(
            environmentValue: configuredAssetCount
        )
        let parentURL = environment["IMAGEALL_SYNTHETIC_MIGRATION_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let resolvedParentPath = parentURL.standardizedFileURL.resolvingSymlinksInPath().path
        let forbiddenRoots = [
            "/Volumes/HDD2",
            "/Volumes/SSD1/ImageAll/user",
        ]
        guard !forbiddenRoots.contains(where: {
            resolvedParentPath == $0 || resolvedParentPath.hasPrefix($0 + "/")
        }) else {
            return XCTFail("Migration calibration root is protected: \(resolvedParentPath)")
        }

        let root = parentURL.appendingPathComponent(
            "ImageAll-MigrationCalibration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let pathsResolver = StartupTestSupport.makePathsResolver(root: root)
        let paths = try pathsResolver.resolve()
        try pathsResolver.ensureRequiredDirectories(for: paths)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: paths.catalogDatabaseURL.path, configuration: configuration)
        try DatabaseTestSupport.makeV005OnlyMigrator().migrate(pool)
        let v005Database = CatalogDatabase(pool: pool)
        _ = try CatalogQueryTestSupport.seedScaleCatalog(database: v005Database, assetCount: assetCount)

        try pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), assetCount)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision"),
                CatalogQueryTestSupport.scaleDecisionCount(assetCount: assetCount)
            )
            XCTAssertEqual(
                try CatalogDatabase.readAppliedMigrationIDs(from: db),
                Array(CatalogMigrationID.knownOrdered.prefix(5))
            )
            try CatalogDatabase.performQuickCheck(on: db)
        }
        try v005Database.checkpointAndCloseForReplacement()

        let capacityChecker = CatalogCapacityChecker()
        let sourceFootprint = try capacityChecker.databaseFootprintBytes(at: paths.catalogDatabaseURL)
        let baselineUsage = CatalogMigrationFootprintMonitor.measureUsage(at: root)
        let requiredAdditional = try XCTUnwrap(
            CatalogCapacityRequirement.requiredAdditionalBytes(sourceFootprint: sourceFootprint)
        )
        let initialAvailable = try FoundationCatalogCapacityProvider().availableBytes(for: root)
        let initialFileSystemFree = CatalogMigrationFootprintMonitor.fileSystemFreeBytes(at: root)
        let operationID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
        let monitor = CatalogMigrationFootprintMonitor(rootURL: root)
        monitor.start()

        let startedAt = ContinuousClock.now
        let result = CatalogBootstrapCoordinator(
            dependencies: StartupTestSupport.makeDependencies(
                root: root,
                capacityProvider: FixedCapacityProvider(bytes: .max),
                operationID: operationID
            )
        ).bootstrap()
        let elapsed = ContinuousClock.now - startedAt
        let peak = monitor.stop()

        guard case let .ready(token) = result else {
            return XCTFail("Expected ready after v005 to v006 migration, got \(result)")
        }
        defer { try? token.close() }

        let finalDatabase = token.runtime.database
        try finalDatabase.validateQuickCheck()
        XCTAssertEqual(try finalDatabase.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
        let representativeIndex = assetCount - 2
        try finalDatabase.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), assetCount)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source"), 2)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision"),
                CatalogQueryTestSupport.scaleDecisionCount(assetCount: assetCount)
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_search"), assetCount)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT asset.id
                    FROM asset_search
                    INNER JOIN asset ON asset.rowid = asset_search.rowid
                    WHERE asset_search MATCH ?
                    """,
                    arguments: ["\"\(CatalogQueryTestSupport.scaleSearchText(index: representativeIndex))\""]
                ),
                [CatalogQueryTestSupport.scaleAssetID(representativeIndex).uuidString.lowercased()]
            )
        }

        let backupURL = paths.catalogDirectory.appendingPathComponent(
            "ImageAll.sqlite.pre-restore-\(operationID.uuidString.lowercased())"
        )
        XCTAssertEqual(
            try SnapshotTestSupport.readMigrationIDs(at: backupURL),
            Array(CatalogMigrationID.knownOrdered.prefix(5))
        )
        let backupAssetCount = try CatalogDatabase.withReadonlyQueue(at: backupURL) { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        }
        XCTAssertEqual(backupAssetCount, assetCount)

        let peakAdditionalLogical = peak.logicalBytes > baselineUsage.logicalBytes
            ? peak.logicalBytes - baselineUsage.logicalBytes
            : 0
        XCTAssertGreaterThan(peak.sampleCount, 0)
        XCTAssertGreaterThanOrEqual(requiredAdditional, peakAdditionalLogical)

        let finalFootprint = try capacityChecker.databaseFootprintBytes(at: paths.catalogDatabaseURL)
        let availableDrop: UInt64?
        if let initialAvailable, let minimumAvailable = peak.minimumAvailableBytes,
           initialAvailable >= minimumAvailable {
            availableDrop = initialAvailable - minimumAvailable
        } else {
            availableDrop = nil
        }
        let fileSystemFreeDrop: UInt64?
        if let initialFileSystemFree, let minimumFileSystemFree = peak.minimumFileSystemFreeBytes,
           initialFileSystemFree >= minimumFileSystemFree {
            fileSystemFreeDrop = initialFileSystemFree - minimumFileSystemFree
        } else {
            fileSystemFreeDrop = nil
        }
        let legacyRequirement = sourceFootprint * 2 + CatalogCapacityRequirement.minimumMarginBytes
        let attachment = XCTAttachment(
            string: [
                "assets=\(assetCount)",
                "migration_elapsed=\(elapsed)",
                "v005_source_bytes=\(sourceFootprint)",
                "v006_live_bytes=\(finalFootprint)",
                "baseline_logical_bytes=\(baselineUsage.logicalBytes)",
                "peak_logical_bytes=\(peak.logicalBytes)",
                "peak_additional_logical_bytes=\(peakAdditionalLogical)",
                "peak_allocated_bytes=\(peak.allocatedBytes)",
                "available_capacity_drop_bytes=\(availableDrop.map(String.init) ?? "unavailable")",
                "file_system_free_drop_bytes=\(fileSystemFreeDrop.map(String.init) ?? "unavailable")",
                "legacy_required_additional_bytes=\(legacyRequirement)",
                "required_additional_bytes=\(requiredAdditional)",
                "samples=\(peak.sampleCount)",
            ].joined(separator: "\n")
        )
        attachment.name = "ImageAll \(assetCount) v005-to-v006 migration calibration"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testUnknownFutureMigrationIsRejected() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let seedPool = try DatabasePool(path: url.path, configuration: config)
        try seedPool.write { db in
            try db.execute(
                sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
                """
            )
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v999_future_migration"]
            )
        }

        XCTAssertThrowsError(try CatalogDatabase.open(at: url)) { error in
            guard case let CatalogDatabaseError.futureSchema(applied, unknown) = error else {
                return XCTFail("Expected futureSchema, got \(error)")
            }
            XCTAssertEqual(applied, ["v999_future_migration"])
            XCTAssertEqual(unknown, ["v999_future_migration"])
        }

        try seedPool.read { db in
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            XCTAssertEqual(applied, ["v999_future_migration"])
            let tables = try DatabaseTestSupport.tableNames(db)
            XCTAssertEqual(tables, [], "v001 must not be applied when future migration is present")
        }
    }

    func testFailedMigrationRollsBackDDLChanges() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("test_fail_after_ddl") { db in
            try db.execute(sql: "CREATE TABLE test_fail_marker (id INTEGER PRIMARY KEY) STRICT")
            throw TestMigrationFailure.intentional
        }

        XCTAssertThrowsError(try migrator.migrate(pool))

        try pool.read { db in
            let tables = try DatabaseTestSupport.tableNames(db)
            XCTAssertFalse(tables.contains("test_fail_marker"))
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertFalse(applied.contains("test_fail_after_ddl"))
        }
    }

    func testSchemaDumpEvidence() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        let dump = try database.pool.read { db in
            try DatabaseTestSupport.schemaDump(db)
        }

        XCTAssertTrue(dump.contains("applied_migrations=v001_create_catalog_core, v002_add_stage_1_catalog_query_support"))
        XCTAssertTrue(dump.contains("journal_mode=wal"))
        XCTAssertTrue(dump.contains("foreign_keys=1"))
        XCTAssertTrue(dump.contains("quick_check=ok"))
        XCTAssertTrue(dump.contains("table:source"))
        XCTAssertTrue(dump.contains("CREATE TABLE source"))
        XCTAssertTrue(dump.contains("index:asset_current_file_locator_uq"))
        XCTAssertTrue(dump.contains("<null>"))
    }
}

private enum TestMigrationFailure: Error {
    case intentional
}

private final class CatalogMigrationFootprintMonitor: @unchecked Sendable {
    struct Usage {
        var logicalBytes: UInt64
        var allocatedBytes: UInt64
    }

    struct Result {
        var logicalBytes: UInt64
        var allocatedBytes: UInt64
        var minimumAvailableBytes: UInt64?
        var minimumFileSystemFreeBytes: UInt64?
        var sampleCount: Int
    }

    private let rootURL: URL
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var shouldStop = false
    private var result = Result(
        logicalBytes: 0,
        allocatedBytes: 0,
        minimumAvailableBytes: nil,
        minimumFileSystemFreeBytes: nil,
        sampleCount: 0
    )

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while true {
                recordSample()
                lock.lock()
                let stop = shouldStop
                lock.unlock()
                if stop { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func stop() -> Result {
        lock.lock()
        shouldStop = true
        lock.unlock()
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    static func measureUsage(at rootURL: URL) -> Usage {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys
        ) else {
            return Usage(logicalBytes: 0, allocatedBytes: 0)
        }

        var usage = Usage(logicalBytes: 0, allocatedBytes: 0)
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }
            usage.logicalBytes += UInt64(max(values.fileSize ?? 0, 0))
            usage.allocatedBytes += UInt64(max(values.totalFileAllocatedSize ?? 0, 0))
        }
        return usage
    }

    static func fileSystemFreeBytes(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let bytes = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return bytes.uint64Value
    }

    private func recordSample() {
        let usage = Self.measureUsage(at: rootURL)
        let available: UInt64?
        do {
            available = try FoundationCatalogCapacityProvider().availableBytes(for: rootURL)
        } catch {
            available = nil
        }
        let fileSystemFree = Self.fileSystemFreeBytes(at: rootURL)

        lock.lock()
        defer { lock.unlock() }
        result.logicalBytes = max(result.logicalBytes, usage.logicalBytes)
        result.allocatedBytes = max(result.allocatedBytes, usage.allocatedBytes)
        if let available {
            result.minimumAvailableBytes = min(result.minimumAvailableBytes ?? available, available)
        }
        if let fileSystemFree {
            result.minimumFileSystemFreeBytes = min(
                result.minimumFileSystemFreeBytes ?? fileSystemFree,
                fileSystemFree
            )
        }
        result.sampleCount += 1
    }
}
