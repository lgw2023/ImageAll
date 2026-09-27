import Foundation
import Testing
@testable import ImageAllLocalLibrary

@Test func backupRestoresOfflineFactsAndFrozenDeliveryWithoutTouchingSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("live.sqlite"))
    try await store.observe([.init(localIdentifier: "hidden-later", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["hidden-later"]).first)
    let tag = try await store.createTag(name: "离线标签")
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
    try await store.setFavoriteTarget(assetID: asset.id, isFavorite: true)
    let frozen = try await store.prepareSharedSnapshot(visibleIdentifiers: ["hidden-later"])
    let pending = try await store.pendingSharedOperations().map(\.id)
    let report = try await store.exportBackup(to: root.appendingPathComponent("backup.sqlite"))
    #expect(report.assetCount == 1 && report.tagCount == 1 && report.pendingSharedCount == pending.count)
    #expect(report.byteCount > 0 && report.sha256.count == 64)
    #expect(!FileManager.default.fileExists(atPath: report.url.path + "-wal"))
    try await store.setDecision(assetID: asset.id, tagID: tag, decision: .rejected)
    let restoredURL = root.appendingPathComponent("independent/local.sqlite")
    try FileManager.default.createDirectory(at: restoredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: report.url, to: restoredURL)
    let restored = try LocalLibraryStore(url: restoredURL)
    let installID = try await store.installID(), epoch = try await store.sourceEpoch()
    #expect(try await restored.installID() == installID)
    #expect(try await restored.sourceEpoch() == epoch)
    #expect(try await restored.decisions(assetID: asset.id)[tag] == .accepted)
    #expect(try await restored.pendingSharedOperations().map(\.id) == pending)
    #expect(try await restored.pendingSharedSnapshot() == frozen)
    #expect(try await restored.assets(visibleIdentifiers: ["hidden-later"]).first?.favoriteTarget == true)
    #expect(try await store.decisions(assetID: asset.id)[tag] == .rejected)
    #expect(try LocalLibraryBackup.verify(at: report.url).sha256 == report.sha256)
    await #expect(throws: (any Error).self) { try await store.exportBackup(to: report.url) }
    #expect(try LocalLibraryBackup.verify(at: report.url).sha256 == report.sha256)
}

@Test func backupVerificationRejectsTruncatedCopyAndExistingSymlink() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("live.sqlite"))
    let damaged = root.appendingPathComponent("damaged.sqlite")
    try Data("SQLite format 3".utf8).write(to: damaged)
    #expect(throws: (any Error).self) { try LocalLibraryBackup.verify(at: damaged) }
    let link = root.appendingPathComponent("link.sqlite")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: damaged)
    await #expect(throws: (any Error).self) { try await store.exportBackup(to: link) }
    #expect(try Data(contentsOf: damaged) == Data("SQLite format 3".utf8))
}
