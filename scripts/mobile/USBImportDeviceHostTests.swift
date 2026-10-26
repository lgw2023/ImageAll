import CryptoKit
import Darwin
import Foundation
import GRDB
import Security
@testable import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

/// Interactive physical-device fixture. No production App composition root.
extension RemoteHTTPServerTests {
    @MainActor
    func testPhysicalUSBImportTask() async throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let configRoot = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_DEVICE_CONFIG"]))
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configRoot.appendingPathComponent("run-config.json"))) as! [String: Any]
        let hostID = try XCTUnwrap(UUID(uuidString: config["hostID"] as! String))
        let port = UInt16(config["port"] as! Int)
        let pin = config["fingerprint"] as! String
        let p12 = try Data(contentsOf: configRoot.appendingPathComponent("synthetic.p12"))
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: "synthetic-only",
                       kSecImportToMemoryOnly as String: true] as [String: Any]
        XCTAssertEqual(SecPKCS12Import(p12 as CFData, options as CFDictionary, &imported), errSecSuccess)
        let entries = try XCTUnwrap(imported as? [[String: Any]])
        let identity = entries[0][kSecImportItemIdentity as String] as! SecIdentity
        ImageAllMigrationArchiveDiagnostics.start()
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        PhoneArchiveImportProcessHolder.attach(database: database)
        let pairing = RemotePairingStore(hostContext: .init(hostID: hostID,
            hostDisplayName: "ImageAll USB task acceptance", listenPort: Int(port), usesTLS: true,
            certificateFingerprintSHA256: pin), storageURL: root.appendingPathComponent("pairing.json"),
            legacyDebugToken: nil)
        let sync = try RemoteLocalLibrarySyncStore(hostID: hostID, storageURL: root.appendingPathComponent("sync.json"))
        for name in ["receiver", "archive"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let transfer = try ImageAllMigrationTransferStore(root: root.appendingPathComponent("receiver"), recoveryPolicy: .receiveProgress)
        if config["journalEncodingCache"] as? Bool == false {
            await transfer.disableJournalEncodingCacheForDiagnostics()
        }
        let cleanupLog = USBImportCleanupLog(root: root)
        let handoffScenario = config["scenario"] as? String == "mac-handoff"
        let host = makeServer(port: port, pairingStore: pairing, localLibrarySyncStore: sync,
            migrationTransferStore: transfer, migrationHandoffAccepted: handoffScenario ? {} : nil,
            automaticCleanupProvider: { query, nonce, deviceID in
                do {
                    let result = try await PhoneImportTaskActivity.automaticCleanup(query, nonce: nonce,
                        hostID: hostID, deviceID: deviceID, receiver: transfer)
                    await cleanupLog.record(nonce: nonce, success: true)
                    return result
                } catch {
                    await cleanupLog.record(nonce: nonce, success: false)
                    throw error
                }
            }, exportCleanupReceiptProvider: { query, nonce, deviceID in
                try await PhoneImportTaskActivity.exportCleanupReceipt(query, nonce: nonce, hostID: hostID, deviceID: deviceID)
            }, importTaskStatusProvider: { try await PhoneImportTaskActivity.status($0) },
            hostID: hostID, secIdentity: identity, certificateFingerprint: pin).0
        try await host.start()
        var tunnel: ImageAllUSBMacTunnel?
        var tunnelTask: Task<Void, Never>?
        defer { tunnel?.stop(); tunnelTask?.cancel(); Task { await host.stop() } }
        var events: [[String: Any]] = []
        var lastCommand = ""
        var lastCount = -1
        var activeReader: ImageAllMigrationStagingLease?
        var published: UUID?
        var physicalAbsent = false
        var connectionCount = 0
        var handedOff = false
        var detachedStarted = false
        func event(_ name: String, _ details: [String: Any] = [:]) throws {
            var row = details
            row["event"] = name; row["atMs"] = Int64(Date().timeIntervalSince1970 * 1000)
            events.append(row)
            try JSONEncoder().encode(ImageAllMigrationArchiveDiagnostics.snapshot())
                .write(to: root.appendingPathComponent("verification-timing.json"), options: .atomic)
            try JSONSerialization.data(withJSONObject: ["events": events, "publishedSourceID": published?.uuidString ?? "",
                "physicalAbsent": physicalAbsent, "connectionCount": connectionCount],
                options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("host-report.json"), options: .atomic)
        }
        if config["restartPublished"] as? Bool == true {
            let publisher = PhoneNativeLibraryPublisher(database: database)
            XCTAssertTrue(try publisher.unpublishedBatches().isEmpty)
            let batch = try XCTUnwrap(VerifiedPhoneArchiveImporter(database: database).importedBatches().first)
            published = try publisher.publish(migrationID: batch.id, archiveRoot: URL(fileURLWithPath: batch.archivePath))
            let reads = ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count
            XCTAssertEqual(reads, 0, "completed Host restart must not fully read original resources")
            try event("completedRestart", ["fullReads": reads, "migrationID": batch.id.uuidString])
        }
        try event("ready")
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline {
            let devices = try ImageAllUSBMux.devices()
            if devices.count != lastCount {
                if devices.isEmpty && connectionCount > 0 { physicalAbsent = true }
                lastCount = devices.count
                try event("physicalUSBInventory", ["count": devices.count])
            }
            if handoffScenario {
                let jobs = try await transfer.hostJobs()
                if !jobs.isEmpty && !handedOff {
                    handedOff = true
                    try event("handoffAccepted", ["migrationID": jobs[0].id.uuidString])
                }
                // Test-only barrier: observe a real cable removal BEFORE allowing
                // the production worker to begin. Shipping handoff starts immediately.
                if handedOff && physicalAbsent && !detachedStarted {
                    detachedStarted = true
                    tunnel?.stop(); tunnelTask?.cancel(); tunnel = nil
                    await host.stop()
                    PhoneHostImportProcess.wake(receiver: transfer, target: root.appendingPathComponent("receiver"))
                    try event("detachedProcessingStarted")
                }
                if jobs.first?.state?.phase == .complete && published == nil {
                    published = try PhoneNativeLibraryPublisher(database: database).publish(migrationID: jobs[0].id,
                        archiveRoot: root.appendingPathComponent("receiver/ImageAll-Archive-\(jobs[0].id.uuidString.lowercased())"))
                    try event("detachedComplete", ["migrationID": jobs[0].id.uuidString])
                }
                if jobs.first?.state?.phase == .needsAttention {
                    XCTFail("Mac detached worker failed: \(jobs[0].state?.error ?? "unknown")")
                    return
                }
            }
            let commandURL = root.appendingPathComponent("command.txt")
            let command = (try? String(contentsOf: commandURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            if !command.isEmpty && command != lastCommand {
                lastCommand = command
                if command.hasPrefix("connect") {
                    tunnel?.stop(); tunnelTask?.cancel()
                    XCTAssertEqual(devices.count, 1)
                    let device = try XCTUnwrap(devices.first)
                    let offer = await pairing.issueOffer()
                    let next = try ImageAllUSBMacTunnel(device: device, offer: offer)
                    tunnel = next; connectionCount += 1
                    tunnelTask = Task.detached {
                        do {
                            try next.run(onReady: {
                                try? Data("ready".utf8).write(to: root.appendingPathComponent("tunnel-ready.txt"), options: .atomic)
                            })
                        } catch {
                            try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("tunnel-last-error.txt"), options: .atomic)
                        }
                    }
                    try event("connect", ["attempt": connectionCount])
                } else if command == "publish" {
                    let archives = try await transfer.sealedArchives()
                    XCTAssertEqual(archives.count, 1)
                    let archive = try XCTUnwrap(archives.first)
                    if config["scenario"] as? String == "automatic-cleanup" { activeReader = try .readingPackage(archive.packageURL) }
                    PhoneImportTaskActivity.set(.verifying, for: archive.id)
                    try event("verifying")
                    try await Task.sleep(for: .seconds(5))
                    let result = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                        try VerifiedPhoneArchiveImporter(database: database).importArchive(
                            from: archive.packageURL, to: root.appendingPathComponent("archive"))
                    }
                    PhoneImportTaskActivity.set(.publishing, for: archive.id)
                    try event("publishing")
                    try await Task.sleep(for: .seconds(5))
                    published = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                        try PhoneNativeLibraryPublisher(database: database).publish(
                            importReceipt: result)
                    }
                    PhoneImportTaskActivity.set(nil, for: archive.id)
                    try event("browsable", ["migrationID": archive.id.uuidString])
                } else if command == "release-reader" {
                    XCTAssertNotNil(activeReader); activeReader = nil
                    try event("readerReleased")
                } else if command == "disconnect" {
                    tunnel?.stop(); tunnelTask?.cancel(); tunnel = nil
                    try event("disconnected")
                } else if command == "audit-completed" {
                    let batch = try XCTUnwrap(VerifiedPhoneArchiveImporter(database: database).importedBatches().first)
                    let before = ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count
                    let report = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                        try VerifiedPhoneArchiveImporter(database: database).auditImportedArchive(
                            migrationID: batch.id, archiveRoot: URL(fileURLWithPath: batch.archivePath))
                    }
                    let reads = ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count - before
                    XCTAssertEqual(reads, 2)
                    XCTAssertEqual(report.itemCount, 2889)
                    try event("explicitFullAuditPassed", ["fullReads": reads, "items": report.itemCount])
                } else if command == "finish" {
                    XCTAssertNotNil(published)
                    if !["cold-resume", "cleanup", "automatic-cleanup"].contains(config["scenario"] as? String ?? "") {
                        XCTAssertTrue(physicalAbsent, "must observe actual usbmux USB device removal")
                    }
                    XCTAssertGreaterThanOrEqual(connectionCount, config["restartPublished"] as? Bool == true || ["cleanup", "automatic-cleanup", "mac-handoff"].contains(config["scenario"] as? String ?? "") ? 1 : 3)
                    let count = try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM phone_library_publication") }
                    XCTAssertEqual(count, 1)
                    try event("finished", ["publishedCount": count ?? -1])
                    try Data("physical USB scenario host finished".utf8).write(to: root.appendingPathComponent("scenario-result.json"))
                    return
                } else if command == "seed-cold-resume" {
                    // Only this new, explicitly synthetic config can install a prior
                    // receiver fixture. The real receiver performs cold repair on use.
                    XCTAssertEqual(config["scenario"] as? String, "cold-resume")
                    let seed = configRoot.appendingPathComponent("Seed/receiver")
                    let identity = try JSONSerialization.jsonObject(with: Data(contentsOf:
                        configRoot.appendingPathComponent("phone-connected.json"))) as! [String: Any]
                    let deviceID = try XCTUnwrap(identity["authenticatedDeviceID"] as? String)
                    XCTAssertNotNil(UUID(uuidString: deviceID))
                    for directory in try FileManager.default.contentsOfDirectory(at: seed, includingPropertiesForKeys: nil) {
                        let destination = root.appendingPathComponent("receiver").appendingPathComponent(directory.lastPathComponent)
                        try FileManager.default.copyItem(at: directory, to: destination)
                        let sessionURL = destination.appendingPathComponent("session.json")
                        var session = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as! [String: Any]
                        session["deviceID"] = deviceID
                        var receipts = session["verifiedResources"] as! [String: [String: Any]]
                        for key in Array(receipts.keys) { receipts[key]!["deviceID"] = deviceID }
                        session["verifiedResources"] = receipts
                        try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
                            .write(to: sessionURL, options: .atomic)
                    }
                    if config["stagedRecovery"] as? Bool == true {
                        // A separate store enrolls this legacy synthetic seed, as
                        // normal writes would bind objects before a later crash.
                        // The HTTP receiver above remains completely unloaded.
                        let started = ProcessInfo.processInfo.systemUptime
                        let enrollment = try ImageAllMigrationTransferStore(root: root.appendingPathComponent("receiver"))
                        let scenario = try JSONSerialization.jsonObject(with: Data(contentsOf: configRoot.appendingPathComponent("Seed/scenario.json"))) as! [String: Any]
                        let migration = try XCTUnwrap(UUID(uuidString: scenario["migrationID"] as! String))
                        _ = try await enrollment.begin(migrationID: migration, authenticatedDeviceID: UUID(uuidString: deviceID)!)
                        // Recreate the same crash tail after enrollment. It must
                        // be truncated by the measured cold receiver, not here.
                        let resources = scenario["resources"] as! [[String: Any]]
                        let path = resources.last!["relativePath"] as! String
                        let file = root.appendingPathComponent("receiver/.imageall-transfer-\(migration.uuidString.lowercased())/package/\(path)")
                        let handle = try FileHandle(forWritingTo: file)
                        try handle.seekToEnd(); try handle.write(contentsOf: Data("uncommitted-tail".utf8))
                        try handle.synchronize(); try handle.close()
                        try event("stagedCheckpointPrepared", ["legacyEnrollmentSeconds": ProcessInfo.processInfo.systemUptime - started,
                            "httpReceiverStillCold": true, "crashTailBytes": 16])
                    }
                    try event("coldFixtureSeeded")
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("interactive acceptance timed out")
    }
}


