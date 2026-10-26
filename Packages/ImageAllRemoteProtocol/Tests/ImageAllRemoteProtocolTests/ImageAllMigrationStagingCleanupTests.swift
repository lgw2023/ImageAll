import CryptoKit
import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllMigrationStagingCleanupTests: XCTestCase {
    func testCleanupReusesOnlyPreflightAndRejectsStalePublicationVerification() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let verified = try ImageAllMigrationArchive.verify(at: f.archive)
        ImageAllMigrationArchiveDiagnostics.start()
        _ = try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, publicationVerification: { verified }, validatePublication: {})
        let reads = ImageAllMigrationArchiveDiagnostics.snapshot().filter { $0.stage == "verify" }
        XCTAssertEqual(reads.filter { $0.path == f.archive.path }.reduce(Int64(0)) { $0 + $1.resourceBytes }, 8192,
            "final full-byte pass must remain; only the redundant preflight is removed")
        let changed = try await fixture(); defer { try? FileManager.default.removeItem(at: changed.root) }
        let old = try ImageAllMigrationArchive.verify(at: changed.archive)
        try Data(repeating: 99, count: 4096).write(to: changed.archive.appendingPathComponent(changed.paths[0]))
        XCTAssertThrowsError(try ImageAllMigrationStagingCleanup.release(root: changed.receiver,
            migrationID: changed.migration, finalArchive: changed.archive,
            publicationVerification: { old }, validatePublication: {}))
        for path in changed.paths {
            XCTAssertEqual(try Data(contentsOf: changed.package.appendingPathComponent(path)).count, 4096)
        }
    }

    struct Fixture: Codable {
        let root: URL, receiver: URL, archive: URL, package: URL
        let migration: UUID, device: UUID
        let paths: [String]
    }

    func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("fixture-\(UUID().uuidString)")
        let archive = root.appendingPathComponent("final"), receiver = root.appendingPathComponent("receiver")
        for url in [archive.appendingPathComponent("resources"), receiver] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let migration = UUID(), device = UUID()
        var resources: [ImageAllMigrationResource] = [], paths: [String] = []
        for index in 0..<2 {
            let id = UUID(), bytes = Data(repeating: UInt8(42 + index), count: 4096)
            let path = "resources/\(id.uuidString.lowercased()).bin"
            try bytes.write(to: archive.appendingPathComponent(path))
            paths.append(path)
            resources.append(.init(id: id, role: "original", version: 1, uniformTypeIdentifier: "public.data",
                required: true, status: .present, relativePath: path, byteCount: Int64(bytes.count), sha256: hash(bytes)))
        }
        let header = ImageAllMigrationHeader(migrationID: migration, sourceDeviceID: device, sourceEpoch: UUID(),
            scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
        let item = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic", mediaKind: .image,
            createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1,
            tagDecisions: [], collections: [], resources: resources)
        try ImageAllMigrationArchive.write(header: header, items: [item], to: archive)
        let store = try ImageAllMigrationTransferStore(root: receiver)
        _ = try await store.begin(migrationID: migration, authenticatedDeviceID: device)
        for path in ["manifest.jsonl"] + paths {
            let bytes = try Data(contentsOf: archive.appendingPathComponent(path))
            _ = try await store.append(migrationID: migration, authenticatedDeviceID: device,
                relativePath: path, offset: 0, bytes: bytes, sha256: hash(bytes))
        }
        let (package, _) = try await store.sealVerifiedArchive(migrationID: migration, authenticatedDeviceID: device)
        return Fixture(root: root, receiver: receiver, archive: archive, package: package,
                       migration: migration, device: device, paths: paths)
    }

    func testReleasePreservesFinalBytesAndRetiresResume() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try ImageAllMigrationArchive.verify(at: f.archive)
        let journal = try Data(contentsOf: f.package.deletingLastPathComponent().appendingPathComponent("session.json"))
        let result = try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, validatePublication: {})
        XCTAssertEqual(result.logicalBytesReleased, 8192)
        XCTAssertEqual(result.resourceCount, 2)
        XCTAssertFalse(result.alreadyReleased)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.archive), before)
        XCTAssertEqual(try Data(contentsOf: f.package.deletingLastPathComponent().appendingPathComponent("session.json")), journal)
        for path in f.paths { XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(path)).count, 0) }
        let repeated = try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, validatePublication: {})
        XCTAssertTrue(repeated.alreadyReleased)
        XCTAssertEqual(repeated.logicalBytesReleased, 0)
        let store = try ImageAllMigrationTransferStore(root: f.receiver)
        do {
            _ = try await store.begin(migrationID: f.migration, authenticatedDeviceID: f.device)
            XCTFail("retired payload resumed")
        } catch ImageAllMigrationCleanupError.retired { }
        let discovered = try await store.sealedArchives()
        XCTAssertTrue(discovered.isEmpty)
    }

    func testAutomaticCleanupDefersForReaderThenRetiresWithoutStoppingReceiver() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (header, verified) = try ImageAllMigrationArchive.readVerifiedHeader(at: f.archive)
        let query = RemoteImportTaskQuery(taskID: UUID(), migrationID: f.migration,
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch, manifestSHA256: verified.manifestSHA256)
        let store = try ImageAllMigrationTransferStore(root: f.receiver)
        var reader: ImageAllMigrationStagingLease? = try .readingPackage(f.package)
        do {
            _ = try await store.performAutomaticCleanup(query: query, authenticatedDeviceID: f.device) { root in
                try ImageAllMigrationStagingCleanup.release(root: root, migrationID: f.migration,
                    finalArchive: f.archive, validatePublication: {})
            }
            XCTFail("active reader must defer")
        } catch ImageAllMigrationCleanupError.busy { }
        XCTAssertNotNil(reader); reader = nil
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.archive), verified)
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(f.paths[0])).count, 4096)
        let result = try await store.performAutomaticCleanup(query: query, authenticatedDeviceID: f.device) { root in
            try ImageAllMigrationStagingCleanup.release(root: root, migrationID: f.migration,
                finalArchive: f.archive, validatePublication: {})
        }
        XCTAssertEqual(result.logicalBytesReleased, 8192)
        let repeatResult = try await store.performAutomaticCleanup(query: query, authenticatedDeviceID: f.device) { root in
            try ImageAllMigrationStagingCleanup.release(root: root, migrationID: f.migration,
                finalArchive: f.archive, validatePublication: {})
        }
        XCTAssertEqual(repeatResult.logicalBytesReleased, 0)
        _ = try await store.begin(migrationID: UUID(), authenticatedDeviceID: f.device)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.archive), verified)
    }

    private final class LeaseBox: @unchecked Sendable { var lease: ImageAllMigrationStagingLease? }
    func testLostReceiverLeaseBlocksWritesAndLegacyIsNotEnrolled() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (header, verified) = try ImageAllMigrationArchive.readVerifiedHeader(at: f.archive)
        let query = RemoteImportTaskQuery(taskID: UUID(), migrationID: f.migration,
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch, manifestSHA256: verified.manifestSHA256)
        let store = try ImageAllMigrationTransferStore(root: f.receiver), box = LeaseBox()
        _ = try await store.performAutomaticCleanup(query: query, authenticatedDeviceID: f.device) { root in
            box.lease = try ImageAllMigrationStagingLease(root: root, exclusive: true)
            return true
        }
        do { _ = try await store.begin(migrationID: UUID(), authenticatedDeviceID: f.device); XCTFail("unleased write") }
        catch ImageAllMigrationCleanupError.busy { }
        box.lease = nil
        _ = try await store.begin(migrationID: UUID(), authenticatedDeviceID: f.device)
        let journal = f.package.deletingLastPathComponent().appendingPathComponent("session.json")
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        saved.removeValue(forKey: "automaticCleanupVersion")
        try JSONSerialization.data(withJSONObject: saved).write(to: journal)
        do {
            _ = try await store.performAutomaticCleanup(query: query, authenticatedDeviceID: f.device) { _ in XCTFail("legacy adopted"); return true }
            XCTFail("legacy must refuse")
        } catch ImageAllMigrationCleanupError.unowned { }
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.archive), verified)
    }

    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    func testActiveWriterAndExternalReaderRefuseRelease() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let writer = try ImageAllMigrationTransferStore(root: f.receiver)
            XCTAssertThrowsError(try release(f)) { XCTAssertEqual($0 as? ImageAllMigrationCleanupError, .busy) }
            _ = try await writer.status(migrationID: f.migration, authenticatedDeviceID: f.device)
        }
        do {
            let reader = try ImageAllMigrationStagingLease.readingPackage(f.package)
            defer { withExtendedLifetime(reader) {} }
            XCTAssertThrowsError(try release(f)) { XCTAssertEqual($0 as? ImageAllMigrationCleanupError, .busy) }
        }
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.package).verifiedBytes, 8192)
    }

    func testPublicationFailureAndLegacyOwnershipRefuseBeforeMutation() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, validatePublication: { throw ImageAllMigrationCleanupError.incompleteReferences }))
        let journal = f.package.deletingLastPathComponent().appendingPathComponent("session.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        data.removeValue(forKey: "ownershipVersion")
        try JSONSerialization.data(withJSONObject: data).write(to: journal)
        XCTAssertThrowsError(try release(f)) { XCTAssertEqual($0 as? ImageAllMigrationCleanupError, .unowned) }
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.package).verifiedBytes, 8192)
    }

    func testDamageReplacementLinksAndUnknownReferencesRefuseBeforeMutation() async throws {
        for scenario in ["damage", "replacement", "symlink", "hardlink", "unknown", "missing", "finalDamage", "rootSymlink"] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let victim = f.package.appendingPathComponent(f.paths[0])
            let final = f.archive.appendingPathComponent(f.paths[0])
            switch scenario {
            case "damage": try Data(repeating: 99, count: 4096).write(to: victim)
            case "replacement":
                try FileManager.default.moveItem(at: victim, to: f.root.appendingPathComponent("displaced"))
                try Data(repeating: 42, count: 4096).write(to: victim)
            case "symlink", "hardlink":
                try FileManager.default.removeItem(at: victim)
                if scenario == "symlink" { try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: final) }
                else { try FileManager.default.linkItem(at: final, to: victim) }
            case "unknown": try Data([1]).write(to: f.package.appendingPathComponent("resources/unknown.bin"))
            case "missing": try FileManager.default.removeItem(at: victim)
            case "finalDamage": try Data(repeating: 99, count: 4096).write(to: final)
            case "rootSymlink":
                let moved = f.root.appendingPathComponent("moved")
                try FileManager.default.moveItem(at: f.receiver, to: moved)
                try FileManager.default.createSymbolicLink(at: f.receiver, withDestinationURL: moved)
            default: XCTFail()
            }
            XCTAssertThrowsError(try release(f), scenario)
            XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(f.paths[1])).count, 4096, scenario)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.package.deletingLastPathComponent()
                .appendingPathComponent(ImageAllMigrationStagingCleanup.recordName).path), scenario)
        }
    }

    func testInterruptedReleaseRestartsWithoutReleasingReplacement() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try ImageAllMigrationArchive.verify(at: f.archive)
        XCTAssertThrowsError(try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, validatePublication: {}, beforeRelease: { index in
                if index == 1 { throw ImageAllMigrationCleanupError.ioFailure }
            }))
        let sorted = f.paths.sorted()
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(sorted[0])).count, 0)
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(sorted[1])).count, 4096)
        let resumed = try release(f)
        XCTAssertEqual(resumed.logicalBytesReleased, 4096)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.archive), before)
        let victim = f.package.appendingPathComponent(sorted[0])
        try FileManager.default.moveItem(at: victim, to: f.root.appendingPathComponent("retired-object"))
        try Data([5]).write(to: victim)
        XCTAssertThrowsError(try release(f))
        XCTAssertEqual(try Data(contentsOf: victim), Data([5]))
    }

    func testScopedCleanupReusesBothProofsAndRejectsChangedPayloads() async throws {
        for change in ["none", "source", "target", "interrupted"] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let source = try ImageAllMigrationArchive.verify(at: f.package)
            let target = try ImageAllMigrationArchive.verify(at: f.archive)
            let original = try Data(contentsOf: f.archive.appendingPathComponent(f.paths[0]))
            if change == "source" || change == "target" {
                let root = change == "source" ? f.package : f.archive
                try Data(repeating: 99, count: 4096).write(to: root.appendingPathComponent(f.paths[0]))
            }
            ImageAllMigrationArchiveDiagnostics.start()
            let run = {
                try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
                    finalArchive: f.archive, validatePublication: {}, beforeRelease: { _ in
                        if change == "interrupted" { throw ImageAllMigrationCleanupError.ioFailure }
                    }, publicationVerification: { target }, sourceVerification: source, reuseVerifiedContents: true)
            }
            if change == "none" { XCTAssertEqual(try run().logicalBytesReleased, 8192) }
            else {
                XCTAssertThrowsError(try run(), change)
                for path in f.paths { XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(path)).count, 4096) }
            }
            if change != "target" { XCTAssertEqual(try Data(contentsOf: f.archive.appendingPathComponent(f.paths[0])), original) }
            XCTAssertEqual(ImageAllMigrationArchiveDiagnostics.snapshot().reduce(Int64(0)) { $0 + $1.resourceBytes }, 0)
        }
    }

    private func release(_ f: Fixture) throws -> ImageAllMigrationCleanupResult {
        try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, validatePublication: {})
    }

    func testFinalDirectoryReplacementImmediatelyBeforeReleaseIsRejected() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, validatePublication: {}, beforeRelease: { index in
                guard index == 0 else { return }
                let resources = f.archive.appendingPathComponent("resources")
                try FileManager.default.moveItem(at: resources, to: f.root.appendingPathComponent("old-final-resources"))
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
                for path in f.paths { try Data(repeating: 99, count: 4096).write(to: f.archive.appendingPathComponent(path)) }
            }))
        for path in f.paths { XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(path)).count, 4096) }
    }

    func testNewFactsAfterInterruptedCleanupAreNotAdopted() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, validatePublication: {}, beforeRelease: { _ in throw ImageAllMigrationCleanupError.ioFailure }))
        let facts = f.package.appendingPathComponent("facts")
        try FileManager.default.createDirectory(at: facts, withIntermediateDirectories: false)
        try Data([1]).write(to: facts.appendingPathComponent("uncommitted"))
        XCTAssertThrowsError(try release(f))
        for path in f.paths { XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(path)).count, 4096) }
    }

    func testProcessInterruptionBoundary() async throws {
        guard let path = ProcessInfo.processInfo.environment["IMAGEALL_CLEANUP_CRASH_ROOT"],
              let mode = ProcessInfo.processInfo.environment["IMAGEALL_CLEANUP_CRASH_MODE"] else { throw XCTSkip("run by the independent process crash harness") }
        let evidence = URL(fileURLWithPath: path), record = evidence.appendingPathComponent("fixture.json")
        if mode == "crash" {
            let f = try await fixture()
            try JSONEncoder().encode(f).write(to: record)
            _ = try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
                finalArchive: f.archive, validatePublication: {}, beforeRelease: { index in
                    if index == 1 {
                        try Data("first resource released".utf8).write(to: evidence.appendingPathComponent("ready"))
                        raise(SIGSTOP)
                    }
                })
            XCTFail("external SIGKILL was not delivered")
        } else {
            let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: record))
            defer { try? FileManager.default.removeItem(at: f.root) }
            XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.archive).verifiedBytes, 8192)
            let result = try release(f)
            XCTAssertEqual(result.logicalBytesReleased, 4096)
            XCTAssertTrue(try release(f).alreadyReleased)
            XCTAssertEqual(try ImageAllMigrationArchive.verify(at: f.archive).verifiedBytes, 8192)
        }
    }

    func testPermissionFailureCanResumeAfterReverification() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let victim = f.package.appendingPathComponent(f.paths.sorted()[0])
        XCTAssertEqual(chmod(victim.path, 0o400), 0)
        XCTAssertThrowsError(try release(f))
        XCTAssertEqual(chmod(victim.path, 0o600), 0)
        XCTAssertEqual(try release(f).logicalBytesReleased, 8192)
    }

    func testRestartRejectsReplacedFinalObjectEvenWithEqualBytes() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try ImageAllMigrationStagingCleanup.release(root: f.receiver, migrationID: f.migration,
            finalArchive: f.archive, validatePublication: {}, beforeRelease: { _ in throw ImageAllMigrationCleanupError.ioFailure }))
        let target = f.archive.appendingPathComponent(f.paths[0]), data = try Data(contentsOf: target)
        try FileManager.default.moveItem(at: target, to: f.root.appendingPathComponent("displaced-final"))
        try data.write(to: target)
        XCTAssertThrowsError(try release(f))
        for path in f.paths { XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent(path)).count, 4096) }
    }
}
