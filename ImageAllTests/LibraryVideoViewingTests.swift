import AppKit
@preconcurrency import AVFoundation
import Foundation
import GRDB
import XCTest
@testable import ImageAll

@MainActor
final class LibraryVideoViewingTests: XCTestCase {
    private var syntheticVideo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
    }

    func testSyntheticVideoLoadsSeeksAndReleasesOnceWhenClosed() async throws {
        let session = LibraryVideoViewingSession()
        let releases = ReleaseCount()
        let databaseURL = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: databaseURL)
        let ids = try CatalogQueryTestSupport.seedCatalogFixture(
            database: database, repository: CatalogRepository(database: database)
        )
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET media_kind = 'video', media_type = 'public.mpeg-4', duration_ms = 2000 WHERE id IN (?, ?)",
                           arguments: [ids.assetNewest.uuidString.lowercased(), ids.assetMiddle.uuidString.lowercased()])
        }
        let query = GRDBAssetCatalogQueryRepository(database: database)
        let first = try query.fetchInspectorDetail(assetID: ids.assetNewest)
        let photoBefore = try query.fetchInspectorDetail(assetID: ids.assetOldest)
        let identity = LibraryVideoViewingSession.Identity(assetID: first.assetID, revision: first.contentRevision)
        XCTAssertEqual(first.mediaKind, .video)
        await session.load(identity: identity) {
            LibraryVideoPlaybackResource(url: syntheticVideo) { releases.increment() }
        }
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.identity, identity)
        XCTAssertEqual(session.player.rate, 0, "Opening a viewer must not autoplay audio")
        session.setSpeed(1.5)
        XCTAssertEqual(session.player.defaultRate, 1.5)
        session.player.volume = 0.25
        XCTAssertEqual(session.player.volume, 0.25)
        let item = try XCTUnwrap(session.player.currentItem)
        for _ in 0..<200 where item.status == .unknown {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(item.status, .readyToPlay)
        let didSeek = await session.player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600),
                                               toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(didSeek)
        XCTAssertEqual(session.player.currentTime().seconds, 0.5, accuracy: 0.1)
        session.player.play()
        try await Task.sleep(for: .milliseconds(100))
        let tags = GRDBTagCatalogRepository(database: database)
        let tag = try tags.createTag(rawName: "合成视频观看标签", timestampMs: 2_000)
        _ = try tags.batchAccept(tagID: tag.id, assetIDs: [first.assetID], timestampMs: 2_001)
        let second = try query.fetchInspectorDetail(assetID: ids.assetMiddle)
        await session.load(identity: .init(assetID: second.assetID, revision: second.contentRevision)) {
            LibraryVideoPlaybackResource(url: syntheticVideo) { releases.increment() }
        }
        XCTAssertEqual(session.identity?.assetID, second.assetID)
        XCTAssertEqual(releases.value, 1)
        session.stop()
        session.stop()
        let reopened = try CatalogDatabase.open(at: databaseURL)
        let reopenedQuery = GRDBAssetCatalogQueryRepository(database: reopened)
        XCTAssertEqual(try reopenedQuery.fetchInspectorDetail(assetID: first.assetID)
            .tags.first(where: { $0.tagID == tag.id })?.decision, .accepted)
        let photoAfter = try reopenedQuery.fetchInspectorDetail(assetID: ids.assetOldest)
        XCTAssertEqual(photoAfter.acceptedTagCount, photoBefore.acceptedTagCount)
        XCTAssertEqual(photoAfter.tags.filter { $0.decision != .unknown },
                       photoBefore.tags.filter { $0.decision != .unknown })
        XCTAssertEqual(session.player.rate, 0)
        XCTAssertNil(session.player.currentItem)
        XCTAssertEqual(releases.value, 2)
        XCTAssertEqual(session.state, .idle)
    }

    func testLatePreparationCannotReplaceNewSelectionAndCancelledViewReleases() async throws {
        let session = LibraryVideoViewingSession()
        let first = LibraryVideoViewingSession.Identity(assetID: UUID(), revision: 1)
        let second = LibraryVideoViewingSession.Identity(assetID: UUID(), revision: 2)
        let releases = ReleaseCount()
        var pending: CheckedContinuation<LibraryVideoPlaybackResource, Never>?
        let firstTask = Task {
            await session.load(identity: first) {
                await withCheckedContinuation { pending = $0 }
            }
        }
        for _ in 0..<200 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        await session.load(identity: second) {
            LibraryVideoPlaybackResource(url: syntheticVideo) { releases.increment() }
        }
        continuation.resume(returning: LibraryVideoPlaybackResource(url: syntheticVideo) {
            releases.increment()
        })
        await firstTask.value
        XCTAssertEqual(session.identity, second)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(releases.value, 1)
        session.stop(ifMatching: first)
        XCTAssertEqual(session.identity, second, "Old view teardown must not stop the new video")
        session.stop(ifMatching: second)
        XCTAssertEqual(releases.value, 2)

        pending = nil
        let cancelled = Task {
            await session.load(identity: first) {
                await withCheckedContinuation { pending = $0 }
            }
        }
        for _ in 0..<200 where pending == nil { await Task.yield() }
        let cancelledContinuation = try XCTUnwrap(pending)
        cancelled.cancel()
        session.stop(ifMatching: first)
        cancelledContinuation.resume(returning: LibraryVideoPlaybackResource(url: syntheticVideo) {
            releases.increment()
        })
        await cancelled.value
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.player.currentItem)
        XCTAssertEqual(releases.value, 3)
    }

    func testCloudUnavailableAndCorruptVideoHaveVisibleFailureAndNoRetainedLease() async throws {
        let session = LibraryVideoViewingSession()
        let identity = LibraryVideoViewingSession.Identity(assetID: UUID(), revision: 1)
        await session.load(identity: identity) { throw PhotosLibraryError.cloudOnly }
        guard case let .failed(message) = session.state else { return XCTFail("Expected cloud failure") }
        XCTAssertTrue(message.contains("不会自动"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("broken.mov")
        try Data("not a video".utf8).write(to: corrupt)
        let releases = ReleaseCount()
        await session.load(identity: identity) {
            LibraryVideoPlaybackResource(url: corrupt) { releases.increment() }
        }
        guard case .failed = session.state else { return XCTFail("Expected decoder failure") }
        XCTAssertNil(session.player.currentItem)
        XCTAssertEqual(releases.value, 1)
    }
}

private final class ReleaseCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
