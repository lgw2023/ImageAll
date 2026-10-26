import CryptoKit
import Foundation
import GRDB
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

/// Counts actual HTTP bodies. The sole injected failure is BEFORE sending the
/// second resource block; the first response is a real durable receiver ACK.
private actor ImportScenarioTransport: RemoteHTTPTransporting {
    private let http = URLSessionRemoteHTTPTransport()
    private var disconnectAfterFirstBlock: Bool
    private(set) var resourceBytes = 0
    private(set) var metadataBytes = 0
    private(set) var offsets: [Int64] = []
    init(disconnectAfterFirstBlock: Bool = false) {
        self.disconnectAfterFirstBlock = disconnectAfterFirstBlock
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.httpMethod == "PUT" {
            let resource = request.value(forHTTPHeaderField: "X-ImageAll-File")?.hasPrefix("resources/") == true
            if resource, disconnectAfterFirstBlock, !offsets.isEmpty {
                throw URLError(.networkConnectionLost)
            }
            if resource {
                resourceBytes += request.httpBody?.count ?? 0
                offsets.append(Int64(request.value(forHTTPHeaderField: "X-ImageAll-Offset") ?? "") ?? -1)
            } else { metadataBytes += request.httpBody?.count ?? 0 }
        }
        return try await http.data(for: request)
    }
}