extension RemoteHTTPServerTests {
    @MainActor
    func testP3ImportProcessCrashBoundary() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let phase = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_IMPORT_CRASH_PHASE"])
        let incoming = root.appendingPathComponent("incoming"), target = root.appendingPathComponent("archive")
        if phase == "crash" {
            for url in [incoming.appendingPathComponent("resources"), target] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let bytes = Data(repeating: 37, count: 8192), id = UUID()
            let path = "resources/\(id.uuidString.lowercased()).bin"
            try bytes.write(to: incoming.appendingPathComponent(path))
            let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
            let resource = ImageAllMigrationResource(id: id, role: "original", version: 1,
                uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
                byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
                createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
            try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
        }
        let header = try ImageAllMigrationArchive.readVerifiedHeader(at: incoming).0
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        if phase == "crash" {
            _ = try importer.importArchive(from: incoming, to: target, beforeCatalogCommit: {
                try Data("final SHA passed; catalog transaction still uncommitted".utf8)
                    .write(to: root.appendingPathComponent("commit-window-ready"), options: .atomic)
                // The external bounded runner kills only this isolated test PID.
                raise(SIGSTOP)
                throw ImageAllMigrationArchiveError.publicationFailed
            })
            XCTFail("runner must kill the stopped transaction process")
        } else {
            XCTAssertEqual(phase, "recover")
            try database.pool.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_import"), "prepared")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 0)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 0)
            }
            let receipt = try importer.importArchive(from: incoming, to: target)
            let publisher = PhoneNativeLibraryPublisher(database: database)
            let source = try publisher.publish(migrationID: header.migrationID, archiveRoot: receipt.archiveURL)
            XCTAssertTrue(try importer.importArchive(from: incoming, to: target).replayed)
            XCTAssertEqual(try publisher.publish(migrationID: header.migrationID, archiveRoot: receipt.archiveURL), source)
            try database.pool.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 1)
            }
            try Data("crash recovery passed".utf8).write(to: root.appendingPathComponent("scenario-result.json"))
        }
    }

    @MainActor
    func testP3ImportReusesTargetVerificationAndPreservesAtomicity() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        for failure in ["success", "same-size", "truncated", "stale", "replace", "replace-root", "commit-interrupted", "commit-replace"] {
            let root = base.appendingPathComponent(failure)
            let incoming = root.appendingPathComponent("incoming")
            let target = root.appendingPathComponent("archive")
            for url in [incoming.appendingPathComponent("resources"), target] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let bytes = Data(repeating: 37, count: 8192), id = UUID()
            let path = "resources/\(id.uuidString.lowercased()).bin"
            try bytes.write(to: incoming.appendingPathComponent(path))
            let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
            let resource = ImageAllMigrationResource(id: id, role: "original", version: 1,
                uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
                byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
                createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
            try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
            let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
            let importer = VerifiedPhoneArchiveImporter(database: database)

            let final = target.appendingPathComponent("ImageAll-Archive-\(header.migrationID.uuidString.lowercased())", isDirectory: true)
            let file = final.appendingPathComponent(path)
            ImageAllMigrationArchiveDiagnostics.start()
            if failure == "success" {
                let receipt = try importer.importArchive(from: incoming, to: target)
                XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count, 3)
                XCTAssertEqual(receipt.archiveURL, final)
                XCTAssertTrue(try importer.importArchive(from: incoming, to: target).replayed)
                _ = try PhoneNativeLibraryPublisher(database: database).publish(migrationID: header.migrationID, archiveRoot: final)
            } else {
                XCTAssertThrowsError(try importer.importArchive(from: incoming, to: target,
                    beforeCatalogCommit: {
                        if failure == "commit-interrupted" { throw ImageAllMigrationArchiveError.publicationFailed }
                        if failure == "commit-replace" { try bytes.write(to: file, options: .atomic) }
                    }, afterPublication: {
                        if failure.hasPrefix("commit-") { return }
                        if failure == "replace" { try bytes.write(to: file, options: .atomic) }
                        else if failure == "replace-root" {
                            let moved = target.appendingPathComponent("replaced")
                            try FileManager.default.moveItem(at: final, to: moved)
                            try FileManager.default.copyItem(at: moved, to: final)
                        } else {
                            let handle = try FileHandle(forWritingTo: file)
                            if failure == "truncated" { try handle.truncate(atOffset: 1) }
                            else { try handle.write(contentsOf: Data(repeating: 90, count: bytes.count)) }
                            if failure == "stale" { try handle.seek(toOffset: 0); try handle.write(contentsOf: bytes) }
                            try handle.close()
                        }
                    }), failure)
                try database.pool.read { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 0, failure)
                    XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_import"), "prepared", failure)
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 0, failure)
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 0, failure)
                }
                // A fresh attempt must re-verify the surviving target and recover.
                try bytes.write(to: file, options: .atomic)
                ImageAllMigrationArchiveDiagnostics.start()
                _ = try importer.importArchive(from: incoming, to: target)
                XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count, 3, failure)
                _ = try PhoneNativeLibraryPublisher(database: database).publish(migrationID: header.migrationID, archiveRoot: final)
            }
            try database.pool.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 1, failure)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 1, failure)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 1, failure)
            }
        }
        try Data("P3 import checks finished".utf8).write(to: base.appendingPathComponent("scenario-result.json"))
    }

    @MainActor
    func testP3AuditUsesTwoFullReadsAndPreservesAtomicPublication() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let incoming = root.appendingPathComponent("incoming")
        let target = root.appendingPathComponent("archive")
        for path in [incoming.appendingPathComponent("resources"), target] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let bytes = Data(repeating: 37, count: 8192)
        let resourceID = UUID(), path = "resources/\(resourceID.uuidString.lowercased()).bin"
        try bytes.write(to: incoming.appendingPathComponent(path))
        let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
            byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
        try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        let receipt = try importer.importArchive(from: incoming, to: target)
        ImageAllMigrationArchiveDiagnostics.start()
        let publisher = PhoneNativeLibraryPublisher(database: database)
        let source = try publisher.publish(migrationID: header.migrationID, archiveRoot: receipt.archiveURL)
        XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count, 2)
        XCTAssertEqual(try publisher.publish(migrationID: header.migrationID, archiveRoot: receipt.archiveURL), source)
        try database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 1)
        }
        for failure in ["same-size", "truncated", "copy-interrupted", "replace-before-commit"] {
            let failureRoot = root.appendingPathComponent(failure)
            try FileManager.default.createDirectory(at: failureRoot, withIntermediateDirectories: false)
            let db = try CatalogDatabase.open(at: failureRoot.appendingPathComponent("catalog.sqlite"))
            let importer = VerifiedPhoneArchiveImporter(database: db)
            if failure == "copy-interrupted" {
                XCTAssertThrowsError(try importer.importArchive(from: incoming, to: failureRoot,
                    afterPublication: { throw ImageAllMigrationArchiveError.publicationFailed }))
                try db.pool.read { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 0)
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 0)
                }
                let recovered = try importer.importArchive(from: incoming, to: failureRoot)
                _ = try PhoneNativeLibraryPublisher(database: db).publish(migrationID: header.migrationID, archiveRoot: recovered.archiveURL)
            } else {
                let imported = try importer.importArchive(from: incoming, to: failureRoot)
                let file = imported.archiveURL.appendingPathComponent(path)
                if failure == "replace-before-commit" {
                    XCTAssertThrowsError(try PhoneNativeLibraryPublisher(database: db).publish(
                        migrationID: header.migrationID, archiveRoot: imported.archiveURL,
                        beforeCommit: { try bytes.write(to: file, options: .atomic) }))
                } else {
                    let handle = try FileHandle(forWritingTo: file)
                    if failure == "truncated" { try handle.truncate(atOffset: 1) }
                    else { try handle.write(contentsOf: Data(repeating: 90, count: bytes.count)) }
                    try handle.close()
                    XCTAssertThrowsError(try PhoneNativeLibraryPublisher(database: db).publish(migrationID: header.migrationID, archiveRoot: imported.archiveURL))
                }
                try db.pool.read { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 0)
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 0)
                }
            }
        }
        try Data("P3 checks finished".utf8).write(to: root.appendingPathComponent("scenario-result.json"))
    }
}

