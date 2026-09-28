import AppKit
@preconcurrency import AVFoundation
import Foundation
import GRDB
import XCTest
import SwiftUI
@testable import ImageAll

@MainActor
final class LibraryVideoViewingTests: XCTestCase {
    private var syntheticVideo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
    }

    func testInteractiveNativeVideoViewerWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["IMAGEALL_INTERACTIVE_VIDEO_EVIDENCE"] else {
            throw XCTSkip("Explicit synthetic interactive verification only")
        }
        let evidence = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let withAudio = ProcessInfo.processInfo.environment["IMAGEALL_INTERACTIVE_VIDEO_WITH_AUDIO"] == "1"
        let source = withAudio ? evidence.appendingPathComponent("synthetic-audio.mp4") : syntheticVideo
        if withAudio {
            let tracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
            XCTAssertFalse(tracks.isEmpty)
        }
        let sourceID = UUID(), assetID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Synthetic only", state: .active),
            reconciledItems: [], startsConnected: true)
        let model = LibraryWorkspaceModel(service: service,
            videoPlaybackProvider: InteractiveSyntheticVideoProvider(url: source),
            idlePrewarmInstallEventMonitor: false)
        let host = NSHostingView(rootView: LibraryVideoViewer(assetID: assetID, contentRevision: 1, model: model)
            .frame(width: 960, height: 640).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ImageAll Synthetic Video Verification"
        window.contentView = host
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { model.videoViewingSession.stop(); window.close() }
        var samples: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(300)
        let finish = evidence.appendingPathComponent("finish")
        while Date() < deadline, !FileManager.default.fileExists(atPath: finish.path) {
            let session = model.videoViewingSession
            samples.append(["elapsed": 300 - deadline.timeIntervalSinceNow,
                "state": String(describing: session.state), "speed": session.speed,
                "rate": session.player.rate, "volume": session.player.volume,
                "muted": session.player.isMuted, "hasItem": session.player.currentItem != nil,
                "time": session.player.currentTime().seconds.isFinite ? session.player.currentTime().seconds : -1])
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("player-observations.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: finish.path), "Interactive verification timed out")
        XCTAssertTrue(samples.contains { ($0["rate"] as? Float ?? 0) > 0 })
        XCTAssertTrue(samples.contains { ($0["speed"] as? Float) == 1.5 })
        XCTAssertTrue(samples.contains { ($0["time"] as? Double ?? 0) > 0.4 })
        if withAudio {
            XCTAssertTrue(samples.contains { ($0["volume"] as? Float ?? 1) > 0 && ($0["volume"] as? Float ?? 1) < 0.8 })
            XCTAssertTrue(samples.contains { ($0["muted"] as? Bool) == true || ($0["volume"] as? Float) == 0 })
        }
        if ProcessInfo.processInfo.environment["IMAGEALL_INTERACTIVE_VIDEO_REQUIRE_FOCUS"] == "1" {
            let firstReady = try XCTUnwrap(samples.firstIndex { ($0["state"] as? String) == "ready" })
            let stopped = try XCTUnwrap(samples.indices.first { $0 > firstReady && (samples[$0]["state"] as? String) == "idle" })
            XCTAssertEqual(samples[stopped]["rate"] as? Float, 0)
            XCTAssertEqual(samples[stopped]["hasItem"] as? Bool, false)
            XCTAssertTrue(samples.indices.contains { $0 > stopped && (samples[$0]["state"] as? String) == "ready"
                && (samples[$0]["rate"] as? Float) == 0 })
        }
        model.videoViewingSession.stop()
        XCTAssertNil(model.videoViewingSession.player.currentItem)
        XCTAssertEqual(model.videoViewingSession.player.rate, 0)
    }

    func testHostedViewerReleasesOnResignAndReloadsPausedOnBecomeActive() async throws {
        let sourceID = UUID(), assetID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Synthetic only", state: .active),
            reconciledItems: [], startsConnected: true)
        let model = LibraryWorkspaceModel(service: service,
            videoPlaybackProvider: InteractiveSyntheticVideoProvider(url: syntheticVideo),
            idlePrewarmInstallEventMonitor: false)
        let host = NSHostingView(rootView: LibraryVideoViewer(assetID: assetID, contentRevision: 1, model: model)
            .frame(width: 960, height: 640))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { model.videoViewingSession.stop(); window.close() }
        host.layoutSubtreeIfNeeded()
        let session = model.videoViewingSession
        for _ in 0..<100 where session.state != .ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(session.state, .ready)
        let originalItem = try XCTUnwrap(session.player.currentItem)
        session.player.play()
        for _ in 0..<100 where session.player.rate == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(session.player.rate, 0)

        // Exercise the production view's subscriptions without claiming an OS focus switch.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        for _ in 0..<100 where session.state != .idle { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.player.rate, 0)
        XCTAssertNil(session.player.currentItem)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        for _ in 0..<100 where session.state != .ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(session.state, .ready)
        XCTAssertNotNil(session.player.currentItem)
        XCTAssertFalse(session.player.currentItem === originalItem)
        XCTAssertEqual(session.player.rate, 0, "Returning to the app must not automatically resume audio")
    }

    func testFrozenPredictionEvidenceStripRendersPresentAndMissingFrames() async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: syntheticVideo))
        generator.appliesPreferredTrackTransform = true
        let cgImage = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [:]))
        let snapshot = VideoPredictionEvidenceReader.Snapshot(modelRevision: 7,
            frames: [.init(actualTimeMs: 500, jpegBytes: jpeg), .init(actualTimeMs: 750, jpegBytes: nil)])
        let host = NSHostingView(rootView: VideoPredictionEvidenceStrip(snapshot: snapshot, seek: { _ in })
            .frame(width: 720, height: 190).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 190)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "video-frozen-review-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["IMAGEALL_VIDEO_EVIDENCE_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent("video-frozen-review-evidence.png"))
        }
    }

    func testStoryVideoClipPersistsAndValidatesHalfOpenRangeAndGain() throws {
        let clip = TimeStoryVideoClip(inPointMs: 101, outPointMs: 901, sourceDurationMs: 1000)
        let decoded = try JSONDecoder().decode(TimeStoryVideoClip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(decoded, clip)
        let range = try decoded.validatedFrameRange(actualDurationMs: 1000)
        XCTAssertEqual(range.startFrame, 4)
        XCTAssertEqual(range.endFrame, 27)
        XCTAssertEqual(range.frameCount, 23)
        XCTAssertThrowsError(try clip.validatedFrameRange(actualDurationMs: 999))
        for (start, end, gain) in [(0, 0, 1.0), (-1, 500, 1), (0, 1001, 1),
                                    (10, 20, 1), (0, 500, -0.1), (0, 500, 1.1), (0, 500, Double.nan)] {
            XCTAssertThrowsError(try TimeStoryVideoClip(inPointMs: Int64(start), outPointMs: Int64(end),
                sourceDurationMs: 1000, originalAudioGain: gain).validatedFrameRange(actualDurationMs: 1000))
        }
        XCTAssertNoThrow(try TimeStoryVideoClip(inPointMs: 0, outPointMs: 1000,
            sourceDurationMs: 1000, originalAudioGain: 0).validatedFrameRange(actualDurationMs: 1000))
        let legacy = Data("{\"id\":\"00000000-0000-4000-8000-000000000001\",\"assetID\":\"00000000-0000-4000-8000-000000000002\",\"contentRevision\":1,\"chapterID\":\"00000000-0000-4000-8000-000000000003\",\"caption\":\"\",\"durationSeconds\":3.5,\"presentationMode\":\"aspectFitBlack\",\"reasons\":[],\"isLocked\":false,\"isUserEdited\":false}".utf8)
        var shot = try JSONDecoder().decode(TimeStoryShot.self, from: legacy)
        XCTAssertNil(shot.videoClip)
        shot.videoClip = clip
        XCTAssertEqual(try JSONDecoder().decode(TimeStoryShot.self, from: JSONEncoder().encode(shot)).videoClip, clip)
    }

    func testPhotosAnalysisWaitIsCancellableAndCompletionIsOneShot() throws {
        let cancelled = PhotosVideoAnalysisRequestState()
        XCTAssertThrowsError(try cancelled.wait(checkCancellation: { throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let completed = PhotosVideoAnalysisRequestState()
        completed.complete(.success(AVURLAsset(url: syntheticVideo)))
        completed.complete(.failure(PhotosLibraryError.cloudOnly))
        let resource = try completed.wait(checkCancellation: {})
        XCTAssertEqual(try PhotoKitPhotosLibraryAdapter.localOriginalVideoURL(resource), syntheticVideo)
        XCTAssertThrowsError(try PhotosVideoAnalysisRequestState().wait(timeout: 0, checkCancellation: {}))
        XCTAssertFalse(PhotoKitPhotosLibraryAdapter.makeLocalOnlyOriginalVideoRequestOptions().isNetworkAccessAllowed)
        XCTAssertThrowsError(try PhotoKitPhotosLibraryAdapter.localOriginalVideoURL(AVMutableComposition()))
    }

    func testAnalysisEvidenceTimeSeeksOnlyMatchingReadyVideo() async throws {
        let session = LibraryVideoViewingSession()
        let identity = LibraryVideoViewingSession.Identity(assetID: UUID(), revision: 1)
        await session.load(identity: identity) { LibraryVideoPlaybackResource(url: self.syntheticVideo) {} }
        let success = await session.seekToAnalysisTime(500, expected: identity)
        XCTAssertTrue(success)
        XCTAssertEqual(session.player.currentTime().seconds, 0.5, accuracy: 0.04)
        XCTAssertEqual(session.player.rate, 0)
        let wrong = await session.seekToAnalysisTime(500, expected: .init(assetID: UUID(), revision: 1))
        XCTAssertFalse(wrong)
        let beyond = await session.seekToAnalysisTime(99_000, expected: identity)
        XCTAssertFalse(beyond)
        session.stop()
        let stopped = await session.seekToAnalysisTime(500, expected: identity)
        XCTAssertFalse(stopped)
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
            LibraryVideoPlaybackResource(url: self.syntheticVideo) { releases.increment() }
        }
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.identity, identity)
        XCTAssertTrue(session.technicalMetadataLoadFinished)
        let metadata = try XCTUnwrap(session.technicalMetadata)
        XCTAssertEqual(metadata.codec, "avc1")
        XCTAssertGreaterThan(try XCTUnwrap(metadata.nominalFrameRate), 0)
        XCTAssertGreaterThan(try XCTUnwrap(metadata.estimatedDataRate), 0)
        XCTAssertEqual(metadata.audioTrackCount, 0)

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
            LibraryVideoPlaybackResource(url: self.syntheticVideo) { releases.increment() }
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
        XCTAssertNil(session.technicalMetadata)
        XCTAssertFalse(session.technicalMetadataLoadFinished)
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
            LibraryVideoPlaybackResource(url: self.syntheticVideo) { releases.increment() }
        }
        continuation.resume(returning: LibraryVideoPlaybackResource(url: self.syntheticVideo) {
            releases.increment()
        })
        await firstTask.value
        XCTAssertEqual(session.identity, second)
        XCTAssertEqual(session.technicalMetadata?.codec, "avc1")
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
        cancelledContinuation.resume(returning: LibraryVideoPlaybackResource(url: self.syntheticVideo) {
            releases.increment()
        })
        await cancelled.value
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.player.currentItem)
        XCTAssertEqual(releases.value, 3)
    }

    func testPlaybackObservationsPersistForCurrentPhotoKitRevisionAndReachInspector() async throws {
        let (database, query) = try CatalogQueryTestSupport.openGalleryOverviewDatabase()
        let assetID = UUID(uuidString: "42000000-0000-4000-8000-000000000006")!
        let before = try query.fetchInspectorDetail(assetID: assetID)
        XCTAssertNil(before.videoTechnicalMetadata)
        let session = LibraryVideoViewingSession()
        var persisted = false
        await session.load(identity: .init(assetID: assetID, revision: before.contentRevision),
                           onTechnicalMetadata: { metadata in
            persisted = (try? query.recordPhotoKitVideoTechnicalMetadata(
                assetID: assetID, expectedRevision: before.contentRevision, metadata: metadata, timestampMs: 10
            )) == true
        }) {
            LibraryVideoPlaybackResource(url: self.syntheticVideo)
        }
        XCTAssertTrue(persisted)
        let after = try query.fetchInspectorDetail(assetID: assetID)
        XCTAssertEqual(after.videoTechnicalMetadata, session.technicalMetadata)
        XCTAssertEqual(after.contentRevision, before.contentRevision)
        XCTAssertEqual(after.tags, before.tags)
        let oldObservation = try XCTUnwrap(session.technicalMetadata)
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET content_revision = content_revision + 1, video_technical_metadata_json = NULL WHERE id = ?",
                           arguments: [assetID.uuidString.lowercased()])
        }
        XCTAssertFalse(try query.recordPhotoKitVideoTechnicalMetadata(
            assetID: assetID, expectedRevision: before.contentRevision, metadata: oldObservation, timestampMs: 11
        ))
        XCTAssertNil(try query.fetchInspectorDetail(assetID: assetID).videoTechnicalMetadata)
        let photoID = UUID(uuidString: "42000000-0000-4000-8000-000000000002")!
        XCTAssertFalse(try query.recordPhotoKitVideoTechnicalMetadata(
            assetID: photoID, expectedRevision: 1, metadata: oldObservation, timestampMs: 11
        ))
        XCTAssertNil(try query.fetchInspectorDetail(assetID: photoID).videoTechnicalMetadata)
        session.stop()
    }

    func testCloudVideoProviderRequiresCurrentPhotoKitRevisionAndRejectsLateChanges() async throws {
        let (database, query) = try CatalogQueryTestSupport.openGalleryOverviewDatabase()
        let assetID = UUID(uuidString: "42000000-0000-4000-8000-000000000006")!
        let detail = try query.fetchInspectorDetail(assetID: assetID)
        let (authorization, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database, picker: FolderAuthorizationTestSupport.FakeDirectoryPicker()
        )
        let fake = CloudVideoPhotosFake(url: syntheticVideo)
        let provider = AppKitLibraryVideoPlaybackProvider(
            database: database, folderAuthorization: authorization, photosLibrary: fake
        )
        do {
            _ = try await provider.prepareVideoPlayback(assetID: assetID)
            XCTFail("Local playback must not acquire a cloud original")
        } catch { XCTAssertEqual(error as? PhotosLibraryError, .cloudOnly) }
        let beforeCount = await fake.downloadCount
        XCTAssertEqual(beforeCount, 0)
        let resource = try await provider.downloadCloudVideoForPlayback(
            assetID: assetID, expectedRevision: detail.contentRevision, grant: .issue(), onProgress: { _ in }
        )
        XCTAssertEqual(resource.url, syntheticVideo)
        resource.release()
        let afterCount = await fake.downloadCount
        XCTAssertEqual(afterCount, 1)
        do {
            _ = try await provider.downloadCloudVideoForPlayback(
                assetID: assetID, expectedRevision: detail.contentRevision + 1, grant: .issue(), onProgress: { _ in }
            )
            XCTFail("Stale client revision must not start a download")
        } catch { XCTAssertEqual(error as? LibraryOriginalAssetOpenError, .unavailable) }
        let rejectedCount = await fake.downloadCount
        XCTAssertEqual(rejectedCount, 1)
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE source SET state = 'disabled' WHERE id = ?",
                           arguments: [detail.sourceID.uuidString.lowercased()])
        }
        do {
            _ = try await provider.downloadCloudVideoForPlayback(
                assetID: assetID, expectedRevision: detail.contentRevision, grant: .issue(), onProgress: { _ in }
            )
            XCTFail("Disabled sources must not download")
        } catch { XCTAssertEqual(error as? LibraryOriginalAssetOpenError, .unavailable) }
        let disabledCount = await fake.downloadCount
        XCTAssertEqual(disabledCount, 1)
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE source SET state = 'active' WHERE id = ?",
                           arguments: [detail.sourceID.uuidString.lowercased()])
        }

        let changed = CloudVideoPhotosFake(url: syntheticVideo) {
            try await database.pool.write { db in
                try db.execute(sql: "UPDATE asset SET content_revision = content_revision + 1 WHERE id = ?",
                               arguments: [assetID.uuidString.lowercased()])
            }
        }
        let changingProvider = AppKitLibraryVideoPlaybackProvider(
            database: database, folderAuthorization: authorization, photosLibrary: changed
        )
        do {
            _ = try await changingProvider.downloadCloudVideoForPlayback(
                assetID: assetID, expectedRevision: detail.contentRevision, grant: .issue(), onProgress: { _ in }
            )
            XCTFail("A changed asset must not attach the old downloaded resource")
        } catch { XCTAssertEqual(error as? LibraryOriginalAssetOpenError, .unavailable) }
    }

    func testExplicitCloudVideoProgressCancellationAndRetryStayRequestScoped() async throws {
        let session = LibraryVideoViewingSession()
        let identity = LibraryVideoViewingSession.Identity(assetID: UUID(), revision: 3)
        await session.load(identity: identity) { throw PhotosLibraryError.cloudOnly }
        XCTAssertTrue(session.canRequestCloudDownload)
        XCTAssertNil(session.cloudDownloadProgress)
        let request = UUID()
        var started = false
        var cancelled = false
        let download = Task {
            await session.load(identity: identity, cloudDownloadRequestID: request) {
                started = true
                session.reportCloudProgress(0.4, request: request)
                session.reportCloudProgress(0.1, request: request)
                session.reportCloudProgress(0.9, request: UUID())
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled = error is CancellationError; throw error }
                return LibraryVideoPlaybackResource(url: self.syntheticVideo)
            }
        }
        for _ in 0..<200 where !started { await Task.yield() }
        XCTAssertTrue(started)
        XCTAssertEqual(session.cloudDownloadProgress, 0.4)
        session.stop(ifMatching: identity)
        await download.value
        XCTAssertTrue(cancelled, "Closing/backgrounding must cancel the pending PhotoKit preparation")
        XCTAssertNil(session.cloudDownloadProgress)
        XCTAssertFalse(session.canRequestCloudDownload)
        XCTAssertEqual(session.state, .idle)
        let retry = UUID()
        await session.load(identity: identity, cloudDownloadRequestID: retry) {
            session.reportCloudProgress(1, request: retry)
            return LibraryVideoPlaybackResource(url: self.syntheticVideo)
        }
        session.reportCloudProgress(0.8, request: request)
        XCTAssertEqual(session.state, .ready)
        XCTAssertNil(session.cloudDownloadProgress)
        XCTAssertEqual(session.player.rate, 0)
        session.stop()
    }

    func testCloudUnavailableAndCorruptVideoHaveVisibleFailureAndNoRetainedLease() async throws {
        let session = LibraryVideoViewingSession()
        let identity = LibraryVideoViewingSession.Identity(assetID: UUID(), revision: 1)
        await session.load(identity: identity) { throw PhotosLibraryError.cloudOnly }
        guard case let .failed(message) = session.state else { return XCTFail("Expected cloud failure") }
        XCTAssertTrue(message.contains("不会自动"))
        await session.load(identity: identity, cloudDownloadRequestID: UUID()) {
            throw PhotosVideoResourceError.insufficientSpace
        }
        guard case let .failed(spaceMessage) = session.state else { return XCTFail("Expected disk-full failure") }
        XCTAssertTrue(spaceMessage.contains("空间不足"))
        XCTAssertTrue(session.canRequestCloudDownload)
        await session.load(identity: identity, cloudDownloadRequestID: UUID()) {
            throw PhotosVideoResourceError.unsupportedAssetRepresentation
        }
        guard case let .failed(compositionMessage) = session.state else { return XCTFail("Expected composition boundary") }
        XCTAssertTrue(compositionMessage.contains("编辑合成资源"))
        XCTAssertFalse(session.canRequestCloudDownload)

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

private actor CloudVideoPhotosFake: PhotosVideoResourcePort {
    let url: URL
    let beforeReturn: @Sendable () async throws -> Void
    private(set) var downloadCount = 0

    init(url: URL, beforeReturn: @escaping @Sendable () async throws -> Void = {}) {
        self.url = url
        self.beforeReturn = beforeReturn
    }

    func requestOriginalVideoURL(localIdentifier: String) async throws -> URL {
        throw PhotosLibraryError.cloudOnly
    }

    func requestCloudOriginalVideoURL(
        localIdentifier: String, grant: PhotosCloudDownloadGrant,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        downloadCount += 1
        onProgress(0.5)
        try await beforeReturn()
        onProgress(1)
        return url
    }
}

private struct InteractiveSyntheticVideoProvider: LibraryVideoPlaybackProviding {
    let url: URL
    func prepareVideoPlayback(assetID: UUID) async throws -> LibraryVideoPlaybackResource {
        LibraryVideoPlaybackResource(url: url)
    }
}