extension RemoteHTTPServerTests {
    /// Compiled by run_import_task_e2e.py with the actual mobile task/journal
    /// source, not by a production app test host.
    @MainActor
    func testImportTaskHTTPPauseResumePublishAndDamage() async throws {
        let parent = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEALL_SYNTHETIC_ROOT"])
        let evidence = URL(fileURLWithPath: parent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("SYNTHETIC-ONLY").path))
        let root = evidence.appendingPathComponent("scenario-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("sender")
        let receiver = root.appendingPathComponent("receiver")
        let target = root.appendingPathComponent("archive")
        for directory in [source, receiver, target] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let databaseURL = root.appendingPathComponent("catalog.sqlite")
        let database = try CatalogDatabase.open(at: databaseURL)
        // This process has no production composition root or production database.
        PhoneArchiveImportProcessHolder.attach(database: database)
        let hostID = UUID(), installID = UUID(), epoch = UUID()
        let port = UInt16.random(in: 30_000...39_000)
        let pairing = RemotePairingStore(hostContext: .init(hostID: hostID,
            hostDisplayName: "Synthetic import host", listenPort: Int(port), usesTLS: false,
            certificateFingerprintSHA256: ""), storageURL: root.appendingPathComponent("pairing.json"),
            legacyDebugToken: nil)
        let sync = try RemoteLocalLibrarySyncStore(hostID: hostID, storageURL: root.appendingPathComponent("sync.json"))
        var transfer = try ImageAllMigrationTransferStore(root: receiver)
        func server(_ store: ImageAllMigrationTransferStore) -> RemoteHTTPServer {
            makeServer(port: port, pairingStore: pairing, localLibrarySyncStore: sync,
                migrationTransferStore: store,
                importTaskStatusProvider: { try await PhoneImportTaskActivity.status($0) }).0
        }
        var host = server(transfer)
        try await host.start()
        defer { let current = host; Task { await current.stop() } }
        let offer = await pairing.issueOffer()
        let tokens = try await pairing.completePairing(.init(pairingToken: offer.pairingToken,
            deviceName: "Synthetic phone", devicePublicKeySPKI_SHA256: "synthetic-import-task"))
        _ = try await sync.submit(.init(hostID: hostID, installID: installID, sourceEpoch: epoch,
            scopeRevision: 1, snapshotSequence: 1, selectedAssetIDs: [], assets: []),
            authenticatedDeviceID: tokens.deviceID)
        let endpoint = try RemoteHostEndpoint(host: "127.0.0.1", port: Int(port), accessToken: tokens.accessToken)
        let mediaID = UUID(), migrationID = UUID(), resourceID = UUID()
        let resourcePath = "resources/\(resourceID.uuidString.lowercased()).bin"
        let bytes = Data((0..<(8 * 1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0) })
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present,
            relativePath: resourcePath, byteCount: Int64(bytes.count), sha256: digest)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("resources"), withIntermediateDirectories: false)
        let file = source.appendingPathComponent(resourcePath)
        try bytes.write(to: file)
        let header = ImageAllMigrationHeader(migrationID: migrationID, sourceDeviceID: installID,
            sourceEpoch: epoch, scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        let item = ImageAllMigrationItem(mediaID: mediaID, sourceLocalIdentifier: "synthetic-only",
            mediaKind: .image, createdAtMs: nil, favoriteTarget: nil, observedFavorite: false,
            factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
        try ImageAllMigrationArchive.write(header: header, items: [item], to: source)
        let journal = LocalShareTaskJournal(directory: root.appendingPathComponent("phone-task"))
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false)
        var phone = LocalShareTaskRecord()
        let taskID = phone.taskID
        try phone.begin(selectionIDs: [mediaID], includeAlbumCatalog: false,
            hostID: hostID.uuidString, fingerprint: "synthetic-pin", target: "Synthetic Mac", intent: .transferSelection)
        try phone.bind(sourceInstallID: installID, sourceEpoch: epoch)
        try phone.bind(migrationID: migrationID)
        try journal.save(phone)
        let interrupted = ImportScenarioTransport(disconnectAfterFirstBlock: true)
        let first = RemoteLibraryClient(endpoint: endpoint, transport: interrupted)
        do {
            _ = try await first.uploadMigrationFile(at: file, migrationID: migrationID,
                relativePath: resourcePath, byteCount: resource.byteCount!, sha256: digest, sourceInstallID: installID)
            XCTFail("injected connection loss must interrupt the transfer")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        phone.task.requestPause(.usbDisconnected)
        phone.task.pause(reason: .cancelled)
        try journal.save(phone)
        let firstBytes = await interrupted.resourceBytes
        XCTAssertEqual(firstBytes, 4 * 1_024 * 1_024)
        await host.stop()
        transfer = try ImageAllMigrationTransferStore(root: receiver)
        host = server(transfer)
        try await host.start()
        phone = try XCTUnwrap(journal.load())
        XCTAssertEqual(phone.taskID, taskID)
        XCTAssertEqual(phone.migrationID, migrationID)
        XCTAssertEqual(phone.task.phase, .paused)
        XCTAssertEqual(phone.task.pauseReason, .usbDisconnected)
        let transport = ImportScenarioTransport()
        let client = RemoteLibraryClient(endpoint: endpoint, transport: transport)
        let beforeResume = await transport.resourceBytes
        XCTAssertEqual(beforeResume, 0, "loading task and receiver must not upload")
        try phone.begin(selectionIDs: [mediaID], includeAlbumCatalog: false, hostID: hostID.uuidString,
            fingerprint: "synthetic-pin", target: "Synthetic Mac", intent: .transferSelection)
        try journal.save(phone)
        let progress = try await client.uploadMigrationFile(at: file, migrationID: migrationID,
            relativePath: resourcePath, byteCount: resource.byteCount!, sha256: digest, sourceInstallID: installID)
        XCTAssertEqual(progress.files.first { $0.relativePath == resourcePath }?.committedBytes, Int64(bytes.count))
        let resumedOffsets = await transport.offsets
        let resumedBytes = await transport.resourceBytes
        XCTAssertEqual(resumedOffsets, [4 * 1_024 * 1_024])
        XCTAssertEqual(resumedBytes, 4 * 1_024 * 1_024)
        let receipt = try await client.finishPreparedMigration(at: source, header: header, items: [item])
        try phone.receive(receipt)
        try journal.save(phone)
        let query = try XCTUnwrap(phone.statusQuery)
        var observed: [String] = []
        func observe(_ expected: RemoteImportTaskStatus.Phase) async throws {
            let state = try await client.importTaskStatus(query)
            XCTAssertEqual(state.phase, expected)
            XCTAssertEqual(state.query.taskID, taskID)
            try phone.observe(state)
            observed.append(state.phase.rawValue)
        }
        try await observe(.awaitingImport)
        let sealed = try await transfer.sealedArchives()
        let package = try XCTUnwrap(sealed.first { $0.id == migrationID }).packageURL
        // These are the same boundaries used by PhoneArchiveImportModel.
        PhoneImportTaskActivity.set(.verifying, for: migrationID)
        try await observe(.verifying)
        let imported = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
            try VerifiedPhoneArchiveImporter(database: database).importArchive(from: package, to: target)
        }
        PhoneImportTaskActivity.set(.publishing, for: migrationID)
        try await observe(.publishing)
        let sourceID = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
            try PhoneNativeLibraryPublisher(database: database).publish(migrationID: migrationID, archiveRoot: imported.archiveURL)
        }
        PhoneImportTaskActivity.set(nil, for: migrationID)
        try await observe(.browsable)
        XCTAssertEqual(phone.task.macStatus?.sourceID, sourceID)
        let presentation = LocalSharePresentation.resolve(task: phone.task, selectedCount: 1,
            canReadPhotos: true, needsFullAccess: false, connected: true, awaitingConsent: false,
            otherWork: false, selectionMatches: true, transferPhase: "")
        XCTAssertEqual(presentation.title, "已导入 Mac · 可浏览")
        let uploadedBeforeRepeat = await transport.resourceBytes
        let metadataBeforeRepeat = await transport.metadataBytes
        _ = try await client.uploadMigrationFile(at: file, migrationID: migrationID,
            relativePath: resourcePath, byteCount: resource.byteCount!, sha256: digest, sourceInstallID: installID)
        let repeated = try await client.finishPreparedMigration(at: source, header: header, items: [item])
        XCTAssertEqual(repeated, receipt)
        let uploadedAfterRepeat = await transport.resourceBytes
        let metadataAfterRepeat = await transport.metadataBytes
        XCTAssertEqual(uploadedAfterRepeat, uploadedBeforeRepeat)
        XCTAssertEqual(metadataAfterRepeat, metadataBeforeRepeat)
        phone = try XCTUnwrap(journal.load())
        XCTAssertNil(phone.task.macStatus)
        try await observe(.browsable)
        XCTAssertEqual(phone.taskID, taskID)
        // Same-size damage in a second synthetic sealed batch cannot publish.
        let damagedID = UUID()
        let damagedSource = root.appendingPathComponent("damaged-sender")
        try FileManager.default.createDirectory(at: damagedSource.appendingPathComponent("resources"), withIntermediateDirectories: true)
        try bytes.write(to: damagedSource.appendingPathComponent(resourcePath))
        let damagedHeader = ImageAllMigrationHeader(migrationID: damagedID, sourceDeviceID: installID,
            sourceEpoch: epoch, scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        try ImageAllMigrationArchive.write(header: damagedHeader, items: [item], to: damagedSource)
        _ = try await client.uploadMigrationFile(at: damagedSource.appendingPathComponent(resourcePath),
            migrationID: damagedID, relativePath: resourcePath, byteCount: resource.byteCount!, sha256: digest, sourceInstallID: installID)
        let damagedReceipt = try await client.finishPreparedMigration(at: damagedSource, header: damagedHeader, items: [item])
        let damagedArchives = try await transfer.sealedArchives()
        let damagedPackage = try XCTUnwrap(damagedArchives.first { $0.id == damagedID }).packageURL
        let handle = try FileHandle(forWritingTo: damagedPackage.appendingPathComponent(resourcePath))
        try handle.write(contentsOf: Data([0xff])); try handle.close()
        PhoneImportTaskActivity.set(.verifying, for: damagedID)
        do {
            _ = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try VerifiedPhoneArchiveImporter(database: database).importArchive(from: damagedPackage, to: target)
            }
            XCTFail("same-size corruption must fail verification")
        } catch {
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .resourceChanged)
            PhoneImportTaskActivity.set(.needsAttention, for: damagedID)
        }
        let failed = try await client.importTaskStatus(.init(taskID: UUID(), migrationID: damagedID,
            sourceInstallID: installID, sourceEpoch: epoch, manifestSHA256: damagedReceipt.manifestSHA256))
        XCTAssertEqual(failed.phase, .needsAttention)
        let publishedCount = try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM phone_library_publication") }
        XCTAssertEqual(publishedCount, 1, "failed batch must not create partial publication")
        PhoneImportTaskActivity.set(nil, for: damagedID)
        let result: [String: Any] = [
            "scope": "real localhost HTTP; production mobile task/client and Mac receiver/import/publisher; synthetic coordinator, no USB/PhotoKit/UI host",
            "taskID": taskID.uuidString, "migrationID": migrationID.uuidString,
            "phases": observed, "firstUploadBytes": firstBytes,
            "resumeOffset": resumedOffsets, "resumedUploadBytes": resumedBytes,
            "repeatResourceUploadBytes": uploadedAfterRepeat - uploadedBeforeRepeat,
            "repeatMetadataUploadBytes": metadataAfterRepeat - metadataBeforeRepeat,
            "pauseReason": "usbDisconnected (injected transport failure)",
            "sameSizeDamage": failed.phase.rawValue, "publishedBatchCount": publishedCount ?? -1
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("scenario-result.json"), options: .atomic)
    }
}