extension RemoteHTTPServerTests {
    @MainActor
    func testP3SyntheticStageTiming() throws {
        struct Scenario: Decodable {
            let migrationID: UUID
            let installID: UUID
            let sourceEpoch: UUID
            let resources: [ImageAllMigrationResource]
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let config = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_DEVICE_CONFIG"]))
        let seed = config.appendingPathComponent("Seed")
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: seed.appendingPathComponent("scenario.json")))
        let incoming = root.appendingPathComponent("incoming"), target = root.appendingPathComponent("archive")
        let package = seed.appendingPathComponent("receiver/.imageall-transfer-\(scenario.migrationID.uuidString.lowercased())/package")
        try FileManager.default.copyItem(at: package, to: incoming)
        let large = incoming.appendingPathComponent(scenario.resources.last!.relativePath!)
        try FileManager.default.removeItem(at: large)
        try FileManager.default.copyItem(at: seed.appendingPathComponent("source/pending.bin"), to: large)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let header = ImageAllMigrationHeader(migrationID: scenario.migrationID, sourceDeviceID: scenario.installID,
            sourceEpoch: scenario.sourceEpoch, scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: scenario.resources.count)
        let items = scenario.resources.enumerated().map { n, resource in
            ImageAllMigrationItem(mediaID: resource.id, sourceLocalIdentifier: "synthetic-\(n)", mediaKind: .image,
                createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1,
                tagDecisions: [], collections: [], resources: [resource])
        }
        try ImageAllMigrationArchive.write(header: header, items: items, to: incoming)
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        ImageAllMigrationArchiveDiagnostics.start()
        let started = ProcessInfo.processInfo.systemUptime
        let receipt = try VerifiedPhoneArchiveImporter(database: database).importArchive(from: incoming, to: target)
        let imported = ProcessInfo.processInfo.systemUptime
        let importSamples = ImageAllMigrationArchiveDiagnostics.snapshot().count
        _ = try PhoneNativeLibraryPublisher(database: database).publish(importReceipt: receipt)
        let ended = ProcessInfo.processInfo.systemUptime
        try JSONEncoder().encode(ImageAllMigrationArchiveDiagnostics.snapshot()).write(to: root.appendingPathComponent("verification-timing.json"))
        try JSONSerialization.data(withJSONObject: ["importSeconds": imported-started, "publishSeconds": ended-imported,
            "importSampleCount": importSamples, "transport": "local stages only, no USB timing"])
            .write(to: root.appendingPathComponent("scenario-result.json"))
    }
}

