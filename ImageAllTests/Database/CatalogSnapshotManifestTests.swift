import XCTest
@testable import ImageAll

final class CatalogSnapshotManifestTests: XCTestCase {
    func testManifestEncodeDecodeRoundTripPreservesSemantics() throws {
        let snapshotID = UUID().uuidString.lowercased()
        let manifest = SnapshotTestSupport.makeManifest(snapshotID: snapshotID)

        let data = try CatalogSnapshotManifestCodec.encode(manifest)
        let decoded = try CatalogSnapshotManifestCodec.decode(from: data)

        XCTAssertEqual(decoded, manifest)
        try CatalogSnapshotManifestValidator.validate(decoded, expectedSnapshotID: snapshotID)
    }

    func testManifestDecodeIgnoresUnknownExtraFields() throws {
        let snapshotID = UUID().uuidString.lowercased()
        let json = """
        {
          "format_version": 1,
          "snapshot_id": "\(snapshotID)",
          "created_at_ms": 100,
          "app_version": "test",
          "applied_migrations": ["v001_create_catalog_core"],
          "database_filename": "ImageAll.sqlite",
          "database_bytes": 10,
          "database_sha256": "\(String(repeating: "b", count: 64))",
          "unexpected_field": true
        }
        """
        let decoded = try CatalogSnapshotManifestCodec.decode(from: Data(json.utf8))
        try CatalogSnapshotManifestValidator.validate(decoded, expectedSnapshotID: snapshotID)
    }

    func testUnsupportedFormatVersionIsRejected() {
        let manifest = CatalogSnapshotManifest(
            formatVersion: 2,
            snapshotID: UUID().uuidString.lowercased(),
            createdAtMs: 1,
            appVersion: "test",
            appliedMigrations: [],
            databaseFilename: CatalogSnapshotConstants.databaseFilename,
            databaseBytes: 1,
            databaseSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertThrowsError(try CatalogSnapshotManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .unsupportedManifestFormat(version: 2))
        }
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try CatalogSnapshotManifestCodec.decode(from: Data("{".utf8)))
    }

    func testNonCanonicalUUIDIsRejected() {
        let manifest = SnapshotTestSupport.makeManifest(snapshotID: "NOT-A-UUID")
        XCTAssertThrowsError(try CatalogSnapshotManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .invalidSnapshotID)
        }
    }

    func testUppercaseChecksumIsRejected() {
        let manifest = SnapshotTestSupport.makeManifest(
            snapshotID: UUID().uuidString.lowercased(),
            databaseSHA256: String(repeating: "A", count: 64)
        )
        XCTAssertThrowsError(try CatalogSnapshotManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .invalidDatabaseChecksum)
        }
    }

    func testDuplicateMigrationIsRejected() {
        XCTAssertThrowsError(
            try CatalogSnapshotManifestValidator.validateMigrationPrefix([
                CatalogMigrationID.v001CreateCatalogCore,
                CatalogMigrationID.v001CreateCatalogCore,
            ])
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .invalidMigrationHistory)
        }
    }

    func testUnknownMigrationPrefixIsRejected() {
        XCTAssertThrowsError(
            try CatalogSnapshotManifestValidator.validateMigrationPrefix(["v999_unknown"])
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .invalidMigrationHistory)
        }
    }
}

final class CatalogSnapshotDiscoveryTests: XCTestCase {
    func testQualifiedFinalDirectoryIsListedWithStableSort() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)

        let olderID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let newerID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        _ = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: olderID,
            sourceDatabase: database,
            createdAtMs: 100
        )
        _ = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: newerID,
            sourceDatabase: database,
            createdAtMs: 200
        )

        let listed = try CatalogSnapshotCatalog.discoverPublishedSnapshots(in: backups)
        XCTAssertEqual(listed.map(\.snapshotID), [newerID.uuidString.lowercased(), olderID.uuidString.lowercased()])
    }

    func testTmpMissingManifestSidecarAndBadHashDirectoriesAreExcluded() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)

        let tmpID = UUID().uuidString.lowercased()
        let tmpDir = backups.appendingPathComponent("\(tmpID).tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let sidecarID = UUID().uuidString.lowercased()
        let sidecarDir = backups.appendingPathComponent(sidecarID, isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        let sidecarDB = sidecarDir.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        try Data([0x01]).write(to: sidecarDB)
        try Data("{}".utf8).write(to: sidecarDir.appendingPathComponent(CatalogSnapshotConstants.manifestFilename))
        try Data([0x02]).write(to: URL(fileURLWithPath: sidecarDB.path + "-wal"))

        let badHashID = UUID().uuidString.lowercased()
        let badHashDir = backups.appendingPathComponent(badHashID, isDirectory: true)
        try FileManager.default.createDirectory(at: badHashDir, withIntermediateDirectories: true)
        let badDB = badHashDir.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        try Data([0x03]).write(to: badDB)
        let badManifest = SnapshotTestSupport.makeManifest(
            snapshotID: badHashID,
            databaseBytes: Int64(try CatalogSnapshotHashing.fileSize(of: badDB)),
            databaseSHA256: String(repeating: "c", count: 64)
        )
        try CatalogSnapshotManifestCodec.encode(badManifest).write(
            to: badHashDir.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)
        )

        XCTAssertTrue(try CatalogSnapshotCatalog.discoverPublishedSnapshots(in: backups).isEmpty)
    }

    func testSymlinkDatabaseIsRejectedFromDiscovery() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: UUID(),
            sourceDatabase: database
        )

        let symlinkID = UUID().uuidString.lowercased()
        let symlinkDir = backups.appendingPathComponent(symlinkID, isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
        let realDB = descriptor.directoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        try FileManager.default.createSymbolicLink(
            at: symlinkDir.appendingPathComponent(CatalogSnapshotConstants.databaseFilename),
            withDestinationURL: realDB
        )
        try CatalogSnapshotManifestCodec.encode(descriptor.manifest).write(
            to: symlinkDir.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)
        )

        let listed = try CatalogSnapshotCatalog.discoverPublishedSnapshots(in: backups)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].snapshotID, descriptor.snapshotID)
    }
}
