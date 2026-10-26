import CryptoKit
import Foundation
import GRDB
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

extension RemoteHTTPServerTests {
    @MainActor
    func testMacOwnedHandoffWithoutConnection() async throws {
        let evidence = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"]))
        let root = evidence.appendingPathComponent("handoff")
        let source = root.appendingPathComponent("sender")
        let target = ProcessInfo.processInfo.environment["IMAGEALL_HANDOFF_TARGET"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("receiver")
        for dir in [source.appendingPathComponent("resources"), target] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("Independent generated fixture only".utf8).write(to: target.appendingPathComponent("SYNTHETIC-ONLY"))
        try JSONEncoder().encode(target.path).write(to: root.appendingPathComponent("target.json"))
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let importer = VerifiedPhoneArchiveImporter(database: database)
        PhoneArchiveImportProcessHolder.attach(database: database)
        let hostID = UUID(), install = UUID(), epoch = UUID(), migration = UUID(), media = UUID(), resourceID = UUID()
        let port = UInt16.random(in: 30_000...39_000)
        let pairing = RemotePairingStore(hostContext: .init(hostID: hostID, hostDisplayName: "Detached synthetic host",
            listenPort: Int(port), usesTLS: false, certificateFingerprintSHA256: ""),
            storageURL: root.appendingPathComponent("pairing.json"), legacyDebugToken: nil)
        let sync = try RemoteLocalLibrarySyncStore(hostID: hostID, storageURL: root.appendingPathComponent("sync.json"))
        let receiver = try ImageAllMigrationTransferStore(root: target, recoveryPolicy: .receiveProgress)
        // Intentionally defer the process launch until AFTER stopping the server.
        // The only authority to resume is the journal returned by a fresh receiver.
        let server = makeServer(port: port, pairingStore: pairing, localLibrarySyncStore: sync,
            migrationTransferStore: receiver, migrationHandoffAccepted: {}, hostID: hostID).0
        try await server.start()
        defer { Task { await server.stop() } }
        let offer = await pairing.issueOffer()
        let tokens = try await pairing.completePairing(.init(pairingToken: offer.pairingToken,
            deviceName: "Synthetic phone", devicePublicKeySPKI_SHA256: "handoff-fixture"))
        _ = try await sync.submit(.init(hostID: hostID, installID: install, sourceEpoch: epoch,
            scopeRevision: 1, snapshotSequence: 1, selectedAssetIDs: [], assets: []), authenticatedDeviceID: tokens.deviceID)
        let client = RemoteLibraryClient(endpoint: try .init(host: "127.0.0.1", port: Int(port), accessToken: tokens.accessToken))
        let path = "resources/\(resourceID.uuidString.lowercased()).bin"
        let block = Data(repeating: 0x42, count: 1024 * 1024)
        let sizeMiB = Int(ProcessInfo.processInfo.environment["IMAGEALL_HANDOFF_MIB"] ?? "16") ?? 16
        XCTAssertTrue((1...4096).contains(sizeMiB))
        let file = source.appendingPathComponent(path)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        var hash = SHA256()
        for _ in 0..<sizeMiB { try writer.write(contentsOf: block); hash.update(data: block) }
        try writer.synchronize(); try writer.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
            byteCount: Int64(sizeMiB) * 1024 * 1024, sha256: digest)
        let itemCount = Int(ProcessInfo.processInfo.environment["IMAGEALL_HANDOFF_ITEMS"] ?? "1") ?? 1
        XCTAssertTrue((1...3000).contains(itemCount))
        let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: install, sourceEpoch: epoch,
            scopeRevision: 1, inventoryWatermark: 0, declaredItemCount: itemCount,
            appleAlbumCoverage: itemCount > 1 ? .selectedAssetsOnly : nil,
            appleAlbumCatalog: itemCount > 1 ? [.init(localIdentifier: "synthetic-album", title: "Synthetic album", kind: .album,
                parentLocalIdentifier: nil, sourceOrdinal: 0, observedAssetCount: itemCount)] : nil)
        let item = ImageAllMigrationItem(mediaID: media, sourceLocalIdentifier: "synthetic-only", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 0,
            tagDecisions: [], collections: [], resources: [resource])
        var items = [item]
        let tag = UUID(), collection = UUID()
        for index in 1..<itemCount {
            let resourceID = UUID(), mediaID = UUID()
            let relative = "resources/\(resourceID.uuidString.lowercased()).bin"
            let bytes = Data(repeating: UInt8(index % 251), count: 64 * 1024)
            try bytes.write(to: source.appendingPathComponent(relative))
            items.append(.init(mediaID: mediaID, sourceLocalIdentifier: "synthetic-\(index)", mediaKind: .image,
                createdAtMs: Int64(index), favoriteTarget: nil, observedFavorite: index % 2 == 0, factRevision: 0,
                tagDecisions: [.init(tagID: tag, tagName: "Synthetic tag", decision: .accepted)],
                collections: [.init(collectionID: collection, collectionName: "Synthetic collection", included: true)],
                resources: [.init(id: resourceID, role: "original", version: 1, uniformTypeIdentifier: "public.data",
                    required: true, status: .present, relativePath: relative, byteCount: Int64(bytes.count),
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
                appleAlbums: [.init(albumLocalIdentifier: "synthetic-album", albumTitle: "Synthetic album", folderPath: [], sourceOrdinal: Int64(index))]))
        }
        try ImageAllMigrationArchive.write(header: header, items: items, to: source)
        if itemCount > 1 {
            let factsURL = root.appendingPathComponent("synthetic.imageallfacts")
            try ImageAllMigrationFacts.write(.init(sourceDeviceID: install, sourceEpoch: epoch, scopeRevision: 1,
                snapshotSequence: 1, factWatermark: 1, items: items.map {
                    .init(mediaID: $0.mediaID, observedFavorite: $0.observedFavorite, favoriteTarget: $0.favoriteTarget,
                        tagDecisions: $0.tagDecisions, collections: $0.collections)
                }), to: factsURL)
            _ = try ImageAllMigrationFacts.publish(from: factsURL, into: source)
        }
        let totalBytes = items.flatMap(\.resources).reduce(Int64(0)) { $0 + ($1.byteCount ?? 0) }
        let transferStarted = ProcessInfo.processInfo.systemUptime
        _ = try await client.uploadMigrationFile(at: file, migrationID: migration, relativePath: path,
            byteCount: resource.byteCount!, sha256: digest, sourceInstallID: install)
        let resourceAckStart = ProcessInfo.processInfo.systemUptime
        _ = try await client.acceptMigrationResource(migrationID: migration, deviceID: tokens.deviceID,
            request: .init(relativePath: path, byteCount: resource.byteCount!, sha256: digest))
        let resourceAckSeconds = ProcessInfo.processInfo.systemUptime - resourceAckStart
        for next in items.dropFirst() {
            let r = next.resources[0]
            _ = try await client.uploadMigrationFile(at: source.appendingPathComponent(r.relativePath!),
                migrationID: migration, relativePath: r.relativePath!, byteCount: r.byteCount!, sha256: r.sha256!, sourceInstallID: install)
            _ = try await client.acceptMigrationResource(migrationID: migration, deviceID: tokens.deviceID,
                request: .init(relativePath: r.relativePath!, byteCount: r.byteCount!, sha256: r.sha256!))
        }
        ImageAllMigrationArchiveDiagnostics.start()
        let handoffStart = ProcessInfo.processInfo.systemUptime
        let receipt = try await client.finishPreparedMigration(at: source, header: header, items: items, handoffToMac: true)
        let handoffSeconds = ProcessInfo.processInfo.systemUptime - handoffStart
        let transferSeconds = ProcessInfo.processInfo.systemUptime - transferStarted
        let workStart = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(receipt.hostProcessingVersion, 1)
        XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().reduce(Int64(0)) { $0 + $1.resourceBytes }, 0)
        // Read back a lost response while still connected, with no PUT or seal.
        let recovered = try await client.migrationHandoffReceipt(migrationID: migration)
        XCTAssertEqual(recovered, receipt)
        var phone = LocalShareTaskRecord()
        try phone.begin(selectionIDs: Set(items.map(\.mediaID)), includeAlbumCatalog: false, hostID: hostID.uuidString,
            fingerprint: "synthetic", target: "fixture", intent: .transferSelection)
        try phone.bind(sourceInstallID: install, sourceEpoch: epoch); try phone.bind(migrationID: migration)
        try phone.receive(receipt)
        phone = try JSONDecoder().decode(LocalShareTaskRecord.self, from: JSONEncoder().encode(phone)).restored()
        XCTAssertNil(phone.automaticCleanup)
        let presentation = LocalSharePresentation.resolve(task: phone.task, selectedCount: 1,
            canReadPhotos: true, needsFullAccess: false, connected: false, awaitingConsent: false,
            otherWork: false, selectionMatches: true)
        XCTAssertEqual(presentation.title, "传输完成 · 可以拔线")
        XCTAssertEqual(presentation.action, .macNextStep)
        try JSONEncoder().encode(phone).write(to: root.appendingPathComponent("phone-task.json"), options: .atomic)
        await server.stop()
        if ProcessInfo.processInfo.environment["IMAGEALL_HANDOFF_PREPARE_ONLY"] == "1" {
            try JSONSerialization.data(withJSONObject: ["handoffSeconds": handoffSeconds, "resourceAckSeconds": resourceAckSeconds,
                "transferSeconds": transferSeconds, "bytes": totalBytes, "handoffReadBytes": 0, "serverStopped": true,
                "preparedOnly": true, "processID": ProcessInfo.processInfo.processIdentifier], options: [.prettyPrinted])
                .write(to: evidence.appendingPathComponent("scenario-result.json"))
            return
        }
        // No network server and no phone participate from here onward.
        let jobs = try await receiver.hostJobs()
        let job = try XCTUnwrap(jobs.first)
        PhoneHostImportProcess.wake(receiver: receiver, target: target)
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            let current = try await receiver.hostJobs().first { $0.id == migration }
            if current?.phase == .complete || current?.phase == .needsAttention { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let workSeconds = ProcessInfo.processInfo.systemUptime - workStart
        let done = try await receiver.hostJobs()
        XCTAssertEqual(done.first?.phase, .complete, done.first?.state?.error ?? "")
        let publisher = PhoneNativeLibraryPublisher(database: database)
        XCTAssertEqual(try publisher.importTaskStatus(job.query)?.phase, .browsable)
        XCTAssertEqual(try importer.importedBatches().count, 1)
        let package = target.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package")
        XCTAssertEqual(try package.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize, 0)
        let samples = ImageAllMigrationArchiveDiagnostics.snapshot()
        XCTAssertEqual(samples.reduce(Int64(0)) { $0 + $1.resourceBytes }, 2 * totalBytes,
            "continuous handoff must fully verify source and target exactly once each")
        XCTAssertLessThanOrEqual(workSeconds, transferSeconds, "post-transfer time budget")
        try JSONEncoder().encode(samples).write(to: evidence.appendingPathComponent("verification-timing.json"))
        // Normal wake/restart consults complete state; it cannot rerun import or cleanup.
        ImageAllMigrationArchiveDiagnostics.start()
        PhoneHostImportProcess.wake(receiver: receiver, target: target)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().reduce(Int64(0)) { $0 + $1.resourceBytes }, 0)
        XCTAssertEqual(try importer.importedBatches().count, 1)
        // A task interrupted after custody is durable is discovered afresh. A
        // same-size corruption must fail locally, without affecting publication.
        let badID = UUID(), badResource = UUID()
        let badPath = "resources/\(badResource.uuidString.lowercased()).bin"
        let badSource = root.appendingPathComponent("damaged-sender")
        try FileManager.default.createDirectory(at: badSource.appendingPathComponent("resources"), withIntermediateDirectories: true)
        let small = Data(repeating: 7, count: 4096)
        let smallHash = SHA256.hash(data: small).map { String(format: "%02x", $0) }.joined()
        try small.write(to: badSource.appendingPathComponent(badPath))
        try ImageAllMigrationArchive.write(header: .init(migrationID: badID, sourceDeviceID: install,
            sourceEpoch: epoch, scopeRevision: 1, inventoryWatermark: 0, declaredItemCount: 1), items: [
                .init(mediaID: UUID(), sourceLocalIdentifier: "damaged-synthetic", mediaKind: .image,
                    createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 0,
                    tagDecisions: [], collections: [], resources: [.init(id: badResource, role: "original", version: 1,
                        uniformTypeIdentifier: "public.data", required: true, status: .present,
                        relativePath: badPath, byteCount: 4096, sha256: smallHash)])], to: badSource)
        _ = try await receiver.begin(migrationID: badID, authenticatedDeviceID: tokens.deviceID, sourceInstallID: install)
        for path in [badPath, "manifest.jsonl"] {
            let data = try Data(contentsOf: badSource.appendingPathComponent(path))
            _ = try await receiver.append(migrationID: badID, authenticatedDeviceID: tokens.deviceID,
                relativePath: path, offset: 0, bytes: data,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        _ = try await receiver.verifyResource(migrationID: badID, authenticatedDeviceID: tokens.deviceID,
            request: .init(relativePath: badPath, byteCount: 4096, sha256: smallHash))
        let manifest = try Data(contentsOf: badSource.appendingPathComponent("manifest.jsonl"))
        _ = try await receiver.acceptHandoff(migrationID: badID, authenticatedDeviceID: tokens.deviceID,
            manifestSHA256: SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined())
        try await receiver.recordHostState(.init(migrationID: badID, phase: .verifying))
        let interruptedJobs = try await receiver.hostJobs()
        let interruptedJob = try XCTUnwrap(interruptedJobs.first { $0.id == badID })
        let badFile = target.appendingPathComponent(".imageall-transfer-\(badID.uuidString.lowercased())/package/\(badPath)")
        try Data(repeating: 8, count: 4096).write(to: badFile)
        await PhoneHostImportProcess.process(interruptedJob, receiver: receiver, target: target, importer: importer)
        let failedJobs = try await receiver.hostJobs()
        XCTAssertEqual(failedJobs.first { $0.id == badID }?.phase, .needsAttention)
        XCTAssertNil(try publisher.sourceID(migrationID: badID))
        XCTAssertEqual(try publisher.importTaskStatus(job.query)?.phase, .browsable)
        XCTAssertEqual(try badFile.resourceValues(forKeys: [.fileSizeKey]).fileSize, 4096)
        XCTAssertEqual(try importer.importedBatches().count, 1)
        if sizeMiB == 16 { try verifyScopedTransactionFailures(at: evidence) }
        try JSONSerialization.data(withJSONObject: ["handoffSeconds": handoffSeconds, "resourceAckSeconds": resourceAckSeconds,
            "transferSeconds": transferSeconds, "postToTransferRatio": workSeconds / transferSeconds,
            "detachedWorkSeconds": workSeconds, "bytes": totalBytes, "itemCount": itemCount,
            "phoneDisconnected": true, "completed": true, "restartReadBytes": 0,
            "handoffReadBytes": 0, "cleanupRequestsFromPhone": 0, "damagedRestartRejected": true,
            "postTransferReadBytes": samples.reduce(Int64(0)) { $0 + $1.resourceBytes }], options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("scenario-result.json"))
    }

    private func verifyScopedTransactionFailures(at evidence: URL) throws {
        for phase in ["commit-damage", "commit-stale", "commit-replace", "commit-interrupt", "publish-damage", "publish-interrupt"] {
            let root = evidence.appendingPathComponent(phase)
            let incoming = root.appendingPathComponent("incoming"), target = root.appendingPathComponent("target")
            for dir in [incoming.appendingPathComponent("resources"), target] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let bytes = Data(repeating: 71, count: 8192), migration = UUID(), resource = UUID()
            let path = "resources/\(resource.uuidString.lowercased()).bin"
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try bytes.write(to: incoming.appendingPathComponent(path))
            let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: UUID(), sourceEpoch: UUID(),
                scopeRevision: 1, inventoryWatermark: 0, declaredItemCount: 1)
            let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
                createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 0,
                tagDecisions: [], collections: [], resources: [.init(id: resource, role: "original", version: 1,
                    uniformTypeIdentifier: "public.data", required: true, status: .present, relativePath: path,
                    byteCount: Int64(bytes.count), sha256: digest)])
            try ImageAllMigrationArchive.write(header: header, items: [item], to: incoming)
            let db = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
            let importer = VerifiedPhoneArchiveImporter(database: db)
            let file = target.appendingPathComponent("ImageAll-Archive-\(migration.uuidString.lowercased())/\(path)")
            let failure: @Sendable () throws -> Void = {
                if phase.hasSuffix("interrupt") { throw ImageAllMigrationArchiveError.publicationFailed }
                if phase.hasSuffix("replace") { try bytes.write(to: file, options: .atomic); return }
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.write(contentsOf: Data(repeating: 99, count: bytes.count))
                if phase.hasSuffix("stale") { try handle.seek(toOffset: 0); try handle.write(contentsOf: bytes) }
            }
            if phase.hasPrefix("commit") {
                XCTAssertThrowsError(try importer.importArchive(from: incoming, to: target,
                    reuseVerifiedContents: true, beforeCatalogCommit: failure), phase)
                try db.pool.read { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_import_item"), 0, phase)
                }
            } else {
                let receipt = try importer.importArchive(from: incoming, to: target, reuseVerifiedContents: true)
                XCTAssertThrowsError(try PhoneNativeLibraryPublisher(database: db).publish(importReceipt: receipt,
                    reuseVerifiedContents: true, beforeCommit: failure), phase)
            }
            try db.pool.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_asset"), 0, phase)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_publication"), 0, phase)
            }
            XCTAssertEqual(try Data(contentsOf: incoming.appendingPathComponent(path)), bytes)
            if phase == "commit-interrupt" || phase == "publish-interrupt" {
                // Fresh publisher has no proof from the interrupted operation.
                // It must do one real SHA, then recover atomically without duplicates.
                ImageAllMigrationArchiveDiagnostics.start()
                let publisher = PhoneNativeLibraryPublisher(database: db)
                let archive = file.deletingLastPathComponent().deletingLastPathComponent()
                _ = try publisher.publish(migrationID: migration, archiveRoot: archive, reuseVerifiedContents: true)
                XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().reduce(Int64(0)) { $0 + $1.resourceBytes }, Int64(bytes.count))
                ImageAllMigrationArchiveDiagnostics.start()
                _ = try publisher.publish(migrationID: migration, archiveRoot: archive, reuseVerifiedContents: true)
                XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().reduce(Int64(0)) { $0 + $1.resourceBytes }, 0)
                try db.pool.read { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM phone_library_asset"), 1)
                }
            }
        }
    }

    @MainActor
    func testMacOwnedColdResume() async throws {
        let env = ProcessInfo.processInfo.environment
        let existing = URL(fileURLWithPath: try XCTUnwrap(env["IMAGEALL_HANDOFF_EXISTING"]))
        let output = URL(fileURLWithPath: try XCTUnwrap(env["IMAGEALL_SYNTHETIC_ROOT"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.appendingPathComponent("SYNTHETIC-ONLY").path))
        let root = existing.appendingPathComponent("handoff")
        let target = URL(fileURLWithPath: try JSONDecoder().decode(String.self, from: Data(contentsOf: root.appendingPathComponent("target.json"))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("SYNTHETIC-ONLY").path))
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        PhoneArchiveImportProcessHolder.attach(database: database)
        let receiver = try ImageAllMigrationTransferStore(root: target, recoveryPolicy: .receiveProgress)
        let before = try await receiver.hostJobs()
        let expectedComplete = before.allSatisfy { $0.phase == .complete || $0.phase == .needsAttention }
        let phoneBytes = try Data(contentsOf: root.appendingPathComponent("phone-task.json"))
        let phone = try JSONDecoder().decode(LocalShareTaskRecord.self, from: phoneBytes).restored()
        XCTAssertEqual(phone.task.macOwnsProcessing, true)
        XCTAssertNil(phone.automaticCleanup)
        ImageAllMigrationArchiveDiagnostics.start()
        let started = ProcessInfo.processInfo.systemUptime
        PhoneHostImportProcess.wake(receiver: receiver, target: target)
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            if try await receiver.hostJobs().allSatisfy({ $0.phase == .complete || $0.phase == .needsAttention }) { break }
        }
        let after = try await receiver.hostJobs()
        let completed = try XCTUnwrap(after.first { $0.id == phone.migrationID })
        XCTAssertEqual(completed.phase, .complete, completed.state?.error ?? "")
        XCTAssertEqual(try PhoneNativeLibraryPublisher(database: database).importTaskStatus(completed.query)?.phase, .browsable)
        XCTAssertEqual(try VerifiedPhoneArchiveImporter(database: database).importedBatches().count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("phone-task.json")), phoneBytes)
        let samples = ImageAllMigrationArchiveDiagnostics.snapshot()
        let bytes = samples.reduce(Int64(0)) { $0 + $1.resourceBytes }
        if expectedComplete { XCTAssertEqual(bytes, 0) }
        try JSONEncoder().encode(samples).write(to: output.appendingPathComponent("verification-timing.json"))
        try JSONSerialization.data(withJSONObject: ["seconds": ProcessInfo.processInfo.systemUptime - started,
            "postTransferReadBytes": bytes, "processID": ProcessInfo.processInfo.processIdentifier,
            "wasComplete": expectedComplete, "completed": true, "phoneUnchanged": true,
            "networkRequests": 0], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("scenario-result.json"))
    }
}
