import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllMigrationExportCheckpointTests: XCTestCase {
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
