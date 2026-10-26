import CryptoKit
import Foundation
@testable import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest

final class MigrationTransferClientTests: XCTestCase {
    func testArchiveUploadResumesFromReceiverOffsetAndSealsVerifiedPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MigrationTransferClient-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let receiver = root.appendingPathComponent("receiver", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: true)
        let migrationID = UUID()
        let deviceID = UUID()
        let installID = UUID()
        let resourceID = UUID()
        let path = "resources/\(resourceID.uuidString.lowercased()).bin"
        let resourceBytes = Data(repeating: 0x33, count: 160 * 1_024)
        let resourceURL = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try resourceBytes.write(to: resourceURL)
        let header = ImageAllMigrationHeader(
            migrationID: migrationID, sourceDeviceID: installID, sourceEpoch: UUID(),
            scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1,
            appleAlbumCoverage: .selectedAssetsOnly,
            appleAlbumCatalog: [.init(localIdentifier: "empty-folder", title: "Empty folder", kind: .folder,
                parentLocalIdentifier: nil, sourceOrdinal: 0, observedAssetCount: nil),
                .init(localIdentifier: "empty-album", title: "Empty album", kind: .album,
                parentLocalIdentifier: "empty-folder", sourceOrdinal: 0, observedAssetCount: 0)]
        )
        let item = ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "selected-photo",
            mediaKind: .image, createdAtMs: nil, favoriteTarget: nil,
            observedFavorite: false, factRevision: 1,
            tagDecisions: [], collections: [], resources: [.init(
                id: resourceID, role: "original", version: 1,
                uniformTypeIdentifier: "public.data", required: true,
                status: .present, relativePath: path,
                byteCount: Int64(resourceBytes.count), sha256: hash(resourceBytes)
            )]
        )
        try ImageAllMigrationArchive.write(header: header, items: [item], to: source)
        let manifest = try Data(contentsOf: source.appendingPathComponent("manifest.jsonl"))
        let store = try ImageAllMigrationTransferStore(
            root: receiver, maximumChunkBytes: 64 * 1_024
        )
        _ = try await store.begin(migrationID: migrationID, authenticatedDeviceID: deviceID)
        let prefix = Data(manifest.prefix(32))
        _ = try await store.append(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: "manifest.jsonl", offset: 0,
            bytes: prefix, sha256: hash(prefix)
        )

        let transport = TransferFixtureTransport(store: store, deviceID: deviceID)
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"
            ), transport: transport
        )
        // A prepared resource can finish before the manifest exists locally.
        let manifestURL = source.appendingPathComponent("manifest.jsonl")
        try FileManager.default.removeItem(at: manifestURL)
        let resourcePrefix = Data(resourceBytes.prefix(123))
        _ = try await store.append(migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: path, offset: 0, bytes: resourcePrefix, sha256: hash(resourcePrefix))
        let confirmed = ConfirmedTransferBytes()
        let uploaded = try await client.uploadMigrationFile(
            at: resourceURL, migrationID: migrationID, relativePath: path,
            byteCount: Int64(resourceBytes.count), sha256: hash(resourceBytes), sourceInstallID: installID,
            onCommittedBytes: { await confirmed.add($0) }
        )
        let confirmedTotal = await confirmed.total
        XCTAssertEqual(confirmedTotal, Int64(resourceBytes.count - resourcePrefix.count),
                       "resumed bytes must not inflate the current transfer speed")
        XCTAssertFalse(uploaded.sealed)
        XCTAssertEqual(uploaded.files.first { $0.relativePath == path }?.committedBytes,
                       Int64(resourceBytes.count))
        let resourceReceipt = try await client.verifyMigrationResource(
            migrationID: migrationID, deviceID: deviceID,
            request: .init(relativePath: path, byteCount: Int64(resourceBytes.count), sha256: hash(resourceBytes)))
        XCTAssertEqual(resourceReceipt.resource.sha256, hash(resourceBytes))
        // Simulate the one-resource window being released, then regenerated for
        // an archive retry. The receiver must retain exactly the first copy.
        try FileManager.default.removeItem(at: resourceURL)
        try Data("unexpected manifest contents".utf8).write(to: manifestURL)
        do {
            _ = try await client.finishPreparedMigration(at: source, header: header, items: [item])
            XCTFail("planning manifest changed without detection")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        try manifest.write(to: manifestURL)
        let streamed = try await client.finishPreparedMigration(at: source, header: header, items: [item])
        XCTAssertEqual(streamed.verifiedBytes, Int64(resourceBytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resourceURL.path),
                       "stream completion must not require a full local resource copy")
        let planning = root.appendingPathComponent("planning", isDirectory: true)
        try FileManager.default.createDirectory(at: planning, withIntermediateDirectories: true)
        try manifest.write(to: planning.appendingPathComponent(ImageAllMigrationArchive.manifestFilename))
        let streamRecord = try ImageAllMigrationStreamRecord(hostID: UUID(), deviceID: deviceID,
            header: header, items: [item], receipt: streamed)
        try streamRecord.save(in: planning)
        XCTAssertEqual(try ImageAllMigrationStreamRecord.read(in: planning), streamRecord)
        try resourceBytes.write(to: resourceURL)
        let oldClient = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
            host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"),
            transport: TransferFixtureTransport(store: store, deviceID: deviceID, supportsAlbumCatalog: false))
        do {
            _ = try await oldClient.uploadMigrationArchive(at: source)
            XCTFail("old host accepted a version 2 directory")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        let networkGate = PreparedFileGate()
        do {
            _ = try await client.uploadMigrationArchive(at: source, pairedDeviceID: deviceID,
                beforeChunk: { try await networkGate.check() })
            XCTFail("whole-archive transfer ignored a suspended network gate")
        } catch is CancellationError { }
        let retained = try await store.status(migrationID: migrationID, authenticatedDeviceID: deviceID)
        XCTAssertEqual(retained.files.first { $0.relativePath == path }?.committedBytes,
                       Int64(resourceBytes.count))
        XCTAssertEqual(try Data(contentsOf: resourceURL), resourceBytes)
        let receipt = try await client.uploadMigrationArchive(at: source, pairedDeviceID: deviceID)
        XCTAssertEqual(receipt.migrationID, migrationID)
        XCTAssertEqual(receipt.resourceCount, 1)
        XCTAssertEqual(receipt.verifiedBytes, Int64(resourceBytes.count))
        let (package, verified) = try await store.sealVerifiedArchive(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertEqual(receipt.manifestSHA256, verified.manifestSHA256)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(path)), resourceBytes)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.jsonl")), manifest)

        let factFile = root.appendingPathComponent("tail.imageallfacts")
        try ImageAllMigrationFacts.write(.init(
            sourceDeviceID: installID, sourceEpoch: header.sourceEpoch,
            scopeRevision: header.scopeRevision, snapshotSequence: 2,
            factWatermark: 2, items: [.init(
                mediaID: item.mediaID, observedFavorite: true,
                favoriteTarget: true, tagDecisions: [], collections: []
            )]
        ), to: factFile)
        _ = try ImageAllMigrationFacts.publish(from: factFile, into: source)
        _ = try ImageAllMigrationFacts.publish(from: factFile, into: planning)
        let updatedReceipt = try await client.finishPreparedMigration(at: planning, header: header, items: [item])
        XCTAssertTrue(streamRecord.matchesMedia(updatedReceipt))
        XCTAssertNotEqual(streamRecord.receipt.factsSHA256, updatedReceipt.factsSHA256)
        try ImageAllMigrationStreamRecord(hostID: streamRecord.hostID, deviceID: deviceID,
            header: header, items: [item], receipt: updatedReceipt).save(in: planning)
        XCTAssertEqual(try ImageAllMigrationStreamRecord.read(in: planning).receipt, updatedReceipt)
        XCTAssertNotNil(updatedReceipt.factsSHA256)
        XCTAssertEqual(updatedReceipt.verifiedBytes, receipt.verifiedBytes)
        let (_, updatedVerification) = try await store.sealVerifiedArchive(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertEqual(updatedReceipt.factsSHA256, updatedVerification.factsSHA256)
    }

    func testPreparedFileRejectsChangedDigestAndCancellationWithoutSealing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receiver = root.appendingPathComponent("receiver")
        try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: true)
        let store = try ImageAllMigrationTransferStore(root: receiver, maximumChunkBytes: 32)
        let deviceID = UUID(), migrationID = UUID()
        let file = root.appendingPathComponent("prepared.bin")
        let bytes = Data(repeating: 0x44, count: 99)
        try bytes.write(to: file)
        let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
            host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"
        ), transport: TransferFixtureTransport(store: store, deviceID: deviceID))
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        do {
            _ = try await client.uploadMigrationFile(at: file, migrationID: migrationID,
                relativePath: path, byteCount: 99, sha256: hash(Data(repeating: 0x55, count: 99)))
            XCTFail("wrong digest accepted")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        let progress = try await store.status(migrationID: migrationID, authenticatedDeviceID: deviceID)
        XCTAssertFalse(progress.sealed)
        // Even a fully committed file must be rehashed when resuming.
        do {
            _ = try await client.uploadMigrationFile(at: file, migrationID: migrationID,
                relativePath: path, byteCount: 99, sha256: hash(Data(repeating: 0x55, count: 99)))
            XCTFail("committed offset bypassed source digest")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        let canceledID = UUID()
        do {
            _ = try await client.uploadMigrationFile(at: file, migrationID: canceledID,
                relativePath: path, byteCount: 99, sha256: hash(bytes),
                beforeChunk: { throw CancellationError() })
            XCTFail("cancellation ignored")
        } catch is CancellationError {}
        do {
            _ = try await store.status(migrationID: canceledID, authenticatedDeviceID: deviceID)
            XCTFail("canceled preparation created a receiver session")
        } catch let error as ImageAllMigrationTransferError { XCTAssertEqual(error, .invalidSession) }
        let interruptedID = UUID()
        let gate = PreparedFileGate()
        do {
            _ = try await client.uploadMigrationFile(at: file, migrationID: interruptedID,
                relativePath: path, byteCount: 99, sha256: hash(bytes),
                beforeChunk: { try await gate.check() })
            XCTFail("in-flight cancellation ignored")
        } catch is CancellationError {}
        let partial = try await store.status(migrationID: interruptedID, authenticatedDeviceID: deviceID)
        XCTAssertEqual(partial.files.first?.committedBytes, 32)
        let resumed = try await client.uploadMigrationFile(at: file, migrationID: interruptedID,
            relativePath: path, byteCount: 99, sha256: hash(bytes))
        XCTAssertEqual(resumed.files.first?.committedBytes, 99)
        XCTAssertFalse(resumed.sealed)
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do {
            _ = try await client.uploadMigrationFile(at: link, migrationID: UUID(),
                relativePath: path, byteCount: 99, sha256: hash(bytes))
            XCTFail("source symlink accepted")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .badRequest) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testPreparedFileRejectsMalformedProgressBeforeSendingBytes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        let valid: [String: Any] = ["migrationID": id.uuidString, "maximumChunkBytes": 32,
            "maximumSessionBytes": 1024, "files": [], "sealed": false]
        var cases: [[String: Any]] = []
        for changes: [String: Any] in [
            ["migrationID": UUID().uuidString], ["maximumChunkBytes": 0],
            ["maximumChunkBytes": ImageAllMigrationTransferStore.defaultMaximumChunkBytes + 1],
            ["files": [["relativePath": path, "committedBytes": 4]]],
            ["files": [["relativePath": path, "committedBytes": -1]]],
            ["files": [["relativePath": path, "committedBytes": 0],
                       ["relativePath": path, "committedBytes": 0]]]
        ] {
            cases.append(valid.merging(changes) { _, new in new })
        }
        for value in cases {
            let transport = InvalidProgressTransport(payload: try JSONSerialization.data(withJSONObject: value))
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"
            ), transport: transport)
            do {
                _ = try await client.uploadMigrationFile(at: file, migrationID: id,
                    relativePath: path, byteCount: 3, sha256: hash(bytes))
                XCTFail("invalid receiver progress accepted")
            } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
            let count = await transport.requestCount
            XCTAssertEqual(count, 1, "invalid begin response must stop before a chunk request")
        }
    }

    func testSourceBindingMustBeAcknowledgedBeforeUploading() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let migrationID = UUID(), installID = UUID()
        for echoedID in [nil, UUID().uuidString] as [String?] {
            var payload: [String: Any] = ["migrationID": migrationID.uuidString,
                "maximumChunkBytes": 32, "maximumSessionBytes": 1024, "files": [], "sealed": false]
            if let echoedID { payload["sourceInstallID"] = echoedID }
            let transport = InvalidProgressTransport(payload: try JSONSerialization.data(withJSONObject: payload))
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"), transport: transport)
            do {
                _ = try await client.uploadMigrationFile(at: file, migrationID: migrationID,
                    relativePath: "resources/\(UUID().uuidString.lowercased()).bin",
                    byteCount: 3, sha256: hash(bytes), sourceInstallID: installID)
                XCTFail("unconfirmed source identity accepted")
            } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
            let count = await transport.requestCount
            XCTAssertEqual(count, 1, "no media chunks may be sent to an unbound receiver")
        }
    }

    func testPreparedFileChecksRemainingQuotaBeforeSendingButAllowsCommittedReplay() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        for committed in [0, 3] {
            let progress: [String: Any] = ["migrationID": id.uuidString, "maximumChunkBytes": 32,
                "maximumSessionBytes": 1, "files": [["relativePath": path, "committedBytes": committed]],
                "sealed": false]
            let transport = InvalidProgressTransport(payload: try JSONSerialization.data(withJSONObject: progress))
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"
            ), transport: transport)
            do {
                let result = try await client.uploadMigrationFile(at: file, migrationID: id,
                    relativePath: path, byteCount: 3, sha256: hash(bytes))
                XCTAssertEqual(committed, 3, "uncommitted file exceeds capacity")
                XCTAssertEqual(result.files.first?.committedBytes, 3)
            } catch let error as RemoteAPIError {
                XCTAssertEqual(committed, 0)
                XCTAssertEqual(error.code, .badRequest)
                XCTAssertTrue(error.message.contains("接收额度"))
            }
            let count = await transport.requestCount
            XCTAssertEqual(count, 1, "quota failure and full replay both need no chunk writes")
        }
    }

    func testPreparedFileUsesReceiverBoundedFourMegabyteChunksAndResumesOldSmallChunkOffset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x6a, count: 8 * 1_024 * 1_024 + 17)
        let file = root.appendingPathComponent("synthetic.bin")
        try bytes.write(to: file)
        let receiver = root.appendingPathComponent("receiver")
        try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: true)
        let store = try ImageAllMigrationTransferStore(root: receiver)
        let migrationID = UUID(), deviceID = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        _ = try await store.begin(migrationID: migrationID, authenticatedDeviceID: deviceID)
        let prefix = Data(bytes.prefix(64 * 1_024))
        _ = try await store.append(migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: path, offset: 0, bytes: prefix, sha256: hash(prefix))
        let transport = RecordingTransferTransport(base: .init(store: store, deviceID: deviceID))
        let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
            host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"), transport: transport)
        let confirmed = ConfirmedTransferBytes()
        _ = try await client.uploadMigrationFile(at: file, migrationID: migrationID, relativePath: path,
            byteCount: Int64(bytes.count), sha256: hash(bytes),
            onCommittedBytes: { await confirmed.add($0) })
        let sizes = await transport.chunkSizes
        XCTAssertEqual(sizes, [4 * 1_024 * 1_024, 4 * 1_024 * 1_024 - 64 * 1_024 + 17])
        let total = await confirmed.total
        XCTAssertEqual(total, Int64(bytes.count - prefix.count))
        let verified = try await store.verifyResource(migrationID: migrationID, authenticatedDeviceID: deviceID,
            request: .init(relativePath: path, byteCount: Int64(bytes.count), sha256: hash(bytes)))
        XCTAssertEqual(verified.resource.byteCount, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testCompactChunkAcknowledgmentsRetainFullReturnProgressAndSupportOldHosts() async throws {
        for supportsCompact in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompactACK-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let receiver = root.appendingPathComponent("receiver")
            try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: true)
            let store = try ImageAllMigrationTransferStore(root: receiver, maximumChunkBytes: 32)
            let id = UUID(), device = UUID()
            let oldPath = "resources/\(UUID().uuidString.lowercased()).bin"
            let path = "resources/\(UUID().uuidString.lowercased()).bin"
            let prior = Data([1, 2, 3]), bytes = Data(repeating: 7, count: 99)
            _ = try await store.begin(migrationID: id, authenticatedDeviceID: device)
            _ = try await store.append(migrationID: id, authenticatedDeviceID: device,
                relativePath: oldPath, offset: 0, bytes: prior, sha256: hash(prior))
            let file = root.appendingPathComponent("synthetic.bin")
            try bytes.write(to: file)
            let transport = RecordingTransferTransport(base: .init(store: store, deviceID: device,
                supportsCompactProgress: supportsCompact))
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787,
                accessToken: "synthetic-bearer"), transport: transport)
            let result = try await client.uploadMigrationFile(at: file, migrationID: id,
                relativePath: path, byteCount: 99, sha256: hash(bytes))
            XCTAssertEqual(result.files.count, 2, "public upload result must retain earlier files")
            XCTAssertEqual(result.files.first { $0.relativePath == oldPath }?.committedBytes, 3)
            XCTAssertEqual(result.files.first { $0.relativePath == path }?.committedBytes, 99)
            let counts = await transport.ackFileCounts
            XCTAssertEqual(counts, Array(repeating: supportsCompact ? 1 : 2, count: 4))
            let requested = await transport.compactRequests
            XCTAssertEqual(requested, 4)
            let reopened = try ImageAllMigrationTransferStore(root: receiver)
            let durable = try await reopened.status(migrationID: id, authenticatedDeviceID: device)
            XCTAssertEqual(durable.files, result.files, "compact replies must not reduce durable recovery data")
        }
    }

    func testImportRequestsAllowSlowReceiverWorkWithoutChangingOrdinaryRequests() async throws {
        let id = UUID(), device = UUID()
        let transport = ImportBudgetProbeTransport()
        let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
            host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"), transport: transport)
        let operations: [@Sendable () async throws -> Void] = [
            { _ = try await client.beginMigrationTransfer(migrationID: id) },
            { _ = try await client.beginMigrationTransfer(migrationID: id, sourceInstallID: UUID()) },
            { _ = try await client.migrationTransferProgress(migrationID: id) },
            { _ = try await client.verifyMigrationResource(migrationID: id, deviceID: device,
                request: .init(relativePath: "resources/fixture.bin", byteCount: 1,
                               sha256: String(repeating: "a", count: 64))) },
            { _ = try await client.sealMigrationTransfer(migrationID: id) },
            { _ = try await client.uploadMigrationChunk(migrationID: id,
                relativePath: "resources/fixture.bin", offset: 0, bytes: Data([1])) },
            { _ = try await client.fetchCapabilities() }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("probe must stop before decoding") }
            catch ImportBudgetProbeTransport.Observed.request { }
        }
        let pinned = RemotePinnedURLSessionFactory.makeSession(
            certificateFingerprintSHA256: String(repeating: "a", count: 64))
        defer { pinned.invalidateAndCancel() }
        XCTAssertGreaterThanOrEqual(pinned.configuration.timeoutIntervalForResource, 1_860,
                                   "TLS session must not cut off a longer archive request")
        XCTAssertEqual(pinned.configuration.timeoutIntervalForRequest, 15)
    }

    func testContinuousBatchRecoversLostAcknowledgmentAndExpiredTokenThenSeals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResilientBatch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), receiver = root.appendingPathComponent("receiver")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: true)
        let store = try ImageAllMigrationTransferStore(root: receiver)
        let checkpoint = try ImageAllMigrationExportCheckpoint(parent: root, binding: Data("unchanged selected batch".utf8))
        let device = UUID(), install = UUID(), migration = checkpoint.migrationID
        let transport = RecoverableBatchTransport(base: TransferFixtureTransport(store: store, deviceID: device))
        let tokens = RecoveryProbeTokens()
        let raw = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 1, accessToken: "synthetic-bearer"), transport: transport)
        let client = raw.recoveringMigrationRequests(beforeAttempt: {}, accessToken: { try await tokens.token(rejected: $0) })
        var items: [ImageAllMigrationItem] = []
        let confirmed = ConfirmedTransferBytes()
        for index in 0..<4 {
            let id = UUID(), path = "resources/" + id.uuidString.lowercased() + ".bin"
            let bytes = Data(repeating: UInt8(index), count: 1_572_864)
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            let resource = ImageAllMigrationResource(id: id, role: "original", version: 1,
                uniformTypeIdentifier: "public.data", required: true, status: .present,
                relativePath: path, byteCount: Int64(bytes.count), sha256: hash(bytes))
            _ = try await client.uploadMigrationFile(at: file, migrationID: migration, relativePath: path,
                byteCount: Int64(bytes.count), sha256: hash(bytes), sourceInstallID: install,
                onCommittedBytes: { await confirmed.add($0) })
            let verified = try await client.verifyMigrationResource(migrationID: migration, deviceID: device,
                request: .init(relativePath: path, byteCount: Int64(bytes.count), sha256: hash(bytes)))
            try checkpoint.recordVerifiedStreamingResource(resource, receipt: verified)
            try FileManager.default.removeItem(at: file)
            items.append(.init(mediaID: UUID(), sourceLocalIdentifier: "synthetic-\(index)", mediaKind: .image,
                createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1,
                tagDecisions: [], collections: [], resources: [resource]))
        }
        checkpoint.close()
        let resumed = try ImageAllMigrationExportCheckpoint(parent: root, binding: Data("unchanged selected batch".utf8))
        defer { resumed.close() }
        XCTAssertEqual(resumed.migrationID, migration)
        let resumeReceipts = try await client.migrationResumeCheckpoint(
            migrationID: migration, deviceID: device, sourceInstallID: install)
        XCTAssertEqual(resumeReceipts.count, 4)
        for resource in items.flatMap(\.resources) {
            let saved = try XCTUnwrap(resumed.verifiedStreamingResource(id: resource.id))
            XCTAssertEqual(saved, resource)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(saved.relativePath!).path))
            let durable = try XCTUnwrap(resumeReceipts[saved.relativePath!])
            XCTAssertEqual(durable.resource.byteCount, saved.byteCount)
            XCTAssertEqual(durable.resource.sha256, saved.sha256)
        }
        let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: install, sourceEpoch: UUID(),
            scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: items.count)
        try ImageAllMigrationArchive.write(header: header, items: items, to: source)
        let receipt = try await client.finishPreparedMigration(at: source, header: header, items: items)
        XCTAssertEqual(receipt.itemCount, 4)
        XCTAssertEqual(receipt.verifiedBytes, 6_291_456)
        let amount = await confirmed.total
        XCTAssertEqual(amount, receipt.verifiedBytes, "lost ACK must not double count received bytes")
        let refreshes = await tokens.refreshes
        XCTAssertEqual(refreshes, 1)
        let faults = await transport.faults
        XCTAssertEqual(faults, 2)
        let resumeCalls = await transport.resumeCalls
        let verifyCalls = await transport.verifyCalls
        XCTAssertEqual(resumeCalls, 1, "one resume exchange regardless of completed resource count")
        XCTAssertEqual(verifyCalls, 4, "reconnect must not repeat any per-resource hash requests")
    }

    func testResumeRejectsWrongSourceAndDuplicateReceipts() async throws {
        let migration = UUID(), device = UUID(), install = UUID()
        let receipt: [String: Any] = ["migrationID": migration.uuidString, "deviceID": device.uuidString,
            "resource": ["relativePath": "resources/\(UUID().uuidString.lowercased()).bin", "byteCount": 3,
                         "sha256": String(repeating: "a", count: 64)]]
        for (source, resources) in [(UUID(), [receipt]), (install, [receipt, receipt])] {
            let payload = try JSONSerialization.data(withJSONObject: ["migrationID": migration.uuidString,
                "deviceID": device.uuidString, "sourceInstallID": source.uuidString, "sealed": false,
                "resources": resources])
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 1,
                accessToken: "synthetic-bearer"), transport: InvalidProgressTransport(payload: payload))
            do {
                _ = try await client.migrationResumeCheckpoint(migrationID: migration, deviceID: device, sourceInstallID: install)
                XCTFail("invalid receipt must not skip resources")
            } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        }
    }

    func testRecoveryIsBoundedAndRejectsCertificateErrorsAndCancelledGate() async throws {
        for (code, expected) in [(URLError.timedOut, 5), (.serverCertificateUntrusted, 1)] {
            let base = AlwaysFailingMigrationTransport(code: code)
            let recovery = RemoteMigrationRecoveryTransport(base: base, beforeAttempt: {}, accessToken: { _ in "synthetic" }, onRetry: { _ in }, sleep: { _ in })
            var request = URLRequest(url: URL(string: "https://127.0.0.1/v1/migration-transfers/" + UUID().uuidString)!)
            request.httpMethod = "POST"
            do { _ = try await recovery.data(for: request); XCTFail("must fail") } catch { }
            let attempts = await base.attempts
            XCTAssertEqual(attempts, expected)
        }
        let resumeBase = AlwaysFailingMigrationTransport(code: .networkConnectionLost)
        let resumeRecovery = RemoteMigrationRecoveryTransport(base: resumeBase, beforeAttempt: {},
            accessToken: { _ in "synthetic" }, onRetry: { _ in }, sleep: { _ in })
        var resumeRequest = URLRequest(url: URL(string: "https://127.0.0.1" + RemoteHTTPPaths.migrationTransferResume(UUID()))!)
        resumeRequest.httpMethod = "GET"
        do { _ = try await resumeRecovery.data(for: resumeRequest); XCTFail("must fail after bounded retries") } catch { }
        let resumeAttempts = await resumeBase.attempts
        XCTAssertEqual(resumeAttempts, 5)
        let base = AlwaysFailingMigrationTransport(code: .timedOut)
        let cancelled = RemoteMigrationRecoveryTransport(base: base, beforeAttempt: { throw CancellationError() }, accessToken: { _ in "synthetic" }, onRetry: { _ in }, sleep: { _ in })
        do {
            _ = try await cancelled.data(for: URLRequest(url: URL(string: "https://127.0.0.1/v1/migration-transfers/" + UUID().uuidString)!))
            XCTFail("cancel gate ignored")
        } catch is CancellationError { }
        let attempts = await base.attempts
        XCTAssertEqual(attempts, 0)
    }

    private func hash(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct TransferFixtureTransport: RemoteHTTPTransporting {
    let store: ImageAllMigrationTransferStore
    let deviceID: UUID
    var supportsAlbumCatalog = true
    var supportsCompactProgress = true

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-bearer",
              let url = request.url else {
            throw RemoteAPIError(code: .unauthorized, message: "missing bearer")
        }
        let path = url.path
        if path.hasPrefix("/v1/migration-transfers/") {
            XCTAssertTrue(supportsAlbumCatalog, "old receiver must be rejected before migration requests")
            XCTAssertFalse(request.allowsCellularAccess, "all migration requests must deny cellular fallback")
        } else if path == RemoteHTTPPaths.capabilities {
            XCTAssertTrue(request.allowsCellularAccess, "ordinary control requests retain their existing policy")
        }
        let migrationID: UUID? = {
            let parts = path.split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return UUID(uuidString: String(parts[2]))
        }()
        let payload: Data
        if path == RemoteHTTPPaths.capabilities {
            payload = try JSONEncoder().encode(RemoteCapabilities(
                hostAppVersion: "test", capabilities: [.migrationTransfer, .migrationResourceVerification],
                migrationAlbumCatalogVersion: supportsAlbumCatalog ? 1 : nil
            ))
        } else if let migrationID,
                  path == RemoteHTTPPaths.migrationTransfer(migrationID),
                  request.httpMethod == "POST" {
            payload = try JSONEncoder().encode(try await store.begin(
                migrationID: migrationID, authenticatedDeviceID: deviceID,
                sourceInstallID: request.value(forHTTPHeaderField: "X-ImageAll-Source-Install-ID").flatMap(UUID.init(uuidString:))
            ))
        } else if let migrationID, path == RemoteHTTPPaths.migrationTransferResume(migrationID),
                  request.httpMethod == "GET" {
            payload = try JSONEncoder().encode(try await store.resumeCheckpoint(
                migrationID: migrationID, authenticatedDeviceID: deviceID))
        } else if let migrationID,
                  path == RemoteHTTPPaths.migrationTransferChunks(migrationID),
                  request.httpMethod == "PUT" {
            let body = request.httpBody ?? Data()
            let progress = try await store.append(
                migrationID: migrationID, authenticatedDeviceID: deviceID,
                relativePath: request.value(forHTTPHeaderField: "X-ImageAll-File") ?? "",
                offset: Int64(request.value(forHTTPHeaderField: "X-ImageAll-Offset") ?? "") ?? -1,
                bytes: body,
                sha256: request.value(forHTTPHeaderField: "X-ImageAll-SHA256") ?? "",
                fileProgressOnly: supportsCompactProgress && request.value(forHTTPHeaderField: "X-ImageAll-Progress-Scope") == "file"
            )
            payload = try JSONEncoder().encode(progress)
        } else if let migrationID,
                  path == RemoteHTTPPaths.migrationTransferVerifyResource(migrationID),
                  request.httpMethod == "POST" {
            let resource = try JSONDecoder().decode(ImageAllMigrationResourceVerificationRequest.self,
                from: request.httpBody ?? Data())
            payload = try JSONEncoder().encode(try await store.verifyResource(
                migrationID: migrationID, authenticatedDeviceID: deviceID, request: resource))
        } else if let migrationID,
                  path == RemoteHTTPPaths.migrationTransferSeal(migrationID),
                  request.httpMethod == "POST" {
            let (_, verification) = try await store.sealVerifiedArchive(
                migrationID: migrationID, authenticatedDeviceID: deviceID
            )
            payload = try JSONEncoder().encode(
                ImageAllMigrationTransferSealReceipt(verification: verification)
            )
        } else {
            throw RemoteAPIError(code: .notFound, message: "unexpected test route")
        }
        return (
            payload,
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private actor PreparedFileGate {
    private var calls = 0
    func check() throws {
        calls += 1
        if calls >= 3 { throw CancellationError() }
    }
}

private actor ConfirmedTransferBytes {
    private(set) var total: Int64 = 0
    func add(_ count: Int64) { total += count }
}

private actor InvalidProgressTransport: RemoteHTTPTransporting {
    let payload: Data
    private(set) var requestCount = 0
    init(payload: Data) { self.payload = payload }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        return (payload, HTTPURLResponse(url: request.url!, statusCode: 200,
                                         httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private actor RecordingTransferTransport: RemoteHTTPTransporting {
    let base: TransferFixtureTransport
    private(set) var chunkSizes: [Int] = []
    private(set) var ackFileCounts: [Int] = []
    private(set) var compactRequests = 0
    init(base: TransferFixtureTransport) { self.base = base }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await base.data(for: request)
        if request.httpMethod == "PUT" {
            chunkSizes.append(request.httpBody?.count ?? 0)
            ackFileCounts.append(try JSONDecoder().decode(ImageAllMigrationTransferProgress.self, from: result.0).files.count)
            if request.value(forHTTPHeaderField: "X-ImageAll-Progress-Scope") == "file" { compactRequests += 1 }
        }
        return result
    }
}

private struct ImportBudgetProbeTransport: RemoteHTTPTransporting {
    enum Observed: Error { case request }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let expected: TimeInterval = path.hasSuffix("/seal") ? 1_800
            : path.hasSuffix("/chunks") ? 90 : path.hasPrefix("/v1/migration-transfers/") ? 600 : 15
        XCTAssertEqual(request.timeoutInterval, expected,
                       "receiver recovery and hashing must survive the ordinary 15-second deadline")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-bearer")
        if path.hasPrefix("/v1/migration-transfers/") { XCTAssertFalse(request.allowsCellularAccess) }
        throw Observed.request
    }
}

private actor RecoveryProbeTokens {
    var current = "synthetic-bearer"
    var refreshes = 0
    func token(rejected: String?) throws -> String {
        if rejected == current { current = "renewed-synthetic-bearer"; refreshes += 1 }
        return current
    }
}
private actor RecoverableBatchTransport: RemoteHTTPTransporting {
    let base: TransferFixtureTransport
    var expected = "Bearer synthetic-bearer"
    var puts = 0
    var faults = 0
    var resumeCalls = 0
    var verifyCalls = 0
    init(base: TransferFixtureTransport) { self.base = base }
    func data(for original: URLRequest) async throws -> (Data, URLResponse) {
        if original.url!.path.hasSuffix("/resume") { resumeCalls += 1 }
        if original.url!.path.hasSuffix("/verify-resource") { verifyCalls += 1 }
        if original.httpMethod == "PUT" {
            puts += 1
            if puts == 3 { expected = "Bearer renewed-synthetic-bearer"; faults += 1 }
        }
        if original.value(forHTTPHeaderField: "Authorization") != expected {
            return (try JSONEncoder().encode(RemoteAPIError(code: .unauthorized, message: "synthetic expiry")),
                HTTPURLResponse(url: original.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        var request = original
        request.setValue("Bearer synthetic-bearer", forHTTPHeaderField: "Authorization")
        let result = try await base.data(for: request)
        if puts == 1, original.httpMethod == "PUT" { faults += 1; throw URLError(.timedOut) }
        return result
    }
}
private actor AlwaysFailingMigrationTransport: RemoteHTTPTransporting {
    let code: URLError.Code
    var attempts = 0
    init(code: URLError.Code) { self.code = code }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        attempts += 1; throw URLError(code)
    }
}
