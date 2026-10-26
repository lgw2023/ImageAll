import CryptoKit
import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllMigrationHandoffTests: XCTestCase {
    func testCustodyIsExplicitDoesNotLeakIntoLegacyVerificationAndStillRejectsDamageAtFinalGate() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let receiver = try ImageAllMigrationTransferStore(root: f.target, recoveryPolicy: .receiveProgress)
        try await f.upload(receiver)
        let accepted = try await receiver.acceptResource(migrationID: f.id, authenticatedDeviceID: f.device, request: f.request)
        XCTAssertEqual(accepted.custodyVersion, 1)
        let legacy = try await receiver.resumeCheckpoint(migrationID: f.id, authenticatedDeviceID: f.device)
        XCTAssertTrue(legacy.resources.isEmpty, "old clients must not mistake custody for full-file verification")
        let resumed = try await receiver.resumeCheckpoint(migrationID: f.id, authenticatedDeviceID: f.device, allowDurableCustody: true)
        XCTAssertEqual(resumed.resources, [accepted])
        do {
            _ = try await receiver.acceptResource(migrationID: f.id, authenticatedDeviceID: f.device,
                request: .init(relativePath: f.request.relativePath, byteCount: f.request.byteCount, sha256: String(repeating: "0", count: 64)))
            XCTFail("changed expected hash was adopted")
        } catch ImageAllMigrationTransferError.identityConflict { }
        let verified = try await receiver.verifyResource(migrationID: f.id, authenticatedDeviceID: f.device, request: f.request)
        XCTAssertNil(verified.custodyVersion)
        let upgraded = try await receiver.resumeCheckpoint(migrationID: f.id, authenticatedDeviceID: f.device)
        XCTAssertEqual(upgraded.resources, [verified])
        _ = try await receiver.acceptHandoff(migrationID: f.id, authenticatedDeviceID: f.device, manifestSHA256: f.manifestHash)
        try Data(repeating: 0x43, count: f.bytes.count).write(to: f.package.appendingPathComponent(f.request.relativePath))
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: f.package))
    }

    func testHandoffRequiresWholeVerifiedResourcesAndSurvivesReceiverRestart() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let receiver = try ImageAllMigrationTransferStore(root: f.target, recoveryPolicy: .receiveProgress)
        try await f.upload(receiver)
        do {
            _ = try await receiver.acceptHandoff(migrationID: f.id, authenticatedDeviceID: f.device,
                manifestSHA256: f.manifestHash)
            XCTFail("missing per-resource receipt accepted")
        } catch ImageAllMigrationTransferError.incompleteArchive { }
        _ = try await receiver.verifyResource(migrationID: f.id, authenticatedDeviceID: f.device, request: f.request)
        let receipt = try await receiver.acceptHandoff(migrationID: f.id, authenticatedDeviceID: f.device,
            manifestSHA256: f.manifestHash)
        XCTAssertEqual(receipt.hostProcessingVersion, 1)
        let fresh = try ImageAllMigrationTransferStore(root: f.target, recoveryPolicy: .receiveProgress)
        let jobs = try await fresh.hostJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.receipt, receipt)
        let replay = try await fresh.acceptHandoff(migrationID: f.id, authenticatedDeviceID: f.device,
            manifestSHA256: f.manifestHash)
        XCTAssertEqual(replay, receipt)
        do {
            _ = try await fresh.acceptHandoff(migrationID: f.id, authenticatedDeviceID: f.device,
                manifestSHA256: String(repeating: "0", count: 64))
            XCTFail("old manifest accepted")
        } catch ImageAllMigrationTransferError.identityConflict { }
        // Handoff is custody, never a substitute for the later full-byte gate.
        let resource = f.package.appendingPathComponent(f.request.relativePath)
        try Data(repeating: 0x43, count: f.bytes.count).write(to: resource)
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: f.package))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.appendingPathComponent("ImageAll-Archive-\(f.id)").path))
    }

    func testReplacedObjectRejectedBeforeHandoffAndLegacyTasksNotEnrolled() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let receiver = try ImageAllMigrationTransferStore(root: f.target, recoveryPolicy: .receiveProgress)
        try await f.upload(receiver)
        _ = try await receiver.verifyResource(migrationID: f.id, authenticatedDeviceID: f.device, request: f.request)
        let legacy = try await receiver.hostJobs()
        XCTAssertTrue(legacy.isEmpty)
        try f.bytes.write(to: f.package.appendingPathComponent(f.request.relativePath), options: .atomic)
        do {
            _ = try await receiver.acceptHandoff(migrationID: f.id, authenticatedDeviceID: f.device,
                manifestSHA256: f.manifestHash)
            XCTFail("replaced resource adopted")
        } catch ImageAllMigrationTransferError.identityConflict { }
    }

    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAllHandoff-\(UUID())")
        let id = UUID(), device = UUID(), install = UUID()
        let bytes = Data(repeating: 0x42, count: 64 * 1024)
        let target: URL, source: URL, package: URL
        let request: ImageAllMigrationResourceVerificationRequest
        let manifest: Data, manifestHash: String
        init() throws {
            target = root.appendingPathComponent("receiver"); source = root.appendingPathComponent("source")
            package = target.appendingPathComponent(".imageall-transfer-\(id.uuidString.lowercased())/package")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("resources"), withIntermediateDirectories: true)
            let resourceID = UUID(), path = "resources/\(resourceID.uuidString.lowercased()).bin"
            request = .init(relativePath: path, byteCount: Int64(bytes.count), sha256: Self.hash(bytes))
            try bytes.write(to: source.appendingPathComponent(path))
            let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
                uniformTypeIdentifier: "public.data", required: true, status: .present,
                relativePath: path, byteCount: request.byteCount, sha256: request.sha256)
            try ImageAllMigrationArchive.write(header: .init(migrationID: id, sourceDeviceID: install,
                sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 0, declaredItemCount: 1),
                items: [.init(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
                    createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 0,
                    tagDecisions: [], collections: [], resources: [resource])], to: source)
            manifest = try Data(contentsOf: source.appendingPathComponent("manifest.jsonl"))
            manifestHash = Self.hash(manifest)
        }
        func upload(_ store: ImageAllMigrationTransferStore) async throws {
            _ = try await store.begin(migrationID: id, authenticatedDeviceID: device, sourceInstallID: install)
            for (path, data) in [(request.relativePath, bytes), ("manifest.jsonl", manifest)] {
                _ = try await store.append(migrationID: id, authenticatedDeviceID: device,
                    relativePath: path, offset: 0, bytes: data, sha256: Self.hash(data))
            }
        }
        static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
}
