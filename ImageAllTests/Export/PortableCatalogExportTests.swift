import Foundation
import GRDB
import XCTest
@testable import ImageAll

final class PortableCatalogExportTests: XCTestCase {
    func testExportsStableFolderAndPhotosFactsWithVerifiedManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-PortableExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("catalog.sqlite")
        let exportParent = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)
        let database = try CatalogDatabase.open(at: databaseURL)
        try insertPortableFacts(into: database)

        let result = try PortableCatalogExporter(database: database).export(
            PortableCatalogExportRequest(
                parentDirectoryURL: exportParent,
                bundleName: "ImageAll-Export-20260717-010203Z",
                createdAtMs: 1_752_695_723_000,
                appVersion: "1.0-test"
            )
        )

        XCTAssertEqual(result.totalRecordCount, 12)
        XCTAssertEqual(result.bundleURL.lastPathComponent, "ImageAll-Export-20260717-010203Z")

        let manifestData = try Data(contentsOf: result.bundleURL.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(PortableExportManifest.self, from: manifestData)
        XCTAssertEqual(manifest.format, "imageall-portable-export")
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.createdAtMs, 1_752_695_723_000)
        XCTAssertEqual(manifest.appVersion, "1.0-test")
        XCTAssertEqual(manifest.appliedMigrations, CatalogMigrationID.knownOrdered)

        let expectedCounts = [
            "assets.jsonl": 2,
            "decisions.jsonl": 2,
            "file_fingerprints.jsonl": 1,
            "model_revisions.jsonl": 1,
            "model_samples.jsonl": 2,
            "sources.jsonl": 2,
            "tag_models.jsonl": 1,
            "tags.jsonl": 1,
        ]
        XCTAssertEqual(manifest.files.map(\.filename), expectedCounts.keys.sorted())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.filename, $0.recordCount) }), expectedCounts)

        for file in manifest.files {
            let fileURL = result.bundleURL.appendingPathComponent(file.filename)
            let data = try Data(contentsOf: fileURL)
            XCTAssertEqual(file.byteCount, Int64(data.count), file.filename)
            XCTAssertEqual(file.sha256, PortableExportHashing.sha256Hex(data), file.filename)
            XCTAssertTrue(data.last == 0x0a, file.filename)
        }

        let sources = try jsonLines(at: result.bundleURL.appendingPathComponent("sources.jsonl"))
        XCTAssertEqual(sources.map { $0["id"] as? String }, [
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002",
        ])
        let assets = try jsonLines(at: result.bundleURL.appendingPathComponent("assets.jsonl"))
        XCTAssertTrue(assets[0]["photos_local_identifier"] is NSNull)
        XCTAssertTrue(assets[1]["relative_path"] is NSNull)

        let exportedText = try (["manifest.json"] + manifest.files.map(\.filename))
            .map { try String(contentsOf: result.bundleURL.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        for excludedSecret in [
            "bookmark-secret", "sync-secret", "resource-secret",
            "positive.fprint", "negative.fprint",
        ] {
            XCTAssertFalse(exportedText.contains(excludedSecret), excludedSecret)
        }
    }

    func testScaleExportConfigurationAcceptsOnlySupportedCounts() throws {
        XCTAssertEqual(try CatalogQueryTestSupport.scaleExportAssetCount(environmentValue: nil), 100_000)
        XCTAssertEqual(try CatalogQueryTestSupport.scaleExportAssetCount(environmentValue: "100000"), 100_000)
        XCTAssertEqual(try CatalogQueryTestSupport.scaleExportAssetCount(environmentValue: "1000000"), 1_000_000)
        XCTAssertThrowsError(
            try CatalogQueryTestSupport.scaleExportAssetCount(environmentValue: "10000")
        ) { error in
            XCTAssertEqual(
                error as? CatalogQueryTestSupport.ScaleFixtureError,
                .unsupportedExportAssetCount("10000")
            )
        }
    }

    func testExportsConfiguredSyntheticAssetsWithVerifiedManifest() throws {
        let assetCount = try CatalogQueryTestSupport.scaleExportAssetCount(
            environmentValue: ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_EXPORT_ASSET_COUNT"]
        )
        let databaseURL = try makeTempDatabaseURL()
        let exportParent = databaseURL.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)
        let fixture = try CatalogQueryTestSupport.openScaleDatabase(at: databaseURL, assetCount: assetCount)

        let startedAt = ContinuousClock.now
        let result = try PortableCatalogExporter(database: fixture.database).export(
            PortableCatalogExportRequest(
                parentDirectoryURL: exportParent,
                bundleName: "ImageAll-Export-Scale-\(assetCount)",
                createdAtMs: 1_752_700_000_000,
                appVersion: "scale-test"
            )
        )
        let elapsed = ContinuousClock.now - startedAt

        let manifestData = try Data(contentsOf: result.bundleURL.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(PortableExportManifest.self, from: manifestData)
        let counts = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.filename, $0.recordCount) })
        XCTAssertEqual(counts["assets.jsonl"], assetCount)
        XCTAssertEqual(counts["decisions.jsonl"], CatalogQueryTestSupport.scaleDecisionCount(assetCount: assetCount))
        XCTAssertEqual(result.totalRecordCount, CatalogQueryTestSupport.scalePortableRecordCount(assetCount: assetCount))
        XCTAssertTrue(manifest.files.allSatisfy { $0.byteCount >= 0 && $0.sha256.count == 64 })
        let threshold: Duration = assetCount == 100_000 ? .seconds(10) : .seconds(90)
        XCTAssertLessThan(elapsed, threshold)

        let byteCount = manifest.files.reduce(Int64(0)) { $0 + $1.byteCount }
        let attachment = XCTAttachment(
            string: "assets=\(assetCount) export_seconds=\(elapsed) export_bytes=\(byteCount)"
        )
        attachment.name = "ImageAll \(assetCount) synthetic export baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPublicationFailureRemovesTemporaryBundleAndPublishesNothing() throws {
        struct PublicationFailure: PortableExportFaultInjecting {
            func beforePublication() throws {
                throw PortableCatalogExportError.publicationFailed
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-PortableExportFault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let exportParent = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try PortableCatalogExporter(database: database).export(
                PortableCatalogExportRequest(
                    parentDirectoryURL: exportParent,
                    bundleName: "ImageAll-Export-20260717-010203Z",
                    createdAtMs: 1_752_695_723_000,
                    appVersion: "1.0-test"
                ),
                faultInjector: PublicationFailure()
            )
        ) { error in
            XCTAssertEqual(error as? PortableCatalogExportError, .publicationFailed)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportParent.path), [])
    }

    func testDataFileWriteFailureRemovesTemporaryBundleAndPublishesNothing() throws {
        struct DataFileWriteFailure: PortableExportFaultInjecting {
            func beforeWritingFile(filename: String) throws {
                if filename == "assets.jsonl" {
                    throw PortableCatalogExportError.writeFailed
                }
            }

            func beforePublication() throws {}
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-PortableExportWriteFault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let exportParent = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try PortableCatalogExporter(database: database).export(
                PortableCatalogExportRequest(
                    parentDirectoryURL: exportParent,
                    bundleName: "ImageAll-Export-20260717-010204Z",
                    createdAtMs: 1_752_695_724_000,
                    appVersion: "1.0-test"
                ),
                faultInjector: DataFileWriteFailure()
            )
        ) { error in
            XCTAssertEqual(error as? PortableCatalogExportError, .writeFailed)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportParent.path), [])
    }

    private func jsonLines(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0a).map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line))
            return try XCTUnwrap(object as? [String: Any])
        }
    }

    private func insertPortableFacts(into database: CatalogDatabase) throws {
        let folderSource = "00000000-0000-0000-0000-000000000001"
        let photosSource = "00000000-0000-0000-0000-000000000002"
        let folderAsset = "00000000-0000-0000-0000-000000000011"
        let photosAsset = "00000000-0000-0000-0000-000000000012"
        let tagID = "00000000-0000-0000-0000-000000000021"
        let bookmark = Data("bookmark-secret".utf8)
        let syncCursor = Data("sync-secret".utf8)

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, sync_cursor, state, created_at_ms, updated_at_ms
                ) VALUES
                    (?, 'folder', 'Folder Source', ?, ?, 'active', 10, 11),
                    (?, 'photos', 'Apple Photos', NULL, ?, 'active', 12, 13)
                """,
                arguments: [folderSource, bookmark, syncCursor, photosSource, syncCursor]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, file_name, media_type, width, height,
                    media_created_at_ms, media_modified_at_ms, content_revision,
                    last_seen_generation, availability, record_created_at_ms, record_updated_at_ms
                ) VALUES
                    (?, ?, 'file', 'album/photo.jpg', NULL, 'current', 'photo.jpg',
                     'public.jpeg', 100, 80, 20, 21, 1, 0, 'available', 30, 31),
                    (?, ?, 'photos', NULL, 'photos-local-identifier', 'current', NULL,
                     'public.heic', 200, 160, 22, 23, 2, 0, 'available', 32, 33)
                """,
                arguments: [folderAsset, folderSource, photosAsset, photosSource]
            )
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns, resource_id, sha256)
                VALUES (?, 1234, 5678, ?, ?)
                """,
                arguments: [folderAsset, Data("resource-secret".utf8), Data(repeating: 0xab, count: 32)]
            )
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Favorite', 'favorite', 'active', 40, 41)
                """,
                arguments: [tagID]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', 50), (?, ?, 'rejected', 51)
                """,
                arguments: [folderAsset, tagID, photosAsset, tagID]
            )
            for (assetID, cacheKey, hashByte) in [
                (folderAsset, "objects/aa/positive.fprint", UInt8(0x44)),
                (photosAsset, "objects/bb/negative.fprint", UInt8(0x55)),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO feature (
                        asset_id, provider, request_revision, preprocessing_revision,
                        content_revision, element_type, element_count, byte_count,
                        vector_sha256, cache_key, created_at_ms
                    ) VALUES (?, 'vision-feature-print', 2, 1,
                        ?, 'float32', 2, 8, ?, ?, 60)
                    """,
                    arguments: [assetID, assetID == folderAsset ? 1 : 2, Data(repeating: hashByte, count: 32), cacheKey]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO tag_model_revision (
                    tag_id, revision, provider, request_revision, preprocessing_revision,
                    threshold, positive_count, negative_count, neighbor_count,
                    sample_budget_per_role, created_at_ms
                ) VALUES (?, 1, 'vision-feature-print', 2, 1, 0.25, 1, 1, 1, 1, 70)
                """,
                arguments: [tagID]
            )
            try db.execute(
                sql: """
                INSERT INTO tag_model_sample (
                    tag_id, model_revision, asset_id, content_revision, role, rank,
                    provider, request_revision, preprocessing_revision
                ) VALUES
                    (?, 1, ?, 1, 'positive', 0, 'vision-feature-print', 2, 1),
                    (?, 1, ?, 2, 'negative', 0, 'vision-feature-print', 2, 1)
                """,
                arguments: [tagID, folderAsset, tagID, photosAsset]
            )
            try db.execute(
                sql: "INSERT INTO tag_model (tag_id, current_revision, updated_at_ms) VALUES (?, 1, 80)",
                arguments: [tagID]
            )
        }
    }
}
