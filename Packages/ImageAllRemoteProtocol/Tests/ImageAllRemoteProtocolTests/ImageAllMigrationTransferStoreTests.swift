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
            migrationID: migrationID, sourceDeviceID: deviceID, sourceEpoch: UUID(),
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
            migrationID: migrationID, authenticatedDeviceID: deviceID
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

    private func hash(_ bytes: Data) -> String {
        Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
