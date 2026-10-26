import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllMigrationExportCheckpointTests: XCTestCase {
    func testSealOnlyRequiresExistingExactScopeWithoutCreatingAnotherBatch() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let binding = Data("binding".utf8), scope = Data("retained scope".utf8)
        XCTAssertThrowsError(try ImageAllMigrationExportCheckpoint.streaming(parent: parent,
            binding: binding, scope: scope, requireExisting: true))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        let initial = try ImageAllMigrationExportCheckpoint.streaming(parent: parent, binding: binding, scope: scope)
        let id = initial.migrationID
        try initial.rememberStreamingScope(scope); initial.close()
        let resumed = try ImageAllMigrationExportCheckpoint.streaming(parent: parent,
            binding: Data("new observation".utf8), scope: scope, requireExisting: true)
        XCTAssertEqual(resumed.migrationID, id); resumed.close()
        XCTAssertThrowsError(try ImageAllMigrationExportCheckpoint.streaming(parent: parent,
            binding: binding, scope: Data("changed selection".utf8), requireExisting: true))
    }

    func testActiveScopeKeepsOriginalBatchAcrossMetadataDriftAndColdRestart() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let old = try ImageAllMigrationExportCheckpoint(parent: parent, binding: Data("old album metadata".utf8))
        let id = old.migrationID, root = old.root
        old.close()
        let scope = Data("exact selection, facts, source epoch and paired destination".utf8)
        let current = Data("updated album metadata".utf8)
        let recovered = try ImageAllMigrationExportCheckpoint.streaming(parent: parent, binding: current,
            scope: scope, legacyMigrationID: id)
        XCTAssertEqual(recovered.migrationID, id)
        XCTAssertFalse(recovered.matchesOriginalBinding(current))
        try recovered.rememberStreamingScope(scope)
        recovered.close()
        let cold = try ImageAllMigrationExportCheckpoint.streaming(parent: parent,
            binding: Data("another observation".utf8), scope: scope)
        XCTAssertEqual(cold.root, root)
        XCTAssertEqual(cold.migrationID, id)
        cold.close()
        XCTAssertThrowsError(try ImageAllMigrationExportCheckpoint.streaming(parent: parent,
            binding: current, scope: scope, legacyMigrationID: UUID()))
        let different = try ImageAllMigrationExportCheckpoint.streaming(parent: parent,
            binding: Data("other destination binding".utf8), scope: Data("other destination".utf8))
        XCTAssertNotEqual(different.migrationID, id)
        different.close()
    }

    func testLegacySourceValidationPersistsAndRejectsChangedBytesVersionsAndSymlinks() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let binding = Data("source binding".utf8)
        let first = try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding)
        let location = try first.resourceLocation(key: "asset|0", fileExtension: "jpg")
        let hash = String(repeating: "a", count: 64)
        let resource = ImageAllMigrationResource(id: location.id, role: "original", version: 1,
            uniformTypeIdentifier: "public.jpeg", required: true, status: .present,
            relativePath: location.relativePath, byteCount: 10, sha256: hash)
        let version = Data("current PhotoKit version".utf8)
        XCTAssertThrowsError(try first.recordStreamingSourceVerification(resource, version: version, byteCount: 10, sha256: hash))
        try first.recordVerifiedStreamingResource(resource, receipt: .init(migrationID: first.migrationID,
            deviceID: UUID(), resource: .init(relativePath: location.relativePath, byteCount: 10, sha256: hash)))
        XCTAssertFalse(try first.isStreamingSourceVerified(resource, version: version))
        XCTAssertThrowsError(try first.recordStreamingSourceVerification(resource, version: version, byteCount: 11, sha256: hash))
        XCTAssertThrowsError(try first.recordStreamingSourceVerification(resource, version: version, byteCount: 10, sha256: String(repeating: "b", count: 64)))
        try first.recordStreamingSourceVerification(resource, version: version, byteCount: 10, sha256: hash)
        first.close()
        let cold = try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding)
        defer { cold.close() }
        XCTAssertTrue(try cold.isStreamingSourceVerified(resource, version: version))
        XCTAssertFalse(try cold.isStreamingSourceVerified(resource, version: Data("changed source".utf8)))
        let record = cold.root.appendingPathComponent("source-verified-\(resource.id.uuidString.lowercased()).json")
        let sentinel = parent.appendingPathComponent("sentinel")
        try Data([7]).write(to: sentinel)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: sentinel)
        XCTAssertThrowsError(try cold.isStreamingSourceVerified(resource, version: version))
        XCTAssertThrowsError(try cold.recordStreamingSourceVerification(resource, version: version, byteCount: 10, sha256: hash))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([7]))
    }

    func testInterruptedResourcesReopenAndPublishedArchiveIsNeverReused() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let binding = Data("synthetic scope and source versions".utf8)
        let first = try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding)
        let location = try first.resourceLocation(key: "asset-1|0", fileExtension: "jpg")
        try Data("complete synthetic resource".utf8).write(to: location.url)
        XCTAssertThrowsError(try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding))
        let id = first.migrationID
        first.close()
        let resumed = try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding)
        XCTAssertEqual(resumed.migrationID, id)
        let cached = try resumed.resourceLocation(key: "asset-1|0", fileExtension: "jpg")
        XCTAssertEqual(cached.url, location.url)
        XCTAssertEqual(try Data(contentsOf: cached.url), Data("complete synthetic resource".utf8))
        let manifest = resumed.root.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        try Data("partial manifest".utf8).write(to: manifest)
        try resumed.removeUnpublishedManifest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        let changed = try ImageAllMigrationExportCheckpoint(parent: parent, binding: Data("different source version".utf8))
        XCTAssertNotEqual(changed.root, resumed.root)
        changed.close()
        let published = parent.appendingPathComponent("\(id.uuidString).imageallarchive")
        try FileManager.default.moveItem(at: resumed.root, to: published)
        resumed.close()
        let next = try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding)
        defer { next.close() }
        XCTAssertNotEqual(next.migrationID, id)
        let fresh = try next.resourceLocation(key: "asset-1|0", fileExtension: "jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.url.path))
        XCTAssertEqual(try Data(contentsOf: published.appendingPathComponent(location.relativePath)), Data("complete synthetic resource".utf8))
    }

    func testStreamingContextSurvivesRetryWhileOnlyOwnedResourceWindowIsReset() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let binding = Data("source scope plus paired destination".utf8)
        let first = try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding)
        let frozen = Data("first immutable planning snapshot".utf8)
        XCTAssertEqual(try first.frozenContext(frozen), frozen)
        let resource = try first.resourceLocation(key: "asset|0", fileExtension: "bin")
        try Data([1, 2, 3]).write(to: resource.url)
        let id = first.migrationID
        first.close()
        let retry = try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding)
        defer { retry.close() }
        XCTAssertEqual(retry.migrationID, id)
        XCTAssertEqual(try retry.frozenContext(Data("new facts must not rewrite old manifest".utf8)), frozen)
        try retry.resetStreamingResourceWindow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path))
        XCTAssertEqual(try retry.frozenContext(Data([4])), frozen)
        let sentinel = parent.appendingPathComponent("original.bin")
        try Data([5, 6]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: resource.url, withDestinationURL: sentinel)
        XCTAssertThrowsError(try retry.resetStreamingResourceWindow())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([5, 6]))
        let context = retry.root.appendingPathComponent("stream-context.json")
        try FileManager.default.removeItem(at: context)
        try FileManager.default.createSymbolicLink(at: context, withDestinationURL: sentinel)
        XCTAssertThrowsError(try retry.frozenContext(Data([7])))
        XCTAssertThrowsError(try retry.resetStreamingResourceWindow())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([5, 6]))
    }

    func testPendingWindowUsesPackageIdentityAcrossParentAliasesAndPreservesBytes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let actualParent = base.appendingPathComponent("actual", isDirectory: true)
        let aliasParent = base.appendingPathComponent("container-alias", isDirectory: true)
        let actual = actualParent.appendingPathComponent("container", isDirectory: true)
        let alias = aliasParent.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: actualParent)
        let binding = Data("unchanged selected source versions".utf8)
        let first = try ImageAllMigrationExportCheckpoint(parent: alias, binding: binding)
        _ = try first.frozenContext(Data("frozen source scope".utf8))
        let resource = try first.resourceLocation(key: "selected-asset|0", fileExtension: "jpg")
        let payload = Data([1, 2, 3, 4])
        try payload.write(to: resource.url)
        let id = first.migrationID
        first.close()
        let retry = try ImageAllMigrationExportCheckpoint(parent: actual, binding: binding)
        defer { retry.close() }
        XCTAssertEqual(retry.migrationID, id)
        XCTAssertEqual(try retry.streamingResourceWindowRelativePaths(), [resource.relativePath])
        let same = try retry.resourceLocation(key: "selected-asset|0", fileExtension: "jpg")
        XCTAssertTrue(try retry.streamingResourceWindowRelativePaths().contains(same.relativePath))
        let changed = try retry.resourceLocation(key: "different-asset|0", fileExtension: "jpg")
        XCTAssertFalse(try retry.streamingResourceWindowRelativePaths().contains(changed.relativePath))
        XCTAssertEqual(try Data(contentsOf: resource.url), payload)
        let sentinel = base.appendingPathComponent("source-original.jpg")
        try payload.write(to: sentinel)
        try retry.resetStreamingResourceWindow()
        XCTAssertTrue(try retry.streamingResourceWindowRelativePaths().isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), payload)
    }

    func testVerifiedResourceSurvivesRestartAndRejectsChangedReceiptAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = Data("same scope source version and destination".utf8)
        let first = try ImageAllMigrationExportCheckpoint(parent: root, binding: binding)
        let location = try first.resourceLocation(key: "asset|0", fileExtension: "jpg")
        let resource = ImageAllMigrationResource(id: location.id, role: "original", version: 1,
            uniformTypeIdentifier: "public.jpeg", required: true, status: .present,
            relativePath: location.relativePath, byteCount: 10, sha256: String(repeating: "a", count: 64))
        let receipt = ImageAllMigrationResourceVerificationReceipt(migrationID: first.migrationID, deviceID: UUID(),
            resource: .init(relativePath: location.relativePath, byteCount: 10, sha256: resource.sha256!))
        try first.recordVerifiedStreamingResource(resource, receipt: receipt)
        let id = first.migrationID
        first.close()
        let reopened = try ImageAllMigrationExportCheckpoint(parent: root, binding: binding)
        defer { reopened.close() }
        XCTAssertEqual(reopened.migrationID, id)
        XCTAssertEqual(try reopened.verifiedStreamingResource(id: resource.id), resource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url.path), "receipt recovery must not need old source scratch")
        let bad = ImageAllMigrationResourceVerificationReceipt(migrationID: id, deviceID: receipt.deviceID,
            resource: .init(relativePath: location.relativePath, byteCount: 11, sha256: resource.sha256!))
        XCTAssertThrowsError(try reopened.recordVerifiedStreamingResource(resource, receipt: bad))
        let changed = try ImageAllMigrationExportCheckpoint(parent: root, binding: Data("different source version".utf8))
        defer { changed.close() }
        XCTAssertNil(try changed.verifiedStreamingResource(id: resource.id))
        let saved = reopened.root.appendingPathComponent("verified-" + resource.id.uuidString.lowercased() + ".json")
        let sentinel = root.appendingPathComponent("unrelated")
        try Data([1, 2, 3]).write(to: sentinel)
        try FileManager.default.removeItem(at: saved)
        try FileManager.default.createSymbolicLink(at: saved, withDestinationURL: sentinel)
        XCTAssertThrowsError(try reopened.verifiedStreamingResource(id: resource.id))
        XCTAssertThrowsError(try reopened.recordVerifiedStreamingResource(resource, receipt: receipt))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([1, 2, 3]))
    }

    func testCheckpointRejectsResourceAndManifestSymlinks() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let checkpoint = try ImageAllMigrationExportCheckpoint(parent: parent, binding: Data("synthetic".utf8))
        defer { checkpoint.close() }
        let outside = parent.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: checkpoint.root.appendingPathComponent("resources"), withDestinationURL: outside)
        XCTAssertThrowsError(try checkpoint.resourceLocation(key: "asset", fileExtension: "jpg"))
        try FileManager.default.createSymbolicLink(at: checkpoint.root.appendingPathComponent(ImageAllMigrationArchive.manifestFilename), withDestinationURL: sentinel)
        XCTAssertThrowsError(try checkpoint.removeUnpublishedManifest())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
}