extension RemoteHTTPServerTests {
    @MainActor
    func testP3ImportToPublicationReusesFinalVerification() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let incoming = root.appendingPathComponent("incoming")
        let target = root.appendingPathComponent("archive")
        for path in [incoming.appendingPathComponent("resources"), target] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let bytes = Data(repeating: 37, count: 8192)
        let resourceID = UUID(), path = "resources/\(resourceID.uuidString.lowercased()).bin"
        try bytes.write(to: incoming.appendingPathComponent(path))
        let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
            byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
        try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        ImageAllMigrationArchiveDiagnostics.start()
        let receipt = try importer.importArchive(from: incoming, to: target)
        let publisher = PhoneNativeLibraryPublisher(database: database)
        let source = try publisher.publish(importReceipt: receipt)
        XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count, 4)
        XCTAssertEqual(try publisher.publish(importReceipt: receipt), source)
        try database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 1)
        }
        try database.pool.write { db in
            try db.execute(sql: "UPDATE asset_favorite_state SET desired_value = 1")
        }
        XCTAssertEqual(try publisher.publish(importReceipt: receipt), source)
        try database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT desired_value FROM asset_favorite_state"), 1)
        }
        for failure in ["same-size", "truncated", "stale", "replace", "replace-root",
                        "wrong-root", "wrong-migration", "commit-interrupted", "commit-replace", "facts-advance", "replayed"] {
            let failureRoot = root.appendingPathComponent(failure)
            try FileManager.default.createDirectory(at: failureRoot, withIntermediateDirectories: false)
            let db = try CatalogDatabase.open(at: failureRoot.appendingPathComponent("catalog.sqlite"))
            let importer = VerifiedPhoneArchiveImporter(database: db)
            let imported = try importer.importArchive(from: incoming, to: failureRoot)
            XCTAssertNotNil(imported.publicationVerification, failure)
            let file = imported.archiveURL.appendingPathComponent(path)
            let publisher = PhoneNativeLibraryPublisher(database: db)
            if failure == "replayed" {
                let replay = try importer.importArchive(from: incoming, to: failureRoot)
                XCTAssertTrue(replay.replayed)
                XCTAssertNil(replay.publicationVerification)
                ImageAllMigrationArchiveDiagnostics.start()
                _ = try publisher.publish(importReceipt: replay)
                XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count, 2)
                continue
            }
            if failure == "facts-advance" {
                let facts = ImageAllMigrationFactSnapshot(sourceDeviceID: header.sourceDeviceID,
                    sourceEpoch: header.sourceEpoch, scopeRevision: 1, snapshotSequence: 2, factWatermark: 2,
                    items: [.init(mediaID: item.mediaID, observedFavorite: true, favoriteTarget: true,
                                  tagDecisions: [], collections: [])])
                let factsURL = failureRoot.appendingPathComponent("new-facts.json")
                try ImageAllMigrationFacts.write(facts, to: factsURL)
                _ = try importer.reconcileFacts(from: factsURL, migrationID: imported.migrationID,
                                               archiveRoot: imported.archiveURL)
            }
            if failure == "replace-root" {
                let moved = failureRoot.appendingPathComponent("old-object")
                try FileManager.default.moveItem(at: imported.archiveURL, to: moved)
                try FileManager.default.copyItem(at: moved, to: imported.archiveURL)
            } else if failure == "replace" { try bytes.write(to: file, options: .atomic) }
            else if ["same-size", "truncated", "stale"].contains(failure) {
                let handle = try FileHandle(forWritingTo: file)
                if failure == "truncated" { try handle.truncate(atOffset: 1) }
                else { try handle.write(contentsOf: Data(repeating: 90, count: bytes.count)) }
                if failure == "stale" { try handle.seek(toOffset: 0); try handle.write(contentsOf: bytes) }
                try handle.close()
            }
            if failure == "wrong-root" || failure == "wrong-migration" {
                XCTAssertThrowsError(try publisher.publish(
                    migrationID: failure == "wrong-migration" ? UUID() : imported.migrationID,
                    archiveRoot: failure == "wrong-root" ? incoming : imported.archiveURL,
                    priorVerification: imported.publicationVerification), failure)
            } else {
                XCTAssertThrowsError(try publisher.publish(importReceipt: imported, beforeCommit: {
                    if failure == "commit-interrupted" { throw ImageAllMigrationArchiveError.publicationFailed }
                    if failure == "commit-replace" { try bytes.write(to: file, options: .atomic) }
                }), failure)
            }
            try db.pool.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 0, failure)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 0, failure)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source"), 0, failure)
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_import"), "catalogCommitted", failure)
            }
            try bytes.write(to: file, options: .atomic)
            ImageAllMigrationArchiveDiagnostics.start()
            let recovered = try publisher.publish(migrationID: imported.migrationID, archiveRoot: imported.archiveURL)
            XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count, 2)
            XCTAssertEqual(try publisher.publish(migrationID: imported.migrationID, archiveRoot: imported.archiveURL), recovered)
        }
        try Data("publication proof reuse passed".utf8).write(to: root.appendingPathComponent("scenario-result.json"))
    }
}

