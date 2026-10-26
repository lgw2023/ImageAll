import CryptoKit
import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllMigrationResumeTests: XCTestCase {
    func testUncachedDiagnosticWriterStillChecksBytesAndRecoversReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Uncached-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImageAllMigrationTransferStore(root: root, recoveryPolicy: .receiveProgress)
        await store.disableJournalEncodingCacheForDiagnostics()
        let migration = UUID(), device = UUID(), path = "resources/\(UUID().uuidString.lowercased()).bin"
        let bytes = Data([3, 4, 5]), hash = SHA256.hash(data: Data([3, 4, 5])).map { String(format: "%02x", $0) }.joined()
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        do {
            _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
                relativePath: path, offset: 0, bytes: bytes, sha256: String(repeating: "0", count: 64))
            XCTFail("diagnostic baseline must retain byte checks")
        } catch ImageAllMigrationTransferError.changedChunk { }
        _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash)
        let receipt = try await store.verifyResource(migrationID: migration, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: 3, sha256: hash))
        let cold = try ImageAllMigrationTransferStore(root: root, recoveryPolicy: .verifiedBytes)
        let checkpoint = try await cold.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
        XCTAssertEqual(checkpoint.resources, [receipt])
    }

    func testJournalSnapshotPreservesReceiptsAcrossTasksAndFailedCommitRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JournalRetry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImageAllMigrationTransferStore(root: root, recoveryPolicy: .receiveProgress)
        let device = UUID(), first = UUID(), second = UUID(), install = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        let a = Data([1, 2, 3]), b = Data([4, 5, 6])
        _ = try await store.begin(migrationID: first, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: first, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: a, sha256: hash(a))
        let receipt = try await store.verifyResource(migrationID: first, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: 3, sha256: hash(a)))
        // Same relative path in a different task must never reuse the first bytes/receipt.
        _ = try await store.begin(migrationID: second, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: second, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: b, sha256: hash(b))
        _ = try await store.begin(migrationID: first, authenticatedDeviceID: device, sourceInstallID: install)
        let pending = "resources/\(UUID().uuidString.lowercased()).bin"
        _ = try await store.append(migrationID: first, authenticatedDeviceID: device,
            relativePath: pending, offset: 0, bytes: a, sha256: hash(a))
        let journal = root.appendingPathComponent(".imageall-transfer-\(first.uuidString.lowercased())/session.json")
        let saved = root.appendingPathComponent("saved-session.json")
        try FileManager.default.moveItem(at: journal, to: saved)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        try Data([0]).write(to: journal.appendingPathComponent("block-atomic-replace"))
        let incoming = try await store.allocateIncomingChunk(migrationID: first,
            authenticatedDeviceID: device, relativePath: pending, byteCount: b.count)
        try b.write(to: incoming)
        do {
            _ = try await store.commitIncomingChunk(migrationID: first, authenticatedDeviceID: device,
                relativePath: pending, offset: 3, temporaryURL: incoming, byteCount: b.count, sha256: hash(b))
            XCTFail("failed journal replacement must not acknowledge the chunk")
        } catch { }
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.moveItem(at: saved, to: journal)
        // Retry a different suffix in the same actor. The failed cached candidate
        // and uncommitted file tail must not survive into the acknowledged state.
        let retry = Data([7, 8, 9])
        let temporary = try await store.allocateIncomingChunk(migrationID: first,
            authenticatedDeviceID: device, relativePath: pending, byteCount: retry.count)
        try retry.write(to: temporary)
        _ = try await store.commitIncomingChunk(migrationID: first, authenticatedDeviceID: device,
            relativePath: pending, offset: 3, temporaryURL: temporary, byteCount: retry.count, sha256: hash(retry))
        let cold = try ImageAllMigrationTransferStore(root: root, recoveryPolicy: .verifiedBytes)
        let progress = try await cold.begin(migrationID: first, authenticatedDeviceID: device, sourceInstallID: install)
        XCTAssertEqual(progress.files.first(where: { $0.relativePath == pending })?.committedBytes, 6)
        let checkpoint = try await cold.resumeCheckpoint(migrationID: first, authenticatedDeviceID: device)
        XCTAssertEqual(checkpoint.resources, [receipt])
        _ = try await cold.verifyResource(migrationID: first, authenticatedDeviceID: device,
            request: .init(relativePath: pending, byteCount: 6, sha256: hash(a + retry)))
        _ = try await cold.begin(migrationID: second, authenticatedDeviceID: device)
        _ = try await cold.verifyResource(migrationID: second, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: 3, sha256: hash(b)))
    }

    func testColdRecoveryRejectsByteIdenticalStorageObjectReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ObjectReplacement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let migration = UUID(), device = UUID()
        let store = try ImageAllMigrationTransferStore(root: root)
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        let bytes = Data([1, 2, 3])
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash)
        let file = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package/\(path)")
        // Retain the old inode so the replacement is unambiguously a new object.
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("old-object"))
        try bytes.write(to: file)
        let cold = try ImageAllMigrationTransferStore(root: root, recoveryPolicy: .receiveProgress)
        do {
            _ = try await cold.begin(migrationID: migration, authenticatedDeviceID: device)
            XCTFail("a historical checkpoint must not authorize a different storage object")
        } catch ImageAllMigrationTransferError.identityConflict { }
    }

    func testColdRecoveryRejectsStaleResourceReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StaleReceipt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let migration = UUID(), device = UUID()
        let store = try ImageAllMigrationTransferStore(root: root)
        let path = "resources/\(UUID().uuidString.lowercased()).bin", bytes = Data([1, 2, 3])
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash)
        _ = try await store.verifyResource(migrationID: migration, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: 3, sha256: hash))
        let journal = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/session.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        var receipts = try XCTUnwrap(json["verifiedResources"] as? [String: [String: Any]])
        var receipt = try XCTUnwrap(receipts[path])
        var resource = try XCTUnwrap(receipt["resource"] as? [String: Any])
        resource["sha256"] = String(repeating: "a", count: 64)
        receipt["resource"] = resource; receipts[path] = receipt; json["verifiedResources"] = receipts
        try JSONSerialization.data(withJSONObject: json).write(to: journal)
        let cold = try ImageAllMigrationTransferStore(root: root, recoveryPolicy: .receiveProgress)
        do {
            _ = try await cold.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
            XCTFail("stale receipt must not be associated with the current committed ledger")
        } catch ImageAllMigrationTransferError.invalidSession { }
    }

    func testImportStatusObservationNeverRepairsOrCachesUnverifiedTransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatusReadOnly-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID(), migration = UUID(), install = UUID()
        let writer = try ImageAllMigrationTransferStore(root: root)
        _ = try await writer.begin(migrationID: migration, authenticatedDeviceID: device, sourceInstallID: install)
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        let bytes = Data([1, 2, 3])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        _ = try await writer.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: digest)
        let package = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package")
        let file = package.appendingPathComponent(path)
        let corrupted = Data([9, 2, 3, 4])
        try corrupted.write(to: file)
        let reader = try ImageAllMigrationTransferStore(root: root)
        let sealed = try await reader.recordedSealState(migrationID: migration,
            authenticatedDeviceID: device, sourceInstallID: install)
        XCTAssertFalse(sealed)
        XCTAssertEqual(try Data(contentsOf: file), corrupted, "status must neither read/hash originals nor truncate tails")
        do {
            _ = try await reader.recordedSealState(migrationID: migration,
                authenticatedDeviceID: UUID(), sourceInstallID: install)
            XCTFail("wrong device")
        } catch { XCTAssertEqual(error as? ImageAllMigrationTransferError, .identityConflict) }
        do {
            _ = try await reader.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
            XCTFail("status must not cache an unrecovered session and bypass hash verification")
        } catch { XCTAssertEqual(error as? ImageAllMigrationTransferError, .changedChunk) }
    }

    func testVerifiedSubsetSealsSameBatchWithoutUploadingResourcesAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubsetSeal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImageAllMigrationTransferStore(root: root)
        let device = UUID(), migration = UUID(), media = UUID(), deferred = UUID(), resourceID = UUID()
        let path = "resources/\(resourceID.uuidString.lowercased()).bin", bytes = Data([1, 2, 3])
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash(bytes))
        _ = try await store.verifyResource(migrationID: migration, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: 3, sha256: hash(bytes)))
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present,
            relativePath: path, byteCount: 3, sha256: hash(bytes))
        let item = ImageAllMigrationItem(mediaID: media, sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: true, factRevision: 1,
            tagDecisions: [], collections: [], resources: [resource])
        let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: device,
            sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1,
            retainedSelectionIDs: [media, deferred])
        let package = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package")
        let before = try await store.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
        try ImageAllMigrationArchive.write(header: header, items: [item], to: package)
        let first = try await store.sealVerifiedArchive(migrationID: migration, authenticatedDeviceID: device)
        let replay = try await store.sealVerifiedArchive(migrationID: migration, authenticatedDeviceID: device)
        XCTAssertEqual(first.1.manifestSHA256, replay.1.manifestSHA256)
        XCTAssertEqual(first.1.itemCount, 1)
        XCTAssertEqual(first.1.verifiedBytes, 3)
        let after = try await store.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
        XCTAssertEqual(before.resources, after.resources)
        XCTAssertEqual(try ImageAllMigrationArchive.readVerifiedHeader(at: package).0.retainedSelectionIDs, [media, deferred])
        XCTAssertThrowsError(try header.validateRetainedSelection(mediaIDs: [UUID()]))
    }

    func testSealedDiscoveryDoesNotReadResourcesButVerificationStillRejectsCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubsetSeal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImageAllMigrationTransferStore(root: root)
        let device = UUID(), migration = UUID(), media = UUID(), deferred = UUID(), resourceID = UUID()
        let path = "resources/\(resourceID.uuidString.lowercased()).bin", bytes = Data([1, 2, 3])
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash(bytes))
        _ = try await store.verifyResource(migrationID: migration, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: 3, sha256: hash(bytes)))
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present,
            relativePath: path, byteCount: 3, sha256: hash(bytes))
        let item = ImageAllMigrationItem(mediaID: media, sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: true, factRevision: 1,
            tagDecisions: [], collections: [], resources: [resource])
        let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: device,
            sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1,
            retainedSelectionIDs: [media, deferred])
        let package = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package")
        try ImageAllMigrationArchive.write(header: header, items: [item], to: package)
        _ = try await store.sealVerifiedArchive(migrationID: migration, authenticatedDeviceID: device)
        // Same-size corruption: discovery must neither hash nor repair originals.
        let file = package.appendingPathComponent(path)
        try Data([9, 2, 3]).write(to: file)
        let cold = try ImageAllMigrationTransferStore(root: root)
        let discovered = try await cold.sealedArchives()
        XCTAssertEqual(discovered.map(\.id), [migration])
        XCTAssertEqual(try Data(contentsOf: file), Data([9, 2, 3]))
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: package))
        // Even a missing resource is a discoverable historical seal, never an
        // integrity receipt. The import verifier remains fail-closed.
        try FileManager.default.removeItem(at: file)
        let missing = try await cold.sealedArchives()
        XCTAssertEqual(missing.map(\.id), [migration])
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: package))
        // Legacy format-1 journals have no factsUpdatePending key. Discovery
        // remains metadata-only and does not trigger cold resource repair.
        let journal = package.deletingLastPathComponent().appendingPathComponent("session.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        legacy.removeValue(forKey: "factsUpdatePending")
        try JSONSerialization.data(withJSONObject: legacy).write(to: journal)
        let legacyStore = try ImageAllMigrationTransferStore(root: root)
        let legacyList = try await legacyStore.sealedArchives()
        XCTAssertEqual(legacyList.map(\.id), [migration])
        // Metadata itself cannot escape through a symlink.
        let manifest = package.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        let outside = root.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at: manifest, to: outside)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        do { _ = try await cold.sealedArchives(); XCTFail("linked manifest must be rejected") }
        catch ImageAllMigrationTransferError.invalidSession { }
    }

    func testDurableCheckpointExcludesUnverifiedTailAndRejectsWrongOwnerOrMissingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID(), install = UUID(), migration = UUID()
        let store = try ImageAllMigrationTransferStore(root: root)
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device, sourceInstallID: install)
        let bytes = Data(repeating: 42, count: 1024)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let paths = (0..<3).map { _ in "resources/" + UUID().uuidString.lowercased() + ".bin" }
        for path in paths {
            _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
                relativePath: path, offset: 0, bytes: bytes, sha256: hash)
        }
        for path in paths.prefix(2) {
            _ = try await store.verifyResource(migrationID: migration, authenticatedDeviceID: device,
                request: .init(relativePath: path, byteCount: 1024, sha256: hash))
        }
        // Reopen exactly as after a Mac restart; the second receipt can have been
        // lost on the wire. Receiver durable truth still includes it once only.
        let restarted = try ImageAllMigrationTransferStore(root: root)
        let checkpoint = try await restarted.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
        XCTAssertEqual(checkpoint.sourceInstallID, install)
        XCTAssertEqual(Set(checkpoint.resources.map(\.resource.relativePath)), Set(paths.prefix(2)))
        XCTAssertFalse(checkpoint.sealed)
        do {
            _ = try await restarted.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: UUID())
            XCTFail("must not disclose another device's checkpoint")
        } catch ImageAllMigrationTransferError.identityConflict { }
        let package = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package")
        try FileManager.default.removeItem(at: package.appendingPathComponent(paths[0]))
        do {
            _ = try await restarted.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
            XCTFail("must not silently skip a missing original")
        } catch ImageAllMigrationTransferError.invalidSession { }
    }

    func testColdRecoveryRejectsSameSizeCorruptionDespiteDurableReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ColdCorruption-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImageAllMigrationTransferStore(root: root)
        let device = UUID(), migration = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        let bytes = Data(repeating: 7, count: 128 * 1024)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash)
        _ = try await store.verifyResource(migrationID: migration, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: Int64(bytes.count), sha256: hash))
        let file = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package/\(path)")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 65_537)
        try handle.write(contentsOf: Data([9]))
        try handle.close()
        let cold = try ImageAllMigrationTransferStore(root: root)
        do {
            _ = try await cold.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
            XCTFail("cold recovery trusted a receipt without checking committed bytes")
        } catch ImageAllMigrationTransferError.changedChunk { }
    }

    func testLegacyJournalCannotEnrollCorruptBytesIntoFastRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ColdCorruption-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImageAllMigrationTransferStore(root: root)
        let device = UUID(), migration = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        let bytes = Data(repeating: 7, count: 128 * 1024)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash)
        _ = try await store.verifyResource(migrationID: migration, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: Int64(bytes.count), sha256: hash))
        let file = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package/\(path)")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 65_537)
        try handle.write(contentsOf: Data([9]))
        try handle.close()
        let journal = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("session.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        for key in ["storageObjects", "directoryObjects", "ledgerDigests", "ownerBinding"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: journal)
        let cold = try ImageAllMigrationTransferStore(root: root, recoveryPolicy: .receiveProgress)
        do {
            _ = try await cold.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
            XCTFail("cold recovery trusted a receipt without checking committed bytes")
        } catch ImageAllMigrationTransferError.changedChunk { }
    }

    func testCheckpointIsNotCompletionAndSealStillDetectsSameSizeCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResumeSeal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImageAllMigrationTransferStore(root: root)
        let device = UUID(), migration = UUID(), resourceID = UUID()
        let path = "resources/\(resourceID.uuidString.lowercased()).bin", bytes = Data([1, 2, 3])
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash(bytes))
        _ = try await store.verifyResource(migrationID: migration, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: 3, sha256: hash(bytes)))
        let package = root.appendingPathComponent(".imageall-transfer-\(migration.uuidString.lowercased())/package")
        let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: device,
            sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present,
            relativePath: path, byteCount: 3, sha256: hash(bytes))
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1,
            tagDecisions: [], collections: [], resources: [resource])
        try ImageAllMigrationArchive.write(header: header, items: [item], to: package)
        try Data([3, 2, 1]).write(to: package.appendingPathComponent(path))
        let cold = try ImageAllMigrationTransferStore(root: root, recoveryPolicy: .receiveProgress)
        _ = try await cold.begin(migrationID: migration, authenticatedDeviceID: device)
        let checkpoint = try await cold.resumeCheckpoint(migrationID: migration, authenticatedDeviceID: device)
        XCTAssertFalse(checkpoint.sealed)
        XCTAssertEqual(checkpoint.resources.count, 1, "receipt describes previous verification, not a fresh hash")
        do {
            _ = try await cold.sealVerifiedArchive(migrationID: migration, authenticatedDeviceID: device)
            XCTFail("fast resume must never turn corrupted bytes into completed import")
        } catch { }
    }
}
