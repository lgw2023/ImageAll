import CryptoKit
import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllMigrationTransferStoreTests: XCTestCase {
    func testBeginRecoversOnlyEmptyPreJournalDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImageAllTransfer-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ImageAllMigrationTransferStore(root: root)
        let migrationID = UUID()
        let deviceID = UUID()
        let package = root.appendingPathComponent(
            ".imageall-transfer-\(migrationID.uuidString.lowercased())/package",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let progress = try await store.begin(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertTrue(progress.files.isEmpty)
        let resumed = try await store.status(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertEqual(resumed, progress)

        let blockedID = UUID()
        let blockedPackage = root.appendingPathComponent(
            ".imageall-transfer-\(blockedID.uuidString.lowercased())/package",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: blockedPackage, withIntermediateDirectories: true
        )
        try Data([1]).write(to: blockedPackage.appendingPathComponent("manifest.jsonl"))
        do {
            _ = try await store.begin(
                migrationID: blockedID, authenticatedDeviceID: deviceID
            )
            XCTFail("nonempty unauthenticated directory was adopted")
        } catch ImageAllMigrationTransferError.invalidSession { }
    }

    func testChunkResumeTruncatesUncommittedTailAndSealsIndependentArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImageAllTransfer-\(UUID().uuidString)", isDirectory: true
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
        let relativePath = "resources/\(resourceID.uuidString.lowercased()).bin"
        let bytes = Data(repeating: 0x42, count: 96 * 1_024)
        let resourceURL = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bytes.write(to: resourceURL)
        let resource = ImageAllMigrationResource(
            id: resourceID, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present,
            relativePath: relativePath, byteCount: Int64(bytes.count), sha256: hash(bytes)
        )
        let header = ImageAllMigrationHeader(
            migrationID: migrationID, sourceDeviceID: installID, sourceEpoch: UUID(),
            scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1
        )
        let item = ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "synthetic-local-id",
            mediaKind: .image, createdAtMs: nil, favoriteTarget: nil,
            observedFavorite: false, factRevision: 1,
            tagDecisions: [], collections: [], resources: [resource]
        )
        try ImageAllMigrationArchive.write(header: header, items: [item], to: source)
        let manifest = try Data(contentsOf: source.appendingPathComponent("manifest.jsonl"))
        let firstHalf = Data(bytes.prefix(bytes.count / 2))
        let secondHalf = Data(bytes.suffix(bytes.count / 2))

        let otherReceiver = root.appendingPathComponent("other-receiver", isDirectory: true)
        try FileManager.default.createDirectory(
            at: otherReceiver, withIntermediateDirectories: true
        )
        let otherDevice = UUID()
        let wrongOwner = try ImageAllMigrationTransferStore(root: otherReceiver)
        _ = try await wrongOwner.begin(
            migrationID: migrationID, authenticatedDeviceID: otherDevice
        )
        for (path, data) in [("manifest.jsonl", manifest), (relativePath, bytes)] {
            _ = try await wrongOwner.append(
                migrationID: migrationID, authenticatedDeviceID: otherDevice,
                relativePath: path, offset: 0, bytes: data, sha256: hash(data)
            )
        }
        do {
            _ = try await wrongOwner.sealVerifiedArchive(
                migrationID: migrationID, authenticatedDeviceID: otherDevice
            )
            XCTFail("archive source identity differed from authenticated device")
        } catch ImageAllMigrationTransferError.incompleteArchive { }

        let first = try ImageAllMigrationTransferStore(
            root: receiver, maximumChunkBytes: 64 * 1_024
        )
        let started = try await first.begin(
            migrationID: migrationID, authenticatedDeviceID: deviceID, sourceInstallID: installID
        )
        XCTAssertTrue(started.files.isEmpty)
        _ = try await first.append(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: "manifest.jsonl", offset: 0,
            bytes: manifest, sha256: hash(manifest)
        )
        _ = try await first.append(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: relativePath, offset: 0,
            bytes: firstHalf, sha256: hash(firstHalf)
        )
        let staged = receiver.appendingPathComponent(
            ".imageall-transfer-\(migrationID.uuidString.lowercased())/package/\(relativePath)"
        )
        let handle = try FileHandle(forWritingTo: staged)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("uncommitted tail".utf8))
        try handle.synchronize()
        try handle.close()

        let resumed = try ImageAllMigrationTransferStore(
            root: receiver, maximumChunkBytes: 64 * 1_024
        )
        let progress = try await resumed.status(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertEqual(progress.sourceInstallID, installID)
        do {
            _ = try await resumed.begin(migrationID: migrationID,
                authenticatedDeviceID: deviceID, sourceInstallID: UUID())
            XCTFail("source installation rebound")
        } catch ImageAllMigrationTransferError.identityConflict { }
        XCTAssertEqual(progress.files.first(where: { $0.relativePath == relativePath })?.committedBytes,
                       Int64(firstHalf.count))
        XCTAssertEqual(try Data(contentsOf: staged), firstHalf)
        do {
            _ = try await resumed.status(
                migrationID: migrationID, authenticatedDeviceID: UUID()
            )
            XCTFail("different device read transfer progress")
        } catch ImageAllMigrationTransferError.identityConflict { }
        _ = try await resumed.append(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: relativePath, offset: 0,
            bytes: firstHalf, sha256: hash(firstHalf)
        )
        _ = try await resumed.append(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: relativePath, offset: Int64(firstHalf.count),
            bytes: secondHalf, sha256: hash(secondHalf)
        )
        let (package, verified) = try await resumed.sealVerifiedArchive(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertTrue(verified.isComplete)
        XCTAssertEqual(verified.itemCount, 1)
        XCTAssertEqual(verified.verifiedBytes, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(relativePath)), bytes)
        let replay = try await resumed.sealVerifiedArchive(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertEqual(replay.1, verified)

        let factFile = root.appendingPathComponent("updated.imageallfacts")
        try ImageAllMigrationFacts.write(.init(
            sourceDeviceID: installID, sourceEpoch: header.sourceEpoch,
            scopeRevision: header.scopeRevision, snapshotSequence: 2,
            factWatermark: 2, items: [.init(
                mediaID: item.mediaID, observedFavorite: true,
                favoriteTarget: true, tagDecisions: [], collections: []
            )]
        ), to: factFile)
        let publishedFact = try ImageAllMigrationFacts.publish(
            from: factFile, into: source
        )
        let factBytes = try Data(contentsOf: publishedFact)
        let factPath = "facts/\(publishedFact.lastPathComponent)"
        let firstFactPart = Data(factBytes.prefix(factBytes.count / 2))
        let lastFactPart = Data(factBytes.suffix(factBytes.count - firstFactPart.count))
        let incomingFact = try await resumed.allocateIncomingChunk(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: factPath, byteCount: firstFactPart.count)
        try firstFactPart.write(to: incomingFact)
        _ = try await resumed.commitIncomingChunk(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: factPath, offset: 0, temporaryURL: incomingFact,
            byteCount: firstFactPart.count, sha256: hash(firstFactPart))
        let readyDuringUpload = try await resumed.sealedArchives()
        XCTAssertTrue(readyDuringUpload.isEmpty)
        let coldListing = try ImageAllMigrationTransferStore(root: receiver)
        let coldPending = try await coldListing.sealedArchives()
        XCTAssertTrue(coldPending.isEmpty, "pending facts marker must survive process restart")
        let journal = package.deletingLastPathComponent().appendingPathComponent("session.json")
        let journalBytes = try Data(contentsOf: journal)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: journalBytes) as? [String: Any])
        legacy.removeValue(forKey: "factsUpdatePending")
        try JSONSerialization.data(withJSONObject: legacy).write(to: journal)
        let legacyReader = try ImageAllMigrationTransferStore(root: receiver)
        let legacyPending = try await legacyReader.sealedArchives()
        XCTAssertTrue(legacyPending.isEmpty, "legacy partial facts must remain hidden")
        try journalBytes.write(to: journal)
        do {
            _ = try await resumed.append(migrationID: migrationID, authenticatedDeviceID: deviceID,
                relativePath: "manifest.jsonl", offset: 0, bytes: Data([1]), sha256: hash(Data([1])))
            XCTFail("pending facts must not unlock sealed media or manifest")
        } catch ImageAllMigrationTransferError.sealed { }
        _ = try await resumed.append(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: factPath, offset: Int64(firstFactPart.count),
            bytes: lastFactPart, sha256: hash(lastFactPart)
        )
        let updated = try await resumed.sealVerifiedArchive(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertNotNil(updated.1.factsSHA256)
        let readyAfterFacts = try await ImageAllMigrationTransferStore(root: receiver).sealedArchives()
        XCTAssertEqual(readyAfterFacts.map(\.id), [migrationID])
        do {
            _ = try await resumed.append(
                migrationID: migrationID, authenticatedDeviceID: deviceID,
                relativePath: relativePath, offset: Int64(bytes.count),
                bytes: Data([1]), sha256: hash(Data([1]))
            )
            XCTFail("sealed archive accepted another chunk")
        } catch ImageAllMigrationTransferError.sealed { }
    }

    func testRejectsUnsafePathAndChangedChunkBeforeWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImageAllTransfer-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ImageAllMigrationTransferStore(root: root, maximumChunkBytes: 32)
        let migrationID = UUID()
        let deviceID = UUID()
        _ = try await store.begin(migrationID: migrationID, authenticatedDeviceID: deviceID)
        do {
            _ = try await store.append(
                migrationID: migrationID, authenticatedDeviceID: deviceID,
                relativePath: "../escape", offset: 0,
                bytes: Data([1]), sha256: hash(Data([1]))
            )
            XCTFail("unsafe path was accepted")
        } catch ImageAllMigrationTransferError.unsafePath { }
        do {
            _ = try await store.append(
                migrationID: migrationID, authenticatedDeviceID: deviceID,
                relativePath: "manifest.jsonl", offset: 0,
                bytes: Data([1]), sha256: String(repeating: "0", count: 64)
            )
            XCTFail("changed chunk was accepted")
        } catch ImageAllMigrationTransferError.changedChunk { }
        let progress = try await store.status(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertTrue(progress.files.isEmpty)
    }

    func testResourceVerificationPersistsFrozenExtentAndRechecksReceiverBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), device = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        let bytes = Data(repeating: 0x3a, count: 90_001)
        let request = ImageAllMigrationResourceVerificationRequest(
            relativePath: path, byteCount: Int64(bytes.count), sha256: hash(bytes))
        let store = try ImageAllMigrationTransferStore(root: root)
        _ = try await store.begin(migrationID: id, authenticatedDeviceID: device)
        _ = try await store.append(migrationID: id, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash(bytes))
        do {
            _ = try await store.verifyResource(migrationID: id, authenticatedDeviceID: UUID(), request: request)
            XCTFail("wrong owner accepted")
        } catch ImageAllMigrationTransferError.identityConflict {}
        do {
            _ = try await store.verifyResource(migrationID: id, authenticatedDeviceID: device,
                request: .init(relativePath: path, byteCount: Int64(bytes.count), sha256: String(repeating: "0", count: 64)))
            XCTFail("wrong expected digest accepted")
        } catch ImageAllMigrationTransferError.changedChunk {}
        let first = try await store.verifyResource(migrationID: id, authenticatedDeviceID: device, request: request)
        XCTAssertEqual(first.resource, request)
        XCTAssertEqual(first.deviceID, device)
        let resumed = try ImageAllMigrationTransferStore(root: root)
        let second = try await resumed.verifyResource(migrationID: id, authenticatedDeviceID: device, request: request)
        XCTAssertEqual(first, second)
        _ = try await resumed.append(migrationID: id, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: bytes, sha256: hash(bytes))
        do {
            let tail = Data([9])
            _ = try await resumed.append(migrationID: id, authenticatedDeviceID: device,
                relativePath: path, offset: Int64(bytes.count), bytes: tail, sha256: hash(tail))
            XCTFail("verified extent extended after reopening")
        } catch ImageAllMigrationTransferError.sealed {}
        let progress = try await resumed.status(migrationID: id, authenticatedDeviceID: device)
        XCTAssertFalse(progress.sealed, "resource confirmation is not whole archive seal")
        let file = root.appendingPathComponent(".imageall-transfer-\(id.uuidString.lowercased())/package/\(path)")
        try Data(repeating: 0x2b, count: bytes.count).write(to: file)
        do {
            _ = try await resumed.verifyResource(migrationID: id, authenticatedDeviceID: device, request: request)
            XCTFail("cached receipt bypassed actual receiver digest")
        } catch ImageAllMigrationTransferError.changedChunk {}
    }

    func testQuotaChangeResumesSameJournalWithoutDeletingCommittedData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), device = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        let first = Data([1, 2]), last = Data([3, 4])
        let small = try ImageAllMigrationTransferStore(root: root, maximumSessionBytes: 3)
        _ = try await small.begin(migrationID: id, authenticatedDeviceID: device)
        _ = try await small.append(migrationID: id, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: first, sha256: hash(first))
        do {
            _ = try await small.append(migrationID: id, authenticatedDeviceID: device,
                relativePath: path, offset: 2, bytes: last, sha256: hash(last))
            XCTFail("quota ignored")
        } catch ImageAllMigrationTransferError.quotaExceeded {}
        try await small.updateMaximumSessionBytes(8)
        let raised = small
        let resumed = try await raised.begin(migrationID: id, authenticatedDeviceID: device)
        XCTAssertEqual(resumed.files.first?.committedBytes, 2)
        XCTAssertEqual(resumed.maximumSessionBytes, 8)
        _ = try await raised.append(migrationID: id, authenticatedDeviceID: device,
            relativePath: path, offset: 2, bytes: last, sha256: hash(last))
        let lowered = try ImageAllMigrationTransferStore(root: root, maximumSessionBytes: 1)
        let receipt = try await lowered.verifyResource(migrationID: id, authenticatedDeviceID: device,
            request: .init(relativePath: path, byteCount: 4, sha256: hash(first + last)))
        XCTAssertEqual(receipt.resource.byteCount, 4)
        _ = try await lowered.append(migrationID: id, authenticatedDeviceID: device,
            relativePath: path, offset: 0, bytes: first, sha256: hash(first))
        do {
            _ = try await lowered.append(migrationID: id, authenticatedDeviceID: device,
                relativePath: "manifest.jsonl", offset: 0, bytes: Data([1]), sha256: hash(Data([1])))
            XCTFail("lowered quota permitted growth")
        } catch ImageAllMigrationTransferError.quotaExceeded {}
        let progress = try await lowered.status(migrationID: id, authenticatedDeviceID: device)
        XCTAssertEqual(progress.files.count, 1)
        XCTAssertEqual(progress.files.first?.committedBytes, 4)
    }

    func testListingDoesNotRepairAnotherReceiversUncommittedTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), device = UUID()
        let writer = try ImageAllMigrationTransferStore(root: root)
        _ = try await writer.begin(migrationID: id, authenticatedDeviceID: device)
        let committed = Data([1, 2])
        _ = try await writer.append(migrationID: id, authenticatedDeviceID: device,
            relativePath: "manifest.jsonl", offset: 0, bytes: committed, sha256: hash(committed))
        let file = root.appendingPathComponent(".imageall-transfer-\(id.uuidString.lowercased())/package/manifest.jsonl")
        let inFlight = Data([1, 2, 3])
        try inFlight.write(to: file)
        let reader = try ImageAllMigrationTransferStore(root: root)
        let listed = try await reader.sealedArchives()
        XCTAssertTrue(listed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), inFlight, "listing must not truncate another receiver's pending write")
        _ = try await reader.begin(migrationID: id, authenticatedDeviceID: device)
        XCTAssertEqual(try Data(contentsOf: file), committed, "explicit resume still performs journal recovery")
    }

    private func hash(_ bytes: Data) -> String {
        Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