extension RemoteHTTPServerTests {
    @MainActor
    func testP3PublicationProcessCrashBoundary() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let phase = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_IMPORT_CRASH_PHASE"])
        let incoming = root.appendingPathComponent("incoming"), target = root.appendingPathComponent("archive")
        if phase == "crash" {
            for url in [incoming.appendingPathComponent("resources"), target] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let bytes = Data(repeating: 37, count: 8192), id = UUID()
            let path = "resources/\(id.uuidString.lowercased()).bin"
            try bytes.write(to: incoming.appendingPathComponent(path))
            let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
            let resource = ImageAllMigrationResource(id: id, role: "original", version: 1,
                uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
                byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
                createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
            try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
        }
        let header = try ImageAllMigrationArchive.readVerifiedHeader(at: incoming).0
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        let publisher = PhoneNativeLibraryPublisher(database: database)
        if phase == "crash" {
            let receipt = try importer.importArchive(from: incoming, to: target)
            _ = try publisher.publish(importReceipt: receipt, beforeCommit: {
                try Data("publication final SHA passed; projection transaction uncommitted".utf8)
                    .write(to: root.appendingPathComponent("commit-window-ready"), options: .atomic)
                raise(SIGSTOP)
                throw ImageAllMigrationArchiveError.publicationFailed
            })
            XCTFail("runner must kill the stopped publication process")
        } else {
            XCTAssertEqual(phase, "recover")
            try database.pool.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_import"), "catalogCommitted")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 0)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 0)
            }
            let batch = try XCTUnwrap(importer.importedBatches().first)
            let archive = target.appendingPathComponent("ImageAll-Archive-" + batch.id.uuidString.lowercased())
            ImageAllMigrationArchiveDiagnostics.start()
            let source = try publisher.publish(migrationID: header.migrationID, archiveRoot: archive)
            XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count, 2)
            XCTAssertEqual(try publisher.publish(migrationID: header.migrationID, archiveRoot: archive), source)
            try database.pool.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 1)
            }
            try Data("publication crash recovery passed".utf8).write(to: root.appendingPathComponent("scenario-result.json"))
        }
    }
    func testP4RetireCompletedUSBStaging() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        let batch = try XCTUnwrap(importer.importedBatches().first)
        let publisher = PhoneNativeLibraryPublisher(database: database)
        let source = try XCTUnwrap(publisher.sourceID(migrationID: batch.id))
        let result = try publisher.releaseStagingPayload(migrationID: batch.id, receiverRoot: root.appendingPathComponent("receiver"))
        XCTAssertEqual(result.logicalBytesReleased, 16 * 1024 * 1024)
        XCTAssertEqual(try publisher.sourceID(migrationID: batch.id), source)
        _ = try importer.auditImportedArchive(migrationID: batch.id, archiveRoot: URL(fileURLWithPath: batch.archivePath))
        try JSONSerialization.data(withJSONObject: ["migrationID": batch.id.uuidString, "sourceID": source.uuidString,
            "logicalBytesReleased": result.logicalBytesReleased, "resources": result.resourceCount])
            .write(to: root.appendingPathComponent("mac-retirement.json"))
    }

    func testP4PublishedStagingCleanup() async throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let incoming = root.appendingPathComponent("incoming", isDirectory: true), receiver = root.appendingPathComponent("receiver", isDirectory: true)
        for dir in [incoming.appendingPathComponent("resources"), receiver] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let bytes = Data(repeating: 61, count: 8192), resourceID = UUID(), migration = UUID(), device = UUID()
        let path = "resources/\(resourceID.uuidString.lowercased()).bin"
        try bytes.write(to: incoming.appendingPathComponent(path))
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
            byteCount: 8192, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1,
            tagDecisions: [], collections: [], resources: [resource])
        let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: device,
            sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
        let package: URL
        do {
            let store = try ImageAllMigrationTransferStore(root: receiver)
            _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
            for relative in ["manifest.jsonl", path] {
                let data = try Data(contentsOf: incoming.appendingPathComponent(relative))
                _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
                    relativePath: relative, offset: 0, bytes: data,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
            package = try await store.sealVerifiedArchive(migrationID: migration, authenticatedDeviceID: device).0
        }
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        let receipt = try importer.importArchive(from: package, to: receiver)
        let publisher = PhoneNativeLibraryPublisher(database: database)
        XCTAssertThrowsError(try publisher.releaseStagingPayload(migrationID: migration, receiverRoot: receiver))
        let source = try publisher.publish(importReceipt: receipt)
        let originalRelative = receipt.archiveURL.lastPathComponent + "/" + path
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE asset_favorite_state SET desired_value = 1")
            try db.execute(sql: "UPDATE asset SET relative_path = 'wrong-reference'")
        }
        XCTAssertThrowsError(try publisher.releaseStagingPayload(migrationID: migration, receiverRoot: receiver))
        try await database.pool.write { db in try db.execute(sql: "UPDATE asset SET relative_path = ?", arguments: [originalRelative]) }
        // Real filesystem write failure after persistent intent, before payload release.
        let staged = package.appendingPathComponent(path)
        XCTAssertEqual(chmod(staged.path, 0o400), 0)
        XCTAssertThrowsError(try publisher.releaseStagingPayload(migrationID: migration, receiverRoot: receiver))
        XCTAssertEqual(try publisher.sourceID(migrationID: migration), source)
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
        XCTAssertEqual(chmod(staged.path, 0o600), 0)
        let result = try publisher.releaseStagingPayload(migrationID: migration, receiverRoot: receiver)
        XCTAssertEqual(result.logicalBytesReleased, 8192)
        XCTAssertEqual(try Data(contentsOf: receipt.archiveURL.appendingPathComponent(path)), bytes)
        XCTAssertTrue(try publisher.releaseStagingPayload(migrationID: migration, receiverRoot: receiver).alreadyReleased)
        let restarted = PhoneNativeLibraryPublisher(database: try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite")))
        ImageAllMigrationArchiveDiagnostics.start()
        XCTAssertEqual(try restarted.publish(migrationID: migration, archiveRoot: receipt.archiveURL), source)
        XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count, 0)
        try await database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT desired_value FROM asset_favorite_state"), 1)
        }
        _ = try importer.auditImportedArchive(migrationID: migration, archiveRoot: receipt.archiveURL)
        try Data("published cleanup integration passed".utf8).write(to: root.appendingPathComponent("scenario-result.json"))
    }

    func testP3PreparedArchiveRestartDiscovery() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let incoming = root.appendingPathComponent("incoming"), target = root.appendingPathComponent("archive")
        for url in [incoming.appendingPathComponent("resources"), target] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let bytes = Data(repeating: 41, count: 8192), id = UUID()
        let path = "resources/\(id.uuidString.lowercased()).bin"
        try bytes.write(to: incoming.appendingPathComponent(path))
        let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        let resource = ImageAllMigrationResource(id: id, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
            byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
        try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
        let databaseURL = root.appendingPathComponent("catalog.sqlite")
        do {
            let database = try CatalogDatabase.open(at: databaseURL)
            XCTAssertThrowsError(try VerifiedPhoneArchiveImporter(database: database).importArchive(
                from: incoming, to: target, afterPublication: { throw ImageAllMigrationArchiveError.publicationFailed }))
            try database.pool.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_import"), "prepared")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 0)
            }
        }
        // The staging source is not needed once the durable target exists.
        try FileManager.default.removeItem(at: incoming)
        let restarted = try CatalogDatabase.open(at: databaseURL)
        let publisher = PhoneNativeLibraryPublisher(database: restarted)
        let batches = try publisher.unpublishedBatches()
        XCTAssertEqual(batches.map(\.id), [header.migrationID], "restart must discover the prepared durable target")
        guard let batch = batches.first else { return }
        let archive = URL(fileURLWithPath: batch.archivePath)
        let source = try publisher.publish(migrationID: batch.id, archiveRoot: archive)
        XCTAssertEqual(try publisher.publish(migrationID: batch.id, archiveRoot: archive), source)
        XCTAssertTrue(try publisher.unpublishedBatches().isEmpty)
        try restarted.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 1)
        }
        try Data("restart discovery passed".utf8).write(to: root.appendingPathComponent("scenario-result.json"))
    }

    func testP3RestartPersistentBoundaries() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let phase = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_IMPORT_CRASH_PHASE"])
        let boundary = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_RESTART_BOUNDARY"])
        let incoming = root.appendingPathComponent("incoming"), target = root.appendingPathComponent("archive")
        let identityURL = root.appendingPathComponent("identity.json")
        if phase == "crash" {
            for url in [incoming.appendingPathComponent("resources"), target] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let bytes = Data(repeating: 47, count: 8192), id = UUID()
            let path = "resources/\(id.uuidString.lowercased()).bin"
            try bytes.write(to: incoming.appendingPathComponent(path))
            let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
            let resource = ImageAllMigrationResource(id: id, role: "original", version: 1,
                uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
                byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
                createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
            try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
            try JSONEncoder().encode(header).write(to: identityURL)
        }
        let header = try JSONDecoder().decode(ImageAllMigrationHeader.self, from: Data(contentsOf: identityURL))
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        let publisher = PhoneNativeLibraryPublisher(database: database)
        let archive = target.appendingPathComponent("ImageAll-Archive-" + header.migrationID.uuidString.lowercased())
        let stop: @Sendable () throws -> Void = {
            try Data(boundary.utf8).write(to: root.appendingPathComponent("commit-window-ready"), options: .atomic)
            raise(SIGSTOP)
            throw ImageAllMigrationArchiveError.publicationFailed
        }
        if phase == "crash" {
            let receipt = try importer.importArchive(from: incoming, to: target,
                beforeCatalogCommit: { if boundary == "import-transaction" { try stop() } },
                afterPublication: { if boundary == "archive-renamed" { try stop() } })
            if boundary == "import-committed" { try stop() }
            if boundary == "facts-published" {
                let media = try database.pool.read { try String.fetchOne($0, sql: "SELECT media_id FROM migration_import_item")! }
                let facts = ImageAllMigrationFactSnapshot(sourceDeviceID: header.sourceDeviceID,
                    sourceEpoch: header.sourceEpoch, scopeRevision: 1, snapshotSequence: 2, factWatermark: 2,
                    items: [.init(mediaID: UUID(uuidString: media)!, observedFavorite: true, favoriteTarget: true,
                                  tagDecisions: [], collections: [])])
                let factsURL = root.appendingPathComponent("facts.json")
                try ImageAllMigrationFacts.write(facts, to: factsURL)
                _ = try importer.reconcileFacts(from: factsURL, migrationID: header.migrationID,
                                               archiveRoot: archive, afterFactPublication: stop)
            }
            let source = try publisher.publish(importReceipt: receipt,
                beforeCommit: { if boundary == "publication-transaction" { try stop() } })
            try database.pool.write { db in
                try db.execute(sql: "UPDATE asset_favorite_state SET desired_value = 1")
            }
            try Data(source.uuidString.utf8).write(to: root.appendingPathComponent("source-id"))
            try stop()
            XCTFail("runner must kill only this synthetic process")
        } else {
            let completed = boundary == "publication-committed"
            try database.pool.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_import"),
                    ["archive-renamed", "import-transaction"].contains(boundary) ? "prepared" : "catalogCommitted")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), completed ? 1 : 0)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), completed ? 1 : 0)
            }
            try FileManager.default.removeItem(at: incoming)
            if completed {
                // An unavailable archive must not turn historical completion into
                // an implicit full verification or overwrite local edits.
                try FileManager.default.moveItem(at: archive, to: root.appendingPathComponent("offline-archive"))
            }
            ImageAllMigrationArchiveDiagnostics.start()
            let candidates = try publisher.unpublishedBatches()
            XCTAssertEqual(candidates.count, completed ? 0 : 1)
            let source = try publisher.publish(migrationID: header.migrationID, archiveRoot: archive)
            XCTAssertEqual(try publisher.publish(migrationID: header.migrationID, archiveRoot: archive), source)
            let hash = try database.pool.read { try String.fetchOne($0, sql: "SELECT manifest_sha256 FROM migration_import")! }
            let query = RemoteImportTaskQuery(taskID: UUID(), migrationID: header.migrationID,
                sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch, manifestSHA256: hash)
            XCTAssertEqual(try publisher.importTaskStatus(query)?.phase, .browsable)
            XCTAssertTrue(try publisher.unpublishedBatches().isEmpty)
            let reads = ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }.count
            if completed {
                XCTAssertEqual(reads, 0)
                XCTAssertEqual(source.uuidString, try String(contentsOf: root.appendingPathComponent("source-id"), encoding: .utf8))
            } else { XCTAssertGreaterThan(reads, 0) }
            try database.pool.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 1)
                if completed { XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT desired_value FROM asset_favorite_state"), 1) }
                if boundary == "facts-published" {
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT fact_snapshot_sequence FROM migration_import"), 2)
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT desired_value FROM asset_favorite_state"), 1)
                }
            }
            if completed {
                // A stray publication row cannot make an uncommitted journal
                // browsable, and a stale candidate must not abort enumeration.
                try database.pool.write { try $0.execute(sql: "UPDATE migration_import SET state = 'prepared'") }
                XCTAssertThrowsError(try publisher.sourceID(migrationID: header.migrationID))
                XCTAssertEqual(try publisher.importTaskStatus(query)?.phase, .needsAttention)
                XCTAssertEqual(try publisher.unpublishedBatches().count, 1)
            }
            try JSONSerialization.data(withJSONObject: ["boundary": boundary, "fullReads": reads,
                "sourceID": source.uuidString, "browsable": true, "items": 1], options: [.prettyPrinted])
                .write(to: root.appendingPathComponent("scenario-result.json"))
        }
    }
    func testP3PreparedRecoveryRejectsInvalidTargets() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        for fault in ["same-size", "truncated", "wrong-identity", "symlink", "missing"] {
        let root = base.appendingPathComponent(fault)

        let incoming = root.appendingPathComponent("incoming"), target = root.appendingPathComponent("archive")
        for url in [incoming.appendingPathComponent("resources"), target] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let bytes = Data(repeating: 41, count: 8192), id = UUID()
        let path = "resources/\(id.uuidString.lowercased()).bin"
        try bytes.write(to: incoming.appendingPathComponent(path))
        let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        let resource = ImageAllMigrationResource(id: id, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
            byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
        try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
        let databaseURL = root.appendingPathComponent("catalog.sqlite")
        do {
            let database = try CatalogDatabase.open(at: databaseURL)
            XCTAssertThrowsError(try VerifiedPhoneArchiveImporter(database: database).importArchive(
                from: incoming, to: target, afterPublication: { throw ImageAllMigrationArchiveError.publicationFailed }))
            try database.pool.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_import"), "prepared")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 0)
            }
        }
        // The staging source is not needed once the durable target exists.
        try FileManager.default.removeItem(at: incoming)
        let restarted = try CatalogDatabase.open(at: databaseURL)
        let publisher = PhoneNativeLibraryPublisher(database: restarted)
        let batches = try publisher.unpublishedBatches()
        XCTAssertEqual(batches.map(\.id), [header.migrationID], "restart must discover the prepared durable target")
        guard let batch = batches.first else { return }
        let archive = URL(fileURLWithPath: batch.archivePath)
        let resourceURL = archive.appendingPathComponent(path)
        if fault == "same-size" { try Data(repeating: 42, count: bytes.count).write(to: resourceURL) }
        if fault == "truncated" { try Data(bytes.prefix(3)).write(to: resourceURL) }
        if fault == "wrong-identity" {
            let replacement = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: header.sourceDeviceID,
                sourceEpoch: header.sourceEpoch, scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
            let other = root.appendingPathComponent("replacement")
            try FileManager.default.createDirectory(at: other.appendingPathComponent("resources"), withIntermediateDirectories: true)
            try bytes.write(to: other.appendingPathComponent(path))
            try ImageAllMigrationArchive.write(header: replacement, items: [item], to: other)
            try FileManager.default.moveItem(at: archive, to: root.appendingPathComponent("original-target"))
            try FileManager.default.moveItem(at: other, to: archive)
        }
        if fault == "symlink" {
            let moved = root.appendingPathComponent("other")
            try FileManager.default.moveItem(at: archive, to: moved)
            try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: moved)
        }
        if fault == "missing" { try FileManager.default.moveItem(at: archive, to: root.appendingPathComponent("unavailable")) }
        XCTAssertThrowsError(try publisher.publish(migrationID: batch.id, archiveRoot: archive), fault)
        try restarted.pool.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_import"), "prepared")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 0)
        }
        }
        try Data("invalid recovery targets rejected".utf8).write(to: base.appendingPathComponent("scenario-result.json"))
    }

}

extension RemoteHTTPServerTests {
    func testP4ExportCleanupReceiptRequiresIntactPublishedCopy() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        let batch = try XCTUnwrap(importer.importedBatches().first)
        let archive = URL(fileURLWithPath: batch.archivePath)
        let (header, verification) = try ImageAllMigrationArchive.readVerifiedHeader(at: archive)
        let query = RemoteImportTaskQuery(taskID: UUID(), migrationID: batch.id,
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch, manifestSHA256: verification.manifestSHA256)
        let publisher = PhoneNativeLibraryPublisher(database: database), nonce = UUID(), host = UUID(), device = UUID()
        let receipt = try publisher.exportCleanupReceipt(query, nonce: nonce, hostID: host, deviceID: device)
        XCTAssertEqual(receipt.verifiedBytes, verification.verifiedBytes)
        XCTAssertEqual(receipt.sourceID, try publisher.sourceID(migrationID: batch.id))
        XCTAssertThrowsError(try publisher.exportCleanupReceipt(.init(taskID: query.taskID, migrationID: batch.id,
            sourceInstallID: query.sourceInstallID, sourceEpoch: UUID(), manifestSHA256: query.manifestSHA256),
            nonce: nonce, hostID: host, deviceID: device))
        var resource: URL?
        _ = try ImageAllMigrationArchive.visitVerifiedRecords(at: archive, priorVerification: verification,
            onHeader: { _ in }, onItem: { item in
                if resource == nil, let path = item.resources.first?.relativePath { resource = archive.appendingPathComponent(path) }
            })
        let file = try FileHandle(forUpdating: XCTUnwrap(resource)); defer { try? file.close() }
        let original = try XCTUnwrap(file.read(upToCount: 1))
        defer { try? file.seek(toOffset: 0); try? file.write(contentsOf: original); try? file.synchronize() }
        try file.seek(toOffset: 0); try file.write(contentsOf: Data([original[0] ^ 0xff])); try file.synchronize()
        XCTAssertThrowsError(try publisher.exportCleanupReceipt(query, nonce: nonce, hostID: host, deviceID: device))
        try file.seek(toOffset: 0); try file.write(contentsOf: original); try file.synchronize()
        XCTAssertEqual(try publisher.exportCleanupReceipt(query, nonce: UUID(), hostID: host, deviceID: device).sourceID, receipt.sourceID)
        XCTAssertEqual(try publisher.importTaskStatus(query)?.phase, .browsable)
    }
}

extension RemoteHTTPServerTests {
    func testExportRootBindingSurvivesRestartAndRejectsTraversal() throws {
        var record = LocalShareTaskRecord()
        try record.begin(selectionIDs: [UUID()], includeAlbumCatalog: false, hostID: UUID().uuidString,
            fingerprint: "synthetic", target: "test", intent: .transferSelection)
        try record.bind(sourceInstallID: UUID(), sourceEpoch: UUID())
        let migration = UUID(); try record.bind(migrationID: migration)
        let name = ".staging-" + String(repeating: "a", count: 64)
        try record.bindExportRoot(URL(fileURLWithPath: "/synthetic/" + name), migrationID: migration)
        let restored = try JSONDecoder().decode(LocalShareTaskRecord.self, from: JSONEncoder().encode(record)).restored()
        XCTAssertEqual(restored.exportStagingName, name)
        XCTAssertEqual(restored.taskID, record.taskID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["exportStagingName"] = "../other/" + name
        let changed = try JSONDecoder().decode(LocalShareTaskRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try changed.validate())
    }
}

@MainActor
private final class USBImportCleanupLog {
    let file: URL
    var records: [[String: Any]]
    init(root: URL) {
        file = root.appendingPathComponent("automatic-requests.json")
        records = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]) ?? []
    }
    func record(nonce: UUID, success: Bool) {
        records.append(["nonce": nonce.uuidString, "success": success, "pid": Int(getpid())])
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

extension RemoteHTTPServerTests {
    @MainActor
    func testAutomaticCleanupFailurePreservesPublishedLibraryAndRecords() async throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let root = base.appendingPathComponent("auto-failure-\(UUID())")
        let sender = root.appendingPathComponent("sender"), receiver = root.appendingPathComponent("receiver"), target = root.appendingPathComponent("target")
        for path in [sender.appendingPathComponent("resources"), receiver, target] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        PhoneArchiveImportProcessHolder.attach(database: database)
        let migration = UUID(), install = UUID(), epoch = UUID(), device = UUID(), host = UUID()
        let resourceID = UUID(), path = "resources/\(resourceID.uuidString.lowercased()).bin"
        let bytes = Data(repeating: 42, count: 4096)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: sender.appendingPathComponent(path))
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
            byteCount: 4096, sha256: digest)
        let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: install, sourceEpoch: epoch,
            scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "generated-auto-failure", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
        try ImageAllMigrationArchive.write(header: header, items: [item], to: sender)
        let store = try ImageAllMigrationTransferStore(root: receiver)
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device, sourceInstallID: install)
        for name in ["manifest.jsonl", path] {
            let data = try Data(contentsOf: sender.appendingPathComponent(name))
            _ = try await store.append(migrationID: migration, authenticatedDeviceID: device, relativePath: name, offset: 0,
                bytes: data, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let (package, seal) = try await store.sealVerifiedArchive(migrationID: migration, authenticatedDeviceID: device)
        let imported = try VerifiedPhoneArchiveImporter(database: database).importArchive(from: package, to: target)
        let publisher = PhoneNativeLibraryPublisher(database: database)
        let source = try publisher.publish(importReceipt: imported)
        let query = RemoteImportTaskQuery(taskID: UUID(), migrationID: migration, sourceInstallID: install,
            sourceEpoch: epoch, manifestSHA256: seal.manifestSHA256)
        let journal = package.deletingLastPathComponent().appendingPathComponent("session.json")
        let originalJournal = try Data(contentsOf: journal)
        let manifest = try Data(contentsOf: package.appendingPathComponent("manifest.jsonl"))
        var reader: ImageAllMigrationStagingLease? = try .readingPackage(package)
        do {
            _ = try await PhoneImportTaskActivity.automaticCleanup(query, nonce: UUID(), hostID: host, deviceID: device, receiver: store)
            XCTFail("reader must defer automatic cleanup")
        } catch ImageAllMigrationCleanupError.busy { }
        XCTAssertNotNil(reader); reader = nil
        XCTAssertEqual(chmod(package.appendingPathComponent(path).path, 0o400), 0)
        do {
            _ = try await PhoneImportTaskActivity.automaticCleanup(query, nonce: UUID(), hostID: host, deviceID: device, receiver: store)
            XCTFail("permission failure must defer")
        } catch { }
        XCTAssertEqual(try publisher.sourceID(migrationID: migration), source)
        XCTAssertEqual(try publisher.importTaskStatus(query)?.phase, .browsable)
        XCTAssertEqual(try Data(contentsOf: imported.archiveURL.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: journal), originalJournal)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.jsonl")), manifest)
        XCTAssertEqual(chmod(package.appendingPathComponent(path).path, 0o600), 0)
        let nonce = UUID()
        let proof = try await PhoneImportTaskActivity.automaticCleanup(query, nonce: nonce, hostID: host, deviceID: device, receiver: store)
        XCTAssertEqual(proof.nonce, nonce); XCTAssertEqual(proof.sourceID, source)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(path)).count, 0)
        XCTAssertEqual(try Data(contentsOf: journal), originalJournal)
        XCTAssertEqual(try Data(contentsOf: imported.archiveURL.appendingPathComponent(path)), bytes)
        _ = try await store.begin(migrationID: UUID(), authenticatedDeviceID: device, sourceInstallID: install)
    }
}

extension RemoteHTTPServerTests {
    func testAutomaticPhoneTaskEnrollmentAndInterruptedAttemptAreDurable() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let root = base.appendingPathComponent("phone-scheduler-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let journal = LocalShareTaskJournal(directory: root)
        var task = LocalShareTaskRecord()
        try task.begin(selectionIDs: [UUID()], includeAlbumCatalog: false, hostID: UUID().uuidString,
            fingerprint: "synthetic", target: "fixture", intent: .transferSelection)
        try task.bind(sourceInstallID: UUID(), sourceEpoch: UUID())
        let migration = UUID(); try task.bind(migrationID: migration)
        try task.bindExportRoot(root.appendingPathComponent(".staging-" + String(repeating: "b", count: 64)), migrationID: migration)
        let receipt = try JSONDecoder().decode(ImageAllMigrationTransferSealReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "migrationID": migration.uuidString, "manifestSHA256": String(repeating: "a", count: 64),
            "itemCount": 1, "resourceCount": 1, "verifiedBytes": 4096]))
        try task.receive(receipt)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        legacy.removeValue(forKey: "automaticCleanup")
        var old = try JSONDecoder().decode(LocalShareTaskRecord.self, from: JSONSerialization.data(withJSONObject: legacy)).restored()
        XCTAssertNil(old.beginAutomaticCleanup(nowMs: 0, connected: true, ready: true))
        let nonce = try XCTUnwrap(task.beginAutomaticCleanup(nowMs: 1000, connected: true, ready: true))
        try journal.save(task)
        var restored = try XCTUnwrap(journal.load())
        XCTAssertEqual(restored.taskID, task.taskID); XCTAssertEqual(restored.task.phase, .received)
        XCTAssertEqual(restored.automaticCleanup?.phase, .deferred)
        XCTAssertNil(restored.beginAutomaticCleanup(nowMs: 2000, connected: true, ready: true))
        let fresh = try XCTUnwrap(restored.beginAutomaticCleanup(nowMs: 31000, connected: true, ready: true))
        XCTAssertNotEqual(fresh, nonce)
        restored.finishAutomaticCleanup(fresh, nowMs: 31000); try journal.save(restored)
        XCTAssertEqual(try journal.load()?.automaticCleanup?.phase, .complete)
    }
}

extension RemoteHTTPServerTests {
    func testStartingNextImportPreservesDeferredCleanupRegistration() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let directory = base.appendingPathComponent("pending-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var task = LocalShareTaskRecord()
        let host = UUID().uuidString
        try task.begin(selectionIDs: [UUID()], includeAlbumCatalog: false, hostID: host,
            fingerprint: "synthetic", target: "fixture", intent: .transferSelection)
        try task.bind(sourceInstallID: UUID(), sourceEpoch: UUID())
        let migration = UUID(); try task.bind(migrationID: migration)
        try task.bindExportRoot(directory.appendingPathComponent(".staging-" + String(repeating: "c", count: 64)), migrationID: migration)
        let receipt = try JSONDecoder().decode(ImageAllMigrationTransferSealReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "migrationID": migration.uuidString, "manifestSHA256": String(repeating: "a", count: 64),
            "itemCount": 1, "resourceCount": 1, "verifiedBytes": 4096]))
        try task.receive(receipt)
        let first = try XCTUnwrap(task.beginAutomaticCleanup(nowMs: 1000, connected: true, ready: true))
        task.finishAutomaticCleanup(first, failure: .busy, nowMs: 1000)
        let queue = LocalShareCleanupQueue(directory: directory)
        try queue.retain(task)
        XCTAssertNil(try queue.next(hostID: host, fingerprint: "synthetic", nowMs: 2000))
        XCTAssertNil(try queue.next(hostID: UUID().uuidString, fingerprint: "synthetic", nowMs: 31000))
        var restored = try XCTUnwrap(LocalShareCleanupQueue(directory: directory).next(hostID: host, fingerprint: "synthetic", nowMs: 31000))
        XCTAssertEqual(restored.taskID, task.taskID)
        XCTAssertEqual(restored.statusQuery, task.statusQuery)
        let fresh = try XCTUnwrap(restored.beginAutomaticCleanup(nowMs: 31000, connected: true, ready: true))
        try queue.save(restored)
        restored.finishAutomaticCleanup(fresh, nowMs: 32000); try queue.save(restored)
        XCTAssertNil(try queue.next(hostID: host, fingerprint: "synthetic", nowMs: 999999))
        let kept = try LocalShareTaskJournal(directory: directory.appendingPathComponent(task.taskID.uuidString.lowercased())).load()
        XCTAssertEqual(kept?.automaticCleanup?.phase, .complete)
        XCTAssertEqual(kept?.statusQuery, task.statusQuery)
    }
}
